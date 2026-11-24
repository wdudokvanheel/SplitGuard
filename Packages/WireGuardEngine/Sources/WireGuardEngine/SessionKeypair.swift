// SPDX-License-Identifier: MIT
// Copyright (C) 2017-2023 WireGuard LLC. All Rights Reserved.

import CryptoKit
import Foundation

final class SessionKeypair {
    let sendKey: SymmetricKey
    let receiveKey: SymmetricKey
    let created: ProtocolInstant
    let isInitiator: Bool
    let localIndex: UInt32
    let remoteIndex: UInt32

    // The send and receive queues can use the same session concurrently.
    private let sendLock = NSLock()
    private let receiveLock = NSLock()
    private var sendCounter: UInt64 = 0
    private var replayFilter = ReplayFilter()

    init(
        sendKey: Data, receiveKey: Data, created: ProtocolInstant, isInitiator: Bool,
        localIndex: UInt32, remoteIndex: UInt32
    ) throws {
        guard sendKey.count == ChaCha20Poly1305.keyLength, receiveKey.count == ChaCha20Poly1305.keyLength else {
            throw WireGuardCryptoError.invalidKeyLength
        }
        self.sendKey = SymmetricKey(data: sendKey)
        self.receiveKey = SymmetricKey(data: receiveKey)
        self.created = created
        self.isInitiator = isInitiator
        self.localIndex = localIndex
        self.remoteIndex = remoteIndex
    }

    var nextSendCounter: UInt64 { sendLock.withLock { sendCounter } }

    func reserveSendCounter() -> UInt64? {
        sendLock.withLock {
            guard sendCounter < ReplayFilter.rejectAfterMessages else { return nil }
            let counter = sendCounter
            sendCounter += 1
            return counter
        }
    }

    func expireSending() {
        sendLock.withLock { sendCounter = ReplayFilter.rejectAfterMessages }
    }

    func validateReceivedCounter(_ counter: UInt64) -> Bool {
        receiveLock.withLock { replayFilter.validate(counter) }
    }
}

final class SessionKeypairs {
    struct Slots {
        var previous: SessionKeypair?
        var current: SessionKeypair?
        var next: SessionKeypair?
    }

    private let lock = NSLock()
    private var slots = Slots()

    var current: SessionKeypair? { lock.withLock { slots.current } }

    /// Phase 3 can rotate the three slots atomically and retire their index entries.
    func withSlots<Result>(_ body: (inout Slots) -> Result) -> Result {
        lock.withLock { body(&slots) }
    }
}
