// SPDX-License-Identifier: MIT

import Dispatch
import Foundation
import Network
import NetworkExtension
import WireGuardEngine
import WireGuardKit

public enum TunnelLogLevel: Int32, Sendable {
    case verbose = 0
    case error = 1
}

public enum TunnelControllerError: Error, Sendable {
    case invalidState
    case dnsResolution([DNSResolutionError])
    case setNetworkSettings(Error)
    case configuration(Error)
    case startEngine(Error)
}

public protocol TunnelProviderHost: AnyObject {
    associatedtype Flow: PacketFlow
    var packetFlow: Flow { get }
    var reasserting: Bool { get set }
    func setTunnelNetworkSettings(
        _ tunnelNetworkSettings: NETunnelNetworkSettings?,
        completionHandler: (@Sendable (Error?) -> Void)?
    )
}

extension NEPacketTunnelProvider: TunnelProviderHost {}

struct TunnelNetworkPath: Sendable, Equatable {
    let isSatisfiable: Bool
    let summary: String
}

protocol PathMonitoring: AnyObject, Sendable {
    var onPathUpdate: (@Sendable (TunnelNetworkPath) -> Void)? { get set }
    func start(queue: DispatchQueue)
    func cancel()
}

final class SystemPathMonitor: PathMonitoring, @unchecked Sendable {
    private let monitor = NWPathMonitor()

    var onPathUpdate: (@Sendable (TunnelNetworkPath) -> Void)? {
        didSet {
            if let callback = onPathUpdate {
                monitor.pathUpdateHandler = { path in
                    callback(TunnelNetworkPath(
                        isSatisfiable: path.status.isSatisfiable,
                        summary: "\(path.status) route and interface order \(path.availableInterfaces)"
                    ))
                }
            } else {
                monitor.pathUpdateHandler = nil
            }
        }
    }

    func start(queue: DispatchQueue) {
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }
}

private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

/// SplitGuard-owned tunnel controller bridging `NEPacketTunnelProvider` and `WireGuardDevice`
/// using typed configuration, typed status snapshots, structured engine events, and in-place
/// pause/resume across network transitions.
public final class TunnelController: @unchecked Sendable {
    private enum State {
        case stopped
        case running(
            device: WireGuardDevice,
            tunnel: PacketFlowTunnelDevice,
            settingsGenerator: PacketTunnelSettingsGenerator,
            paused: Bool
        )
    }

    private enum RetryOperation {
        case rebind
        case resume
    }

    public static var engineVersion: String { WireGuardEngineVersion.current }

    #if os(iOS)
    static let defaultPauseOnOffline = true
    #else
    static let defaultPauseOnOffline = false
    #endif

    /// Capped exponential backoff for rebind/resume retries (500ms, 1s, 2s, 4s, 8s, capped at 10s).
    static func defaultRetryDelayMilliseconds(forAttempt attempt: Int) -> Int {
        guard attempt > 0 else { return 500 }
        return min(10_000, 500 << min(attempt - 1, 5))
    }

    private weak var provider: (any TunnelProviderHost)?
    private let logHandler: @Sendable (TunnelLogLevel, String) -> Void
    private let makeTransport: () -> UDPTransport
    private let retryDelayMilliseconds: (Int) -> Int
    private let makePathMonitor: () -> PathMonitoring
    private let pauseOnOffline: Bool

    private let workQueue = DispatchQueue(label: "SplitGuard.TunnelController.work")
    private let retryTimer: DispatchSourceTimer
    private var nextRetry: DispatchTime?
    private var retryOperation: RetryOperation = .rebind
    private var retryAttempts = 0

    private var state: State = .stopped
    private var packetFlowReader: PacketFlowReader?
    private var pathMonitor: PathMonitoring?

    private let eventHandlerLock = NSLock()
    private var eventHandler: (@Sendable (DeviceEvent) -> Void)?

    private let activeDeviceLock = NSLock()
    private var activeDevice: WireGuardDevice?
    private var installedHook: (hook: any PacketHook, filter: PacketHookFilter)?

    public var onEvent: (@Sendable (DeviceEvent) -> Void)? {
        get { eventHandlerLock.withLock { eventHandler } }
        set { eventHandlerLock.withLock { eventHandler = newValue } }
    }

    public convenience init(
        provider: NEPacketTunnelProvider,
        logHandler: @escaping @Sendable (TunnelLogLevel, String) -> Void
    ) {
        self.init(
            provider: provider as any TunnelProviderHost,
            makeTransport: { BSDUDPTransport() },
            retryDelayMilliseconds: Self.defaultRetryDelayMilliseconds,
            makePathMonitor: { SystemPathMonitor() },
            pauseOnOffline: Self.defaultPauseOnOffline,
            logHandler: logHandler
        )
    }

