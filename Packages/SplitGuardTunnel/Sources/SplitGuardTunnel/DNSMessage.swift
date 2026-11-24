// SPDX-License-Identifier: MIT

import Foundation
import SplitGuardCore

public enum DNSResponseCode: UInt8, Equatable, Hashable, Sendable {
    case noError = 0
    case formatError = 1
    case serverFailure = 2
    case nameError = 3
    case notImplemented = 4
    case refused = 5
}

public struct DNSResourceRecord: Equatable, Hashable, Sendable {
    public let name: String
    public let type: UInt16
    public let recordClass: UInt16
    public let ttl: UInt32
    public let rdata: Data

    public init(name: String, type: UInt16, recordClass: UInt16 = 1, ttl: UInt32, rdata: Data) {
        self.name = SplitDNSConfiguration.normalizeDomain(name)
        self.type = type
        self.recordClass = recordClass
        self.ttl = ttl
        self.rdata = rdata
    }
}

public struct DNSQuery: Equatable, Hashable, Sendable {
    public let id: UInt16
    public let recursionDesired: Bool
    public let name: String
    public let type: UInt16
    public let recordClass: UInt16
    public let maxPayloadSize: Int
    public let hasEDNS: Bool

    public init(
        id: UInt16,
        recursionDesired: Bool = true,
        name: String,
        type: UInt16,
        recordClass: UInt16 = 1,
        maxPayloadSize: Int = 512,
        hasEDNS: Bool = false
    ) {
        self.id = id
        self.recursionDesired = recursionDesired
        self.name = SplitDNSConfiguration.normalizeDomain(name)
        self.type = type
        self.recordClass = recordClass
        self.maxPayloadSize = max(512, maxPayloadSize)
        self.hasEDNS = hasEDNS
    }
}

public struct DNSResponse: Equatable, Hashable, Sendable {
    public let id: UInt16
    public let isTruncated: Bool
    public let recursionDesired: Bool
    public let recursionAvailable: Bool
    public let responseCode: DNSResponseCode
    public let questionName: String
    public let questionType: UInt16
    public let questionClass: UInt16
    public let answers: [DNSResourceRecord]
    public let maxPayloadSize: Int
    public let hasEDNS: Bool
}

public enum DNSMessage {
    public static let standardUDPMaxPayload = 512
    public static let optRecordType: UInt16 = 41
    public static let optRecordSize = 11

    public static func parseQuery(_ data: Data) -> DNSQuery? {
        guard data.count >= 12 else { return nil }
        let base = data.startIndex
        let id = readUInt16(data, at: base)
        let flags = readUInt16(data, at: base + 2)
        let qdCount = readUInt16(data, at: base + 4)
        let anCount = readUInt16(data, at: base + 6)
        let nsCount = readUInt16(data, at: base + 8)
        let arCount = readUInt16(data, at: base + 10)

        let isResponse = (flags & 0x8000) != 0
        let opcode = (flags >> 11) & 0x0F
        guard !isResponse, opcode == 0, qdCount >= 1 else { return nil }

        let recursionDesired = (flags & 0x0100) != 0

        guard let (rawName, afterFirstName) = readName(in: data, at: base + 12) else { return nil }
        guard afterFirstName + 4 <= data.endIndex else { return nil }
        let qtype = readUInt16(data, at: afterFirstName)
        let qclass = readUInt16(data, at: afterFirstName + 2)
        var cursor = afterFirstName + 4

        // Skip any extra questions.
        if qdCount > 1 {
            for _ in 1..<qdCount {
                guard let (_, nextOffset) = readName(in: data, at: cursor),
                      nextOffset + 4 <= data.endIndex else {
                    return nil
                }
                cursor = nextOffset + 4
            }
        }

        // Skip answer and authority records if present.
        let nonAdditionalCount = Int(anCount) + Int(nsCount)
        for _ in 0..<nonAdditionalCount {
            guard let next = skipResourceRecord(in: data, at: cursor) else { return nil }
            cursor = next
        }

        // Inspect additional records for EDNS0 OPT pseudo-record.
        var maxPayload = standardUDPMaxPayload
        var hasEDNS = false
        for _ in 0..<Int(arCount) {
            guard let (_, afterName) = readName(in: data, at: cursor),
                  afterName + 10 <= data.endIndex else {
                return nil
            }
            let rrType = readUInt16(data, at: afterName)
            let rrClass = readUInt16(data, at: afterName + 2)
            let rdLength = Int(readUInt16(data, at: afterName + 8))
            let afterRData = afterName + 10 + rdLength
            guard afterRData <= data.endIndex else { return nil }

            if rrType == optRecordType {
                hasEDNS = true
                maxPayload = max(standardUDPMaxPayload, Int(rrClass))
            }
            cursor = afterRData
        }

        return DNSQuery(
            id: id,
            recursionDesired: recursionDesired,
            name: rawName,
            type: qtype,
            recordClass: qclass,
            maxPayloadSize: maxPayload,
            hasEDNS: hasEDNS
        )
    }

