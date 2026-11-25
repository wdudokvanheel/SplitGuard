// SPDX-License-Identifier: MIT

import Foundation
import SplitGuardCore
import WireGuardEngine

actor InMemoryTunnelBackend: TunnelBackend {
    enum RecordedCall: Equatable, Sendable {
        case loadAll
        case save(name: String, replacing: UUID?, onDemandPolicy: OnDemandPolicy, isOnDemandEnabled: Bool)
        case setOnDemandEnabled(id: UUID, isEnabled: Bool)
        case remove(id: UUID)
        case start(id: UUID)
        case stop(id: UUID)
        case fetchLastStartError(id: UUID)
        case fetchDeviceStatus(id: UUID)
        case sendProviderMessage(id: UUID, message: ProviderMessage)
        case refreshStatuses
        case setConfigurationChangeObservationPaused(Bool)
    }

    enum StartErrorSource: Equatable, Sendable {
        case disconnectError(TunnelStartError)
        case unrecognizedDisconnectFallback(TunnelStartError)
        case providerMessageFallback(TunnelStartError)
        case none
    }

    private let eventHub = BackendEventHub()
    private var recordsByID: [UUID: TunnelRecord] = [:]
    private var configurationChangeObservationPaused = false

    private(set) var recordedCalls: [RecordedCall] = []

    var loadError: TunnelError?
    var saveError: TunnelError?
    var onDemandError: TunnelError?
    var removeError: TunnelError?
    var startErrors: [UUID: TunnelError] = [:]
    var scriptedStartStatuses: [UUID: [TunnelStatus]] = [:]
    var scriptedStopStatuses: [UUID: [TunnelStatus]] = [:]
    var suppressStatusEventsOnStart: Set<UUID> = []
    var suppressStatusEventsOnStop: Set<UUID> = []
    var deviceStatuses: [UUID: DeviceStatus] = [:]
    var startErrorSources: [UUID: StartErrorSource] = [:]
    var transitionDelay: Duration = .zero

    nonisolated let saveNewDeactivatesActiveTunnel: Bool

    init(
        initialRecords: [TunnelRecord] = [],
        initialDeviceStatuses: [UUID: DeviceStatus] = [:],
        simulateSaveNewDeactivatesActiveTunnel: Bool = false
    ) {
        self.saveNewDeactivatesActiveTunnel = simulateSaveNewDeactivatesActiveTunnel
        self.deviceStatuses = initialDeviceStatuses
        for record in initialRecords {
            recordsByID[record.id] = record
        }
    }

    deinit {
        eventHub.finish()
    }

    nonisolated func events() -> AsyncStream<BackendEvent> {
        eventHub.stream()
    }

    func setConfigurationChangeObservationPaused(_ paused: Bool) async {
        recordedCalls.append(.setConfigurationChangeObservationPaused(paused))
        configurationChangeObservationPaused = paused
    }

    func loadAll() async throws -> [TunnelRecord] {
        recordedCalls.append(.loadAll)
        if let loadError {
            throw loadError
        }
        return recordsByID.values.sorted {
            $0.profile.name.localizedStandardCompare($1.profile.name) == .orderedAscending
        }
    }

    func save(
        _ profile: TunnelProfile,
        onDemandPolicy: OnDemandPolicy,
        isOnDemandEnabled: Bool,
        localSettings: TunnelLocalSettings,
        replacing id: UUID?
    ) async throws -> TunnelRecord {
        let normalizedPolicy = onDemandPolicy.normalized()
        let effectiveOnDemand = normalizedPolicy.hasRules && isOnDemandEnabled
        recordedCalls.append(.save(
            name: profile.name,
            replacing: id,
            onDemandPolicy: normalizedPolicy,
            isOnDemandEnabled: effectiveOnDemand
        ))
        if let saveError {
            throw saveError
        }

        let targetID: UUID
        let currentStatus: TunnelStatus
        if let id {
            guard let existing = recordsByID[id] else {
                throw TunnelError.tunnelNotFound
            }
            targetID = id
            currentStatus = existing.status
        } else {
            targetID = UUID()
            currentStatus = .inactive
        }

        let record = TunnelRecord(
            id: targetID,
            profile: profile,
            status: currentStatus,
            onDemandPolicy: normalizedPolicy,
            isOnDemandEnabled: effectiveOnDemand,
            localSettings: localSettings
        )
        recordsByID[targetID] = record

        if id == nil && saveNewDeactivatesActiveTunnel {
            let activeIDs = recordsByID.values
                .filter { $0.id != targetID && ($0.status == .active || $0.status == .activating) }
                .map(\.id)
            for activeID in activeIDs {
                scheduleTransitions([.deactivating, .inactive], for: activeID, emitEvents: true)
            }
        }

        return record
    }

    func setOnDemandEnabled(_ isEnabled: Bool, for id: UUID) async throws -> TunnelRecord {
        recordedCalls.append(.setOnDemandEnabled(id: id, isEnabled: isEnabled))
        if let onDemandError {
            throw onDemandError
        }
        guard var record = recordsByID[id] else {
            throw TunnelError.tunnelNotFound
        }
        record.isOnDemandEnabled = record.onDemandPolicy.hasRules && isEnabled
        recordsByID[id] = record
        return record
    }

    func remove(id: UUID) async throws {
        recordedCalls.append(.remove(id: id))
        if let removeError {
            throw removeError
        }
        guard recordsByID.removeValue(forKey: id) != nil else {
            throw TunnelError.tunnelNotFound
        }
    }

    func start(id: UUID) async throws {
        recordedCalls.append(.start(id: id))
        guard recordsByID[id] != nil else {
            throw TunnelError.tunnelNotFound
        }
        if let error = startErrors[id] {
            throw error
        }

        let sequence = scriptedStartStatuses[id] ?? [.activating, .active]
        let emitEvents = !suppressStatusEventsOnStart.contains(id)
        scheduleTransitions(sequence, for: id, emitEvents: emitEvents)
    }

    func stop(id: UUID) async {
        recordedCalls.append(.stop(id: id))
        guard recordsByID[id] != nil else { return }

        let sequence = scriptedStopStatuses[id] ?? [.deactivating, .inactive]
        let emitEvents = !suppressStatusEventsOnStop.contains(id)
        scheduleTransitions(sequence, for: id, emitEvents: emitEvents)
    }

    func fetchLastStartError(for id: UUID) async -> TunnelStartError? {
        recordedCalls.append(.fetchLastStartError(id: id))
        let source = startErrorSources[id] ?? .none

        // Mirror SystemTunnelBackend's dual path: try disconnect error first, then provider message fallback.
        if let simulatedDisconnectNSError = simulatedDisconnectError(for: source),
           let decoded = TunnelStartError(nsError: simulatedDisconnectNSError) {
            return decoded
        }

        if case .lastStartError(let startError) = await sendProviderMessage(.lastStartError, to: id) {
            return startError
        }
        return nil
    }

    func fetchDeviceStatus(for id: UUID) async -> DeviceStatus? {
        recordedCalls.append(.fetchDeviceStatus(id: id))
        guard let record = recordsByID[id], record.status != .inactive else {
            return nil
        }
        return deviceStatuses[id]
    }

    func sendProviderMessage(_ message: ProviderMessage, to id: UUID) async -> ProviderReply? {
        recordedCalls.append(.sendProviderMessage(id: id, message: message))
        guard recordsByID[id] != nil else { return nil }

        // Round-trip through JSON encoding/decoding to exercise the real IPC codec.
        guard let encodedRequest = try? message.encode(),
              let decodedRequest = try? ProviderMessage.decode(from: encodedRequest) else {
            return nil
        }

        let reply: ProviderReply?
        switch decodedRequest {
        case .status:
            reply = deviceStatuses[id].map(ProviderReply.status)
        case .lastStartError:
            let source = startErrorSources[id] ?? .none
            switch source {
            case .providerMessageFallback(let error),
                 .unrecognizedDisconnectFallback(let error):
                reply = .lastStartError(error)
            case .disconnectError, .none:
                reply = .lastStartError(nil)
            }
        case .updateLocalSettings(let settings):
            if var record = recordsByID[id] {
                record.localSettings = settings
                recordsByID[id] = record
            }
            reply = .acknowledged
        case .debugPhysicalDNSProbe(let name):
            reply = .debugPhysicalDNSProbe(PhysicalDNSProbeResult(name: name))
        }

        guard let reply,
              let encodedReply = try? reply.encode() else {
            return nil
        }
        return try? ProviderReply.decode(from: encodedReply)
    }

    func refreshStatuses() async -> [UUID: TunnelStatus] {
        recordedCalls.append(.refreshStatuses)
        var result: [UUID: TunnelStatus] = [:]
        for (id, record) in recordsByID {
            result[id] = record.status
        }
        return result
    }
}