    init(
        provider: any TunnelProviderHost,
        makeTransport: @escaping () -> UDPTransport = { BSDUDPTransport() },
        retryDelayMilliseconds: @escaping (Int) -> Int = TunnelController.defaultRetryDelayMilliseconds,
        makePathMonitor: @escaping () -> PathMonitoring = { SystemPathMonitor() },
        pauseOnOffline: Bool = TunnelController.defaultPauseOnOffline,
        logHandler: @escaping @Sendable (TunnelLogLevel, String) -> Void
    ) {
        self.provider = provider
        self.makeTransport = makeTransport
        self.retryDelayMilliseconds = retryDelayMilliseconds
        self.makePathMonitor = makePathMonitor
        self.pauseOnOffline = pauseOnOffline
        self.logHandler = logHandler

        retryTimer = DispatchSource.makeTimerSource(queue: workQueue)
        retryTimer.setEventHandler { [weak self] in
            self?.handleRetryTimerFired()
        }
        retryTimer.activate()
    }

    deinit {
        retryTimer.cancel()
        pathMonitor?.cancel()
        if case .running(let device, _, _, _) = state {
            activeDeviceLock.withLock { activeDevice = nil }
            workQueue.async { device.close() }
        }
    }

    // MARK: - Public Control API

    public func start(
        tunnelConfiguration: TunnelConfiguration,
        splitDNSConfiguration: SplitDNSConfiguration = .allDomains,
        completionHandler: @escaping @Sendable (TunnelControllerError?) -> Void
    ) {
        let boxedConfig = UncheckedSendableBox(value: tunnelConfiguration)
        workQueue.async { [weak self] in
            guard let self else {
                completionHandler(.invalidState)
                return
            }
            guard case .stopped = self.state else {
                completionHandler(.invalidState)
                return
            }
            guard let provider = self.provider else {
                completionHandler(.invalidState)
                return
            }

            let monitor = self.makePathMonitor()
            monitor.onPathUpdate = { [weak self, weak monitor] path in
                guard let self, let monitor else { return }
                self.workQueue.async {
                    guard self.pathMonitor === monitor else { return }
                    self.didReceivePathUpdate(path)
                }
            }

            do {
                let settingsGenerator = try self.makeSettingsGenerator(
                    with: boxedConfig.value,
                    splitDNSConfiguration: splitDNSConfiguration
                )
                let networkSettings = settingsGenerator.generateNetworkSettings()
                try self.setNetworkSettings(networkSettings, on: provider)

                let reresolved = settingsGenerator.reresolvedEndpoints()
                self.logEndpointResolutionResults(reresolved.map(\.1))
                let effectiveEndpoints: [Endpoint?] = reresolved.map { _, result in
                    if case .some(.success((_, let endpoint))) = result {
                        return endpoint
                    }
                    return nil
                }

                let deviceConfig: DeviceConfiguration
                do {
                    deviceConfig = try settingsGenerator.tunnelConfiguration.makeDeviceConfiguration(
                        resolvedEndpoints: effectiveEndpoints
                    )
                } catch {
                    throw TunnelControllerError.configuration(error)
                }

                let reader = self.packetFlowReader ?? PacketFlowReader(flow: provider.packetFlow)
                self.packetFlowReader = reader
                let tunnel = PacketFlowTunnelDevice(reader: reader, mtu: networkSettings.mtu?.intValue ?? 0)

                let device: WireGuardDevice
                do {
                    device = try WireGuardDevice(tunnel: tunnel, transport: self.makeTransport())
                } catch {
                    throw TunnelControllerError.startEngine(error)
                }

                device.onEvent = { [weak self] event in
                    guard let self else { return }
                    Self.logEvent(event, to: self.logHandler)
                    self.onEvent?(event)
                }

                if let hookEntry = self.activeDeviceLock.withLock({ self.installedHook }) {
                    device.setHook(hookEntry.hook, matching: hookEntry.filter)
                }

                do {
                    try device.apply(deviceConfig)
                } catch {
                    device.close()
                    throw TunnelControllerError.configuration(error)
                }

                do {
                    try device.up()
                } catch {
                    device.close()
                    throw TunnelControllerError.startEngine(error)
                }

                #if os(iOS)
                device.disableSomeRoamingForBrokenMobileSemantics()
                #endif

                self.activeDeviceLock.withLock { self.activeDevice = device }
                self.state = .running(
                    device: device,
                    tunnel: tunnel,
                    settingsGenerator: settingsGenerator,
                    paused: false
                )
                self.pathMonitor = monitor
                monitor.start(queue: self.workQueue)
                self.logHandler(.verbose, "WireGuard engine started (\(Self.engineVersion))")
                completionHandler(nil)
            } catch let error as TunnelControllerError {
                monitor.cancel()
                completionHandler(error)
            } catch {
                monitor.cancel()
                self.logHandler(.error, "Starting tunnel failed with unexpected error: \(error.localizedDescription)")
                completionHandler(.startEngine(error))
            }
        }
    }

