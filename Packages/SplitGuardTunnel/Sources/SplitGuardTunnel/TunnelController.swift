// SPDX-License-Identifier: MIT

import Dispatch
import Foundation
import Network
import NetworkExtension
import SplitGuardCore
import WireGuardEngine

public enum TunnelLogLevel: Int32, Sendable {
    case verbose = 0
    case error = 1
}

public enum EndpointResolutionPolicy: Sendable, Equatable {
    case required
    case bestEffort
}

public enum TunnelControllerError: Error, Sendable {
    case invalidState
    case dnsResolution([EndpointResolutionError])
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
    func cancelTunnelWithError(_ error: Error?)
}

extension NEPacketTunnelProvider: TunnelProviderHost {}

struct TunnelNetworkPath: Sendable, Equatable {
    let isSatisfiable: Bool
    let summary: String
    let physicalInterfaceIndex: UInt32?

    init(isSatisfiable: Bool, summary: String, physicalInterfaceIndex: UInt32? = nil) {
        self.isSatisfiable = isSatisfiable
        self.summary = summary
        self.physicalInterfaceIndex = physicalInterfaceIndex
    }
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
                        summary: "\(path.status) route and interface order \(path.availableInterfaces)",
                        physicalInterfaceIndex: path.status == .satisfied ? Self.physicalInterfaceIndex(
                            from: path.availableInterfaces.map { ($0.type, $0.index, $0.name) },
                            usesInterfaceType: path.usesInterfaceType
                        ) : nil
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

    static func physicalInterfaceIndex(
        from interfaces: [(type: NWInterface.InterfaceType, index: Int, name: String)],
        usesInterfaceType: (NWInterface.InterfaceType) -> Bool
    ) -> UInt32? {
        // Network.framework can report multiple eligible interfaces or interface types.
        let physicalTypes: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet]
        let usedTypes = physicalTypes.filter(usesInterfaceType)
        guard usedTypes.count == 1, let type = usedTypes.first else { return nil }
        let indices = Set(interfaces.compactMap { interface -> UInt32? in
            guard interface.type == type, interface.index > 0 else { return nil }
            return UInt32(exactly: interface.index)
        })
        return indices.count == 1 ? indices.first : nil
    }
}

/// SplitGuard-owned tunnel controller bridging `NEPacketTunnelProvider` and `WireGuardDevice`
/// using typed configuration, typed status snapshots, structured engine events, in-place
/// pause/resume across network transitions, split DNS exclusion interception, and best-effort
/// endpoint resolution with caching for kill-switch tunnels.
public final class TunnelController: @unchecked Sendable {
    private typealias Completion = @Sendable (TunnelControllerError?) -> Void

    private struct AppliedTunnel {
        let device: WireGuardDevice
        let tunnel: PacketFlowTunnelDevice
        let networkSettings: NEPacketTunnelNetworkSettings
        let profile: TunnelProfile
        var paused = false
        var pendingHostnameIndices: Set<Int>
    }

    private struct PreparedConfiguration {
        let networkSettings: NEPacketTunnelNetworkSettings
        let deviceConfiguration: DeviceConfiguration
        let profile: TunnelProfile
        let pendingHostnameIndices: Set<Int>
        let pathRevision: UInt64
    }

    private enum State {
        case stopped
        case running(AppliedTunnel)
        case awaitingProviderStop
    }

    private enum SettingsOperation {
        case start(AppliedTunnel, Completion)
        case update(PreparedConfiguration, Completion)
        case rollback(originalError: TunnelControllerError, Completion)

        var completion: Completion {
            switch self {
            case .start(_, let completion), .update(_, let completion), .rollback(_, let completion):
                return completion
            }
        }
    }

    private enum SettingsError: Error {
        case rejected(Error)
        case timeout
        case cancelled

        var controllerError: TunnelControllerError {
            switch self {
            case .rejected(let error): return .setNetworkSettings(error)
            case .timeout: return .setNetworkSettings(URLError(.timedOut))
            case .cancelled: return .invalidState
            }
        }
    }

    private struct SettingsRequest {
        let id: UUID
        // A timed-out request still owns the settings slot until its callback or provider stop.
        var operation: SettingsOperation?
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

