// SPDX-License-Identifier: MIT

import Foundation
import NetworkExtension
import SplitGuardCore
import SplitGuardTunnel
import WireGuardEngine

class PacketTunnelProvider: NEPacketTunnelProvider {

    #if DEBUG && !targetEnvironment(simulator)
    private let cacheProbe = DebugEndpointCacheProbe()
    #endif

    private lazy var controller: TunnelController = {
        let logger: @Sendable (TunnelLogLevel, String) -> Void = { logLevel, message in
            switch logLevel {
            case .verbose:
                Log.debug(message)
            case .error:
                Log.error(message)
            }
        }
        #if DEBUG && !targetEnvironment(simulator)
        return cacheProbe.makeController(provider: self, logHandler: logger)
        #else
        return TunnelController(provider: self, logHandler: logger)
        #endif
    }()

    private let startErrorLock = NSLock()
    private var lastStartErrorStorage: TunnelStartError?
    private var activeTunnelIDStorage: UUID?
    private var healthAlertMonitorStorage: HealthAlertMonitor?
    private let statusSnapshotStore = TunnelStatusSnapshotStore.shared()
    private let healthAlertPoster = UserNotificationHealthAlertPoster()

    private var lastStartError: TunnelStartError? {
        get { startErrorLock.withLock { lastStartErrorStorage } }
        set { startErrorLock.withLock { lastStartErrorStorage = newValue } }
    }

    private var activeTunnelID: UUID? {
        get { startErrorLock.withLock { activeTunnelIDStorage } }
        set { startErrorLock.withLock { activeTunnelIDStorage = newValue } }
    }

    private var healthAlertMonitor: HealthAlertMonitor? {
        get { startErrorLock.withLock { healthAlertMonitorStorage } }
        set { startErrorLock.withLock { healthAlertMonitorStorage = newValue } }
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        lastStartError = nil

        let startedByApp = (options?["startedByApp"] as? Bool) == true

        Log.configure(source: "NET", fileURL: AppGroup.tunnelLogURL())
        Log.info("Starting tunnel from the " + (startedByApp ? "app" : "OS directly, rather than the app"))

        guard let tunnelProviderProtocol = protocolConfiguration as? NETunnelProviderProtocol else {
            let startError = TunnelStartError.invalidConfiguration
            lastStartError = startError
            Log.error("Starting tunnel failed: protocol configuration is not NETunnelProviderProtocol")
            completionHandler(startError)
            return
        }

        let tunnelID = tunnelProviderProtocol.tunnelID
        activeTunnelID = tunnelID

        let profile: TunnelProfile
        do {
            profile = try ProfileStore().loadProfile(
                from: tunnelProviderProtocol,
                name: tunnelProviderProtocol.serverAddress ?? ""
            )
        } catch {
            let startError = TunnelStartError.invalidConfiguration
            lastStartError = startError
            recordSnapshot(tunnelID: tunnelID, fallbackName: nil, status: .inactive)
            Log.error("Starting tunnel failed: unable to load saved profile: \(error.localizedDescription)")
            completionHandler(startError)
            return
        }

        logConfiguration(profile)
        let displayName = installHealthAlertMonitor(
            tunnelID: tunnelID,
            protocolConfiguration: tunnelProviderProtocol,
            profile: profile
        )

        #if DEBUG && !targetEnvironment(simulator)
        configureCacheProbe(options: options, configuration: tunnelProviderProtocol, profile: profile)
        #endif
        controller.start(profile: profile) { [weak self] controllerError in
            guard let controllerError else {
                Log.info("Tunnel started with WireGuard engine \(TunnelController.engineVersion)")
                self?.recordSnapshot(tunnelID: tunnelID, fallbackName: displayName, status: .active)
                completionHandler(nil)
                return
            }
            self?.stopHealthAlertMonitor()
            let startError = Self.logAndMapStartError(controllerError)
            self?.lastStartError = startError
            self?.recordSnapshot(tunnelID: tunnelID, fallbackName: displayName, status: .inactive)
            completionHandler(startError)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        Log.info("Stopping tunnel")
        lastStartError = nil
        stopHealthAlertMonitor()
        let tunnelID = activeTunnelID ?? (protocolConfiguration as? NETunnelProviderProtocol)?.tunnelID

        controller.stop { [weak self] error in
            if let error {
                Log.error("Failed to stop tunnel controller: \(error)")
            }
            self?.recordSnapshot(tunnelID: tunnelID, fallbackName: nil, status: .inactive)
            self?.activeTunnelID = nil
            Log.flush()
            completionHandler()
        }
    }

    override func wake() {
        controller.wake()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let completionHandler else { return }

        #if DEBUG && !targetEnvironment(simulator)
        if messageData == DebugCacheProbeMessage.request {
            completionHandler(cacheProbe.cachedAddressUsed.map { Data($0.utf8) })
            return
        }
        #endif

        guard let message = try? ProviderMessage.decode(from: messageData) else {
            completionHandler(nil)
            return
        }

        switch message {
        case .status:
            controller.status { status in
                guard let status else {
                    completionHandler(nil)
                    return
                }
                completionHandler(try? ProviderReply.status(status).encode())
            }
        case .lastStartError:
            completionHandler(try? ProviderReply.lastStartError(lastStartError).encode())
        case .updateLocalSettings(let settings):
            healthAlertMonitor?.updateSettings(settings.healthAlerts)
            Log.info(
                "Updated local settings (healthAlerts=\(settings.healthAlerts.isEnabled), delay=\(settings.healthAlerts.delaySeconds)s)"
            )
            completionHandler(try? ProviderReply.acknowledged.encode())
        case .debugPhysicalDNSProbe(let name):
            #if DEBUG
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                completionHandler(nil)
                return
            }
            handleDebugPhysicalDNSProbe(name: trimmed, completionHandler: completionHandler)
            #else
            completionHandler(nil)
            #endif
        }
    }
}

