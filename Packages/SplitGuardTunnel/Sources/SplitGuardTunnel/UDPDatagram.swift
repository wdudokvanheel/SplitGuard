// SPDX-License-Identifier: MIT

import Foundation
import WireGuardEngine

public struct UDPDatagram: Equatable, Hashable, Sendable {
    public let sourceAddress: WireGuardEngine.IPAddress
    public let destinationAddress: WireGuardEngine.IPAddress
    public let sourcePort: UInt16
    public let destinationPort: UInt16
    public let payload: Data

    public init(
        sourceAddress: WireGuardEngine.IPAddress,
        destinationAddress: WireGuardEngine.IPAddress,
        sourcePort: UInt16,
        destinationPort: UInt16,
        payload: Data
    ) {
        self.sourceAddress = sourceAddress
        self.destinationAddress = destinationAddress
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.payload = payload
    }

    public static func parse(_ packet: Data) -> UDPDatagram? {
        guard let first = packet.first else { return nil }
        let base = packet.startIndex
        let count = packet.count

        switch first >> 4 {
        case 4:
            guard count >= 20 else { return nil }
            let ihl = Int(first & 0x0F) * 4
            guard ihl >= 20, count >= ihl + 8 else { return nil }
            let totalLength = Int((UInt16(packet[base + 2]) << 8) | UInt16(packet[base + 3]))
            guard totalLength >= ihl + 8, totalLength <= count else { return nil }
            // Reject fragmented packets (MF flag or non-zero fragment offset).
            let flagsAndFrag = (UInt16(packet[base + 6]) << 8) | UInt16(packet[base + 7])
            guard (flagsAndFrag & 0x3FFF) == 0 else { return nil }
            // Require UDP (protocol 17).
            guard packet[base + 9] == 17 else { return nil }

            guard let src = WireGuardEngine.IPAddress(bytes: packet[(base + 12)..<(base + 16)]),
                  let dst = WireGuardEngine.IPAddress(bytes: packet[(base + 16)..<(base + 20)]) else {
                return nil
            }

            let udpOffset = base + ihl
            let srcPort = (UInt16(packet[udpOffset]) << 8) | UInt16(packet[udpOffset + 1])
            let dstPort = (UInt16(packet[udpOffset + 2]) << 8) | UInt16(packet[udpOffset + 3])
            let udpLength = Int((UInt16(packet[udpOffset + 4]) << 8) | UInt16(packet[udpOffset + 5]))
            guard udpLength >= 8, ihl + udpLength <= totalLength else { return nil }

            let payloadStart = udpOffset + 8
            let payloadEnd = udpOffset + udpLength
            return UDPDatagram(
                sourceAddress: src,
                destinationAddress: dst,
                sourcePort: srcPort,
                destinationPort: dstPort,
                payload: Data(packet[payloadStart..<payloadEnd])
            )

        case 6:
            guard count >= 48 else { return nil }
            let payloadLength = Int((UInt16(packet[base + 4]) << 8) | UInt16(packet[base + 5]))
            guard payloadLength >= 8, 40 + payloadLength <= count else { return nil }
            // Require UDP as immediate next header (17).
            guard packet[base + 6] == 17 else { return nil }

            guard let src = WireGuardEngine.IPAddress(bytes: packet[(base + 8)..<(base + 24)]),
                  let dst = WireGuardEngine.IPAddress(bytes: packet[(base + 24)..<(base + 40)]) else {
                return nil
            }

            let udpOffset = base + 40
            let srcPort = (UInt16(packet[udpOffset]) << 8) | UInt16(packet[udpOffset + 1])
            let dstPort = (UInt16(packet[udpOffset + 2]) << 8) | UInt16(packet[udpOffset + 3])
            let udpLength = Int((UInt16(packet[udpOffset + 4]) << 8) | UInt16(packet[udpOffset + 5]))
            guard udpLength >= 8, udpLength <= payloadLength else { return nil }

            let payloadStart = udpOffset + 8
            let payloadEnd = udpOffset + udpLength
            return UDPDatagram(
                sourceAddress: src,
                destinationAddress: dst,
                sourcePort: srcPort,
                destinationPort: dstPort,
                payload: Data(packet[payloadStart..<payloadEnd])
            )

        default:
            return nil
        }
    }

    public func makeReply(payload replyPayload: Data) -> Data? {
        let reply = UDPDatagram(
            sourceAddress: destinationAddress,
            destinationAddress: sourceAddress,
            sourcePort: destinationPort,
            destinationPort: sourcePort,
            payload: replyPayload
        )
        return reply.serialize()
    }