    /// Capped exponential backoff for rebind/resume/endpoint retries (500ms, 1s, 2s, 4s, 8s, capped at 10s).
    static func defaultRetryDelayMilliseconds(forAttempt attempt: Int) -> Int {
        guard attempt > 0 else { return 500 }
        return min(10_000, 500 << min(attempt - 1, 5))
    }

    private weak var provider: (any TunnelProviderHost)?
    private let logHandler: @Sendable (TunnelLogLevel, String) -> Void
    private let makeTransport: () -> UDPTransport
    private let beforePublishingActiveDevice: () -> Void
    private let retryDelayMilliseconds: (Int) -> Int
    private let makePathMonitor: () -> PathMonitoring
    private let pauseOnOffline: Bool
    private let endpointCache: any EndpointCaching
    private let resolveEndpoints: @Sendable ([Endpoint?]) -> [Result<IPEndpoint, EndpointResolutionError>?]
    private let reresolveEndpoint: (IPEndpoint) throws -> IPEndpoint
    private let scheduleSettingsTimeout: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let physicalResolver: any PhysicalResolver

    private let workQueue = DispatchQueue(label: "SplitGuard.TunnelController.work")
    private let retryTimer: DispatchSourceTimer
    private var nextRetry: DispatchTime?
    private var pendingSocketOperation: RetryOperation?
    private var retryAttempts = 0

    private var state: State = .stopped
    private var settingsRequest: SettingsRequest?
    private var packetFlowReader: PacketFlowReader?
    private var pathMonitor: PathMonitoring?
    private var pathMonitorID: UUID?
    private var latestPath: TunnelNetworkPath?
    private var pathRevision: UInt64 = 0

    private let eventHandlerLock = NSLock()
    private var eventHandler: (@Sendable (DeviceEvent) -> Void)?

    private let activeDeviceLock = NSLock()
    private var activeDevice: WireGuardDevice?
    private var installedHook: (hook: any PacketHook, filter: PacketHookFilter)?
    private var activeInterceptor: SplitDNSInterceptor?

    private let physicalInterfaceLock = NSLock()
    private var physicalInterfaceIndexStorage: UInt32?

    public var onEvent: (@Sendable (DeviceEvent) -> Void)? {
        get { eventHandlerLock.withLock { eventHandler } }
        set { eventHandlerLock.withLock { eventHandler = newValue } }
    }

    public var currentPhysicalInterfaceIndex: UInt32? {
        physicalInterfaceLock.withLock { physicalInterfaceIndexStorage }
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
            endpointCache: FileEndpointCache(),
            resolveEndpoints: { EndpointResolver.resolve($0) },
            physicalResolver: DNSSDResolver(),
            logHandler: logHandler
        )
    }

