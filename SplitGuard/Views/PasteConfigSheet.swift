import SwiftUI
import UIKit

struct PasteConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: TunnelStore

    @State private var tunnelName = ""
    @State private var configText = ""

    private var canImport: Bool {
        !tunnelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !configText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Tunnel Name") {
                    TextField("e.g. hw45", text: $tunnelName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section {
                    TextEditor(text: $configText)
                        .font(SGTypography.monoCompact)
                        .frame(minHeight: 220)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    HStack {
                        Text("Configuration (.conf)")
                        Spacer()
                        Button("Paste") {
                            if let clipboard = UIPasteboard.general.string {
                                configText = clipboard
                            }
                        }
                        .font(SGTypography.caption)
                        .textCase(nil)
                    }
                }
            }
            .navigationTitle("Paste Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("actionCancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        store.importConfigText(configText, named: tunnelName) { succeeded in
                            if succeeded {
                                dismiss()
                            }
                        }
                    }
                    .disabled(!canImport)
                }
            }
        }
    }
}