    public func serialize() -> Data? {
        guard sourceAddress.isIPv6 == destinationAddress.isIPv6 else { return nil }
        let udpLength = 8 + payload.count

        if !sourceAddress.isIPv6 {
            let totalLength = 20 + udpLength
            guard totalLength <= Int(UInt16.max) else { return nil }

            var ipHeader = Data(count: 20)
            ipHeader[0] = 0x45
            ipHeader[2] = UInt8(totalLength >> 8)
            ipHeader[3] = UInt8(truncatingIfNeeded: totalLength)
            ipHeader[6] = 0x40 // Don't Fragment
            ipHeader[8] = 64 // TTL
            ipHeader[9] = 17 // UDP
            ipHeader.replaceSubrange(12..<16, with: sourceAddress.bytes)
            ipHeader.replaceSubrange(16..<20, with: destinationAddress.bytes)

            let headerChecksum = Self.internetChecksum([ipHeader])
            ipHeader[10] = UInt8(headerChecksum >> 8)
            ipHeader[11] = UInt8(truncatingIfNeeded: headerChecksum)

            var udpHeader = Data(count: 8)
            udpHeader[0] = UInt8(sourcePort >> 8)
            udpHeader[1] = UInt8(truncatingIfNeeded: sourcePort)
            udpHeader[2] = UInt8(destinationPort >> 8)
            udpHeader[3] = UInt8(truncatingIfNeeded: destinationPort)
            udpHeader[4] = UInt8(udpLength >> 8)
            udpHeader[5] = UInt8(truncatingIfNeeded: udpLength)

            let udpChecksum = Self.udpChecksumIPv4(
                source: sourceAddress.bytes,
                destination: destinationAddress.bytes,
                udpHeader: udpHeader,
                payload: payload
            )
            udpHeader[6] = UInt8(udpChecksum >> 8)
            udpHeader[7] = UInt8(truncatingIfNeeded: udpChecksum)

            var packet = Data(capacity: totalLength)
            packet.append(ipHeader)
            packet.append(udpHeader)
            packet.append(payload)
            return packet
        } else {
            guard udpLength <= Int(UInt16.max) else { return nil }

            var ipHeader = Data(count: 40)
            ipHeader[0] = 0x60
            ipHeader[4] = UInt8(udpLength >> 8)
            ipHeader[5] = UInt8(truncatingIfNeeded: udpLength)
            ipHeader[6] = 17 // Next Header: UDP
            ipHeader[7] = 64 // Hop Limit
            ipHeader.replaceSubrange(8..<24, with: sourceAddress.bytes)
            ipHeader.replaceSubrange(24..<40, with: destinationAddress.bytes)

            var udpHeader = Data(count: 8)
            udpHeader[0] = UInt8(sourcePort >> 8)
            udpHeader[1] = UInt8(truncatingIfNeeded: sourcePort)
            udpHeader[2] = UInt8(destinationPort >> 8)
            udpHeader[3] = UInt8(truncatingIfNeeded: destinationPort)
            udpHeader[4] = UInt8(udpLength >> 8)
            udpHeader[5] = UInt8(truncatingIfNeeded: udpLength)

            let udpChecksum = Self.udpChecksumIPv6(
                source: sourceAddress.bytes,
                destination: destinationAddress.bytes,
                udpHeader: udpHeader,
                payload: payload
            )
            udpHeader[6] = UInt8(udpChecksum >> 8)
            udpHeader[7] = UInt8(truncatingIfNeeded: udpChecksum)

            var packet = Data(capacity: 40 + udpLength)
            packet.append(ipHeader)
            packet.append(udpHeader)
            packet.append(payload)
            return packet
        }
    }

    // MARK: - Checksums (RFC 1071 / RFC 768 / RFC 8200)

    static func internetChecksum(_ chunks: [Data]) -> UInt16 {
        var sum: UInt32 = 0
        var oddByte: UInt8?

        for chunk in chunks {
            chunk.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                var index = 0
                let count = raw.count
                if let pending = oddByte, count > 0 {
                    sum += (UInt32(pending) << 8) | UInt32(base[0])
                    oddByte = nil
                    index = 1
                }
                while index + 1 < count {
                    sum += (UInt32(base[index]) << 8) | UInt32(base[index + 1])
                    index += 2
                }
                if index < count {
                    oddByte = base[index]
                }
            }
        }

        if let trailing = oddByte {
            sum += UInt32(trailing) << 8
        }

        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }

        return ~UInt16(truncatingIfNeeded: sum)
    }

    static func udpChecksumIPv4(source: [UInt8], destination: [UInt8], udpHeader: Data, payload: Data) -> UInt16 {
        let udpLength = UInt16(udpHeader.count + payload.count)
        var pseudo = Data(capacity: 12)
        pseudo.append(contentsOf: source)
        pseudo.append(contentsOf: destination)
        pseudo.append(0)
        pseudo.append(17)
        pseudo.append(UInt8(udpLength >> 8))
        pseudo.append(UInt8(truncatingIfNeeded: udpLength))

        let checksum = internetChecksum([pseudo, udpHeader, payload])
        return checksum == 0 ? 0xFFFF : checksum
    }

    static func udpChecksumIPv6(source: [UInt8], destination: [UInt8], udpHeader: Data, payload: Data) -> UInt16 {
        let udpLength = UInt32(udpHeader.count + payload.count)
        var pseudo = Data(capacity: 40)
        pseudo.append(contentsOf: source)
        pseudo.append(contentsOf: destination)
        pseudo.append(UInt8((udpLength >> 24) & 0xFF))
        pseudo.append(UInt8((udpLength >> 16) & 0xFF))
        pseudo.append(UInt8((udpLength >> 8) & 0xFF))
        pseudo.append(UInt8(udpLength & 0xFF))
        pseudo.append(contentsOf: [0, 0, 0, 17])

        let checksum = internetChecksum([pseudo, udpHeader, payload])
        return checksum == 0 ? 0xFFFF : checksum
    }
}