    public func stop(completionHandler: @escaping @Sendable (TunnelControllerError?) -> Void) {
        workQueue.async {
            guard case .running(let device, _, _, _) = self.state else {
                completionHandler(.invalidState)
                return
            }

            self.cancelRetry()
            self.retryAttempts = 0
            self.pathMonitor?.cancel()
            self.pathMonitor = nil
            self.activeDeviceLock.withLock { self.activeDevice = nil }
            self.state = .stopped
            device.close()
            completionHandler(nil)
        }
    }

    public func update(
        tunnelConfiguration: TunnelConfiguration,
        splitDNSConfiguration: SplitDNSConfiguration = .allDomains,
        completionHandler: @escaping @Sendable (TunnelControllerError?) -> Void
    ) {
        let boxedConfig = UncheckedSendableBox(value: tunnelConfiguration)
        workQueue.async {
            guard case .running(let device, let tunnel, _, let paused) = self.state,
                  let provider = self.provider else {
                completionHandler(.invalidState)
                return
            }

            provider.reasserting = true
            defer {
                provider.reasserting = false
            }

            do {
                let settingsGenerator = try self.makeSettingsGenerator(
                    with: boxedConfig.value,
                    splitDNSConfiguration: splitDNSConfiguration
                )
                let networkSettings = settingsGenerator.generateNetworkSettings()
                try self.setNetworkSettings(networkSettings, on: provider)

                let reresolved = settingsGenerator.reresolvedEndpoints()
                self.logEndpointResolutionResults(reresolved.map(\.1))
                let effectiveEndpoints: [Endpoint?] = reresolved.map { _, result in
                    if case .some(.success((_, let endpoint))) = result {
                        return endpoint
                    }
                    return nil
                }

                let deviceConfig: DeviceConfiguration
                do {
                    deviceConfig = try settingsGenerator.tunnelConfiguration.makeDeviceConfiguration(
                        resolvedEndpoints: effectiveEndpoints
                    )
                } catch {
                    throw TunnelControllerError.configuration(error)
                }

                tunnel.setMTU(networkSettings.mtu?.intValue ?? 0)
                do {
                    try device.apply(deviceConfig)
                } catch {
                    throw TunnelControllerError.configuration(error)
                }

                #if os(iOS)
                device.disableSomeRoamingForBrokenMobileSemantics()
                #endif

                self.state = .running(
                    device: device,
                    tunnel: tunnel,
                    settingsGenerator: settingsGenerator,
                    paused: paused
                )
                completionHandler(nil)
            } catch let error as TunnelControllerError {
                completionHandler(error)
            } catch {
                self.logHandler(.error, "Updating tunnel failed with unexpected error: \(error.localizedDescription)")
                completionHandler(.configuration(error))
            }
        }
    }

    public func wake() {
        workQueue.async {
            if case .running(let device, _, _, _) = self.state {
                device.reevaluateDeadlines()
            }
        }
    }

    public func status(completionHandler: @escaping @Sendable (DeviceStatus?) -> Void) {
        workQueue.async {
            guard case .running(let device, _, _, _) = self.state else {
                completionHandler(nil)
                return
            }
            completionHandler(device.status())
        }
    }

    public func initiateHandshake(for publicKey: WireGuardPublicKey) {
        let device = activeDeviceLock.withLock { activeDevice }
        device?.initiateHandshake(for: publicKey)
    }

    public func setHook(_ hook: (any PacketHook)?, matching filter: PacketHookFilter) {
        let device: WireGuardDevice? = activeDeviceLock.withLock {
            installedHook = hook.map { ($0, filter) }
            return activeDevice
        }
        device?.setHook(hook, matching: filter)
    }

    public func clearHook() {
        let device: WireGuardDevice? = activeDeviceLock.withLock {
            installedHook = nil
            return activeDevice
        }
        device?.clearHook()
    }

    public func deliverToTunnel(_ packet: Data) throws {
        guard let device = activeDeviceLock.withLock({ activeDevice }) else {
            throw PacketDeliveryError.deviceNotRunning
        }
        try device.deliverToTunnel(packet)
    }

    // MARK: - Path Monitoring & Retry Handling

