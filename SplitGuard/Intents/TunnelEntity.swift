// SPDX-License-Identifier: MIT

import AppIntents
import Foundation
import SplitGuardCore

enum TunnelStatusAppEnum: String, AppEnum, Equatable, Hashable, Sendable {
    case inactive
    case activating
    case active
    case deactivating
    case reasserting
    case restarting
    case waiting

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Tunnel Status")
    }

    static var caseDisplayRepresentations: [TunnelStatusAppEnum: DisplayRepresentation] {
        [
            .inactive: DisplayRepresentation(title: "Inactive", image: .init(systemName: "shield")),
            .activating: DisplayRepresentation(title: "Activating", image: .init(systemName: "arrow.triangle.2.circlepath")),
            .active: DisplayRepresentation(title: "Active", image: .init(systemName: "checkmark.shield.fill")),
            .deactivating: DisplayRepresentation(title: "Deactivating", image: .init(systemName: "shield.slash")),
            .reasserting: DisplayRepresentation(title: "Reactivating", image: .init(systemName: "arrow.triangle.2.circlepath")),
            .restarting: DisplayRepresentation(title: "Restarting", image: .init(systemName: "arrow.triangle.2.circlepath")),
            .waiting: DisplayRepresentation(title: "Waiting", image: .init(systemName: "arrow.triangle.2.circlepath"))
        ]
    }

    init(tunnelStatus: TunnelStatus) {
        switch tunnelStatus {
        case .inactive:
            self = .inactive
        case .activating:
            self = .activating
        case .active:
            self = .active
        case .deactivating:
            self = .deactivating
        case .reasserting:
            self = .reasserting
        case .restarting:
            self = .restarting
        case .waiting:
            self = .waiting
        }
    }

    init(snapshotStatus: TunnelSnapshotStatus) {
        self.init(tunnelStatus: TunnelStatus(snapshotStatus: snapshotStatus))
    }

    var tunnelStatus: TunnelStatus {
        switch self {
        case .inactive:
            return .inactive
        case .activating:
            return .activating
        case .active:
            return .active
        case .deactivating:
            return .deactivating
        case .reasserting:
            return .reasserting
        case .restarting:
            return .restarting
        case .waiting:
            return .waiting
        }
    }

    var symbolName: String {
        tunnelStatus.symbolName
    }
}

struct TunnelEntity: AppEntity, Identifiable, Equatable, Hashable, Sendable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: "Tunnel",
            numericFormat: "\(placeholder: .int) tunnels"
        )
    }

    static var defaultQuery = TunnelEntityQuery()

    let id: UUID

    @Property(title: "Name")
    var name: String

    @Property(title: "Status")
    var status: TunnelStatusAppEnum

    @Property(title: "Is Active")
    var isActive: Bool

    @Property(title: "On-Demand Enabled")
    var isOnDemandEnabled: Bool

    @Property(title: "Status Text")
    var statusText: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(statusText)",
            image: .init(systemName: status.symbolName)
        )
    }

    init(
        id: UUID,
        name: String,
        status: TunnelStatusAppEnum,
        hasOnDemandRules: Bool = false,
        isOnDemandEnabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.isActive = status == .active
        self.isOnDemandEnabled = hasOnDemandRules && isOnDemandEnabled
        self.statusText = TunnelDisplayState(
            status: status.tunnelStatus,
            hasOnDemandRules: hasOnDemandRules,
            isOnDemandEnabled: hasOnDemandRules && isOnDemandEnabled
        ).statusText
    }

    @MainActor
    init(tunnel: Tunnel) {
        self.init(
            id: tunnel.id,
            name: tunnel.name,
            status: TunnelStatusAppEnum(tunnelStatus: tunnel.status),
            hasOnDemandRules: tunnel.hasOnDemandRules,
            isOnDemandEnabled: tunnel.isOnDemandEnabled
        )
    }

    init(entry: TunnelStatusSnapshot.Entry) {
        self.init(
            id: entry.id,
            name: entry.name,
            status: TunnelStatusAppEnum(snapshotStatus: entry.status),
            hasOnDemandRules: entry.hasOnDemandRules,
            isOnDemandEnabled: entry.isOnDemandEnabled
        )
    }

    static func == (lhs: TunnelEntity, rhs: TunnelEntity) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.status == rhs.status
            && lhs.isActive == rhs.isActive
            && lhs.isOnDemandEnabled == rhs.isOnDemandEnabled
            && lhs.statusText == rhs.statusText
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(status)
        hasher.combine(isActive)
        hasher.combine(isOnDemandEnabled)
        hasher.combine(statusText)
    }
}

struct TunnelEntityQuery: EntityQuery, EntityStringQuery, EnumerableEntityQuery {
    func allEntities() async throws -> [TunnelEntity] {
        let entries = await TunnelIntentRuntime.service.entitySnapshots()
        return entries.map(TunnelEntity.init(entry:))
    }

    func suggestedEntities() async throws -> [TunnelEntity] {
        try await allEntities()
    }

    func entities(for identifiers: [UUID]) async throws -> [TunnelEntity] {
        let all = try await allEntities()
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return identifiers.compactMap { byID[$0] }
    }

    func entities(matching string: String) async throws -> [TunnelEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = try await allEntities()
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}
