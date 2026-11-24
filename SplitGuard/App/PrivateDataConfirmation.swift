// SPDX-License-Identifier: MIT

import Foundation
import LocalAuthentication

@MainActor
enum PrivateDataConfirmation {
    static func confirmAccess(reason: String) async -> Bool {
        let context = LAContext()

        var authError: NSError?
        if !context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) {
            if let laError = authError as? LAError, laError.code == .passcodeNotSet {
                return true
            }
            return false
        }

        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }

    static func confirmAccess(to reason: String, _ after: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            if await confirmAccess(reason: reason) {
                after()
            }
        }
    }
}
