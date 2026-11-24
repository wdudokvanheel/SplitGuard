// SPDX-License-Identifier: MIT

import Foundation
import Network
import NetworkExtension
import os
import SplitGuardTunnel
import WireGuardEngine
import WireGuardKit

class PacketTunnelProvider: NEPacketTunnelProvider {

    private lazy var controller: TunnelController = {
        return TunnelController(provider: self) { [weak self] logLevel, message in
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
            wg_log(logLevel.osLogLevel, message: message)
        }
    }()

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
              let configuration = profile.asTunnelConfiguration(),
              configuration.interface.addresses.map(\.stringRepresentation) == ["10.99.0.2/32"],
              configuration.peers.count == 1, var peer = configuration.peers.first,
              peer.allowedIPs.map(\.stringRepresentation) == ["10.99.0.1/32"],
              let endpoint = peer.endpoint, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            completion(nil)
            return
        }
        peer.endpoint = Endpoint(host: endpoint.host, port: endpointPort)
        let updated = TunnelConfiguration(name: configuration.name, interface: configuration.interface, peers: [peer])
        controller.update(tunnelConfiguration: updated, splitDNSConfiguration: profile.splitDNSConfiguration) { error in
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
        let activationAttemptId = options?["activationAttemptId"] as? String
        let errorNotifier = ErrorNotifier(activationAttemptId: activationAttemptId)
        #if DEBUG && !targetEnvironment(simulator)
        recordInteropEvent(activationAttemptId == nil ? "System activation" : "App activation")
        #endif

        Logger.configureGlobal(tagged: "NET", withFilePath: FileManager.logFileURL?.path)

        wg_log(.info, message: "Starting tunnel from the " + (activationAttemptId == nil ? "OS directly, rather than the app" : "app"))

        guard let tunnelProviderProtocol = self.protocolConfiguration as? NETunnelProviderProtocol,
              let tunnelConfiguration = tunnelProviderProtocol.asTunnelConfiguration() else {
            errorNotifier.notify(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
            completionHandler(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
            return
        }

        let splitDNSConfiguration = tunnelProviderProtocol.splitDNSConfiguration
        if splitDNSConfiguration.mode == .onlyDomains {
            let domains = splitDNSConfiguration.normalizedDomainNames.joined(separator: ", ")
            wg_log(.info, message: "Split DNS enabled for domains: \(domains)")
        }

        controller.start(tunnelConfiguration: tunnelConfiguration, splitDNSConfiguration: splitDNSConfiguration) { controllerError in
            guard let controllerError else {
                wg_log(.info, message: "Tunnel started with WireGuard engine \(TunnelController.engineVersion)")
                completionHandler(nil)
                return
            }

            switch controllerError {
            case .dnsResolution(let dnsErrors):
                let hostnamesWithDnsResolutionFailure = dnsErrors.map { $0.address }
                    .joined(separator: ", ")
                wg_log(.error, message: "DNS resolution failed for the following hostnames: \(hostnamesWithDnsResolutionFailure)")
                errorNotifier.notify(PacketTunnelProviderError.dnsResolutionFailure)
                completionHandler(PacketTunnelProviderError.dnsResolutionFailure)

            case .setNetworkSettings(let error):
                wg_log(.error, message: "Starting tunnel failed with setTunnelNetworkSettings returning \(error.localizedDescription)")
                errorNotifier.notify(PacketTunnelProviderError.couldNotSetNetworkSettings)
                completionHandler(PacketTunnelProviderError.couldNotSetNetworkSettings)

            case .configuration(let error):
                wg_log(.error, message: "Starting tunnel failed with configuration error: \(error)")
                errorNotifier.notify(PacketTunnelProviderError.couldNotStartBackend)
                completionHandler(PacketTunnelProviderError.couldNotStartBackend)

            case .startEngine(let error):
                wg_log(.error, message: "Starting tunnel failed with engine error: \(error)")
                errorNotifier.notify(PacketTunnelProviderError.couldNotStartBackend)
                completionHandler(PacketTunnelProviderError.couldNotStartBackend)

            case .invalidState:
                wg_log(.error, staticMessage: "Starting tunnel failed: controller is in an invalid state")
                errorNotifier.notify(PacketTunnelProviderError.couldNotStartBackend)
                completionHandler(PacketTunnelProviderError.couldNotStartBackend)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        wg_log(.info, staticMessage: "Stopping tunnel")

        controller.stop { error in
            ErrorNotifier.removeLastErrorFile()

            if let error {
                wg_log(.error, message: "Failed to stop tunnel controller: \(error)")
            }
            completionHandler()

            #if os(macOS)
            exit(0)
            #endif
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
        if let provider = interopProfile,
           handleInteropMessage(messageData, provider: provider, completionHandler: completionHandler) {
            return
        }
        #endif

        if messageData.count == 1 && messageData[0] == 0 {
            controller.status { status in
                let data = status.flatMap { try? JSONEncoder().encode($0) }
                completionHandler(data)
            }
        } else {
            completionHandler(nil)
        }
    }
}

extension TunnelLogLevel {
    var osLogLevel: OSLogType {
        switch self {
        case .verbose:
            return .debug
        case .error:
            return .error
        }
    }
}
