// SPDX-License-Identifier: MIT

import Foundation

extension TunnelStore {
    func setTunnelActive(_ isOn: Bool, for tunnel: Tunnel) async {
        await activationService.setTunnelActive(isOn, for: tunnel)
    }

    func toggleTunnel(_ tunnel: Tunnel) async {
        await activationService.toggleTunnel(tunnel)
    }

    func startActivation(of tunnel: Tunnel) async {
        await activationService.startActivation(of: tunnel)
    }

    func deactivateTunnel(_ tunnel: Tunnel) async {
        await activationService.deactivateTunnel(tunnel)
    }

    func handleStatusChange(tunnelID: Tunnel.ID, status newStatus: TunnelStatus) async {
        await activationService.handleStatusChange(tunnelID: tunnelID, status: newStatus)
    }

    func restartEditedTunnel(_ tunnel: Tunnel) async {
        await activationService.restartEditedTunnel(tunnel)
    }

    func recoverActiveTunnelAfterAdd(_ activeTunnel: Tunnel) async {
        await activationService.recoverActiveTunnelAfterAdd(activeTunnel)
    }

    func stopAndWaitForDeactivation(of tunnel: Tunnel) async {
        await activationService.stopAndWaitForDeactivation(of: tunnel)
    }

    func updateTransitionPolling() {
        activationService.updateTransitionPolling()
    }
}
