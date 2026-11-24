// SPDX-License-Identifier: MIT
// Copyright (C) 2017-2023 WireGuard LLC. All Rights Reserved.

import Foundation

/// A compressed prefix trie for each address family. The per-owner index preserves
/// the reference's insertion order, including moving a reinserted prefix to the end.
final class AllowedIPs<Owner: AnyObject> {
    private final class Node {
        let prefix: IPPrefix
        var owner: Owner?
        var zero: Node?
        var one: Node?

        init(prefix: IPPrefix, owner: Owner? = nil) {
            self.prefix = prefix
            self.owner = owner
        }

        subscript(branch: Int) -> Node? {
            get { branch == 0 ? zero : one }
            set {
                if branch == 0 { zero = newValue } else { one = newValue }
            }
        }
    }

    private let lock = NSLock()
    private var ipv4: Node?
    private var ipv6: Node?
    private var sequence: UInt64 = 0
    private var entries: [ObjectIdentifier: [IPPrefix: UInt64]] = [:]

    var isEmpty: Bool { lock.withLock { ipv4 == nil && ipv6 == nil } }

    func insert(_ prefix: IPPrefix, for owner: Owner) {
        lock.withLock {
            var replaced: Owner?
            if prefix.address.isIPv6 {
                ipv6 = insert(prefix, owner: owner, into: ipv6, replaced: &replaced)
            } else {
                ipv4 = insert(prefix, owner: owner, into: ipv4, replaced: &replaced)
            }
            if let replaced, replaced !== owner {
                let id = ObjectIdentifier(replaced)
                entries[id]?.removeValue(forKey: prefix)
                if entries[id]?.isEmpty == true { entries.removeValue(forKey: id) }
            }
            sequence += 1
            entries[ObjectIdentifier(owner), default: [:]][prefix] = sequence
        }
    }

    private func insert(_ prefix: IPPrefix, owner: Owner, into node: Node?, replaced: inout Owner?) -> Node {
        guard let node else { return Node(prefix: prefix, owner: owner) }

        let shared = min(prefix.length, node.prefix.length, prefix.address.commonBits(with: node.prefix.address))
        if shared == node.prefix.length {
            if shared == prefix.length {
                replaced = node.owner
                node.owner = owner
            } else {
                let branch = prefix.address.bit(at: shared)
                node[branch] = insert(prefix, owner: owner, into: node[branch], replaced: &replaced)
            }
            return node
        }

        let newNode = Node(prefix: prefix, owner: owner)
        let existingBranch = node.prefix.address.bit(at: shared)
        if shared == prefix.length {
            newNode[existingBranch] = node
            return newNode
        }

        // Both prefixes descend from a new common ancestor, with opposite branch bits.
        let parent = Node(prefix: IPPrefix(address: prefix.address, length: shared)!)
        parent[existingBranch] = node
        parent[1 - existingBranch] = newNode
        return parent
    }

    func lookup(_ address: IPAddress) -> Owner? {
        lock.withLock {
            var node = address.isIPv6 ? ipv6 : ipv4
            var best: Owner?
            while let current = node, current.prefix.contains(address) {
                if let owner = current.owner { best = owner }
                if current.prefix.length == address.bitCount { break }
                node = current[address.bit(at: current.prefix.length)]
            }
            return best
        }
    }

    func prefixes(for owner: Owner) -> [IPPrefix] {
        lock.withLock {
            guard let prefixes = entries[ObjectIdentifier(owner)] else { return [] }
            return prefixes.sorted { $0.value < $1.value }.map(\.key)
        }
    }

    func removeAll(for owner: Owner) {
        lock.withLock {
            guard let prefixes = entries.removeValue(forKey: ObjectIdentifier(owner)) else { return }
            for prefix in prefixes.keys {
                if prefix.address.isIPv6 {
                    ipv6 = remove(prefix, from: ipv6)
                } else {
                    ipv4 = remove(prefix, from: ipv4)
                }
            }
        }
    }

    private func remove(_ prefix: IPPrefix, from node: Node?) -> Node? {
        guard let node else { preconditionFailure("Allowed IP is missing from the trie") }
        if node.prefix == prefix {
            node.owner = nil
        } else {
            let branch = prefix.address.bit(at: node.prefix.length)
            node[branch] = remove(prefix, from: node[branch])
        }
        if node.owner == nil && (node.zero == nil || node.one == nil) {
            return node.zero ?? node.one
        }
        return node
    }
}
