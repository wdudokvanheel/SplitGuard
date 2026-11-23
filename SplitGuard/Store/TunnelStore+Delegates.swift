import Foundation

extension TunnelStore: TunnelsManagerListDelegate {
    nonisolated func tunnelAdded(at index: Int) {
        Task { @MainActor [weak self] in
            self?.syncTunnelsFromManager()
        }
    }

    nonisolated func tunnelModified(at index: Int) {
        Task { @MainActor [weak self] in
            self?.syncTunnelsFromManager()
        }
    }

    nonisolated func tunnelMoved(from oldIndex: Int, to newIndex: Int) {
        Task { @MainActor [weak self] in
            self?.syncTunnelsFromManager()
        }
    }

    nonisolated func tunnelRemoved(at index: Int, tunnel: TunnelContainer) {
        Task { @MainActor [weak self] in
            self?.syncTunnelsFromManager()
        }
    }
}

extension TunnelStore: TunnelsManagerActivationDelegate {
    nonisolated func tunnelActivationAttemptFailed(
        tunnel: TunnelContainer,
        error: TunnelsManagerActivationAttemptError
    ) {
        let alert = error.alertText
        let tunnelName = tunnel.name
        Task { @MainActor [weak self] in
            self?.recordActivationError(
                tunnelName: tunnelName,
                title: alert.title,
                message: alert.message
            )
        }
    }

    nonisolated func tunnelActivationAttemptSucceeded(tunnel: TunnelContainer) {
        let tunnelName = tunnel.name
        Task { @MainActor [weak self] in
            self?.clearActivationError(for: tunnelName)
        }
    }

    nonisolated func tunnelActivationFailed(
        tunnel: TunnelContainer,
        error: TunnelsManagerActivationError
    ) {
        let alert = error.alertText
        let tunnelName = tunnel.name
        Task { @MainActor [weak self] in
            self?.recordActivationError(
                tunnelName: tunnelName,
                title: alert.title,
                message: alert.message
            )
        }
    }

    nonisolated func tunnelActivationSucceeded(tunnel: TunnelContainer) {
        let tunnelName = tunnel.name
        Task { @MainActor [weak self] in
            self?.clearActivationError(for: tunnelName)
        }
    }
}