private extension PacketTunnelProvider {
    func installHealthAlertMonitor(
        tunnelID: UUID?,
        protocolConfiguration: NETunnelProviderProtocol,
        profile: TunnelProfile
    ) -> String {
        let localSettings = protocolConfiguration.localSettings
        let displayName = resolveDisplayName(tunnelID: tunnelID, fallback: protocolConfiguration.serverAddress)
        let monitor = HealthAlertMonitor(
            tunnelID: tunnelID ?? UUID(),
            tunnelName: displayName,
            killSwitchEnabled: profile.options.killSwitch.isEnabled,
            peerPublicKeys: profile.peers.map(\.publicKey),
            settings: localSettings.healthAlerts,
            poster: healthAlertPoster,
            logHandler: { level, message in
                switch level {
                case .verbose:
                    Log.info(message)
                case .error:
                    Log.error(message)
                }
            }
        )
        healthAlertMonitor?.stop()
        healthAlertMonitor = monitor
        controller.onEvent = { [weak monitor] event in
            monitor?.handle(event)
        }
        if localSettings.healthAlerts.isEnabled {
            Log.info("Health alerts enabled (delay=\(localSettings.healthAlerts.delaySeconds)s) for '\(displayName)'")
        }
        return displayName
    }

    func resolveDisplayName(tunnelID: UUID?, fallback: String?) -> String {
        if let tunnelID,
           let snapshotName = statusSnapshotStore.load().entry(for: tunnelID)?.name,
           !snapshotName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return snapshotName
        }
        if let fallback, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallback
        }
        return "VPN Tunnel"
    }

    func stopHealthAlertMonitor() {
        controller.onEvent = nil
        healthAlertMonitor?.stop()
        healthAlertMonitor = nil
    }

    func recordSnapshot(tunnelID: UUID?, fallbackName: String?, status: TunnelSnapshotStatus) {
        guard let tunnelID else { return }
        statusSnapshotStore.upsertEntry(id: tunnelID, fallbackName: fallbackName, status: status)
    }

    #if DEBUG && !targetEnvironment(simulator)
    func configureCacheProbe(options: [String: NSObject]?, configuration: NETunnelProviderProtocol, profile: TunnelProfile) {
        let requestedRef = options?[DebugCacheProbeMessage.startOption] as? Data
        let runProbe = requestedRef != nil && requestedRef == configuration.passwordReference
            && profile.options.killSwitch.isEnabled && profile.peers.count == 1
        cacheProbe.begin(blocking: runProbe ? profile.peers.first?.endpoint?.hostname : nil)
    }
    #endif

    func logConfiguration(_ profile: TunnelProfile) {
        if profile.splitDNS.mode == .onlyDomains {
            let domains = profile.splitDNS.normalizedDomainNames.joined(separator: ", ")
            Log.info("Split DNS enabled for domains: \(domains)")
        }
        if profile.splitDNS.hasExclusions {
            let exclusions = profile.splitDNS.exclusions.map {
                $0.includesSubdomains ? $0.name : "\($0.name) (exact)"
            }.joined(separator: ", ")
            Log.info("Split DNS exclusions enabled: \(exclusions)")
        }

        if profile.options.killSwitch.isEnabled {
            Log.info("Kill switch enabled (allowLocalNetwork=\(profile.options.killSwitch.allowLocalNetwork))")
        }
    }

    static func logAndMapStartError(_ controllerError: TunnelControllerError) -> TunnelStartError {
        switch controllerError {
        case .dnsResolution(let dnsErrors):
            let hostnames = dnsErrors.map(\.address)
            Log.error("DNS resolution failed for the following hostnames: \(hostnames.joined(separator: ", "))")
            return .dnsResolutionFailed(hostnames: hostnames)
        case .setNetworkSettings(let error):
            Log.error("Starting tunnel failed with setTunnelNetworkSettings returning \(error.localizedDescription)")
            return .networkSettingsFailed(error.localizedDescription)
        case .configuration(let error):
            Log.error("Starting tunnel failed with configuration error: \(error)")
            return .engineStartFailed(error.localizedDescription)
        case .startEngine(let error):
            Log.error("Starting tunnel failed with engine error: \(error)")
            return .engineStartFailed(error.localizedDescription)
        case .invalidState:
            Log.error("Starting tunnel failed: controller is in an invalid state")
            return .engineStartFailed("Controller is in an invalid state.")
        }
    }

    #if DEBUG
    func handleDebugPhysicalDNSProbe(name: String, completionHandler: @escaping (Data?) -> Void) {
        controller.probePhysicalDNS(name: name, recordType: 1) { result, interfaceIndex in
            let probeResult: PhysicalDNSProbeResult
            switch result {
            case .success(let response):
                let formattedRecords = response.records.map { record -> String in
                    if record.type == 1, record.rdata.count == 4 {
                        return record.rdata.map(String.init).joined(separator: ".")
                    }
                    return "type=\(record.type) bytes=\(record.rdata.count)"
                }
                probeResult = PhysicalDNSProbeResult(
                    name: name,
                    interfaceIndex: interfaceIndex,
                    responseCode: response.responseCode.rawValue,
                    records: formattedRecords,
                    error: nil
                )
            case .failure(let error):
                probeResult = PhysicalDNSProbeResult(
                    name: name,
                    interfaceIndex: interfaceIndex,
                    responseCode: nil,
                    records: [],
                    error: String(describing: error)
                )
            }
            completionHandler(try? ProviderReply.debugPhysicalDNSProbe(probeResult).encode())
        }
    }
    #endif
}