extension InMemoryTunnelBackend {
    func clearRecordedCalls() {
        recordedCalls.removeAll()
    }

    func setLoadError(_ error: TunnelError?) {
        loadError = error
    }

    func setSaveError(_ error: TunnelError?) {
        saveError = error
    }

    func setOnDemandError(_ error: TunnelError?) {
        onDemandError = error
    }

    func setRemoveError(_ error: TunnelError?) {
        removeError = error
    }

    func setStartError(_ error: TunnelError?, for id: UUID) {
        startErrors[id] = error
    }

    func setScriptedStartStatuses(_ statuses: [TunnelStatus]?, for id: UUID) {
        scriptedStartStatuses[id] = statuses
    }

    func setScriptedStopStatuses(_ statuses: [TunnelStatus]?, for id: UUID) {
        scriptedStopStatuses[id] = statuses
    }

    func setSuppressStatusEventsOnStart(_ suppress: Bool, for id: UUID) {
        if suppress {
            suppressStatusEventsOnStart.insert(id)
        } else {
            suppressStatusEventsOnStart.remove(id)
        }
    }

    func setSuppressStatusEventsOnStop(_ suppress: Bool, for id: UUID) {
        if suppress {
            suppressStatusEventsOnStop.insert(id)
        } else {
            suppressStatusEventsOnStop.remove(id)
        }
    }

