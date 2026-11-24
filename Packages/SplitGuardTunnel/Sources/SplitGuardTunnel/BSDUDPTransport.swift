// SPDX-License-Identifier: MIT

import Darwin
import Dispatch
import Foundation
import WireGuardEngine

public final class BSDUDPTransport: UDPTransport, @unchecked Sendable {
    public typealias SocketOpener = (Int32, inout UInt16) throws -> Int32?
    public typealias InterfaceSocketOpener = (Int32, inout UInt16, UInt32?) throws -> Int32?

    private let queue = DispatchQueue(label: "SplitGuard.UDP.receive", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let socketLock = NSLock()
    private let openSocket: InterfaceSocketOpener
    private var ipv4: SocketRegistration?
    private var ipv6: SocketRegistration?

    public init(openSocket: @escaping InterfaceSocketOpener = { try BSDUDPTransport.open(family: $0, port: &$1, interfaceIndex: $2) }) {
        self.openSocket = openSocket
        queue.setSpecific(key: queueKey, value: 1)
    }

    public convenience init(openSocket: @escaping SocketOpener) {
        self.init(openSocket: { family, port, _ in try openSocket(family, &port) })
    }

    deinit { unbind() }

    public func bind(port requestedPort: UInt16, receive: @escaping (Data, IPEndpoint) -> Bool) throws -> UInt16 {
        try bind(port: requestedPort, interfaceIndex: nil, receive: receive)
    }

    public func bind(
        port requestedPort: UInt16,
        interfaceIndex: UInt32?,
        receive: @escaping (Data, IPEndpoint) -> Bool
    ) throws -> UInt16 {
        try socketLock.withLock {
            guard ipv4 == nil, ipv6 == nil else { throw UDPFailure(EALREADY) }

            // The IPv4 kernel allocation can collide with an existing IPv6-only socket.
            for attempt in 0...100 {
                var port = requestedPort
                let fd4 = try openSocket(AF_INET, &port, interfaceIndex)
                let fd6: Int32?
                do {
                    fd6 = try openSocket(AF_INET6, &port, interfaceIndex)
                } catch {
                    if let fd4 { Darwin.close(fd4) }
                    if requestedPort == 0, attempt < 100, (error as? UDPFailure)?.code == EADDRINUSE {
                        continue
                    }
                    throw error
                }
                guard fd4 != nil || fd6 != nil else { throw UDPFailure(EAFNOSUPPORT) }
                ipv4 = fd4.map { SocketRegistration(fd: $0, queue: queue, receive: receive) }
                ipv6 = fd6.map { SocketRegistration(fd: $0, queue: queue, receive: receive) }
                return port
            }
            throw UDPFailure(EADDRINUSE)
        }
    }

    public func unbind() {
        let registrations: [SocketRegistration] = socketLock.withLock {
            let active = [ipv4, ipv6].compactMap { $0 }
            ipv4 = nil
            ipv6 = nil
            return active
        }
        for registration in registrations { registration.cancel() }
        // Engine receives only attempt admission. A device's last reference can
        // nevertheless be released on this queue from inside the receive callback.
        if DispatchQueue.getSpecific(key: queueKey) == nil {
            for registration in registrations { registration.waitForClose() }
        }
    }

    public func send(_ datagram: Data, to destination: IPEndpoint) throws {
        guard datagram.count <= WireGuardDevice.maxSegmentSize else { throw UDPFailure(EMSGSIZE) }
        try socketLock.withLock {
            let registration = destination.address.isIPv6 ? ipv6 : ipv4
            guard let registration else { throw UDPFailure(EAFNOSUPPORT) }
            try SocketAddress.withAddress(destination) { address, length in
                let count = datagram.withUnsafeBytes {
                    sendto(registration.fd, $0.baseAddress, $0.count, 0, address, length)
                }
                guard count == datagram.count else { throw UDPFailure(count < 0 ? errno : EIO) }
            }
        }
    }

    public static func open(family: Int32, port: inout UInt16, interfaceIndex: UInt32? = nil) throws -> Int32? {
        let fd = socket(family, SOCK_DGRAM, IPPROTO_UDP)
        if fd < 0 {
            let code = errno
            if code == EAFNOSUPPORT || code == EPROTONOSUPPORT || code == EPFNOSUPPORT { return nil }
            throw UDPFailure(code)
        }
        do {
            guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1,
                  fcntl(fd, F_SETFD, FD_CLOEXEC) != -1 else { throw UDPFailure(errno) }
            if family == AF_INET6 {
                var enabled: Int32 = 1
                guard setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
                else { throw UDPFailure(errno) }
            }
            if let interfaceIndex, interfaceIndex != 0 {
                var index = interfaceIndex
                let level = family == AF_INET6 ? IPPROTO_IPV6 : IPPROTO_IP
                let option = family == AF_INET6 ? IPV6_BOUND_IF : IP_BOUND_IF
                guard setsockopt(fd, level, option, &index, socklen_t(MemoryLayout<UInt32>.size)) == 0
                else { throw UDPFailure(errno) }
            }
            let wildcard = WireGuardEngine.IPAddress(family == AF_INET6 ? "::" : "0.0.0.0")!
            try SocketAddress.withAddress(IPEndpoint(address: wildcard, port: port)) { address, length in
                guard Darwin.bind(fd, address, length) == 0 else { throw UDPFailure(errno) }
            }
            if port == 0 {
                var storage = sockaddr_storage()
                var length = socklen_t(MemoryLayout.size(ofValue: storage))
                let result = withUnsafeMutablePointer(to: &storage) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
                }
                guard result == 0 else { throw UDPFailure(errno) }
                guard let local = SocketAddress.endpoint(storage, length: length) else { throw UDPFailure(EINVAL) }
                port = local.port
            }
            return fd
        } catch {
            Darwin.close(fd)
            if (error as? UDPFailure)?.code == EAFNOSUPPORT { return nil }
            throw error
        }
    }
}

