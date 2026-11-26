// SPDX-License-Identifier: MIT

import Dispatch
import Foundation
import SplitGuardCore
import WireGuardEngine

public struct HealthAlertNotification: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case noHandshake
        case stalled
        case recovered
    }

    public let identifier: String
    public let threadIdentifier: String
    public let tunnelID: UUID
    public let tunnelName: String
    public let kind: Kind
    public let killSwitchEnabled: Bool
    public let delaySeconds: Int?
    public let title: String
    public let body: String

    public init(
        identifier: String,
        threadIdentifier: String,
        tunnelID: UUID,
        tunnelName: String,
        kind: Kind,
        killSwitchEnabled: Bool = false,
        delaySeconds: Int? = nil,
        title: String,
        body: String
    ) {
        self.identifier = identifier
        self.threadIdentifier = threadIdentifier
        self.tunnelID = tunnelID
        self.tunnelName = tunnelName
        self.kind = kind
        self.killSwitchEnabled = killSwitchEnabled
        self.delaySeconds = delaySeconds
        self.title = title
        self.body = body
    }
}

public protocol HealthAlertNotificationPosting: Sendable {
    func post(_ notification: HealthAlertNotification)
    func removeDelivered(identifiers: [String])
}

public protocol HealthAlertTimerToken: Sendable {
    func cancel()
}

public protocol HealthAlertScheduling: Sendable {
    func schedule(after seconds: TimeInterval, execute: @escaping @Sendable () -> Void) -> any HealthAlertTimerToken
}

public final class DispatchHealthAlertScheduler: HealthAlertScheduling, @unchecked Sendable {
    private final class Token: HealthAlertTimerToken, @unchecked Sendable {
        private let lock = NSLock()
        private var timer: DispatchSourceTimer?

        init(_ timer: DispatchSourceTimer) {
            self.timer = timer
        }

        func cancel() {
            let active = lock.withLock { () -> DispatchSourceTimer? in
                defer { timer = nil }
                return timer
            }
            active?.cancel()
        }
    }

    private let queue: DispatchQueue

    public init(queue: DispatchQueue = DispatchQueue(label: "SplitGuard.HealthAlertMonitor.timer", qos: .utility)) {
        self.queue = queue
    }

    public func schedule(after seconds: TimeInterval, execute: @escaping @Sendable () -> Void) -> any HealthAlertTimerToken {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let delayMilliseconds = max(0, Int((seconds * 1_000).rounded(.up)))
        timer.schedule(deadline: .now() + .milliseconds(delayMilliseconds), leeway: .milliseconds(250))
        timer.setEventHandler { [weak timer] in
            timer?.cancel()
            execute()
        }
        timer.resume()
        return Token(timer)
    }
}

/// Watches `WireGuardEngine` health and handshake events in the network extension and posts
/// local notifications when a tunnel stays without a working handshake past the configured
/// delay, and again when it recovers.
public final class HealthAlertMonitor: @unchecked Sendable {
    fileprivate struct PendingTimer {
        let id: UUID
        let deadline: Date
        let token: any HealthAlertTimerToken
    }

    fileprivate struct SideEffects {
        var timersToCancel: [any HealthAlertTimerToken] = []
        var scheduleRequest: (id: UUID, delay: TimeInterval)?
        var deliveredIdentifiersToRemove: [String] = []
        var notificationsToPost: [HealthAlertNotification] = []
        var logMessages: [(TunnelLogLevel, String)] = []
    }

    private let tunnelID: UUID
    private let tunnelName: String
    private let killSwitchEnabled: Bool
    private let poster: any HealthAlertNotificationPosting
    private let scheduler: any HealthAlertScheduling
    private let now: @Sendable () -> Date
    private let logHandler: (@Sendable (TunnelLogLevel, String) -> Void)?

    private let lock = NSLock()
    private var isStopped = false
    private var settings: TunnelLocalSettings.HealthAlerts
    private var deviceState: DeviceState
    private var peerHealth: [WireGuardPublicKey: PeerHealth]
    private var unhealthySince: Date?
    private var unhealthyKind: HealthAlertNotification.Kind?
    private var hasPostedUnhealthyAlert = false
    private var pendingTimer: PendingTimer?

    public init(
        tunnelID: UUID,
        tunnelName: String,
        killSwitchEnabled: Bool,
        peerPublicKeys: [WireGuardPublicKey],
        settings: TunnelLocalSettings.HealthAlerts,
        poster: any HealthAlertNotificationPosting,
        scheduler: any HealthAlertScheduling = DispatchHealthAlertScheduler(),
        now: @escaping @Sendable () -> Date = Date.init,
        initialDeviceState: DeviceState = .down,
        logHandler: (@Sendable (TunnelLogLevel, String) -> Void)? = nil
    ) {
        self.tunnelID = tunnelID
        self.tunnelName = tunnelName
        self.killSwitchEnabled = killSwitchEnabled
        self.settings = settings
        self.poster = poster
        self.scheduler = scheduler
        self.now = now
        self.deviceState = initialDeviceState
        self.peerHealth = Dictionary(uniqueKeysWithValues: peerPublicKeys.map { ($0, PeerHealth.idle) })
        self.logHandler = logHandler
    }

