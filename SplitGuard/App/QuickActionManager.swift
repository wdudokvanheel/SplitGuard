import UIKit

enum QuickActionItem {
    static let shortcutType = "com.bitechular.splitguard.tunnel.toggle"
    static let tunnelNameUserInfoKey = "tunnelName"
    static let maxItems = 10

    static func makeShortcutItems(
        allTunnelNames: [String],
        recentTunnelNames: [String]? = nil
    ) -> [UIApplicationShortcutItem] {
        let validNames = Set(allTunnelNames)
        let recent = (recentTunnelNames ?? RecentTunnelsTracker.recentlyActivatedTunnelNames(limit: maxItems))
            .filter { validNames.contains($0) }

        var orderedNames: [String] = []
        var seen = Set<String>()

        for name in recent where !seen.contains(name) {
            orderedNames.append(name)
            seen.insert(name)
            if orderedNames.count == maxItems {
                break
            }
        }

        if orderedNames.count < maxItems {
            for name in allTunnelNames where !seen.contains(name) {
                orderedNames.append(name)
                seen.insert(name)
                if orderedNames.count == maxItems {
                    break
                }
            }
        }

        return orderedNames.map { tunnelName in
            UIApplicationShortcutItem(
                type: shortcutType,
                localizedTitle: tunnelName,
                localizedSubtitle: "Toggle tunnel",
                icon: UIApplicationShortcutIcon(systemImageName: "shield"),
                userInfo: [tunnelNameUserInfoKey: tunnelName as NSSecureCoding]
            )
        }
    }

    static func tunnelName(from shortcutItem: UIApplicationShortcutItem) -> String? {
        guard shortcutItem.type == shortcutType else { return nil }
        if let name = shortcutItem.userInfo?[tunnelNameUserInfoKey] as? String, !name.isEmpty {
            return name
        }
        return shortcutItem.localizedTitle.isEmpty ? nil : shortcutItem.localizedTitle
    }
}

@MainActor
final class QuickActionCoordinator {
    static let shared = QuickActionCoordinator()

    private var pendingTunnelName: String?
    private var handler: ((String) -> Void)?

    private init() {}

    func register(handler: @escaping (String) -> Void) {
        self.handler = handler
        if let pending = pendingTunnelName {
            pendingTunnelName = nil
            handler(pending)
        }
    }

    @discardableResult
    func handle(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
        guard let tunnelName = QuickActionItem.tunnelName(from: shortcutItem) else {
            return false
        }
        if let handler {
            handler(tunnelName)
        } else {
            pendingTunnelName = tunnelName
        }
        return true
    }

    func updateShortcutItems(allTunnelNames: [String]) {
        UIApplication.shared.shortcutItems = QuickActionItem.makeShortcutItems(allTunnelNames: allTunnelNames)
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