    func setDeviceStatus(_ status: DeviceStatus?, for id: UUID) {
        deviceStatuses[id] = status
    }

    func setStartErrorSource(_ source: StartErrorSource, for id: UUID) {
        startErrorSources[id] = source
    }

    func setTransitionDelay(_ delay: Duration) {
        transitionDelay = delay
    }

    func simulateExternalAdd(_ record: TunnelRecord) {
        recordsByID[record.id] = record
        if !configurationChangeObservationPaused {
            eventHub.yield(.configurationsChanged)
        }
    }

    func simulateExternalUpdate(_ record: TunnelRecord) {
        recordsByID[record.id] = record
        if !configurationChangeObservationPaused {
            eventHub.yield(.configurationsChanged)
        }
    }

    func simulateExternalRemove(id: UUID) {
        recordsByID.removeValue(forKey: id)
        if !configurationChangeObservationPaused {
            eventHub.yield(.configurationsChanged)
        }
    }

    func simulateStatusChange(id: UUID, status: TunnelStatus, emitEvent: Bool = true) {
        applyStatus(status, for: id, emitEvent: emitEvent)
    }

    func record(for id: UUID) -> TunnelRecord? {
        recordsByID[id]
    }
}

private extension InMemoryTunnelBackend {
    func simulatedDisconnectError(for source: StartErrorSource) -> NSError? {
        switch source {
        case .disconnectError(let error):
            return error as NSError
        case .unrecognizedDisconnectFallback:
            return NSError(domain: "com.apple.NetworkExtension.TestOther", code: 42)
        case .providerMessageFallback, .none:
            return nil
        }
    }

    func scheduleTransitions(_ statuses: [TunnelStatus], for id: UUID, emitEvents: Bool) {
        let delay = transitionDelay
        if delay == .zero {
            for status in statuses {
                applyStatus(status, for: id, emitEvent: emitEvents)
            }
            return
        }

        Task { [weak self] in
            for status in statuses {
                try? await Task.sleep(for: delay)
                await self?.applyStatus(status, for: id, emitEvent: emitEvents)
            }
        }
    }

    func applyStatus(_ status: TunnelStatus, for id: UUID, emitEvent: Bool) {
        guard var record = recordsByID[id] else { return }
        record.status = status
        recordsByID[id] = record
        if emitEvent {
            eventHub.yield(.statusChanged(tunnelID: id, status: status))
        }
    }
}
