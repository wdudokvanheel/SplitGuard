// SPDX-License-Identifier: MIT

import Dispatch
import Foundation

/// FIFO that releases each element at dequeue time and allocates only as it fills.
struct PacketQueue<Element> {
    private var ring: [Element?] = []
    private var head = 0
    private(set) var count = 0
    let capacity: Int

    mutating func append(_ item: Element) -> Bool {
        guard count < capacity else { return false }
        if count == ring.count {
            let doubled = count <= Int.max / 2 ? count * 2 : Int.max
            let newSize = min(capacity, max(4, doubled))
            var expanded = [Element?](repeating: nil, count: newSize)
            for index in 0..<count {
                expanded[index] = ring[(head + index) % ring.count]
            }
            ring = expanded
            head = 0
        }
        ring[(head + count) % ring.count] = item
        count += 1
        return true
    }

    mutating func popFirst() -> Element? {
        guard count > 0 else { return nil }
        let item = ring[head]
        ring[head] = nil
        head = (head + 1) % ring.count
        count -= 1
        return item
    }

    mutating func removeAll() {
        ring = []
        head = 0
        count = 0
    }
}

struct QueueMetrics {
    var admitted = 0
    var dropped = 0
    var peak = 0
}

/// Admission takes a short lock independently of the engine lock. One dispatch source
/// coalesces readiness, so there is no dispatch block retained per packet.
final class PacketLane<Element> {
    let queue: DispatchQueue
    private let ready: DispatchSourceUserDataAdd
    private let lock = NSLock()
    private var packets: PacketQueue<Element>
    private var metrics = QueueMetrics()
    private var token: UInt64?

    init(_ name: String, capacity: Int) {
        queue = DispatchQueue(label: "WireGuardEngine." + name)
        ready = DispatchSource.makeUserDataAddSource(queue: queue)
        packets = PacketQueue(capacity: capacity)
        ready.resume()
    }

    // Inbound has its own lane; the handshake lane uses its queue for the timer source too.
    func install(_ process: @escaping (Element) -> Void) {
        ready.setEventHandler { [weak self] in self?.drain(process) }
    }

    func register(_ token: UInt64?, discard: Bool = false) {
        lock.withLock {
            self.token = token
            if discard {
                metrics.dropped += packets.count
                packets.removeAll()
            }
        }
    }

    func offer(_ item: Element, token: UInt64) -> Bool {
        lock.withLock {
            guard token == self.token, packets.append(item) else {
                metrics.dropped += 1
                return false
            }
            metrics.admitted += 1
            metrics.peak = max(metrics.peak, packets.count)
            if packets.count == 1 { ready.add(data: 1) }
            return true
        }
    }

    var depth: Int { lock.withLock { packets.count } }
    var snapshot: QueueMetrics { lock.withLock { metrics } }

    private func drain(_ process: (Element) -> Void) {
        // Yield the queue between batches so control and timer events can also run.
        for _ in 0..<32 {
            guard let item = lock.withLock({ packets.popFirst() }) else { return }
            autoreleasepool { process(item) }
        }
        if depth > 0 { ready.add(data: 1) }
    }
}

/// Ready peers take turns on the outbound lane. Expands dynamically with active peer count
/// rather than tying its capacity to the global staged buffer budget.
struct ReadyPeers {
    private var peers = PacketQueue<WireGuardPeer>(capacity: Int.max)
    private var queued: Set<ObjectIdentifier> = []

    var isEmpty: Bool { peers.count == 0 }

    mutating func append(_ peer: WireGuardPeer) {
        let id = ObjectIdentifier(peer)
        guard queued.insert(id).inserted else { return }
        if !peers.append(peer) {
            queued.remove(id)
        }
    }

    mutating func popFirst() -> WireGuardPeer? {
        guard let peer = peers.popFirst() else { return nil }
        queued.remove(ObjectIdentifier(peer))
        return peer
    }

    mutating func remove(_ peer: WireGuardPeer) {
        guard queued.remove(ObjectIdentifier(peer)) != nil else { return }
        for _ in 0..<peers.count {
            guard let candidate = peers.popFirst(), candidate !== peer else { continue }
            _ = peers.append(candidate)
        }
    }
}
