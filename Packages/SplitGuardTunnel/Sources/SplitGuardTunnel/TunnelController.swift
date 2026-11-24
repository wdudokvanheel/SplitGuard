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
                        physicalInterfaceIndex: Self.physicalInterfaceIndex(
                            from: path.availableInterfaces.map { ($0.type, $0.index, $0.name) },
                            usesInterfaceType: path.usesInterfaceType
                        )
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
        usesInterfaceType _: (NWInterface.InterfaceType) -> Bool
    ) -> UInt32? {
        if let primary = interfaces.first(where: {
            ($0.type == .wifi || $0.type == .cellular || $0.type == .wiredEthernet) && $0.index > 0
        }) {
            return UInt32(primary.index)
        }
        if let fallback = interfaces.first(where: { interface in
            guard interface.type != .loopback, interface.index > 0 else { return false }
            let name = interface.name
            return !name.hasPrefix("utun")
                && !name.hasPrefix("ipsec")
                && !name.hasPrefix("ppp")
                && !name.hasPrefix("lo")
        }) {
            return UInt32(fallback.index)
        }
        return nil
    }
}

/// SplitGuard-owned tunnel controller bridging `NEPacketTunnelProvider` and `WireGuardDevice`
/// using typed configuration, typed status snapshots, structured engine events, in-place
/// pause/resume across network transitions, split DNS exclusion interception, and best-effort
/// endpoint resolution with caching for kill-switch tunnels.
public final class TunnelController: @unchecked Sendable {
    private enum State {
        case stopped
        case running(
            device: WireGuardDevice,
            tunnel: PacketFlowTunnelDevice,
            resolvedTunnel: ResolvedTunnel,
            paused: Bool,
            endpointResolutionPolicy: EndpointResolutionPolicy,
            pendingHostnameIndices: Set<Int>
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

    /// Capped exponential backoff for rebind/resume/endpoint retries (500ms, 1s, 2s, 4s, 8s, capped at 10s).
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
    private var packetFlowReader: PacketFlowReader?
    private var pathMonitor: PathMonitoring?

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
        if case .running(let device, _, _, _, _, _) = state {
            activeDeviceLock.withLock { activeDevice = nil }
            workQueue.async { device.close() }
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
                let (resolvedTunnel, pendingHostnameIndices) = try self.resolveTunnel(
                    for: profile,
                    policy: effectivePolicy
                )
                let networkSettings = NetworkSettingsBuilder.build(for: profile)
                try self.setNetworkSettings(networkSettings, on: provider)

                let effectiveEndpoints = self.resolveEffectiveEndpoints(
                    for: resolvedTunnel,
                    policy: effectivePolicy
                )
                let effectiveTunnel = ResolvedTunnel(profile: profile, endpoints: effectiveEndpoints)

                let deviceConfig: DeviceConfiguration
                do {
                    deviceConfig = try effectiveTunnel.makeDeviceConfiguration()
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

                self.configureSplitDNSInterceptor(for: profile)

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
                    resolvedTunnel: resolvedTunnel,
                    paused: false,
                    endpointResolutionPolicy: effectivePolicy,
                    pendingHostnameIndices: pendingHostnameIndices
                )
                self.pathMonitor = monitor
                monitor.start(queue: self.workQueue)
                if !pendingHostnameIndices.isEmpty {
                    self.retryAttempts = 1
                    self.scheduleRetryTimer()
                }
                self.logHandler(.verbose, "WireGuard engine started (\(Self.engineVersion))")
                completionHandler(nil)
            } catch let error as TunnelControllerError {
                monitor.cancel()
                self.clearActiveInterceptorIfNeeded()
                completionHandler(error)
            } catch {
                monitor.cancel()
                self.clearActiveInterceptorIfNeeded()
                self.logHandler(.error, "Starting tunnel failed with unexpected error: \(error.localizedDescription)")
                completionHandler(.startEngine(error))
            }
        }
    }

    public func stop(completionHandler: @escaping @Sendable (TunnelControllerError?) -> Void) {
        workQueue.async {
            guard case .running(let device, _, _, _, _, _) = self.state else {
                completionHandler(.invalidState)
                return
            }

            self.cancelRetry()
            self.pendingSocketOperation = nil
            self.retryAttempts = 0
            self.pathMonitor?.cancel()
            self.pathMonitor = nil
            self.physicalInterfaceLock.withLock { self.physicalInterfaceIndexStorage = nil }
            self.clearActiveInterceptorIfNeeded()
            self.activeDeviceLock.withLock { self.activeDevice = nil }
            self.state = .stopped
            device.close()
            completionHandler(nil)
        }
    }

