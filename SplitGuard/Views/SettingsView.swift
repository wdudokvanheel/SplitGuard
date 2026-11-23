import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let store: TunnelStore

    @State private var exportedZipFile: ExportFileItem?
    @State private var localAlert: AlertItem?
    @State private var isExportingZip = false

    private var appVersionText: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, !build.isEmpty {
            return "\(shortVersion) (\(build))"
        }
        return shortVersion
    }

    var body: some View {
        NavigationStack {
            List {
                Section(tr("settingsSectionTitleAbout")) {
                    LabeledContent("SplitGuard", value: appVersionText)
                    LabeledContent(tr("settingsVersionKeyWireGuardGoBackend"), value: store.backendVersion)
                }

                Section {
                    Button {
                        exportConfigurationsAsZip()
                    } label: {
                        HStack {
                            Label(tr("settingsExportZipButtonTitle"), systemImage: "archivebox")
                            Spacer()
                            if isExportingZip {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .disabled(isExportingZip)
                } header: {
                    Text(tr("settingsSectionTitleExportConfigurations"))
                } footer: {
                    Text("Exported archives include tunnel private keys and require Face ID or passcode authentication.")
                }

                Section(tr("settingsSectionTitleTunnelLog")) {
                    NavigationLink {
                        LogViewerView()
                    } label: {
                        Label(tr("settingsViewLogButtonTitle"), systemImage: "doc.text")
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: SGSpacing.xSmall) {
                        Text(
                            "SplitGuard uses the WireGuard tunnel, cryptography, and configuration code " +
                                "from wireguard-apple and wireguard-go under the MIT License."
                        )
                        .font(SGTypography.caption)
                        .foregroundStyle(SGColor.textSecondary)

                        Text("\"WireGuard\" is a registered trademark of Jason A. Donenfeld.")
                            .font(SGTypography.caption)
                            .foregroundStyle(SGColor.textTertiary)
                    }
                    .padding(.vertical, 2)

                    NavigationLink {
                        LicenseAttributionView()
                    } label: {
                        Label("Open Source Licenses", systemImage: "doc.plaintext")
                    }
                } header: {
                    Text("Attribution")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(tr("settingsViewTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(item: $exportedZipFile) { item in
                ActivityShareSheet(activityItems: [item.url]) {
                    _ = FileManager.deleteFile(at: item.url)
                    exportedZipFile = nil
                }
            }
            .alert(
                localAlert?.title ?? "",
                isPresented: Binding(
                    get: { localAlert != nil },
                    set: { isPresented in
                        if !isPresented {
                            localAlert = nil
                        }
                    }
                )
            ) {
                Button(tr("actionOK"), role: .cancel) {
                    localAlert = nil
                }
            } message: {
                Text(localAlert?.message ?? "")
            }
        }
    }

    private func exportConfigurationsAsZip() {
        PrivateDataConfirmation.confirmAccess(to: tr("iosExportPrivateData")) {
            isExportingZip = true
            store.exportAllTunnelsZip { result in
                isExportingZip = false
                switch result {
                case .success(let url):
                    exportedZipFile = ExportFileItem(url: url)
                case .failure(let alert):
                    localAlert = alert
                }
            }
        }
    }
}

private struct LicenseAttributionView: View {
    private let mitLicenseText = """
    Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

    Permission is hereby granted, free of charge, to any person obtaining a copy of \
    this software and associated documentation files (the "Software"), to deal in \
    the Software without restriction, including without limitation the rights to \
    use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of \
    the Software, and to permit persons to whom the Software is furnished to do so, \
    subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all \
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS \
    FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR \
    COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER \
    IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN \
    CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SGSpacing.medium) {
                Text("wireguard-apple & wireguard-go")
                    .font(SGTypography.cardTitle)
                Text("MIT License")
                    .font(SGTypography.subheadline)
                    .foregroundStyle(SGColor.textSecondary)
                Text(mitLicenseText)
                    .font(SGTypography.monoCompact)
                    .foregroundStyle(SGColor.textPrimary)
                    .textSelection(.enabled)
            }
            .padding(SGSpacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(SGColor.surfacePrimary)
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}
