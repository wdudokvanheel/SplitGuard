// SPDX-License-Identifier: MIT

import Foundation

public enum PacketVerdict: Sendable, Equatable {
    case pass
    case drop
    case consume
}

public enum PacketHookFilter: Sendable, Equatable {
    case udp(port: UInt16, hosts: Set<IPAddress>)
    case all

    public func matches(_ packet: Data, inbound: Bool) -> Bool {
        guard let first = packet.first else { return false }
        let base = packet.startIndex
        let count = packet.count
        switch self {
        case .all:
            switch first >> 4 {
            case 4:
                return count >= 20
            case 6:
                return count >= 40
            default:
                return false
            }
        case .udp(let port, let hosts):
            switch first >> 4 {
            case 4:
                guard count >= 20 else { return false }
                let ihl = Int(first & 0x0F) * 4
                guard ihl >= 20, count >= ihl + 8 else { return false }
                guard packet[base + 9] == 17 else { return false }
                let portOffset = base + ihl + (inbound ? 0 : 2)
                let packetPort = (UInt16(packet[portOffset]) << 8) | UInt16(packet[portOffset + 1])
                guard packetPort == port else { return false }
                if hosts.isEmpty { return true }
                let addressOffset = base + (inbound ? IPHeader.ipv4Source : IPHeader.ipv4Destination)
                guard let address = IPAddress(bytes: packet[addressOffset..<(addressOffset + 4)]) else { return false }
                return hosts.contains(address)
            case 6:
                guard count >= 48 else { return false }
                guard packet[base + 6] == 17 else { return false }
                let portOffset = base + 40 + (inbound ? 0 : 2)
                let packetPort = (UInt16(packet[portOffset]) << 8) | UInt16(packet[portOffset + 1])
                guard packetPort == port else { return false }
                if hosts.isEmpty { return true }
                let addressOffset = base + (inbound ? IPHeader.ipv6Source : IPHeader.ipv6Destination)
                guard let address = IPAddress(bytes: packet[addressOffset..<(addressOffset + 16)]) else { return false }
                return hosts.contains(address)
            default:
                return false
            }
        }
    }
}

public protocol PacketHook: AnyObject, Sendable {
    func outbound(_ packet: Data) -> PacketVerdict
    func inbound(_ packet: Data)
}

public enum PacketDeliveryError: Error, Equatable, Sendable {
    case deviceNotRunning
    case invalidPacket
}

/// Leaf-locked storage for the active packet hook so hook checks and callbacks never hold `WireGuardDevice.lock`.
final class PacketHookStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var entry: (hook: any PacketHook, filter: PacketHookFilter)?

    func set(_ hook: (any PacketHook)?, matching filter: PacketHookFilter) {
        lock.withLock {
            entry = hook.map { ($0, filter) }
        }
    }

    func clear() {
        lock.withLock {
            entry = nil
        }
    }

    func current() -> (hook: any PacketHook, filter: PacketHookFilter)? {
        lock.withLock { entry }
    }
}

extension WireGuardDevice {
    /// Installs or clears the packet inspection hook for packets matching `filter`.
    public func setHook(_ hook: (any PacketHook)?, matching filter: PacketHookFilter) {
        hookStorage.set(hook, matching: filter)
    }

    /// Removes any installed packet hook.
    public func clearHook() {
        hookStorage.clear()
    }

    func currentHook() -> (hook: any PacketHook, filter: PacketHookFilter)? {
        hookStorage.current()
    }

    /// Delivers a synthesized IPv4 or IPv6 packet directly to the tunnel interface without holding `device.lock`.
    public func deliverToTunnel(_ packet: Data) throws {
        guard let parsed = IPPacket(packet, inbound: true) else {
            throw PacketDeliveryError.invalidPacket
        }
        if let first = packet.first, first >> 4 == 4 {
            let ihl = Int(first & 0x0F) * 4
            guard ihl >= 20, ihl <= parsed.length else {
                throw PacketDeliveryError.invalidPacket
            }
        }
        try tunnelSubmission.withLock {
            guard let io, lock.withLock({ io.state == .up }) else {
                throw PacketDeliveryError.deviceNotRunning
            }
            try io.tunnel.write(packet)
        }
    }
}
