import SwiftUI

struct FirstRunOnboardingView: View {
    let onScanQRCode: () -> Void
    let onImportFiles: () -> Void
    let onCreateFromScratch: () -> Void
    let onPasteConfig: () -> Void
    let onOpenSettings: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(spacing: SGSpacing.large) {
                masthead
                FirstRunHeroFrame()
                actionStack
            }
            .padding(.horizontal, SGSpacing.medium)
            .padding(.top, SGSpacing.small)
            .padding(.bottom, SGSpacing.xxLarge)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .background(SGColor.surfacePrimary.ignoresSafeArea())
    }

    private var masthead: some View {
        HStack(alignment: .center, spacing: SGSpacing.small) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text("SPLIT")
                        .foregroundStyle(SGColor.textPrimary)
                    Text("GUARD")
                        .foregroundStyle(SGColor.popRed)
                }
                .font(SGTypography.displayHero)
                .tracking(1.0)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

                Text(
                    L10n.tr("onboarding.tagline", defaultValue: "WireGuard Client + Split DNS").uppercased()
                )
                    .font(SGTypography.metricLabel)
                    .tracking(1.2)
                    .foregroundStyle(SGColor.textSecondary)
            }

            Spacer(minLength: SGSpacing.xSmall)

            BrutalistIconButton(
                systemImage: "gearshape.fill",
                accessibilityLabelText: L10n.tr("settings.title", defaultValue: "Settings"),
                action: onOpenSettings
            )
        }
    }

    private var actionStack: some View {
        VStack(spacing: SGSpacing.small) {
            Button(action: onScanQRCode) {
                HStack(spacing: SGSpacing.small) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.title3.weight(.bold))
                    Text(L10n.tr("onboarding.scanQR", defaultValue: "Scan QR code").uppercased())
                        .font(SGTypography.displayButton)
                        .tracking(1.2)
                    Spacer(minLength: 0)
                    Text(">>")
                        .font(SGTypography.displayButton)
                }
                .padding(.horizontal, SGSpacing.medium)
                .padding(.vertical, 14)
            }
            .buttonStyle(
                BrutalistButtonStyle(
                    fill: SGColor.popPink,
                    foreground: SGColor.pureWhite,
                    borderWidth: SGBorder.regular,
                    shadowOffset: SGShadow.medium,
                    fullWidth: true,
                    showGrain: true
                )
            )

            Button(action: onImportFiles) {
                HStack(spacing: SGSpacing.small) {
                    Image(systemName: "doc.badge.plus")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(SGColor.inkOnPop)
                    Text(importFilesButtonTitle)
                        .font(SGTypography.displayButton)
                        .tracking(1.0)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.headline.weight(.black))
                        .foregroundStyle(SGColor.inkOnPop)
                }
                .padding(.horizontal, SGSpacing.medium)
                .padding(.vertical, 14)
            }
            .buttonStyle(
                BrutalistButtonStyle(
                    fill: SGColor.pureWhite,
                    foreground: SGColor.inkOnPop,
                    borderWidth: SGBorder.regular,
                    shadowOffset: SGShadow.medium,
                    fullWidth: true
                )
            )

            secondaryActionRow
        }
    }

    private var importFilesButtonTitle: AttributedString {
        let full = L10n.tr("onboarding.importFiles", defaultValue: "Import .conf files").uppercased()
        var attributed = AttributedString(full)
        attributed.foregroundColor = SGColor.inkOnPop
        if let range = attributed.range(of: ".CONF") {
            attributed[range].foregroundColor = SGColor.popGreen
        }
        return attributed
    }

    @ViewBuilder
    private var secondaryActionRow: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: SGSpacing.small))
            : AnyLayout(HStackLayout(spacing: SGSpacing.small))

        layout {
            Button(action: onCreateFromScratch) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil")
                        .font(.subheadline.weight(.bold))
                    Text(L10n.tr("onboarding.fromScratch", defaultValue: "From scratch").uppercased())
                        .font(SGTypography.displayCompact)
                        .tracking(0.8)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, SGSpacing.small)
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

            Button(action: onPasteConfig) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.subheadline.weight(.bold))
                    Text(L10n.tr("onboarding.pasteConfig", defaultValue: "Paste config").uppercased())
                        .font(SGTypography.displayCompact)
                        .tracking(0.8)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, SGSpacing.small)
            }
            .buttonStyle(
                BrutalistButtonStyle(
                    fill: SGColor.popBlue,
                    foreground: SGColor.inkOnPop,
                    borderWidth: SGBorder.regular,
                    shadowOffset: SGShadow.small,
                    fullWidth: true,
                    showGrain: true
                )
            )
        }
    }
}