private final class SocketRegistration: @unchecked Sendable {
    let fd: Int32
    private let source: DispatchSourceRead
    private let closed = DispatchGroup()
    private let receive: (Data, IPEndpoint) -> Bool
    private var buffer = [UInt8](repeating: 0, count: WireGuardDevice.maxSegmentSize)

    init(fd: Int32, queue: DispatchQueue, receive: @escaping (Data, IPEndpoint) -> Bool) {
        self.fd = fd
        self.receive = receive
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        closed.enter()
        let group = closed
        source.setCancelHandler {
            Darwin.close(fd)
            group.leave()
        }
        source.activate()
    }

    func cancel() { source.cancel() }
    func waitForClose() { closed.wait() }

    private func drain() {
        // Readiness remains armed for unread datagrams. A fixed batch lets the other
        // socket and cancellation handlers run even while this socket is busy.
        for _ in 0..<32 {
            guard !source.isCancelled else { return }
            var peer = sockaddr_storage()
            var header = msghdr()
            let count = buffer.withUnsafeMutableBytes { bytes in
                var vector = iovec(iov_base: bytes.baseAddress, iov_len: bytes.count)
                return withUnsafeMutablePointer(to: &vector) { vector in
                    withUnsafeMutablePointer(to: &peer) { peer in
                        header.msg_name = UnsafeMutableRawPointer(peer)
                        header.msg_namelen = socklen_t(MemoryLayout<sockaddr_storage>.size)
                        header.msg_iov = vector
                        header.msg_iovlen = 1
                        return recvmsg(fd, &header, 0)
                    }
                }
            }
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            guard header.msg_flags & MSG_TRUNC == 0, count <= buffer.count,
                  let endpoint = SocketAddress.endpoint(peer, length: header.msg_namelen) else { continue }
            _ = receive(Data(buffer.prefix(count)), endpoint)
        }
    }
}

public struct UDPFailure: Error, Equatable, CustomNSError, Sendable {
    public let code: Int32
    public init(_ code: Int32) { self.code = code }

    public static var errorDomain: String { NSPOSIXErrorDomain }
    public var errorCode: Int { Int(code) }
}

enum SocketAddress {
    static func withAddress<T>(
        _ endpoint: IPEndpoint, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
    ) throws -> T {
        let bytes = endpoint.address.bytes
        if endpoint.address.isIPv6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = endpoint.port.bigEndian
            if let zone = endpoint.address.zoneID {
                address.sin6_scope_id = UInt32(zone) ?? if_nametoindex(zone)
                guard address.sin6_scope_id != 0 || zone == "0" else { throw UDPFailure(ENXIO) }
            }
            withUnsafeMutableBytes(of: &address.sin6_addr) { $0.copyBytes(from: bytes) }
            let length = socklen_t(address.sin6_len)
            return try withUnsafePointer(to: &address) {
                try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, length) }
            }
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = endpoint.port.bigEndian
        withUnsafeMutableBytes(of: &address.sin_addr) { $0.copyBytes(from: bytes) }
        let length = socklen_t(address.sin_len)
        return try withUnsafePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, length) }
        }
    }

    static func endpoint(_ storage: sockaddr_storage, length: socklen_t) -> IPEndpoint? {
        withUnsafePointer(to: storage) { pointer in
            switch Int32(storage.ss_family) {
            case AF_INET where length >= MemoryLayout<sockaddr_in>.size:
                let address = pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                return withUnsafeBytes(of: address.sin_addr) { bytes in
                    WireGuardEngine.IPAddress(bytes: bytes).map { IPEndpoint(address: $0, port: UInt16(bigEndian: address.sin_port)) }
                }
            case AF_INET6 where length >= MemoryLayout<sockaddr_in6>.size:
                let address = pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                let scope = address.sin6_scope_id == 0 ? nil : String(address.sin6_scope_id)
                return withUnsafeBytes(of: address.sin6_addr) { bytes in
                    WireGuardEngine.IPAddress(bytes: bytes, zoneID: scope).map {
                        IPEndpoint(address: $0, port: UInt16(bigEndian: address.sin6_port))
                    }
                }
            default:
                return nil
            }
        }
    }
}
