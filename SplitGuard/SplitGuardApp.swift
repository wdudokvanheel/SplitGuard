import SwiftUI

@main
struct SplitGuardApp: App {
    init() {
        Logger.configureGlobal(tagged: "APP", withFilePath: FileManager.logFileURL?.path)
        wg_log(.info, staticMessage: "SplitGuard Phase 0 launched")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
