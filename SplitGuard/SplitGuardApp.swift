import SwiftUI

@main
struct SplitGuardApp: App {
    @State private var store = TunnelStore()

    init() {
        Logger.configureGlobal(tagged: "APP", withFilePath: FileManager.logFileURL?.path)
        wg_log(.info, staticMessage: "SplitGuard launched")
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
        }
    }
}
