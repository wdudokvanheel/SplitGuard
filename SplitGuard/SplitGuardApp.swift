import SwiftUI

@main
struct SplitGuardApp: App {
    @UIApplicationDelegateAdaptor(SplitGuardAppDelegate.self) private var appDelegate
    @State private var store = TunnelStore()

    init() {
        Logger.configureGlobal(tagged: "APP", withFilePath: FileManager.logFileURL?.path)
        wg_log(.info, staticMessage: "SplitGuard launched")
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .onAppear {
                    QuickActionCoordinator.shared.register { tunnelName in
                        store.handleQuickAction(tunnelName: tunnelName)
                    }
                }
        }
    }
}
