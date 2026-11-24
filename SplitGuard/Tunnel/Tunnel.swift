// SPDX-License-Identifier: MIT

import Foundation
import Observation
import SplitGuardCore

@MainActor
@Observable
final class Tunnel: Identifiable, Hashable {
    let id: UUID
    var profile: TunnelProfile
    var status: TunnelStatus
    var onDemandPolicy: OnDemandPolicy
    var isOnDemandEnabled: Bool

    init(
        id: UUID,
        profile: TunnelProfile,
        status: TunnelStatus = .inactive,
        onDemandPolicy: OnDemandPolicy = .off,
        isOnDemandEnabled: Bool = false
    ) {
        self.id = id
        self.profile = profile
        self.status = status
        self.onDemandPolicy = onDemandPolicy
        self.isOnDemandEnabled = isOnDemandEnabled
    }

    convenience init(record: TunnelRecord) {
        self.init(
            id: record.id,
            profile: record.profile,
            status: record.status,
            onDemandPolicy: record.onDemandPolicy,
            isOnDemandEnabled: record.isOnDemandEnabled
        )
    }

    var name: String {
        profile.name
    }

    var splitDNS: SplitDNSConfiguration {
        profile.splitDNS
    }

    var options: TunnelOptions {
        profile.options
    }

    var hasOnDemandRules: Bool {
        onDemandPolicy.hasRules
    }

    var primaryEndpoint: String? {
        let endpoints = profile.peers.compactMap(\.endpoint)
        if endpoints.count == 1 {
            return endpoints[0].description
        }
        if endpoints.count > 1 {
            return "\(endpoints.count) endpoints"
        }
        return nil
    }

    func apply(record: TunnelRecord, preservingStatus: Bool = false) {
        profile = record.profile
        onDemandPolicy = record.onDemandPolicy
        isOnDemandEnabled = record.isOnDemandEnabled
        if !preservingStatus {
            status = record.status
        }
    }

    nonisolated static func == (lhs: Tunnel, rhs: Tunnel) -> Bool {
        lhs.id == rhs.id
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