    public static func buildResponse(
        for query: DNSQuery,
        responseCode: DNSResponseCode,
        answers: [DNSResourceRecord],
        maxPayloadSize: Int? = nil
    ) -> Data {
        let limit = max(standardUDPMaxPayload, maxPayloadSize ?? query.maxPayloadSize)
        let reservedForOPT = query.hasEDNS ? optRecordSize : 0

        var buffer = Data()
        buffer.reserveCapacity(min(limit, 512))

        // Header placeholder (12 bytes).
        buffer.append(contentsOf: [UInt8](repeating: 0, count: 12))

        // Question section at offset 12.
        let encodedQuestionName = encodeName(query.name)
        buffer.append(encodedQuestionName)
        appendUInt16(query.type, to: &buffer)
        appendUInt16(query.recordClass, to: &buffer)

        var writtenAnswers: UInt16 = 0
        var truncated = false

        for record in answers {
            guard record.rdata.count <= Int(UInt16.max) else {
                truncated = true
                break
            }

            var rrBytes = Data()
            if record.name == query.name {
                // Compression pointer to the question name at offset 12.
                rrBytes.append(0xC0)
                rrBytes.append(0x0C)
            } else {
                rrBytes.append(encodeName(record.name))
            }
            appendUInt16(record.type, to: &rrBytes)
            appendUInt16(record.recordClass, to: &rrBytes)
            appendUInt32(record.ttl, to: &rrBytes)
            appendUInt16(UInt16(record.rdata.count), to: &rrBytes)
            rrBytes.append(record.rdata)

            if buffer.count + rrBytes.count + reservedForOPT > limit {
                truncated = true
                break
            }

            buffer.append(rrBytes)
            writtenAnswers &+= 1
        }

        if query.hasEDNS {
            // Root name (0x00), TYPE=OPT (41), CLASS=UDP payload size, TTL=0, RDLENGTH=0.
            buffer.append(0x00)
            appendUInt16(optRecordType, to: &buffer)
            appendUInt16(UInt16(min(limit, 4096)), to: &buffer)
            appendUInt32(0, to: &buffer)
            appendUInt16(0, to: &buffer)
        }

        var flags: UInt16 = 0x8000 | 0x0080 | UInt16(responseCode.rawValue & 0x0F)
        if query.recursionDesired {
            flags |= 0x0100
        }
        if truncated {
            flags |= 0x0200
        }

        writeUInt16(query.id, to: &buffer, at: 0)
        writeUInt16(flags, to: &buffer, at: 2)
        writeUInt16(1, to: &buffer, at: 4) // QDCOUNT
        writeUInt16(writtenAnswers, to: &buffer, at: 6) // ANCOUNT
        writeUInt16(0, to: &buffer, at: 8) // NSCOUNT
        writeUInt16(query.hasEDNS ? 1 : 0, to: &buffer, at: 10) // ARCOUNT

        return buffer
    }

    public static func parseResponse(_ data: Data) -> DNSResponse? {
        guard data.count >= 12 else { return nil }
        let base = data.startIndex
        let id = readUInt16(data, at: base)
        let flags = readUInt16(data, at: base + 2)
        let qdCount = readUInt16(data, at: base + 4)
        let anCount = readUInt16(data, at: base + 6)
        let nsCount = readUInt16(data, at: base + 8)
        let arCount = readUInt16(data, at: base + 10)

        guard (flags & 0x8000) != 0, qdCount >= 1 else { return nil }
        guard let responseCode = DNSResponseCode(rawValue: UInt8(flags & 0x0F)) else { return nil }
        let isTruncated = (flags & 0x0200) != 0
        let recursionDesired = (flags & 0x0100) != 0
        let recursionAvailable = (flags & 0x0080) != 0

        guard let (qName, afterQName) = readName(in: data, at: base + 12),
              afterQName + 4 <= data.endIndex else {
            return nil
        }
        let qType = readUInt16(data, at: afterQName)
        let qClass = readUInt16(data, at: afterQName + 2)
        var cursor = afterQName + 4

        if qdCount > 1 {
            for _ in 1..<qdCount {
                guard let (_, next) = readName(in: data, at: cursor), next + 4 <= data.endIndex else {
                    return nil
                }
                cursor = next + 4
            }
        }

        var answers: [DNSResourceRecord] = []
        answers.reserveCapacity(Int(anCount))
        for _ in 0..<Int(anCount) {
            guard let (name, afterName) = readName(in: data, at: cursor),
                  afterName + 10 <= data.endIndex else {
                return nil
            }
            let type = readUInt16(data, at: afterName)
            let recordClass = readUInt16(data, at: afterName + 2)
            let ttl = readUInt32(data, at: afterName + 4)
            let rdLength = Int(readUInt16(data, at: afterName + 8))
            let rdataStart = afterName + 10
            let rdataEnd = rdataStart + rdLength
            guard rdataEnd <= data.endIndex else { return nil }
            answers.append(DNSResourceRecord(
                name: name,
                type: type,
                recordClass: recordClass,
                ttl: ttl,
                rdata: Data(data[rdataStart..<rdataEnd])
            ))
            cursor = rdataEnd
        }

        for _ in 0..<Int(nsCount) {
            guard let next = skipResourceRecord(in: data, at: cursor) else { return nil }
            cursor = next
        }

        var hasEDNS = false
        var maxPayload = standardUDPMaxPayload
        for _ in 0..<Int(arCount) {
            guard let (_, afterName) = readName(in: data, at: cursor),
                  afterName + 10 <= data.endIndex else {
                return nil
            }
            let type = readUInt16(data, at: afterName)
            let recordClass = readUInt16(data, at: afterName + 2)
            let rdLength = Int(readUInt16(data, at: afterName + 8))
            let rdataEnd = afterName + 10 + rdLength
            guard rdataEnd <= data.endIndex else { return nil }
            if type == optRecordType {
                hasEDNS = true
                maxPayload = max(standardUDPMaxPayload, Int(recordClass))
            }
            cursor = rdataEnd
        }

        return DNSResponse(
            id: id,
            isTruncated: isTruncated,
            recursionDesired: recursionDesired,
            recursionAvailable: recursionAvailable,
            responseCode: responseCode,
            questionName: SplitDNSConfiguration.normalizeDomain(qName),
            questionType: qType,
            questionClass: qClass,
            answers: answers,
            maxPayloadSize: maxPayload,
            hasEDNS: hasEDNS
        )
    }

