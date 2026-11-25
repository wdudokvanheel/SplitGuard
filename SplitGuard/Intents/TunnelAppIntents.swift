// SPDX-License-Identifier: MIT

import AppIntents
import Foundation

struct ConnectTunnelIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect Tunnel"
    static var description = IntentDescription(
        "Connects a SplitGuard WireGuard tunnel, or enables on-demand if the tunnel has on-demand rules.",
        categoryName: "Tunnels"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Tunnel", requestValueDialog: "Which tunnel would you like to connect?")
    var tunnel: TunnelEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Connect \(\.$tunnel)")
    }

    init() {}

    init(tunnel: TunnelEntity) {
        self.tunnel = tunnel
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TunnelEntity> & ProvidesDialog {
        let service = TunnelIntentRuntime.service
        do {
            let outcome = try await service.connectAndWait(tunnelID: tunnel.id)
            let entity = TunnelEntity(tunnel: outcome.tunnel)
            let dialog: IntentDialog
            if outcome.enabledOnDemand && !entity.isActive {
                dialog = "Enabled on-demand for \(entity.name)."
            } else if outcome.alreadyActive {
                dialog = "\(entity.name) is already active."
            } else {
                dialog = "Connected to \(entity.name)."
            }
            return .result(value: entity, dialog: dialog)
        } catch {
            throw TunnelIntentError.map(error, tunnelName: tunnel.name, action: "connect")
        }
    }
}

struct DisconnectTunnelIntent: AppIntent {
    static var title: LocalizedStringResource = "Disconnect Tunnel"
    static var description = IntentDescription(
        "Disconnects a SplitGuard WireGuard tunnel and disables its on-demand rules if enabled.",
        categoryName: "Tunnels"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Tunnel", requestValueDialog: "Which tunnel would you like to disconnect?")
    var tunnel: TunnelEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Disconnect \(\.$tunnel)")
    }

    init() {}

    init(tunnel: TunnelEntity) {
        self.tunnel = tunnel
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TunnelEntity> & ProvidesDialog {
        let service = TunnelIntentRuntime.service
        do {
            let updated = try await service.disconnectAndWait(tunnelID: tunnel.id)
            let entity = TunnelEntity(tunnel: updated)
            return .result(value: entity, dialog: "Disconnected \(entity.name).")
        } catch {
            throw TunnelIntentError.map(error, tunnelName: tunnel.name, action: "disconnect")
        }
    }
}

struct ToggleTunnelIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Tunnel"
    static var description = IntentDescription(
        "Toggles a SplitGuard WireGuard tunnel. For tunnels with on-demand rules, this toggles on-demand instead of the session.",
        categoryName: "Tunnels"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Tunnel", requestValueDialog: "Which tunnel would you like to toggle?")
    var tunnel: TunnelEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Toggle \(\.$tunnel)")
    }

    init() {}

    init(tunnel: TunnelEntity) {
        self.tunnel = tunnel
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TunnelEntity> & ProvidesDialog {
        let service = TunnelIntentRuntime.service
        do {
            let outcome = try await service.toggleAndWait(tunnelID: tunnel.id)
            let entity = TunnelEntity(tunnel: outcome.tunnel)
            let dialog: IntentDialog
            switch outcome.action {
            case .connected:
                dialog = "Connected to \(entity.name)."
            case .disconnected:
                dialog = "Disconnected \(entity.name)."
            case .enabledOnDemand:
                dialog = "Enabled on-demand for \(entity.name)."
            case .disabledOnDemand:
                dialog = "Disabled on-demand for \(entity.name)."
            }
            return .result(value: entity, dialog: dialog)
        } catch {
            throw TunnelIntentError.map(error, tunnelName: tunnel.name, action: "toggle")
        }
    }
}

struct GetTunnelStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Tunnel Status"
    static var description = IntentDescription(
        "Returns the status and name of a SplitGuard tunnel, or the currently active tunnel if none is selected.",
        categoryName: "Tunnels"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Tunnel")
    var tunnel: TunnelEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Get status of \(\.$tunnel)")
    }

    init() {}

    init(tunnel: TunnelEntity? = nil) {
        self.tunnel = tunnel
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TunnelEntity?> & ProvidesDialog {
        let service = TunnelIntentRuntime.service
        do {
            guard let resolved = try await service.statusForIntent(tunnelID: tunnel?.id) else {
                return .result(value: nil, dialog: "No tunnel is currently active.")
            }
            let entity = TunnelEntity(tunnel: resolved)
            return .result(value: entity, dialog: "\(entity.name) is \(entity.statusText).")
        } catch {
            throw TunnelIntentError.map(error, tunnelName: tunnel?.name, action: "check status")
        }
    }
}

struct DisconnectActiveTunnelIntent: AppIntent {
    static var title: LocalizedStringResource = "Disconnect Active Tunnel"
    static var description = IntentDescription(
        "Disconnects whichever SplitGuard WireGuard tunnel is currently active.",
        categoryName: "Tunnels"
    )
    static var openAppWhenRun: Bool = false

    static var parameterSummary: some ParameterSummary {
        Summary("Disconnect active tunnel")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TunnelEntity?> & ProvidesDialog {
        let service = TunnelIntentRuntime.service
        do {
            guard let disconnected = try await service.disconnectActiveAndWait() else {
                return .result(value: nil, dialog: "No tunnel is currently active.")
            }
            let entity = TunnelEntity(tunnel: disconnected)
            return .result(value: entity, dialog: "Disconnected \(entity.name).")
        } catch {
            throw TunnelIntentError.map(error, tunnelName: nil, action: "disconnect")
        }
    }
}
