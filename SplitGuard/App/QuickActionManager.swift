import UIKit

enum QuickActionItem {
    struct Target: Equatable {
        let id: UUID
        let name: String
    }

    static let shortcutType = "com.bitechular.splitguard.tunnel.toggle"
    static let tunnelIDUserInfoKey = "tunnelID"
    static let maxItems = 10

    /// Recently activated tunnels first, then the rest in list order.
    static func makeShortcutItems(
        tunnels: [Target],
        recentTunnelIDs: [UUID]? = nil
    ) -> [UIApplicationShortcutItem] {
        let tunnelsByID = Dictionary(tunnels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let recent = (recentTunnelIDs ?? RecentTunnelsTracker.recentlyActivatedTunnelIDs(limit: maxItems))
            .compactMap { tunnelsByID[$0] }

        var ordered: [Target] = []
        var seen = Set<UUID>()
        for tunnel in recent + tunnels where seen.insert(tunnel.id).inserted {
            ordered.append(tunnel)
            if ordered.count == maxItems {
                break
            }
        }

        return ordered.map { tunnel in
            UIApplicationShortcutItem(
                type: shortcutType,
                localizedTitle: tunnel.name,
                localizedSubtitle: "Toggle tunnel",
                icon: UIApplicationShortcutIcon(systemImageName: "shield"),
                userInfo: [tunnelIDUserInfoKey: tunnel.id.uuidString as NSSecureCoding]
            )
        }
    }

    static func tunnelID(from shortcutItem: UIApplicationShortcutItem) -> UUID? {
        guard shortcutItem.type == shortcutType,
              let rawID = shortcutItem.userInfo?[tunnelIDUserInfoKey] as? String else {
            return nil
        }
        return UUID(uuidString: rawID)
    }
}

@MainActor
final class QuickActionCoordinator {
    static let shared = QuickActionCoordinator()

    private var pendingTunnelID: UUID?
    private var handler: ((UUID) -> Void)?

    private init() {}

    func register(handler: @escaping (UUID) -> Void) {
        self.handler = handler
        if let pending = pendingTunnelID {
            pendingTunnelID = nil
            handler(pending)
        }
    }

    @discardableResult
    func handle(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
        guard let tunnelID = QuickActionItem.tunnelID(from: shortcutItem) else {
            return false
        }
        if let handler {
            handler(tunnelID)
        } else {
            pendingTunnelID = tunnelID
        }
        return true
    }

    func updateShortcutItems(tunnels: [QuickActionItem.Target]) {
        UIApplication.shared.shortcutItems = QuickActionItem.makeShortcutItems(tunnels: tunnels)
    }
}

final class SplitGuardAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let shortcutItem = options.shortcutItem {
            Task { @MainActor in
                QuickActionCoordinator.shared.handle(shortcutItem)
            }
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SplitGuardSceneDelegate.self
        return configuration
    }
}

final class SplitGuardSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let windowScene = scene as? UIWindowScene {
            Task { @MainActor in
                AppAppearanceMode.load().apply(to: windowScene)
            }
        }
        if let shortcutItem = connectionOptions.shortcutItem {
            Task { @MainActor in
                QuickActionCoordinator.shared.handle(shortcutItem)
            }
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            let handled = QuickActionCoordinator.shared.handle(shortcutItem)
            completionHandler(handled)
        }
    }
}