    /// Builds a wire-format DNS query (primarily for testing and diagnostics).
    public static func buildQuery(
        id: UInt16,
        name: String,
        type: UInt16,
        recordClass: UInt16 = 1,
        recursionDesired: Bool = true,
        ednsPayloadSize: UInt16? = nil
    ) -> Data {
        var data = Data()
        appendUInt16(id, to: &data)
        appendUInt16(recursionDesired ? 0x0100 : 0x0000, to: &data)
        appendUInt16(1, to: &data) // QDCOUNT
        appendUInt16(0, to: &data) // ANCOUNT
        appendUInt16(0, to: &data) // NSCOUNT
        appendUInt16(ednsPayloadSize == nil ? 0 : 1, to: &data) // ARCOUNT
        data.append(encodeName(name))
        appendUInt16(type, to: &data)
        appendUInt16(recordClass, to: &data)
        if let ednsPayloadSize {
            data.append(0x00)
            appendUInt16(optRecordType, to: &data)
            appendUInt16(ednsPayloadSize, to: &data)
            appendUInt32(0, to: &data)
            appendUInt16(0, to: &data)
        }
        return data
    }

    // MARK: - Wire Encoding / Decoding Helpers

    static func encodeName(_ name: String) -> Data {
        let normalized = SplitDNSConfiguration.normalizeDomain(name)
        guard !normalized.isEmpty else { return Data([0x00]) }
        var out = Data()
        for label in normalized.split(separator: ".", omittingEmptySubsequences: true) {
            let bytes = Array(label.utf8)
            guard !bytes.isEmpty, bytes.count <= 63 else { continue }
            out.append(UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(0x00)
        return out
    }

    private static func readName(in data: Data, at startOffset: Int) -> (String, Int)? {
        let base = data.startIndex
        var offset = startOffset
        var endAfterName: Int?
        var labels: [String] = []
        var totalWireBytes = 0
        var jumps = 0

        while offset < data.endIndex {
            let lengthByte = data[offset]
            if lengthByte == 0 {
                if endAfterName == nil {
                    endAfterName = offset + 1
                }
                let name = labels.joined(separator: ".").lowercased()
                return (name, endAfterName!)
            }

            let topTwoBits = lengthByte & 0xC0
            if topTwoBits == 0xC0 {
                // Compression pointer (2 bytes).
                guard offset + 1 < data.endIndex else { return nil }
                let pointer = (Int(lengthByte & 0x3F) << 8) | Int(data[offset + 1])
                let target = base + pointer
                guard target < data.endIndex else { return nil }
                if endAfterName == nil {
                    endAfterName = offset + 2
                }
                jumps += 1
                guard jumps <= 64 else { return nil }
                offset = target
                continue
            } else if topTwoBits != 0 {
                // Reserved label type.
                return nil
            }

            let labelLength = Int(lengthByte)
            totalWireBytes += 1 + labelLength
            guard totalWireBytes <= 255 else { return nil }
            let labelStart = offset + 1
            let labelEnd = labelStart + labelLength
            guard labelEnd <= data.endIndex else { return nil }
            guard let label = String(bytes: data[labelStart..<labelEnd], encoding: .utf8) else {
                return nil
            }
            labels.append(label)
            offset = labelEnd
        }

        return nil
    }

    private static func skipResourceRecord(in data: Data, at offset: Int) -> Int? {
        guard let (_, afterName) = readName(in: data, at: offset),
              afterName + 10 <= data.endIndex else {
            return nil
        }
        let rdLength = Int(readUInt16(data, at: afterName + 8))
        let end = afterName + 10 + rdLength
        guard end <= data.endIndex else { return nil }
        return end
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func writeUInt16(_ value: UInt16, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(value >> 8)
        data[offset + 1] = UInt8(truncatingIfNeeded: value)
    }
}
