import enum SplitGuardCore.AppGroup
import enum SplitGuardCore.Log
import SwiftUI
import UIKit

@main
struct SplitGuardApp: App {
    @UIApplicationDelegateAdaptor(SplitGuardAppDelegate.self) private var appDelegate
    @State private var store: TunnelStore

    init() {
        _store = State(initialValue: TunnelStore())
        Log.configure(source: "APP", fileURL: AppGroup.appLogURL())
        Log.info("SplitGuard launched")
        Self.configureBrutalistNavigationAppearance()
    }

    private static func configureBrutalistNavigationAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0x16 / 255.0, green: 0x16 / 255.0, blue: 0x14 / 255.0, alpha: 1)
                : UIColor(red: 0xFE / 255.0, green: 0xFB / 255.0, blue: 0xE9 / 255.0, alpha: 1)
        }
        appearance.shadowColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0xFE / 255.0, green: 0xFB / 255.0, blue: 0xE9 / 255.0, alpha: 1)
                : UIColor.black
        }
        if let bebas = UIFont(name: "BebasNeue-Regular", size: 22) {
            appearance.titleTextAttributes = [
                .font: bebas,
                .kern: 1.0
            ]
        }
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }

    var body: some Scene {
        WindowGroup {
            rootView
        }
    }

    private var rootView: some View {
        RootView(store: store)
            .onAppear {
                QuickActionCoordinator.shared.register { tunnelID in
                    store.handleQuickAction(tunnelID: tunnelID)
                }
                NotificationNavigationCoordinator.shared.register { tunnelID in
                    store.requestedNavigationTunnelID = tunnelID
                }
            }
    }
}