    public func update(
        profile: TunnelProfile,
        endpointResolution: EndpointResolutionPolicy? = nil,
        completionHandler: @escaping @Sendable (TunnelControllerError?) -> Void
    ) {
        workQueue.async {
            guard case .running(
                let device,
                let tunnel,
                _,
                let paused,
                _,
                _
            ) = self.state,
                  let provider = self.provider else {
                completionHandler(.invalidState)
                return
            }

            let effectivePolicy = endpointResolution ?? (profile.options.killSwitch.isEnabled ? .bestEffort : .required)

            provider.reasserting = true
            defer {
                provider.reasserting = false
            }

            do {
                let (resolvedTunnel, pendingHostnameIndices) = try self.resolveTunnel(
                    for: profile,
                    policy: effectivePolicy
                )
                let networkSettings = NetworkSettingsBuilder.build(for: profile)
                try self.setNetworkSettings(networkSettings, on: provider)

                let effectiveEndpoints = self.resolveEffectiveEndpoints(
                    for: resolvedTunnel,
                    policy: effectivePolicy
                )
                let effectiveTunnel = ResolvedTunnel(profile: profile, endpoints: effectiveEndpoints)

                let deviceConfig: DeviceConfiguration
                do {
                    deviceConfig = try effectiveTunnel.makeDeviceConfiguration()
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

                self.configureSplitDNSInterceptor(for: profile)

                self.state = .running(
                    device: device,
                    tunnel: tunnel,
                    resolvedTunnel: resolvedTunnel,
                    paused: paused,
                    endpointResolutionPolicy: effectivePolicy,
                    pendingHostnameIndices: pendingHostnameIndices
                )
                if !pendingHostnameIndices.isEmpty && !paused && self.nextRetry == nil {
                    self.retryAttempts = max(1, self.retryAttempts)
                    self.scheduleRetryTimer()
                }
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
            if case .running(let device, _, _, _, _, _) = self.state {
                device.reevaluateDeadlines()
            }
        }
    }

    public func status(completionHandler: @escaping @Sendable (DeviceStatus?) -> Void) {
        workQueue.async {
            guard case .running(let device, _, _, _, _, _) = self.state else {
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

    private func configureSplitDNSInterceptor(for profile: TunnelProfile) {
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
            deliverToTunnel: { [weak self] packet in
                guard let self else { throw PacketDeliveryError.deviceNotRunning }
                try self.deliverToTunnel(packet)
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

    // MARK: - Path Monitoring & Retry Handling

    private func didReceivePathUpdate(_ path: TunnelNetworkPath) {
        physicalInterfaceLock.withLock {
            physicalInterfaceIndexStorage = path.physicalInterfaceIndex
        }
        logHandler(.verbose, "Network change detected with \(path.summary)")

        guard case .running(
            let device,
            let tunnel,
            var resolvedTunnel,
            let paused,
            let endpointPolicy,
            var pendingHostnameIndices
        ) = state else {
            return
        }

        guard pauseOnOffline else {
            if !pendingHostnameIndices.isEmpty {
                let updated = resolvePendingHostnameEndpoints(
                    device: device,
                    resolvedTunnel: resolvedTunnel,
                    pendingIndices: pendingHostnameIndices
                )
                resolvedTunnel = updated.resolvedTunnel
                pendingHostnameIndices = updated.remainingIndices
                state = .running(
                    device: device,
                    tunnel: tunnel,
                    resolvedTunnel: resolvedTunnel,
                    paused: paused,
                    endpointResolutionPolicy: endpointPolicy,
                    pendingHostnameIndices: pendingHostnameIndices
                )
            }
            device.reevaluateDeadlines()
            bumpSockets(device)
            scheduleEndpointRetryIfNeeded()
            return
        }

        if !path.isSatisfiable {
            guard !paused else { return }
            logHandler(.verbose, "Connectivity offline, pausing engine.")
            cancelRetry()
            pendingSocketOperation = nil
            retryAttempts = 0
            state = .running(
                device: device,
                tunnel: tunnel,
                resolvedTunnel: resolvedTunnel,
                paused: true,
                endpointResolutionPolicy: endpointPolicy,
                pendingHostnameIndices: pendingHostnameIndices
            )
            try? device.pause(reason: .offline)
            return
        }

        if !pendingHostnameIndices.isEmpty {
            let updated = resolvePendingHostnameEndpoints(
                device: device,
                resolvedTunnel: resolvedTunnel,
                pendingIndices: pendingHostnameIndices
            )
            resolvedTunnel = updated.resolvedTunnel
            pendingHostnameIndices = updated.remainingIndices
        }

        let reresolved = resolvedTunnel.reresolveEndpoints(using: reresolveEndpoint)
        logEndpointReresolutionResults(
            initialEndpoints: resolvedTunnel.endpoints,
            results: reresolved.map(\.1)
        )
        let updates = ResolvedTunnel.endpointUpdates(from: reresolved)
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
                resolvedTunnel: resolvedTunnel,
                paused: false,
                endpointResolutionPolicy: endpointPolicy,
                pendingHostnameIndices: pendingHostnameIndices
            )
            cancelRetry()
            pendingSocketOperation = nil
            retryAttempts = 0
            attemptResume(device)
        } else {
            state = .running(
                device: device,
                tunnel: tunnel,
                resolvedTunnel: resolvedTunnel,
                paused: false,
                endpointResolutionPolicy: endpointPolicy,
                pendingHostnameIndices: pendingHostnameIndices
            )
            device.reevaluateDeadlines()
            bumpSockets(device)
        }

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
        guard case .running(_, _, _, let paused, _, let pendingIndices) = state,
              !paused,
              !pendingIndices.isEmpty,
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
        guard case .running(
            let device,
            let tunnel,
            let resolvedTunnel,
            let paused,
            let endpointPolicy,
            let pendingHostnameIndices
        ) = state, !paused else {
            cancelRetry()
            pendingSocketOperation = nil
            return
        }

        cancelRetry()

        if let socketOperation = pendingSocketOperation {
            switch socketOperation {
            case .rebind:
                attemptRebind(device)
            case .resume:
                attemptResume(device)
            }
        }

        if !pendingHostnameIndices.isEmpty {
            let updated = resolvePendingHostnameEndpoints(
                device: device,
                resolvedTunnel: resolvedTunnel,
                pendingIndices: pendingHostnameIndices
            )
            state = .running(
                device: device,
                tunnel: tunnel,
                resolvedTunnel: updated.resolvedTunnel,
                paused: paused,
                endpointResolutionPolicy: endpointPolicy,
                pendingHostnameIndices: updated.remainingIndices
            )
            if updated.remainingIndices.isEmpty && pendingSocketOperation == nil {
                retryAttempts = 0
            } else if !updated.remainingIndices.isEmpty && self.nextRetry == nil {
                retryAttempts += 1
                scheduleRetryTimer()
            }
        }
    }

    private func resolvePendingHostnameEndpoints(
        device: WireGuardDevice,
        resolvedTunnel: ResolvedTunnel,
        pendingIndices: Set<Int>
    ) -> (resolvedTunnel: ResolvedTunnel, remainingIndices: Set<Int>) {
        let peers = resolvedTunnel.profile.peers
        var updatedTunnel = resolvedTunnel
        var remaining = pendingIndices
        var updates: [WireGuardPublicKey: IPEndpoint?] = [:]

        let sortedIndices = pendingIndices.sorted()
        let queryEndpoints: [Endpoint?] = sortedIndices.map { index in
            index < peers.count ? peers[index].endpoint : nil
        }
        let results = resolveEndpoints(queryEndpoints)

        for (offset, peerIndex) in sortedIndices.enumerated() {
            guard peerIndex < peers.count,
                  let originalEndpoint = peers[peerIndex].endpoint,
                  let hostname = originalEndpoint.hostname else {
                remaining.remove(peerIndex)
                continue
            }
            guard let result = results[offset] else { continue }
            switch result {
            case .success(let resolved):
                endpointCache.store(resolvedEndpoint: resolved, for: hostname)
                updatedTunnel.endpoints[peerIndex] = resolved
                remaining.remove(peerIndex)
                updates[peers[peerIndex].publicKey] = resolved
                logHandler(.verbose, "Resolved pending endpoint \(hostname) to \(resolved.address)")
            case .failure(let error):
                logHandler(
                    .verbose,
                    "Pending endpoint resolution failed for \(hostname): \(error.errorDescription ?? "(nil)")"
                )
            }
        }

        if !updates.isEmpty {
            device.updateEndpoints(updates)
        }

        return (updatedTunnel, remaining)
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
        policy: EndpointResolutionPolicy
    ) -> [IPEndpoint?] {
        let reresolved = resolvedTunnel.reresolveEndpoints(using: reresolveEndpoint)
        logEndpointReresolutionResults(
            initialEndpoints: resolvedTunnel.endpoints,
            results: reresolved.map(\.1)
        )
        return zip(resolvedTunnel.endpoints, reresolved).map { initialEndpoint, pair in
            switch pair.1 {
            case .some(.success(let endpoint)):
                return endpoint
            case .some(.failure):
                // Under .bestEffort, keep the initial/cached IP if DNS64 re-resolution fails while offline.
                if policy == .bestEffort, let initialEndpoint {
                    return initialEndpoint
                }
                return nil
            case .none:
                return nil
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
            var timedOut = false
        }

        let waitState = WaitState()
        scheduleSettingsTimeout {
            waitState.condition.withLock {
                waitState.timedOut = true
                waitState.condition.signal()
            }
        }
        provider.setTunnelNetworkSettings(networkSettings) { error in
            waitState.condition.withLock {
                waitState.systemError = error
                waitState.completed = true
                waitState.condition.signal()
            }
        }

        try waitState.condition.withLock {
            while !waitState.completed && !waitState.timedOut {
                waitState.condition.wait()
            }
            guard waitState.completed else {
                logHandler(.error, "setTunnelNetworkSettings timed out after 5 seconds; proceeding anyway")
                return
            }
            if let systemError = waitState.systemError {
                throw TunnelControllerError.setNetworkSettings(systemError)
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
