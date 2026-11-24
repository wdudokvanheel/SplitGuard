// SPDX-License-Identifier: MIT

import Foundation
import SplitGuardCore
import WireGuardEngine

struct TunnelRecord: Equatable, Sendable {
    let id: UUID
    var profile: TunnelProfile
    var status: TunnelStatus
    var onDemandPolicy: OnDemandPolicy
    var isOnDemandEnabled: Bool

    init(
        id: UUID = UUID(),
        profile: TunnelProfile,
        status: TunnelStatus = .inactive,
        onDemandPolicy: OnDemandPolicy = .off,
        isOnDemandEnabled: Bool = false
    ) {
        self.id = id
        self.profile = profile
        self.status = status
        self.onDemandPolicy = onDemandPolicy.normalized()
        self.isOnDemandEnabled = onDemandPolicy.hasRules && isOnDemandEnabled
    }
}

enum BackendEvent: Equatable, Sendable {
    case statusChanged(tunnelID: UUID, status: TunnelStatus)
    case configurationsChanged
}

protocol TunnelBackend: Sendable {
    var saveNewDeactivatesActiveTunnel: Bool { get }

    func loadAll() async throws -> [TunnelRecord]
    func save(
        _ profile: TunnelProfile,
        onDemandPolicy: OnDemandPolicy,
        isOnDemandEnabled: Bool,
        replacing id: UUID?
    ) async throws -> TunnelRecord
    func setOnDemandEnabled(_ isEnabled: Bool, for id: UUID) async throws -> TunnelRecord
    func remove(id: UUID) async throws
    func start(id: UUID) async throws
    func stop(id: UUID) async
    func fetchLastStartError(for id: UUID) async -> TunnelStartError?
    func fetchDeviceStatus(for id: UUID) async -> DeviceStatus?
    func sendProviderMessage(_ message: ProviderMessage, to id: UUID) async -> ProviderReply?
    func refreshStatuses() async -> [UUID: TunnelStatus]
    func events() -> AsyncStream<BackendEvent>
    func setConfigurationChangeObservationPaused(_ paused: Bool) async
}

extension TunnelBackend {
    var saveNewDeactivatesActiveTunnel: Bool { false }

    func setConfigurationChangeObservationPaused(_ paused: Bool) async {}
}

final class BackendEventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<BackendEvent>.Continuation] = [:]

    func stream() -> AsyncStream<BackendEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.withLock {
                continuations[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.remove(id: id)
            }
        }
    }

    func yield(_ event: BackendEvent) {
        let snapshot = lock.withLock { Array(continuations.values) }
        for continuation in snapshot {
            continuation.yield(event)
        }
    }

    func finish() {
        let snapshot = lock.withLock { () -> [AsyncStream<BackendEvent>.Continuation] in
            let values = Array(continuations.values)
            continuations.removeAll()
            return values
        }
        for continuation in snapshot {
            continuation.finish()
        }
    }

    private func remove(id: UUID) {
        lock.withLock {
            _ = continuations.removeValue(forKey: id)
        }
    }
}
