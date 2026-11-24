// SPDX-License-Identifier: MIT
// Copyright (C) 2017-2023 WireGuard LLC. All Rights Reserved.

import Foundation

/// A handshake entry refers to the peer's single handshake state. A keypair
/// entry holds the same peer and the exact session object for inbound lookup.
final class SessionIndexTable<Peer: AnyObject>: @unchecked Sendable {
    enum Entry {
        case handshake(Peer)
        case keypair(Peer, SessionKeypair)
    }

    private let lock = NSLock()
    private var entries: [UInt32: Entry] = [:]

    func insertHandshake(
        for peer: Peer, drawIndex: () throws -> UInt32 = { UInt32.random(in: .min ... .max) }
    ) rethrows -> UInt32 {
        while true {
            let index = try drawIndex()
            let inserted = lock.withLock {
                guard entries[index] == nil else { return false }
                entries[index] = .handshake(peer)
                return true
            }
            if inserted { return index }
        }
    }

    func lookup(_ index: UInt32) -> Entry? {
        lock.withLock { entries[index] }
    }

    @discardableResult
    func swapForKeypair(_ keypair: SessionKeypair, for peer: Peer) -> Bool {
        lock.withLock {
            let index = keypair.localIndex
            guard case .handshake(let owner)? = entries[index], owner === peer else { return false }
            entries[index] = .keypair(peer, keypair)
            return true
        }
    }

    func delete(_ index: UInt32) {
        lock.withLock { entries[index] = nil }
    }

    func deleteHandshake(_ index: UInt32, for peer: Peer) {
        lock.withLock {
            if case .handshake(let current)? = entries[index], current === peer {
                entries[index] = nil
            }
        }
    }

    /// Conditional deletion protects an index that was recycled after a session retired.
    func delete(_ keypair: SessionKeypair) {
        lock.withLock {
            let index = keypair.localIndex
            if case .keypair(_, let current)? = entries[index], current === keypair {
                entries[index] = nil
            }
        }
    }
}
