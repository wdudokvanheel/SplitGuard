// SPDX-License-Identifier: MIT
// Copyright (C) 2017-2023 WireGuard LLC. All Rights Reserved.

import Foundation

enum WireGuardMessageType: UInt32, Sendable {
    case initiation = 1
    case response = 2
    case cookieReply = 3
    case transport = 4

    init?(packet: Data) {
        guard packet.count >= 4 else { return nil }
        self.init(rawValue: packet.readWireInteger(at: 0))
    }
}

struct HandshakePacket {
    enum Kind {
        case initiation
        case response

        fileprivate var type: WireGuardMessageType { self == .initiation ? .initiation : .response }
        var size: Int { self == .initiation ? 148 : 92 }
    }

    let kind: Kind
    private(set) var bytes: Data

    init?(packet: Data) {
        switch WireGuardMessageType(packet: packet) {
        case .initiation: kind = .initiation
        case .response: kind = .response
        default: return nil
        }
        guard packet.count == kind.size else { return nil }
        bytes = packet
    }

    init?(sender: UInt32, ephemeral: NoisePublicKey, encryptedStatic: Data, encryptedTimestamp: Data) {
        guard encryptedStatic.count == 48, encryptedTimestamp.count == 28 else { return nil }
        self.init(kind: .initiation, sender: sender, receiver: nil, ephemeral: ephemeral,
                  encrypted: [encryptedStatic, encryptedTimestamp])
    }

    init?(sender: UInt32, receiver: UInt32, ephemeral: NoisePublicKey, encryptedEmpty: Data) {
        guard encryptedEmpty.count == 16 else { return nil }
        self.init(kind: .response, sender: sender, receiver: receiver, ephemeral: ephemeral,
                  encrypted: [encryptedEmpty])
    }

    private init(kind: Kind, sender: UInt32, receiver: UInt32?, ephemeral: NoisePublicKey, encrypted: [Data]) {
        self.kind = kind
        bytes = Data(capacity: kind.size)
        bytes.appendWireInteger(kind.type.rawValue)
        bytes.appendWireInteger(sender)
        if let receiver { bytes.appendWireInteger(receiver) }
        bytes.append(ephemeral.rawValue)
        for field in encrypted { bytes.append(field) }
        bytes.append(Data(count: 2 * BLAKE2s.macLength))
    }

    var sender: UInt32 { bytes.readWireInteger(at: 4) }
    var receiver: UInt32? { kind == .response ? bytes.readWireInteger(at: 8) : nil }
    var ephemeral: NoisePublicKey {
        NoisePublicKey(rawValue: kind == .initiation ? bytes.wireSlice(8..<40) : bytes.wireSlice(12..<44))!
    }
    var encryptedStatic: Data? { kind == .initiation ? bytes.wireSlice(40..<88) : nil }
    var encryptedTimestamp: Data? { kind == .initiation ? bytes.wireSlice(88..<116) : nil }
    var encryptedEmpty: Data? { kind == .response ? bytes.wireSlice(44..<60) : nil }
    var mac1Input: Data { bytes.dropLast(2 * BLAKE2s.macLength) }
    var mac2Input: Data { bytes.dropLast(BLAKE2s.macLength) }
    var mac1: Data { mac2Input.suffix(BLAKE2s.macLength) }
    var mac2: Data { bytes.suffix(BLAKE2s.macLength) }

    mutating func setMAC1(_ value: Data) {
        precondition(value.count == BLAKE2s.macLength)
        let end = bytes.endIndex - BLAKE2s.macLength
        bytes.replaceSubrange((end - BLAKE2s.macLength)..<end, with: value)
    }

    mutating func setMAC2(_ value: Data) {
        precondition(value.count == BLAKE2s.macLength)
        bytes.replaceSubrange((bytes.endIndex - BLAKE2s.macLength)..<bytes.endIndex, with: value)
    }
}

struct CookieReply {
    static let size = 64
    let bytes: Data

    init?(packet: Data) {
        guard packet.count == Self.size, WireGuardMessageType(packet: packet) == .cookieReply else { return nil }
        bytes = packet
    }

    init?(receiver: UInt32, nonce: Data, encryptedCookie: Data) {
        guard nonce.count == XChaCha20Poly1305.nonceLength,
              encryptedCookie.count == BLAKE2s.macLength + ChaCha20Poly1305.tagLength else { return nil }
        var packet = Data(capacity: Self.size)
        packet.appendWireInteger(WireGuardMessageType.cookieReply.rawValue)
        packet.appendWireInteger(receiver)
        packet.append(nonce)
        packet.append(encryptedCookie)
        bytes = packet
    }

    var receiver: UInt32 { bytes.readWireInteger(at: 4) }
    var nonce: Data { bytes.wireSlice(8..<32) }
    var encryptedCookie: Data { bytes.wireSlice(32..<64) }
}

struct TransportHeader: Sendable {
    static let size = 16
    static let minimumPacketSize = size + ChaCha20Poly1305.tagLength

    let receiver: UInt32
    let counter: UInt64

    init(receiver: UInt32, counter: UInt64) {
        self.receiver = receiver
        self.counter = counter
    }

    /// Decode a standalone header or the prefix of a datagram. Check minimumPacketSize for a datagram.
    init?(header: Data) {
        guard header.count >= Self.size, WireGuardMessageType(packet: header) == .transport else { return nil }
        self.init(receiver: header.readWireInteger(at: 4), counter: header.readWireInteger(at: 8))
    }

    var bytes: Data {
        var data = Data(capacity: Self.size)
        append(to: &data)
        return data
    }

    func append(to data: inout Data) {
        data.appendWireInteger(WireGuardMessageType.transport.rawValue)
        data.appendWireInteger(receiver)
        data.appendWireInteger(counter)
    }

    var nonce: Data {
        var data = Data(count: 4)
        data.appendWireInteger(counter)
        return data
    }

    func withNonceBytes<Result>(_ body: (UnsafeRawBufferPointer) throws -> Result) rethrows -> Result {
        let words: (UInt32, UInt32, UInt32) = (
            0,
            UInt32(truncatingIfNeeded: counter).littleEndian,
            UInt32(truncatingIfNeeded: counter >> 32).littleEndian
        )
        return try Swift.withUnsafeBytes(of: words, body)
    }
}

private extension Data {
    func readWireInteger<T: FixedWidthInteger>(at offset: Int) -> T {
        withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }

    mutating func appendWireInteger<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func wireSlice(_ offsets: Range<Int>) -> Data {
        self[(startIndex + offsets.lowerBound)..<(startIndex + offsets.upperBound)]
    }
}
