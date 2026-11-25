// SPDX-License-Identifier: MIT

import AppIntents
import Foundation

enum FocusTunnelAction: String, AppEnum, Equatable, Hashable, Sendable {
    case connect
    case disconnect
    case disconnectActive

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Focus Tunnel Action")
    }

    static var caseDisplayRepresentations: [FocusTunnelAction: DisplayRepresentation] {
        [
            .connect: DisplayRepresentation(
                title: "Connect Tunnel",
                image: .init(systemName: "checkmark.shield")
            ),
            .disconnect: DisplayRepresentation(
                title: "Disconnect Tunnel",
                image: .init(systemName: "shield.slash")
            ),
            .disconnectActive: DisplayRepresentation(
                title: "Disconnect Active Tunnel",
                image: .init(systemName: "xmark.shield")
            )
        ]
    }
}

struct TunnelFocusFilterIntent: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Set SplitGuard Tunnel"
    static var description: IntentDescription? = IntentDescription(
        "Connect or disconnect a SplitGuard tunnel when this Focus starts."
    )

    @Parameter(title: "Action")
    var action: FocusTunnelAction?

    @Parameter(title: "Tunnel")
    var tunnel: TunnelEntity?

    var displayRepresentation: DisplayRepresentation {
        switch action {
        case .connect:
            if let tunnel {
                return DisplayRepresentation(
                    title: "Connect \(tunnel.name)",
                    subtitle: "SplitGuard",
                    image: .init(systemName: "checkmark.shield")
                )
            }
            return DisplayRepresentation(
                title: "Connect Tunnel",
                subtitle: "Choose a tunnel",
                image: .init(systemName: "checkmark.shield")
            )
        case .disconnect:
            if let tunnel {
                return DisplayRepresentation(
                    title: "Disconnect \(tunnel.name)",
                    subtitle: "SplitGuard",
                    image: .init(systemName: "shield.slash")
                )
            }
            return DisplayRepresentation(
                title: "Disconnect Active Tunnel",
                subtitle: "SplitGuard",
                image: .init(systemName: "shield.slash")
            )
        case .disconnectActive:
            return DisplayRepresentation(
                title: "Disconnect Active Tunnel",
                subtitle: "SplitGuard",
                image: .init(systemName: "xmark.shield")
            )
        case nil:
            return DisplayRepresentation(
                title: "No VPN Change",
                subtitle: "SplitGuard",
                image: .init(systemName: "shield")
            )
        }
    }

    init() {}

    init(action: FocusTunnelAction?, tunnel: TunnelEntity? = nil) {
        self.action = action
        self.tunnel = tunnel
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // When a Focus ends, iOS invokes `perform()` on a default-initialized instance (`action == nil`).
        guard let action else {
            return .result()
        }

        let service = TunnelIntentRuntime.service
        do {
            switch action {
            case .connect:
                guard let tunnel else {
                    throw TunnelIntentError.missingTunnel(action: "connect")
                }
                _ = try await service.connectAndWait(tunnelID: tunnel.id)
            case .disconnect:
                if let tunnel {
                    _ = try await service.disconnectAndWait(tunnelID: tunnel.id)
                } else {
                    _ = try await service.disconnectActiveAndWait()
                }
            case .disconnectActive:
                _ = try await service.disconnectActiveAndWait()
            }
            return .result()
        } catch {
            let verb = action == .connect ? "connect" : "disconnect"
            throw TunnelIntentError.map(error, tunnelName: tunnel?.name, action: verb)
        }
    }
}