    private func didReceivePathUpdate(_ path: TunnelNetworkPath) {
        logHandler(.verbose, "Network change detected with \(path.summary)")

        guard case .running(let device, let tunnel, let settingsGenerator, let paused) = state else {
            return
        }

        guard pauseOnOffline else {
            device.reevaluateDeadlines()
            bumpSockets(device)
            return
        }

        if !path.isSatisfiable {
            guard !paused else { return }
            logHandler(.verbose, "Connectivity offline, pausing engine.")
            cancelRetry()
            retryAttempts = 0
            state = .running(
                device: device,
                tunnel: tunnel,
                settingsGenerator: settingsGenerator,
                paused: true
            )
            try? device.pause(reason: .offline)
            return
        }

        let reresolved = settingsGenerator.reresolvedEndpoints()
        logEndpointResolutionResults(reresolved.map(\.1))
        let updates = TunnelConfiguration.endpointUpdates(from: reresolved)
        if !updates.isEmpty {
            device.updateEndpoints(updates)
        }
        #if os(iOS)
        device.disableSomeRoamingForBrokenMobileSemantics()
        #endif

        if paused {
            logHandler(.verbose, "Connectivity online, resuming engine.")
            device.reevaluateDeadlines()
            state = .running(
                device: device,
                tunnel: tunnel,
                settingsGenerator: settingsGenerator,
                paused: false
            )
            cancelRetry()
            retryAttempts = 0
            attemptResume(device)
        } else {
            device.reevaluateDeadlines()
            bumpSockets(device)
        }
    }

    private func bumpSockets(_ device: WireGuardDevice) {
        cancelRetry()
        retryAttempts = 0
        if case .paused = device.status().state {
            attemptResume(device)
        } else {
            attemptRebind(device)
        }
    }

    private func attemptRebind(_ device: WireGuardDevice) {
        cancelRetry()
        retryAttempts += 1
        do {
            try device.rebind(attempt: retryAttempts, final: false)
            retryAttempts = 0
            device.sendKeepalivesToPeersWithCurrentKeypair()
        } catch {
            scheduleRetry(.rebind)
        }
    }

    private func attemptResume(_ device: WireGuardDevice) {
        cancelRetry()
        retryAttempts += 1
        do {
            try device.resume(attempt: retryAttempts, final: false)
            retryAttempts = 0
            #if os(iOS)
            device.disableSomeRoamingForBrokenMobileSemantics()
            #endif
            device.sendKeepalivesToPeersWithCurrentKeypair()
        } catch {
            scheduleRetry(.resume)
        }
    }

    private func scheduleRetry(_ operation: RetryOperation) {
        retryOperation = operation
        let delay = max(1, retryDelayMilliseconds(retryAttempts))
        let deadline = DispatchTime.now() + .milliseconds(delay)
        nextRetry = deadline
        retryTimer.schedule(deadline: deadline)
    }

    private func cancelRetry() {
        nextRetry = nil
        retryTimer.schedule(deadline: .distantFuture)
    }

    private func handleRetryTimerFired() {
        guard let nextRetry else { return }
        if DispatchTime.now() < nextRetry {
            retryTimer.schedule(deadline: nextRetry)
            return
        }
        guard case .running(let device, _, _, let paused) = state, !paused else {
            cancelRetry()
            return
        }
        switch retryOperation {
        case .rebind:
            attemptRebind(device)
        case .resume:
            attemptResume(device)
        }
    }

    // MARK: - Settings & DNS Resolution

    private func makeSettingsGenerator(
        with tunnelConfiguration: TunnelConfiguration,
        splitDNSConfiguration: SplitDNSConfiguration
    ) throws -> PacketTunnelSettingsGenerator {
        let resolvedEndpoints = try resolvePeers(for: tunnelConfiguration)
        return PacketTunnelSettingsGenerator(
            tunnelConfiguration: tunnelConfiguration,
            resolvedEndpoints: resolvedEndpoints,
            splitDNSConfiguration: splitDNSConfiguration
        )
    }

    private func resolvePeers(for tunnelConfiguration: TunnelConfiguration) throws -> [Endpoint?] {
        let endpoints = tunnelConfiguration.peers.map(\.endpoint)
        let resolutionResults = DNSResolver.resolveSync(endpoints: endpoints)
        let resolutionErrors = resolutionResults.compactMap { result -> DNSResolutionError? in
            if case .some(.failure(let error)) = result {
                return error
            }
            return nil
        }
        guard resolutionErrors.isEmpty else {
            throw TunnelControllerError.dnsResolution(resolutionErrors)
        }
        return try resolutionResults.map { result -> Endpoint? in
            guard let result else { return nil }
            switch result {
            case .success(let endpoint):
                return endpoint
            case .failure(let error):
                throw TunnelControllerError.dnsResolution([error])
            }
        }
    }

