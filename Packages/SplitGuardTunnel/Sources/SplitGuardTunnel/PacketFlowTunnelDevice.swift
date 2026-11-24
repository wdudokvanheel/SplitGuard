// SPDX-License-Identifier: MIT

import Darwin
import Dispatch
import Foundation
import NetworkExtension
import WireGuardEngine

public protocol PacketFlow: AnyObject {
    func readPackets(completionHandler: @escaping @Sendable ([Data], [NSNumber]) -> Void)
    func writePackets(_ packets: [Data], withProtocols protocols: [NSNumber]) -> Bool
}

extension NEPacketTunnelFlow: PacketFlow {}

/// NetworkExtension does not expose cancellation for readPackets. Keep this reader
/// for the provider's lifetime, including when one engine is replaced by another.
public final class PacketFlowReader: @unchecked Sendable {
    fileprivate let flow: PacketFlow
    private let queue = DispatchQueue(label: "SplitGuard.packetFlow.read", qos: .userInitiated)
    private let lock = NSLock()
    private var registration: (id: UUID, receive: (Data) -> Bool)?
    private var readPending = false
    private var readPaused = false
    private var resumeGeneration: UInt64 = 0

    public init(flow: PacketFlow) { self.flow = flow }

    fileprivate func start(_ receive: @escaping (Data) -> Bool) throws -> UUID {
        try lock.withLock {
            guard registration == nil else { throw PacketFlowFailure.invalidState }
            let id = UUID()
            registration = (id, receive)
            readPaused = false
            scheduleRead()
            return id
        }
    }

    fileprivate func stop(_ id: UUID) {
        lock.withLock {
            if registration?.id == id {
                registration = nil
                readPaused = false
            }
        }
    }

    fileprivate func pauseReading(_ id: UUID) {
        lock.withLock {
            guard registration?.id == id else { return }
            readPaused = true
        }
    }

    fileprivate func resumeReading(_ id: UUID) {
        lock.withLock {
            guard registration?.id == id else { return }
            readPaused = false
            resumeGeneration &+= 1
            scheduleRead()
        }
    }

    // Called with the lock held. Reserve the read before scheduling it. An old
    // read that has reached NetworkExtension holds the slot across stop and start.
    private func scheduleRead() {
        guard let id = registration?.id, !readPending, !readPaused else { return }
        readPending = true
        queue.async { [weak self] in self?.issueRead(id) }
    }

    private func issueRead(_ id: UUID) {
        let current = lock.withLock {
            if registration?.id == id, !readPaused { return true }
            readPending = false
            scheduleRead()
            return false
        }
        guard current else { return }
        flow.readPackets { [weak self] packets, _ in
            self?.didRead(packets, id: id)
        }
    }

    private func didRead(_ packets: [Data], id: UUID) {
        let (receive, generationBefore) = lock.withLock {
            registration?.id == id ? (registration?.receive, resumeGeneration) : (nil, resumeGeneration)
        }
        var rejected = false
        if let receive {
            for packet in packets where (1...WireGuardDevice.maxContentSize).contains(packet.count) {
                let owned: Data? = packet.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { return nil }
                    return Data(bytes: base, count: bytes.count)
                }
                if let owned, !receive(owned) {
                    rejected = true
                }
            }
        }
        lock.withLock {
            readPending = false
            if rejected, registration?.id == id, resumeGeneration == generationBefore {
                readPaused = true
            }
            scheduleRead()
        }
    }
}

public final class PacketFlowTunnelDevice: TunnelDevice, @unchecked Sendable {
    private let reader: PacketFlowReader
    private let lock = NSLock()
    private var currentMTU: Int
    private var registration: UUID?
    private var closed = false

    public init(reader: PacketFlowReader, mtu: Int) {
        self.reader = reader
        currentMTU = mtu
    }

    public var mtu: Int { lock.withLock { currentMTU } }

    public func setMTU(_ mtu: Int) {
        lock.withLock { currentMTU = mtu }
    }

    public func start(receive: @escaping (Data) -> Bool) throws {
        try lock.withLock {
            guard !closed, registration == nil else { throw PacketFlowFailure.invalidState }
            registration = try reader.start(receive)
        }
    }

    public func stop() {
        let current = lock.withLock { () -> UUID? in
            let id = registration
            registration = nil
            return id
        }
        if let current { reader.stop(current) }
    }

    public func close() {
        let current = lock.withLock { () -> UUID? in
            closed = true
            let id = registration
            registration = nil
            return id
        }
        if let current { reader.stop(current) }
    }

    public func pauseReading() {
        if let id = lock.withLock({ registration }) {
            reader.pauseReading(id)
        }
    }

    public func resumeReading() {
        if let id = lock.withLock({ registration }) {
            reader.resumeReading(id)
        }
    }

    public func write(_ packet: Data) throws {
        try writeBatch([packet])
    }

    public func writeBatch(_ packets: [Data]) throws {
        guard !packets.isEmpty else { return }
        guard lock.withLock({ registration != nil }) else { throw PacketFlowFailure.invalidState }
        var protocols: [NSNumber] = []
        protocols.reserveCapacity(packets.count)
        for packet in packets {
            let family: Int32
            switch packet.first.map({ $0 >> 4 }) {
            case 4: family = AF_INET
            case 6: family = AF_INET6
            default: throw PacketFlowFailure.invalidPacket
            }
            protocols.append(NSNumber(value: family))
        }
        guard reader.flow.writePackets(packets, withProtocols: protocols) else {
            throw PacketFlowFailure.writeFailed
        }
    }
}

public enum PacketFlowFailure: Error, Equatable, Sendable {
    case invalidState
    case invalidPacket
    case writeFailed
}