    public func handle(_ event: DeviceEvent) {
        let effects = lock.withLock { () -> SideEffects in
            guard !isStopped else { return SideEffects() }
            switch event {
            case .stateChanged(let state):
                deviceState = state
            case .healthChanged(let peerKey, let health):
                peerHealth[peerKey] = health
            case .handshakeGaveUp(let peerKey):
                if peerHealth[peerKey] != .stalled {
                    peerHealth[peerKey] = .noHandshake
                }
            case .handshakeCompleted(let peerKey, _):
                peerHealth[peerKey] = .healthy
            case .handshakeRetry, .endpointChanged, .sendFailed, .socketsRebound, .rebindFailed, .packetsDropped:
                return SideEffects()
            }
            return evaluateLocked()
        }
        perform(effects)
    }

    public func updateSettings(_ newSettings: TunnelLocalSettings.HealthAlerts) {
        let effects = lock.withLock { () -> SideEffects in
            guard !isStopped else { return SideEffects() }
            settings = newSettings
            return evaluateLocked()
        }
        perform(effects)
    }

    public func stop() {
        let effects = lock.withLock { () -> SideEffects in
            isStopped = true
            var effects = SideEffects()
            cancelPendingTimerLocked(&effects)
            unhealthySince = nil
            unhealthyKind = nil
            hasPostedUnhealthyAlert = false
            return effects
        }
        perform(effects)
    }

    public static func formatDelay(_ seconds: Int) -> String {
        let clamped = max(1, seconds)
        if clamped < 60 {
            return clamped == 1 ? "1 second" : "\(clamped) seconds"
        }
        let minutes = clamped / 60
        let remainder = clamped % 60
        if remainder == 0 {
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return "\(minutes)m \(remainder)s"
    }

    public static func combinedPeerHealth(from peers: some Collection<PeerHealth>) -> PeerHealth {
        if peers.contains(.noHandshake) {
            return .noHandshake
        }
        if peers.contains(.stalled) {
            return .stalled
        }
        if peers.contains(.connecting) {
            return .connecting
        }
        if peers.contains(.healthy) {
            return .healthy
        }
        return .idle
    }
}

private extension HealthAlertMonitor {
    var threadIdentifier: String {
        "splitguard.tunnel.\(tunnelID.uuidString)"
    }

    var unhealthyNotificationID: String {
        "splitguard.health.\(tunnelID.uuidString).unhealthy"
    }

    var recoveredNotificationID: String {
        "splitguard.health.\(tunnelID.uuidString).recovered"
    }

    func evaluateLocked() -> SideEffects {
        var effects = SideEffects()

        guard settings.isEnabled else {
            cancelPendingTimerLocked(&effects)
            unhealthySince = nil
            unhealthyKind = nil
            hasPostedUnhealthyAlert = false
            return effects
        }

        guard deviceState == .up else {
            cancelPendingTimerLocked(&effects)
            unhealthySince = nil
            unhealthyKind = nil
            if deviceState == .down {
                hasPostedUnhealthyAlert = false
            }
            return effects
        }

        let combined = Self.combinedPeerHealth(from: peerHealth.values)
        switch combined {
        case .noHandshake, .stalled:
            let kind: HealthAlertNotification.Kind = (combined == .stalled) ? .stalled : .noHandshake
            unhealthyKind = kind
            let currentTime = now()
            let startedAt = unhealthySince ?? currentTime
            unhealthySince = startedAt

            guard !hasPostedUnhealthyAlert else { return effects }

            let deadline = startedAt.addingTimeInterval(TimeInterval(settings.delaySeconds))
            let remaining = deadline.timeIntervalSince(currentTime)
            if remaining <= 0 {
                cancelPendingTimerLocked(&effects)
                hasPostedUnhealthyAlert = true
                let notification = makeUnhealthyNotification(kind: kind, delaySeconds: settings.delaySeconds)
                effects.deliveredIdentifiersToRemove.append(recoveredNotificationID)
                effects.notificationsToPost.append(notification)
                effects.logMessages.append((.verbose, "Health alert posted (\(kind.rawValue)) for '\(tunnelName)'"))
            } else if pendingTimer == nil || abs(pendingTimer!.deadline.timeIntervalSince(deadline)) > 0.01 {
                cancelPendingTimerLocked(&effects)
                let timerID = UUID()
                effects.scheduleRequest = (id: timerID, delay: remaining)
                pendingTimer = PendingTimer(id: timerID, deadline: deadline, token: PlaceholderToken())
            }

        case .connecting:
            // Keep any active unhealthy countdown running across handshake retries.
            break

        case .healthy:
            cancelPendingTimerLocked(&effects)
            unhealthySince = nil
            unhealthyKind = nil
            if hasPostedUnhealthyAlert {
                hasPostedUnhealthyAlert = false
                let notification = makeRecoveredNotification()
                effects.notificationsToPost.append(notification)
                effects.logMessages.append((.verbose, "Health recovery alert posted for '\(tunnelName)'"))
            }

        case .idle:
            cancelPendingTimerLocked(&effects)
            unhealthySince = nil
            unhealthyKind = nil
        }

        return effects
    }