private struct FirstRunHeroFrame: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            artwork
                .frame(maxWidth: .infinity)
                .frame(height: dynamicTypeSize.isAccessibilitySize ? 180 : 210)
                .clipped()
                .background(SGColor.popBlue)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(SGColor.borderInk).frame(height: SGBorder.regular)
                }

            VStack(alignment: .leading, spacing: SGSpacing.small) {
                Text(
                    L10n.tr(
                        "onboarding.heroTitle",
                        defaultValue: "Add your tunnel.\nSplit your DNS.\nKeep everything else fast."
                    ).uppercased()
                )
                    .font(SGTypography.displayTitle)
                    .tracking(0.6)
                    .foregroundStyle(SGColor.inkOnPop)
                    .fixedSize(horizontal: false, vertical: true)

                Text(
                    L10n.tr(
                        "onboarding.heroBody",
                        defaultValue: """
                        Scan a WireGuard QR code or import .conf files. \
                        Route private domains through VPN DNS while keeping everything else on your normal network.
                        """
                    )
                )
                .font(SGTypography.subheadline)
                .foregroundStyle(SGColor.inkOnPop.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(SGSpacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    SGColor.popPurple
                    BrutalistGrainOverlay(opacity: 0.16)
                }
            }

            BrutalistTickerBar(items: [
                L10n.tr("onboarding.ticker.splitDNS", defaultValue: "Split DNS"),
                L10n.tr("onboarding.ticker.killSwitch", defaultValue: "Kill Switch"),
                L10n.tr("onboarding.ticker.onDemand", defaultValue: "On-Demand Rules"),
                L10n.tr("onboarding.ticker.healthAlerts", defaultValue: "Health Alerts"),
                L10n.tr("onboarding.ticker.shortcuts", defaultValue: "Shortcuts & Focus"),
                L10n.tr("onboarding.ticker.liveStats", defaultValue: "Live Traffic Stats"),
                L10n.tr("onboarding.ticker.dnsTester", defaultValue: "DNS Tester"),
                L10n.tr("onboarding.ticker.privateLocal", defaultValue: "Private & Local")
            ])
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.thick, shadowOffset: SGShadow.large)
    }

    @ViewBuilder
    private var artwork: some View {
        if UIImage(named: "OnboardingHero") != nil {
            Image("OnboardingHero")
                .resizable()
                .scaledToFill()
                .accessibilityHidden(true)
        } else {
            ZStack {
                SGColor.popBlue
                BrutalistGrainOverlay(opacity: 0.2)
                HStack(spacing: SGSpacing.large) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 54, weight: .black))
                        .foregroundStyle(SGColor.inkOnPop)
                        .padding(SGSpacing.medium)
                        .background(SGColor.popYellow)
                        .overlay(Rectangle().strokeBorder(SGColor.pureBlack, lineWidth: SGBorder.regular))

                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 38, weight: .black))
                        .foregroundStyle(SGColor.pureWhite)

                    VStack(spacing: SGSpacing.xSmall) {
                        Image(systemName: "house.fill")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(SGColor.inkOnPop)
                            .padding(10)
                            .background(SGColor.popGreen)
                            .overlay(Rectangle().strokeBorder(SGColor.pureBlack, lineWidth: SGBorder.thin))
                        Image(systemName: "globe")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(SGColor.inkOnPop)
                            .padding(10)
                            .background(SGColor.creme)
                            .overlay(Rectangle().strokeBorder(SGColor.pureBlack, lineWidth: SGBorder.thin))
                    }
                }
            }
            .accessibilityHidden(true)
        }
    }
}