    init(
        provider: any TunnelProviderHost,
        makeTransport: @escaping () -> UDPTransport = { BSDUDPTransport() },
        beforePublishingActiveDevice: @escaping () -> Void = {},
        retryDelayMilliseconds: @escaping (Int) -> Int = TunnelController.defaultRetryDelayMilliseconds,
        makePathMonitor: @escaping () -> PathMonitoring = { SystemPathMonitor() },
        pauseOnOffline: Bool = TunnelController.defaultPauseOnOffline,
        endpointCache: any EndpointCaching = FileEndpointCache(fileURL: nil),
        resolveEndpoints: @escaping @Sendable ([Endpoint?]) -> [Result<IPEndpoint, EndpointResolutionError>?] = {
            EndpointResolver.resolve($0)
        },
        reresolveEndpoint: @escaping (IPEndpoint) throws -> IPEndpoint = EndpointResolver.reresolve,
        scheduleSettingsTimeout: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { expire in
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(5), execute: expire)
        },
        physicalResolver: any PhysicalResolver = DNSSDResolver(),
        logHandler: @escaping @Sendable (TunnelLogLevel, String) -> Void
    ) {
        self.provider = provider
        self.makeTransport = makeTransport
        self.beforePublishingActiveDevice = beforePublishingActiveDevice
        self.retryDelayMilliseconds = retryDelayMilliseconds
        self.makePathMonitor = makePathMonitor
        self.pauseOnOffline = pauseOnOffline
        self.endpointCache = endpointCache
        self.resolveEndpoints = resolveEndpoints
        self.reresolveEndpoint = reresolveEndpoint
        self.scheduleSettingsTimeout = scheduleSettingsTimeout
        self.physicalResolver = physicalResolver
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
        if case .running(let applied) = state {
            activeDeviceLock.withLock { activeDevice = nil }
            let device = applied.device
            workQueue.async { device.close() }
        }
        if let operation = settingsRequest?.operation {
            if case .start(let prepared, _) = operation {
                let device = prepared.device
                workQueue.async { device.close() }
            } else {
                provider?.reasserting = false
            }
            let completion = operation.completion
            workQueue.async { completion(.invalidState) }
        }
    }

    // MARK: - Public Control API

    public func start(
        profile: TunnelProfile,
        endpointResolution: EndpointResolutionPolicy? = nil,
        completionHandler: @escaping @Sendable (TunnelControllerError?) -> Void
    ) {
        let effectivePolicy = endpointResolution ?? (profile.options.killSwitch.isEnabled ? .bestEffort : .required)
        workQueue.async { [weak self] in
            guard let self, case .stopped = self.state,
                  self.settingsRequest == nil, let provider = self.provider else {
                completionHandler(.invalidState)
                return
            }
            self.physicalInterfaceLock.withLock { self.physicalInterfaceIndexStorage = nil }

            do {
                let prepared = try self.prepareConfiguration(for: profile, policy: effectivePolicy)
                let reader = self.packetFlowReader ?? PacketFlowReader(flow: provider.packetFlow)
                self.packetFlowReader = reader
                let tunnel = PacketFlowTunnelDevice(reader: reader, mtu: prepared.networkSettings.mtu?.intValue ?? 0)
                let device: WireGuardDevice
                do {
                    device = try WireGuardDevice(tunnel: tunnel, transport: self.makeTransport())
                } catch {
                    throw TunnelControllerError.startEngine(error)
                }

                do {
                    try device.apply(prepared.deviceConfiguration)
                } catch {
                    device.close()
                    throw TunnelControllerError.configuration(error)
                }

                let applying = AppliedTunnel(
                    device: device,
                    tunnel: tunnel,
                    networkSettings: prepared.networkSettings,
                    profile: prepared.profile,
                    pendingHostnameIndices: prepared.pendingHostnameIndices
                )
                self.beginSettingsRequest(
                    prepared.networkSettings,
                    on: provider,
                    operation: .start(applying, completionHandler)
                )
            } catch let error as TunnelControllerError {
                completionHandler(error)
            } catch {
                completionHandler(.startEngine(error))
            }
        }
    }

    public func stop(completionHandler: @escaping @Sendable (TunnelControllerError?) -> Void) {
        workQueue.async {
            if case .stopped = self.state, self.settingsRequest == nil {
                completionHandler(.invalidState)
                return
            }

            self.closeAppliedTunnel()
            self.state = .stopped
            let retired = self.settingsRequest?.operation
            // Provider stop retires the OS request even if its callback never arrived.
            self.settingsRequest = nil
            if let retired {
                self.finishSettingsOperation(retired, result: .failure(.cancelled))
            }
            completionHandler(nil)
        }
    }

    public func update(
        profile: TunnelProfile,
        endpointResolution: EndpointResolutionPolicy? = nil,
        completionHandler: @escaping @Sendable (TunnelControllerError?) -> Void
    ) {
        workQueue.async {
            guard case .running = self.state,
                  self.settingsRequest == nil, let provider = self.provider else {
                completionHandler(.invalidState)
                return
            }

            let effectivePolicy = endpointResolution ?? (profile.options.killSwitch.isEnabled ? .bestEffort : .required)
            do {
                let prepared = try self.prepareConfiguration(for: profile, policy: effectivePolicy)
                provider.reasserting = true
                self.beginSettingsRequest(
                    prepared.networkSettings,
                    on: provider,
                    operation: .update(prepared, completionHandler)
                )
            } catch let error as TunnelControllerError {
                completionHandler(error)
            } catch {
                completionHandler(.configuration(error))
            }
        }
    }

    public func wake() {
        workQueue.async {
            if case .running(let applied) = self.state {
                applied.device.reevaluateDeadlines()
            }
        }
    }

    public func status(completionHandler: @escaping @Sendable (DeviceStatus?) -> Void) {
        workQueue.async {
            guard case .running(let applied) = self.state else {
                completionHandler(nil)
                return
            }
            completionHandler(applied.device.status())
        }
    }

    public func initiateHandshake(for publicKey: WireGuardPublicKey) {
        let device = activeDeviceLock.withLock { activeDevice }
        device?.initiateHandshake(for: publicKey)
    }

    /// Runs a diagnostic physical-interface DNS lookup using the active physical resolver.
    public func probePhysicalDNS(
        name: String,
        recordType: UInt16 = 1,
        recordClass: UInt16 = 1,
        completion: @escaping @Sendable (Result<DNSLookupResponse, Error>, UInt32?) -> Void
    ) {
        let interfaceIndex = currentPhysicalInterfaceIndex
        physicalResolver.resolve(
            name: name,
            recordType: recordType,
            recordClass: recordClass,
            interfaceIndex: interfaceIndex
        ) { result in
            completion(result, interfaceIndex)
        }
    }

    // MARK: - Internal Hook & Packet Delivery

    func setHook(_ hook: (any PacketHook)?, matching filter: PacketHookFilter) {
        let device: WireGuardDevice? = activeDeviceLock.withLock {
            installedHook = hook.map { ($0, filter) }
            return activeDevice
        }
        device?.setHook(hook, matching: filter)
    }

    func clearHook() {
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

    private func configureSplitDNSInterceptor(for profile: TunnelProfile, device: WireGuardDevice) {
        guard !profile.splitDNS.exclusions.isEmpty else {
            clearActiveInterceptorIfNeeded()
            return
        }

        let dnsHosts = Set(profile.interface.dnsServers)
        guard !dnsHosts.isEmpty else {
            clearActiveInterceptorIfNeeded()
            return
        }

        let interceptor = SplitDNSInterceptor(
            configuration: profile.splitDNS,
            dnsServers: profile.interface.dnsServers,
            resolver: physicalResolver,
            interfaceIndexProvider: { [weak self] in
                self?.currentPhysicalInterfaceIndex
            },
            deliverToTunnel: { [weak device] packet in
                guard let device else { throw PacketDeliveryError.deviceNotRunning }
                try device.deliverToTunnel(packet)
            },
            logHandler: logHandler
        )
        activeDeviceLock.withLock {
            activeInterceptor = interceptor
        }
        setHook(interceptor, matching: .udp(port: 53, hosts: dnsHosts))
        logHandler(
            .verbose,
            "Split DNS exclusion interceptor installed for \(profile.splitDNS.exclusions.count) exclusion(s)"
        )
    }

    private func clearActiveInterceptorIfNeeded() {
        let hadInterceptor: Bool = activeDeviceLock.withLock {
            let active = activeInterceptor != nil
            activeInterceptor = nil
            return active
        }
        if hadInterceptor {
            clearHook()
        }
    }

    // MARK: - Network Settings Operations

    private func prepareConfiguration(
        for profile: TunnelProfile,
        policy: EndpointResolutionPolicy
    ) throws -> PreparedConfiguration {
        let (resolvedTunnel, unresolvedHostnames) = try resolveTunnel(for: profile, policy: policy)
        var pendingIndices = unresolvedHostnames
        let endpoints = resolveEffectiveEndpoints(
            for: resolvedTunnel,
            policy: policy,
            pendingHostnameIndices: &pendingIndices
        )
        do {
            let deviceConfiguration = try ResolvedTunnel(profile: profile, endpoints: endpoints).makeDeviceConfiguration()
            return PreparedConfiguration(
                networkSettings: try NetworkSettingsBuilder.build(for: profile),
                deviceConfiguration: deviceConfiguration,
                profile: profile,
                pendingHostnameIndices: pendingIndices,
                pathRevision: pathRevision
            )
        } catch {
            throw TunnelControllerError.configuration(error)
        }
    }

    private func beginSettingsRequest(
        _ settings: NEPacketTunnelNetworkSettings,
        on provider: any TunnelProviderHost,
        operation: SettingsOperation
    ) {
        assert(settingsRequest == nil)
        let id = UUID()
        settingsRequest = SettingsRequest(id: id, operation: operation)
        scheduleSettingsTimeout { [weak self] in
            self?.workQueue.async { [weak self] in
                guard let self, self.settingsRequest?.id == id else { return }
                self.abandonSettingsRequest(with: .timeout)
            }
        }
        provider.setTunnelNetworkSettings(settings) { [weak self] error in
            self?.workQueue.async { [weak self] in
                self?.receiveSettingsResponse(error, id: id)
            }
        }
    }

    private func receiveSettingsResponse(_ error: Error?, id: UUID) {
        guard let request = settingsRequest, request.id == id else { return }
        settingsRequest = nil
        guard let operation = request.operation else { return }
        let result: Result<Void, SettingsError> = error.map { .failure(.rejected($0)) } ?? .success(())
        finishSettingsOperation(operation, result: result)
    }

    private func abandonSettingsRequest(with error: SettingsError) {
        guard let operation = settingsRequest?.operation else { return }
        settingsRequest?.operation = nil
        finishSettingsOperation(operation, result: .failure(error))
    }

    private func finishSettingsOperation(_ operation: SettingsOperation, result: Result<Void, SettingsError>) {
        if case .failure(.timeout) = result {
            logHandler(.error, "Tunnel network settings timed out")
        }
        switch operation {
        case .start(let applying, let completion):
            switch result {
            case .success:
                completion(startEngine(applying))
            case .failure(let error):
                applying.device.close()
                completion(error.controllerError)
            }
        case .update(let prepared, let completion):
            finishUpdate(prepared, result: result, completion: completion)
        case .rollback(let originalError, let completion):
            provider?.reasserting = false
            switch result {
            case .success:
                if case .running(let applied) = state,
                   !applied.paused, applied.device.listenPort == 0 {
                    bumpSockets(applied.device)
                }
            case .failure(.cancelled):
                completion(.invalidState)
                return
            case .failure(let error):
                logHandler(.error, "Restoring prior network settings failed: \(error.controllerError)")
                cancelUnconfirmedTunnel(with: error.controllerError)
            }
            completion(originalError)
        }
    }

    private func startEngine(_ applied: AppliedTunnel) -> TunnelControllerError? {
        let device = applied.device
        device.onEvent = { [weak self] event in
            guard let self else { return }
            Self.logEvent(event, to: self.logHandler)
            self.onEvent?(event)
        }

        configureSplitDNSInterceptor(for: applied.profile, device: device)
        if let hookEntry = activeDeviceLock.withLock({ installedHook }) {
            device.setHook(hookEntry.hook, matching: hookEntry.filter)
        }
        do {
            try device.up()
        } catch {
            clearActiveInterceptorIfNeeded()
            device.close()
            return .startEngine(error)
        }

        #if os(iOS)
        device.disableSomeRoamingForBrokenMobileSemantics()
        #endif

        beforePublishingActiveDevice()
        activeDeviceLock.withLock { activeDevice = device }
        state = .running(applied)
        let monitor = makePathMonitor()
        let monitorID = UUID()
        monitor.onPathUpdate = { [weak self] path in
            self?.workQueue.async { [weak self] in
                guard let self, self.pathMonitorID == monitorID else { return }
                self.didReceivePathUpdate(path)
            }
        }
        pathMonitorID = monitorID
        pathMonitor = monitor
        monitor.start(queue: workQueue)
        scheduleEndpointRetryIfNeeded()
        logHandler(.verbose, "WireGuard engine started (\(Self.engineVersion))")
        return nil
    }

    private func finishUpdate(
        _ prepared: PreparedConfiguration,
        result: Result<Void, SettingsError>,
        completion: @escaping Completion
    ) {
        switch result {
        case .failure(.cancelled):
            provider?.reasserting = false
            completion(.invalidState)
        case .failure(.timeout):
            provider?.reasserting = false
            let error = SettingsError.timeout.controllerError
            cancelUnconfirmedTunnel(with: error)
            completion(error)
        case .failure(let error):
            restoreNetworkSettings(after: error.controllerError, completion: completion)
        case .success:
            guard case .running(let applied) = state else {
                provider?.reasserting = false
                completion(.invalidState)
                return
            }

            do {
                try applied.device.apply(prepared.deviceConfiguration)
            } catch {
                restoreNetworkSettings(after: .configuration(error), completion: completion)
                return
            }

            // WireGuard commits its configuration atomically. Until it accepts the update,
            // the applied state still owns the previous MTU, DNS hook and network settings.
            applied.tunnel.setMTU(prepared.networkSettings.mtu?.intValue ?? 0)
            #if os(iOS)
            applied.device.disableSomeRoamingForBrokenMobileSemantics()
            #endif
            configureSplitDNSInterceptor(for: prepared.profile, device: applied.device)
            var updated = AppliedTunnel(
                device: applied.device,
                tunnel: applied.tunnel,
                networkSettings: prepared.networkSettings,
                profile: prepared.profile,
                paused: applied.paused,
                pendingHostnameIndices: prepared.pendingHostnameIndices
            )
            if let latestPath, latestPath.isSatisfiable, prepared.pathRevision != pathRevision {
                refreshEndpoints(for: &updated, refreshAllHostnames: true)
            }
            state = .running(updated)
            scheduleEndpointRetryIfNeeded()
            provider?.reasserting = false
            completion(nil)
        }
    }

    private func restoreNetworkSettings(after error: TunnelControllerError, completion: @escaping Completion) {
        guard case .running(let applied) = state, let provider else {
            cancelUnconfirmedTunnel(with: error)
            completion(error)
            return
        }
        beginSettingsRequest(applied.networkSettings, on: provider, operation: .rollback(originalError: error, completion))
    }

    private func cancelUnconfirmedTunnel(with error: TunnelControllerError) {
        closeAppliedTunnel()
        state = .awaitingProviderStop
        provider?.cancelTunnelWithError(error)
    }

    private func closeAppliedTunnel() {
        cancelRetry()
        pendingSocketOperation = nil
        retryAttempts = 0
        pathMonitorID = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        latestPath = nil
        physicalInterfaceLock.withLock { physicalInterfaceIndexStorage = nil }
        clearActiveInterceptorIfNeeded()
        activeDeviceLock.withLock { activeDevice = nil }
        if case .running(let applied) = state {
            applied.device.close()
        }
    }

    // MARK: - Path Monitoring & Retry Handling

    private func didReceivePathUpdate(_ path: TunnelNetworkPath) {
        guard case .running(var applied) = state else { return }

        let isHandoff = latestPath != nil
        latestPath = path
        pathRevision &+= 1
        physicalInterfaceLock.withLock {
            physicalInterfaceIndexStorage = path.isSatisfiable ? path.physicalInterfaceIndex : nil
        }
        logHandler(.verbose, "Network change detected with \(path.summary)")

        if !path.isSatisfiable && pauseOnOffline {
            guard !applied.paused else { return }
            logHandler(.verbose, "Connectivity offline, pausing engine.")
            cancelRetry()
            pendingSocketOperation = nil
            retryAttempts = 0
            applied.paused = true
            state = .running(applied)
            try? applied.device.pause(reason: .offline)
            return
        }

        if path.isSatisfiable {
            refreshEndpoints(for: &applied, refreshAllHostnames: isHandoff)
        }

        let wasPaused = applied.paused
        applied.paused = false
        state = .running(applied)
        applied.device.reevaluateDeadlines()
        if wasPaused {
            logHandler(.verbose, "Connectivity online, resuming engine.")
        }
        bumpSockets(applied.device)
        scheduleEndpointRetryIfNeeded()
    }

    private func bumpSockets(_ device: WireGuardDevice) {
        cancelRetry()
        pendingSocketOperation = nil
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
            pendingSocketOperation = nil
            retryAttempts = 0
            device.sendKeepalivesToPeersWithCurrentKeypair()
        } catch {
            pendingSocketOperation = .rebind
            scheduleRetryTimer()
        }
    }

    private func attemptResume(_ device: WireGuardDevice) {
        cancelRetry()
        retryAttempts += 1
        do {
            try device.resume(attempt: retryAttempts, final: false)
            pendingSocketOperation = nil
            retryAttempts = 0
            #if os(iOS)
            device.disableSomeRoamingForBrokenMobileSemantics()
            #endif
            device.sendKeepalivesToPeersWithCurrentKeypair()
        } catch {
            pendingSocketOperation = .resume
            scheduleRetryTimer()
        }
    }

    private func scheduleEndpointRetryIfNeeded() {
        guard case .running(let applied) = state,
              !applied.paused,
              !applied.pendingHostnameIndices.isEmpty,
              nextRetry == nil else {
            return
        }
        retryAttempts = max(1, retryAttempts + 1)
        scheduleRetryTimer()
    }

    private func scheduleRetryTimer() {
        let delay = max(1, retryDelayMilliseconds(max(1, retryAttempts)))
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
        guard case .running(var applied) = state, !applied.paused else {
            cancelRetry()
            pendingSocketOperation = nil
            return
        }

        cancelRetry()

        if let socketOperation = pendingSocketOperation {
            switch socketOperation {
            case .rebind:
                attemptRebind(applied.device)
            case .resume:
                attemptResume(applied.device)
            }
        }

        if !applied.pendingHostnameIndices.isEmpty {
            refreshHostnameEndpoints(for: &applied)
            state = .running(applied)
            if applied.pendingHostnameIndices.isEmpty && pendingSocketOperation == nil {
                retryAttempts = 0
            } else {
                scheduleEndpointRetryIfNeeded()
            }
        }
    }

    private func refreshEndpoints(for applied: inout AppliedTunnel, refreshAllHostnames: Bool) {
        if refreshAllHostnames {
            applied.pendingHostnameIndices.formUnion(applied.profile.peers.indices.filter {
                applied.profile.peers[$0].endpoint?.hostname != nil
            })
        }
        refreshHostnameEndpoints(for: &applied)

        if pauseOnOffline {
            var updates: [WireGuardPublicKey: IPEndpoint?] = [:]
            for peer in applied.profile.peers {
                guard let literal = peer.endpoint?.ipEndpoint,
                      let adapted = adaptEndpoint(literal) else { continue }
                updates[peer.publicKey] = adapted
            }
            if !updates.isEmpty {
                applied.device.updateEndpoints(updates)
            }
        }
        #if os(iOS)
        applied.device.disableSomeRoamingForBrokenMobileSemantics()
        #endif
    }

    private func refreshHostnameEndpoints(for applied: inout AppliedTunnel) {
        guard !applied.pendingHostnameIndices.isEmpty else { return }
        let peers = applied.profile.peers
        let indices = applied.pendingHostnameIndices.sorted()
        let results = resolveEndpoints(indices.map { peers[$0].endpoint })
        var updates: [WireGuardPublicKey: IPEndpoint?] = [:]

        for (index, result) in zip(indices, results) {
            guard let hostname = peers[index].endpoint?.hostname, let result else { continue }
            switch result {
            case .success(let resolved):
                endpointCache.store(resolvedEndpoint: resolved, for: hostname)
                guard let adapted = adaptEndpoint(resolved) else { continue }
                updates[peers[index].publicKey] = adapted
                applied.pendingHostnameIndices.remove(index)
                logHandler(.verbose, "Resolved pending endpoint \(hostname) to \(resolved.address)")
            case .failure(let error):
                logHandler(
                    .verbose,
                    "Pending endpoint resolution failed for \(hostname): \(error.errorDescription ?? "(nil)")"
                )
            }
        }

        if !updates.isEmpty {
            applied.device.updateEndpoints(updates)
        }
    }

    private func adaptEndpoint(_ endpoint: IPEndpoint) -> IPEndpoint? {
        do {
            let adapted = try reresolveEndpoint(endpoint)
            logEndpointReresolutionResults(initialEndpoints: [endpoint], results: [.success(adapted)])
            return adapted
        } catch {
            logHandler(.error, "Failed to resolve endpoint \(endpoint.address): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Settings & DNS Resolution

    private func resolveTunnel(
        for profile: TunnelProfile,
        policy: EndpointResolutionPolicy
    ) throws -> (ResolvedTunnel, Set<Int>) {
        let endpoints = profile.peers.map(\.endpoint)
        let resolutionResults = resolveEndpoints(endpoints)

        if policy == .required {
            let resolutionErrors = resolutionResults.compactMap { result -> EndpointResolutionError? in
                if case .some(.failure(let error)) = result {
                    return error
                }
                return nil
            }
            guard resolutionErrors.isEmpty else {
                throw TunnelControllerError.dnsResolution(resolutionErrors)
            }
        }

        var resolved: [IPEndpoint?] = []
        resolved.reserveCapacity(endpoints.count)
        var pendingHostnameIndices: Set<Int> = []

        for (index, (originalEndpoint, result)) in zip(endpoints, resolutionResults).enumerated() {
            guard let originalEndpoint else {
                resolved.append(nil)
                continue
            }
            switch result {
            case .some(.success(let endpoint)):
                if let hostname = originalEndpoint.hostname {
                    endpointCache.store(resolvedEndpoint: endpoint, for: hostname)
                }
                resolved.append(endpoint)
            case .some(.failure(let error)):
                if policy == .required {
                    throw TunnelControllerError.dnsResolution([error])
                }
                if let hostname = originalEndpoint.hostname,
                   let cached = endpointCache.cachedEndpoint(for: hostname, port: originalEndpoint.port) {
                    logHandler(
                        .verbose,
                        "DNS resolution failed for \(hostname); starting with cached endpoint \(cached.address)"
                    )
                    resolved.append(cached)
                    pendingHostnameIndices.insert(index)
                } else {
                    logHandler(
                        .verbose,
                        "DNS resolution failed for \(error.address) with no cached address; starting peer without endpoint"
                    )
                    resolved.append(nil)
                    pendingHostnameIndices.insert(index)
                }
            case .none:
                resolved.append(nil)
            }
        }

        return (ResolvedTunnel(profile: profile, endpoints: resolved), pendingHostnameIndices)
    }

    private func resolveEffectiveEndpoints(
        for resolvedTunnel: ResolvedTunnel,
        policy: EndpointResolutionPolicy,
        pendingHostnameIndices: inout Set<Int>
    ) -> [IPEndpoint?] {
        let reresolved = resolvedTunnel.reresolveEndpoints(using: reresolveEndpoint)
        logEndpointReresolutionResults(
            initialEndpoints: resolvedTunnel.endpoints,
            results: reresolved.map(\.1)
        )
        return reresolved.enumerated().map { index, pair in
            switch pair.1 {
            case .some(.success(let endpoint)):
                return endpoint
            case .some(.failure):
                if resolvedTunnel.profile.peers[index].endpoint?.hostname != nil {
                    pendingHostnameIndices.insert(index)
                }
                // Under .bestEffort, keep the initial/cached IP if DNS64 re-resolution fails while offline.
                return policy == .bestEffort ? resolvedTunnel.endpoints[index] : nil
            case .none:
                return nil
            }
        }
    }

    private func logEndpointReresolutionResults(
        initialEndpoints: [IPEndpoint?],
        results: [Result<IPEndpoint, EndpointResolutionError>?]
    ) {
        for (source, result) in zip(initialEndpoints, results) {
            guard let result else { continue }
            switch result {
            case .success(let resolved):
                if source?.address == resolved.address {
                    logHandler(.verbose, "DNS64: mapped \(resolved.address) to itself.")
                } else {
                    let sourceText = source?.address.description ?? "unknown"
                    logHandler(.verbose, "DNS64: mapped \(sourceText) to \(resolved.address)")
                }
            case .failure(let resolutionError):
                logHandler(
                    .error,
                    "Failed to resolve endpoint \(resolutionError.address): \(resolutionError.errorDescription ?? "(nil)")"
                )
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
                logHandler(
                    .verbose,
                    String(format: "Peer %@ handshake completed (%.1f ms)", shortKey(publicKey), milliseconds)
                )
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