    private func setNetworkSettings(
        _ networkSettings: NEPacketTunnelNetworkSettings,
        on provider: any TunnelProviderHost
    ) throws {
        final class WaitState: @unchecked Sendable {
            let condition = NSCondition()
            var systemError: Error?
            var completed = false
        }

        let waitState = WaitState()
        provider.setTunnelNetworkSettings(networkSettings) { error in
            waitState.condition.withLock {
                waitState.systemError = error
                waitState.completed = true
                waitState.condition.signal()
            }
        }

        let deadline = Date().addingTimeInterval(5)
        try waitState.condition.withLock {
            while !waitState.completed {
                if !waitState.condition.wait(until: deadline), !waitState.completed {
                    logHandler(.error, "setTunnelNetworkSettings timed out after 5 seconds; proceeding anyway")
                    return
                }
            }
            if let systemError = waitState.systemError {
                throw TunnelControllerError.setNetworkSettings(systemError)
            }
        }
    }

    private func logEndpointResolutionResults(_ resolutionResults: [EndpointResolutionResult?]) {
        for case .some(let result) in resolutionResults {
            switch result {
            case .success((let sourceEndpoint, let resolvedEndpoint)):
                if sourceEndpoint.host == resolvedEndpoint.host {
                    logHandler(.verbose, "DNS64: mapped \(sourceEndpoint.host) to itself.")
                } else {
                    logHandler(.verbose, "DNS64: mapped \(sourceEndpoint.host) to \(resolvedEndpoint.host)")
                }
            case .failure(let resolutionError):
                logHandler(.error, "Failed to resolve endpoint \(resolutionError.address): \(resolutionError.errorDescription ?? "(nil)")")
            }
        }
    }

    // MARK: - Event Formatting

    private static func logEvent(_ event: DeviceEvent, to logHandler: @Sendable (TunnelLogLevel, String) -> Void) {
        switch event {
        case .stateChanged(let state):
            logHandler(.verbose, "WireGuard state changed to \(stateDescription(state))")
        case .healthChanged(let publicKey, let health):
            logHandler(.verbose, "Peer \(shortKey(publicKey)) health changed to \(health.rawValue)")
        case .handshakeCompleted(let publicKey, let roundTrip):
            if let roundTrip {
                let milliseconds = Double(roundTrip.components.seconds) * 1_000
                    + Double(roundTrip.components.attoseconds) / 1e15
                logHandler(.verbose, String(format: "Peer %@ handshake completed (%.1f ms)", shortKey(publicKey), milliseconds))
            } else {
                logHandler(.verbose, "Peer \(shortKey(publicKey)) handshake completed")
            }
        case .handshakeRetry(let publicKey, let attempt):
            logHandler(.verbose, "Peer \(shortKey(publicKey)) handshake retry (attempt \(attempt))")
        case .handshakeGaveUp(let publicKey):
            logHandler(.error, "Peer \(shortKey(publicKey)) handshake gave up after max attempts")
        case .endpointChanged(let publicKey, let endpoint):
            logHandler(.verbose, "Peer \(shortKey(publicKey)) endpoint changed to \(endpoint)")
        case .sendFailed(let publicKey, let code):
            let target = publicKey.map { "peer \(shortKey($0))" } ?? "unassigned destination"
            logHandler(.error, "WireGuard send failed for \(target) (errno \(code))")
        case .socketsRebound(let port):
            logHandler(.verbose, "WireGuard sockets rebound on port \(port)")
        case .rebindFailed(let attempt, let code, let final):
            let suffix = final ? ", final" : ""
            logHandler(.error, "WireGuard rebind failed on attempt \(attempt) (errno \(code)\(suffix))")
        case .packetsDropped(let reason, let count):
            logHandler(.verbose, "WireGuard dropped \(count) packet(s) (\(reason.rawValue))")
        }
    }

    private static func stateDescription(_ state: DeviceState) -> String {
        switch state {
        case .down: return "down"
        case .up: return "up"
        case .paused(let reason): return "paused(\(reason.rawValue))"
        }
    }

    private static func shortKey(_ key: WireGuardPublicKey) -> String {
        String(key.base64.prefix(8)) + "..."
    }
}

private extension Network.NWPath.Status {
    var isSatisfiable: Bool {
        switch self {
        case .requiresConnection, .satisfied:
            return true
        case .unsatisfied:
            return false
        @unknown default:
            return true
        }
    }
}
