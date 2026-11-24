import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let store: TunnelStore

    @State private var exportedZipFile: ExportFileItem?
    @State private var localAlert: AlertItem?
    @State private var isExportingZip = false

    var body: some View {
        VStack(spacing: 0) {
            BrutalistHeaderBar(
                title: String(localized: "settings.title", defaultValue: "Settings"),
                enableSwipeBack: true,
                leading: {
                    BrutalistBackButton {
                        dismiss()
                    }
                }
            )

            ViewThatFits(in: .vertical) {
                settingsContent
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView {
                    settingsContent
                }
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(SGColor.surfacePrimary.ignoresSafeArea())
        }
        .background(SGColor.surfacePrimary.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $exportedZipFile) { item in
            ActivityShareSheet(activityItems: [item.url]) {
                try? FileManager.default.removeItem(at: item.url)
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
            Button(String(localized: "action.ok", defaultValue: "OK"), role: .cancel) {
                localAlert = nil
            }
        } message: {
            Text(localAlert?.message ?? "")
        }
    }

    private var settingsContent: some View {
        VStack(spacing: SGSpacing.medium) {
            brandBannerCard
            AppearanceSettingsSection(store: store)
            actionsSection
            aboutButton
            #if DEBUG
            debugVerificationSection
            #endif
        }
        .padding(.horizontal, SGSpacing.medium)
        .padding(.top, SGSpacing.medium)
        .padding(.bottom, SGSpacing.large)
    }

    private var brandBannerCard: some View {
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
                SGColor.popPurple
                BrutalistGrainOverlay(opacity: 0.18)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.popPurple, borderWidth: SGBorder.thick, shadowOffset: SGShadow.medium)
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
                        Text(String(localized: "settings.exportZip", defaultValue: "Export zip archive").uppercased())
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

            NavigationLink(value: AppRoute.logViewer) {
                HStack(spacing: SGSpacing.small) {
                    Image(systemName: "doc.text.fill")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(SGColor.inkOnPop)
                        .frame(width: 34, height: 34)
                        .background(SGColor.popGreen)
                        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1.5))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "settings.viewLog", defaultValue: "View log").uppercased())
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

    private var aboutButton: some View {
        NavigationLink(value: AppRoute.about) {
            HStack(spacing: SGSpacing.small) {
                Image(systemName: "info.circle.fill")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(SGColor.inkOnPop)
                    .frame(width: 34, height: 34)
                    .background(SGColor.popPurple)
                    .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1.5))

                VStack(alignment: .leading, spacing: 2) {
                    Text("ABOUT")
                        .font(SGTypography.displayCompact)
                        .tracking(0.8)
                        .foregroundStyle(SGColor.textPrimary)
                    Text("Version and source code")
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

    #if DEBUG
    private var debugVerificationSection: some View {
        VStack(spacing: SGSpacing.small) {
            BrutalistSectionBar(title: "Debug Verification", trailingText: "DEBUG ONLY")

            NavigationLink(value: AppRoute.debugVerificationWizard) {
                HStack(spacing: SGSpacing.small) {
                    Image(systemName: "checklist.checked")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(SGColor.pureWhite)
                        .frame(width: 34, height: 34)
                        .background(SGColor.popPink)
                        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1.5))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("DEBUG VERIFICATION WIZARD")
                            .font(SGTypography.displayCompact)
                            .tracking(0.8)
                            .foregroundStyle(SGColor.textPrimary)
                        Text("Run on-device diagnostics, iOS 26 quirk probes & manual checks")
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
    #endif

    private func exportConfigurationsAsZip() {
        Task {
            let reason = String(
                localized: "privacy.exportPrivateKeys",
                defaultValue: "Authenticate to export tunnel private keys."
            )
            guard await PrivateDataConfirmation.confirmAccess(reason: reason) else {
                return
            }
            isExportingZip = true
            defer { isExportingZip = false }
            do {
                let url = try await store.exportAllTunnelsZip()
                exportedZipFile = ExportFileItem(url: url)
            } catch {
                let tunnelError = store.wrapError(error, fallback: TunnelError.exportFailed)
                localAlert = tunnelError.alertItem
            }
        }
    }
}

struct AppearanceSettingsSection: View {
    let store: TunnelStore

    var body: some View {
        VStack(spacing: 0) {
            BrutalistSectionBar(
                title: "Appearance",
                trailingText: store.appearanceMode.title
            )

            BrutalistSegmentedControl(
                selection: Binding(
                    get: { store.appearanceMode },
                    set: { store.setAppearanceMode($0) }
                ),
                options: AppAppearanceMode.allCases.map { mode in
                    .init(
                        value: mode,
                        title: mode.title,
                        accent: mode.accentColor,
                        systemImage: mode.systemImage
                    )
                }
            )
            .padding(SGSpacing.medium)
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
    }
}
