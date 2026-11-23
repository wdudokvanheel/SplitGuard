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
            VStack(spacing: 0) {
                BrutalistHeaderBar(
                    title: tr("settingsViewTitle"),
                    trailing: {
                        BrutalistHeaderButton(
                            title: "Done",
                            fill: SGColor.popYellow,
                            foreground: SGColor.inkOnPop
                        ) {
                            dismiss()
                        }
                    }
                )

                ScrollView {
                    VStack(spacing: SGSpacing.medium) {
                        brandBannerCard
                        actionsSection
                        attributionSection
                    }
                    .padding(.horizontal, SGSpacing.medium)
                    .padding(.top, SGSpacing.medium)
                    .padding(.bottom, SGSpacing.xxLarge)
                }
                .background(SGColor.surfacePrimary.ignoresSafeArea())
            }
            .background(SGColor.surfacePrimary.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
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
                    set: { if !$0 { localAlert = nil } }
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

    private var brandBannerCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: SGSpacing.medium) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 3) {
                        Text("SPLIT")
                            .foregroundStyle(SGColor.inkOnPop)
                        Text("GUARD")
                            .foregroundStyle(SGColor.pureWhite)
                    }
                    .font(SGTypography.displayHero)
                    .tracking(0.8)

                    Text("PRIVATE WIREGUARD + SPLIT DNS")
                        .font(SGTypography.metricLabel)
                        .tracking(1.0)
                        .foregroundStyle(SGColor.inkOnPop.opacity(0.82))
                }
                Spacer(minLength: 0)
            }
            .padding(SGSpacing.medium)
            .background {
                ZStack {
                    SGColor.popBlue
                    BrutalistGrainOverlay(opacity: 0.18)
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(SGColor.borderInk).frame(height: SGBorder.regular)
            }

            VStack(spacing: 0) {
                versionRow(label: "APP VERSION", value: appVersionText)
                Rectangle().fill(SGColor.borderSubtle).frame(height: 1)
                versionRow(label: tr("settingsVersionKeyWireGuardGoBackend").uppercased(), value: store.backendVersion)
            }
            .padding(.horizontal, SGSpacing.medium)
            .padding(.vertical, SGSpacing.xSmall)
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.thick, shadowOffset: SGShadow.medium)
    }

    private func versionRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(SGTypography.metricLabel)
                .foregroundStyle(SGColor.textSecondary)
            Spacer()
            Text(value)
                .font(SGTypography.monoCompact.weight(.semibold))
                .foregroundStyle(SGColor.textPrimary)
        }
        .padding(.vertical, SGSpacing.xSmall)
    }

    private var actionsSection: some View {
        VStack(spacing: SGSpacing.small) {
            BrutalistSectionBar(title: "Tools & Data")

            Button {
                exportConfigurationsAsZip()
            } label: {
                HStack(spacing: SGSpacing.small) {
                    Image(systemName: "archivebox.fill")
                        .font(.headline.weight(.bold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("settingsExportZipButtonTitle").uppercased())
                            .font(SGTypography.displayCompact)
                            .tracking(0.8)
                        Text("Includes private keys • Requires Face ID or passcode")
                            .font(SGTypography.caption)
                            .opacity(0.82)
                    }
                    Spacer()
                    if isExportingZip {
                        ProgressView()
                            .tint(SGColor.inkOnPop)
                    } else {
                        Image(systemName: "arrow.up.right")
                            .font(.subheadline.weight(.black))
                    }
                }
                .padding(SGSpacing.medium)
            }
            .buttonStyle(
                BrutalistButtonStyle(
                    fill: SGColor.popYellow,
                    foreground: SGColor.inkOnPop,
                    borderWidth: SGBorder.regular,
                    shadowOffset: SGShadow.small,
                    fullWidth: true,
                    showGrain: true
                )
            )
            .disabled(isExportingZip)

            NavigationLink {
                LogViewerView()
            } label: {
                HStack(spacing: SGSpacing.small) {
                    Image(systemName: "doc.text.fill")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(SGColor.inkOnPop)
                        .frame(width: 34, height: 34)
                        .background(SGColor.popGreen)
                        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1.5))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("settingsViewLogButtonTitle").uppercased())
                            .font(SGTypography.displayCompact)
                            .tracking(0.8)
                            .foregroundStyle(SGColor.textPrimary)
                        Text("Inspect live tunnel and extension logs")
                            .font(SGTypography.caption)
                            .foregroundStyle(SGColor.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.black))
                        .foregroundStyle(SGColor.textPrimary)
                }
                .padding(SGSpacing.medium)
                .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
            }
            .buttonStyle(.plain)
        }
    }

    private var attributionSection: some View {
        VStack(spacing: 0) {
            BrutalistSectionBar(title: "Attribution")

            VStack(alignment: .leading, spacing: SGSpacing.small) {
                Text(
                    "SplitGuard uses the WireGuard tunnel, cryptography, and configuration code " +
                        "from wireguard-apple and wireguard-go under the MIT License."
                )
                .font(SGTypography.caption)
                .foregroundStyle(SGColor.textSecondary)

                Text("\"WireGuard\" is a registered trademark of Jason A. Donenfeld.")
                    .font(SGTypography.caption)
                    .foregroundStyle(SGColor.textTertiary)

                Rectangle().fill(SGColor.borderSubtle).frame(height: 1)

                NavigationLink {
                    LicenseAttributionView()
                } label: {
                    HStack {
                        Label("Open Source Licenses", systemImage: "doc.plaintext")
                            .font(SGTypography.subheadline.weight(.bold))
                            .foregroundStyle(SGColor.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.black))
                            .foregroundStyle(SGColor.textPrimary)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .padding(SGSpacing.medium)
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
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
    @Environment(\.dismiss) private var dismiss

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

    private let fontLicenseNotice = """
    Typography includes Bebas Neue (Copyright © 2010-2018 Dharma Type) and \
    IBM Plex Sans (Copyright © 2017 IBM Corp.), both licensed under the SIL Open Font License 1.1.
    """

    var body: some View {
        VStack(spacing: 0) {
            BrutalistHeaderBar(
                title: "Licenses",
                enableSwipeBack: true,
                leading: {
                    BrutalistBackButton {
                        dismiss()
                    }
                }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: SGSpacing.medium) {
                    VStack(alignment: .leading, spacing: SGSpacing.small) {
                        Text("WIREGUARD-APPLE & WIREGUARD-GO")
                            .font(SGTypography.displayCompact)
                            .foregroundStyle(SGColor.textPrimary)
                        Text("MIT License")
                            .font(SGTypography.badge)
                            .foregroundStyle(SGColor.textSecondary)
                        Text(mitLicenseText)
                            .font(SGTypography.monoCompact)
                            .foregroundStyle(SGColor.textPrimary)
                            .textSelection(.enabled)
                    }
                    .padding(SGSpacing.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .brutalistCard(fill: SGColor.surfaceCard, shadowOffset: SGShadow.small)

                    VStack(alignment: .leading, spacing: SGSpacing.small) {
                        Text("TYPOGRAPHY")
                            .font(SGTypography.displayCompact)
                            .foregroundStyle(SGColor.textPrimary)
                        Text("SIL Open Font License 1.1")
                            .font(SGTypography.badge)
                            .foregroundStyle(SGColor.textSecondary)
                        Text(fontLicenseNotice)
                            .font(SGTypography.caption)
                            .foregroundStyle(SGColor.textPrimary)
                    }
                    .padding(SGSpacing.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .brutalistCard(fill: SGColor.surfaceCard, shadowOffset: SGShadow.small)
                }
                .padding(SGSpacing.medium)
            }
            .background(SGColor.surfacePrimary.ignoresSafeArea())
        }
        .background(SGColor.surfacePrimary.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}
