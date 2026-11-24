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
        let logger: @Sendable (TunnelLogLevel, String) -> Void = { [weak self] logLevel, message in
            #if DEBUG && !targetEnvironment(simulator)
            let prefixes = [
                "Network change detected",
                "Connectivity offline",
                "Connectivity online",
                "WireGuard engine started",
                "WireGuard rebind failed"
            ]
            if prefixes.contains(where: message.hasPrefix) {
                self?.recordInteropEvent(message)
            }
            #endif
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

    private var lastStartError: TunnelStartError? {
        get { startErrorLock.withLock { lastStartErrorStorage } }
        set { startErrorLock.withLock { lastStartErrorStorage = newValue } }
    }

    // Physical-device Debug telemetry for owned interop profiles.
    #if DEBUG && !targetEnvironment(simulator)
    private let interopEventLock = NSLock()
    private var interopEvents = [InteropTelemetry.Event]()
    private var interopLANActive = false

    private var interopProfile: NETunnelProviderProtocol? {
        guard let provider = protocolConfiguration as? NETunnelProviderProtocol,
              let run = provider.providerConfiguration?[InteropTelemetry.ownershipKey] as? String,
              UUID(uuidString: run) != nil else { return nil }
        return provider
    }

    private func recordInteropEvent(_ message: String) {
        guard interopProfile != nil else { return }
        interopEventLock.withLock {
            if interopEvents.count == 32 { interopEvents.removeFirst() }
            interopEvents.append(InteropTelemetry.Event(message))
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        recordInteropEvent("Provider sleep")
        completionHandler()
    }

    private func updateInteropPort(_ message: Data, profile: NETunnelProviderProtocol,
                                   completion: @escaping (Data?) -> Void) {
        let value = message.dropFirst(InteropTelemetry.portUpdatePrefix.count)
        guard let portText = String(bytes: value, encoding: .utf8),
              let port = UInt16(portText), port != 0,
              var loaded = try? ProfileStore().loadProfile(from: profile),
              loaded.interface.addresses.map(\.description) == ["10.99.0.2/32"],
              loaded.peers.count == 1,
              loaded.peers[0].allowedIPs.map(\.description) == ["10.99.0.1/32"],
              let endpoint = loaded.peers[0].endpoint else {
            completion(nil)
            return
        }
        loaded.peers[0].endpoint = Endpoint(host: endpoint.host, port: port)
        controller.update(profile: loaded) { error in
            if error == nil { self.recordInteropEvent("Controller updated fixture endpoint port to \(port)") }
            completion(error == nil ? InteropTelemetry.updateOK : nil)
        }
    }

    private func handleInteropMessage(
        _ messageData: Data,
        provider: NETunnelProviderProtocol,
        completionHandler: @escaping (Data?) -> Void
    ) -> Bool {
        if let response = encodedInteropTelemetryResponse(for: messageData) {
            completionHandler(response)
            return true
        }
        if messageData.starts(with: InteropBenchmark.lanRequestPrefix) {
            handleInteropLANRequest(messageData, provider: provider, completionHandler: completionHandler)
            return true
        }
        if messageData.starts(with: InteropTelemetry.portUpdatePrefix) {
            updateInteropPort(messageData, profile: provider, completion: completionHandler)
            return true
        }
        return false
    }

    private func encodedInteropTelemetryResponse(for messageData: Data) -> Data?? {
        switch messageData {
        case InteropTelemetry.backendRequest:
            return Data("swift".utf8)
        case InteropTelemetry.footprintRequest:
            return InteropTelemetry.currentFootprint().flatMap { try? JSONEncoder().encode($0) }
        case InteropTelemetry.resourcesRequest:
            return InteropTelemetry.currentResources().flatMap { try? JSONEncoder().encode($0) }
        case InteropTelemetry.benchmarkRequest:
            return InteropTelemetry.currentBenchmarkSample().flatMap { try? JSONEncoder().encode($0) }
        case InteropTelemetry.eventsRequest:
            let events = interopEventLock.withLock { interopEvents }
            return try? JSONEncoder().encode(events)
        default:
            return nil
        }
    }

    private func handleInteropLANRequest(
        _ messageData: Data,
        provider: NETunnelProviderProtocol,
        completionHandler: @escaping (Data?) -> Void
    ) {
        let available = interopEventLock.withLock {
            guard !interopLANActive else { return false }
            interopLANActive = true
            return true
        }
        guard available else {
            completionHandler(nil)
            return
        }
        Task {
            let reply = await InteropBenchmark.runLANRequest(messageData, profile: provider)
            interopEventLock.withLock { interopLANActive = false }
            completionHandler(reply.flatMap { try? JSONEncoder().encode($0) })
        }
    }
    #endif

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        lastStartError = nil

        let startedByApp = (options?["startedByApp"] as? Bool) == true
        #if DEBUG && !targetEnvironment(simulator)
        recordInteropEvent(startedByApp ? "App activation" : "System activation")
        #endif

        Log.configure(source: "NET", fileURL: AppGroup.tunnelLogURL())
        Log.info("Starting tunnel from the " + (startedByApp ? "app" : "OS directly, rather than the app"))

        guard let tunnelProviderProtocol = protocolConfiguration as? NETunnelProviderProtocol else {
            let startError = TunnelStartError.invalidConfiguration
            lastStartError = startError
            Log.error("Starting tunnel failed: protocol configuration is not NETunnelProviderProtocol")
            completionHandler(startError)
            return
        }

        let profile: TunnelProfile
        do {
            profile = try ProfileStore().loadProfile(
                from: tunnelProviderProtocol,
                name: tunnelProviderProtocol.serverAddress ?? ""
            )
        } catch {
            let startError = TunnelStartError.invalidConfiguration
            lastStartError = startError
            Log.error("Starting tunnel failed: unable to load saved profile: \(error.localizedDescription)")
            completionHandler(startError)
            return
        }

        logConfiguration(profile)

        #if DEBUG && !targetEnvironment(simulator)
        configureCacheProbe(options: options, configuration: tunnelProviderProtocol, profile: profile)
        #endif
        controller.start(profile: profile) { [weak self] controllerError in
            guard let controllerError else {
                Log.info("Tunnel started with WireGuard engine \(TunnelController.engineVersion)")
                completionHandler(nil)
                return
            }
            let startError = Self.logAndMapStartError(controllerError)
            self?.lastStartError = startError
            completionHandler(startError)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        Log.info("Stopping tunnel")
        lastStartError = nil

        controller.stop { error in
            if let error {
                Log.error("Failed to stop tunnel controller: \(error)")
            }
            Log.flush()
            completionHandler()
        }
    }

    override func wake() {
        #if DEBUG && !targetEnvironment(simulator)
        recordInteropEvent("Provider wake")
        #endif
        controller.wake()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let completionHandler else { return }

        #if DEBUG && !targetEnvironment(simulator)
        if messageData == DebugCacheProbeMessage.request {
            completionHandler(cacheProbe.cachedAddressUsed.map { Data($0.utf8) })
            return
        }
        if let provider = interopProfile,
           handleInteropMessage(messageData, provider: provider, completionHandler: completionHandler) {
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