    func handleTimerFired(id timerID: UUID) {
        let effects = lock.withLock { () -> SideEffects in
            var effects = SideEffects()
            guard !isStopped,
                  settings.isEnabled,
                  deviceState == .up,
                  !hasPostedUnhealthyAlert,
                  pendingTimer?.id == timerID,
                  unhealthySince != nil else {
                return effects
            }

            pendingTimer = nil
            hasPostedUnhealthyAlert = true
            let kind = unhealthyKind ?? .noHandshake
            let notification = makeUnhealthyNotification(kind: kind, delaySeconds: settings.delaySeconds)
            effects.deliveredIdentifiersToRemove.append(recoveredNotificationID)
            effects.notificationsToPost.append(notification)
            effects.logMessages.append((.verbose, "Health alert posted (\(kind.rawValue)) for '\(tunnelName)'"))
            return effects
        }
        perform(effects)
    }

    func cancelPendingTimerLocked(_ effects: inout SideEffects) {
        if let pending = pendingTimer {
            pendingTimer = nil
            effects.timersToCancel.append(pending.token)
        }
    }

    func perform(_ effects: SideEffects) {
        for token in effects.timersToCancel {
            token.cancel()
        }

        if let request = effects.scheduleRequest {
            let token = scheduler.schedule(after: request.delay) { [weak self] in
                self?.handleTimerFired(id: request.id)
            }
            let shouldCancelImmediately = lock.withLock { () -> Bool in
                guard !isStopped, var current = pendingTimer, current.id == request.id else {
                    return true
                }
                current = PendingTimer(id: current.id, deadline: current.deadline, token: token)
                pendingTimer = current
                return false
            }
            if shouldCancelImmediately {
                token.cancel()
            }
        }

        if !effects.deliveredIdentifiersToRemove.isEmpty {
            poster.removeDelivered(identifiers: effects.deliveredIdentifiersToRemove)
        }

        for notification in effects.notificationsToPost {
            poster.post(notification)
        }

        if let logHandler {
            for (level, message) in effects.logMessages {
                logHandler(level, message)
            }
        }
    }

    func makeUnhealthyNotification(kind: HealthAlertNotification.Kind, delaySeconds: Int) -> HealthAlertNotification {
        let duration = Self.formatDelay(delaySeconds)
        let title: String
        let body: String

        if killSwitchEnabled {
            title = "\(tunnelName): Traffic blocked"
            body = "No working handshake for \(duration). Traffic is blocked until the server responds."
        } else if kind == .stalled {
            title = "\(tunnelName): Connection stalled"
            body = "Sent traffic has received no answer for \(duration)."
        } else {
            title = "\(tunnelName): No handshake"
            body = "No working handshake for \(duration). Check the peer key, endpoint, or network."
        }

        return HealthAlertNotification(
            identifier: unhealthyNotificationID,
            threadIdentifier: threadIdentifier,
            tunnelID: tunnelID,
            tunnelName: tunnelName,
            kind: kind,
            killSwitchEnabled: killSwitchEnabled,
            delaySeconds: delaySeconds,
            title: title,
            body: body
        )
    }

    func makeRecoveredNotification() -> HealthAlertNotification {
        let body = killSwitchEnabled
            ? "Handshake succeeded. Tunnel traffic has resumed."
            : "Handshake succeeded and the tunnel is healthy again."
        return HealthAlertNotification(
            identifier: recoveredNotificationID,
            threadIdentifier: threadIdentifier,
            tunnelID: tunnelID,
            tunnelName: tunnelName,
            kind: .recovered,
            killSwitchEnabled: killSwitchEnabled,
            delaySeconds: nil,
            title: "\(tunnelName): Connection recovered",
            body: body
        )
    }

    private struct PlaceholderToken: HealthAlertTimerToken {
        func cancel() {}
    }
}
