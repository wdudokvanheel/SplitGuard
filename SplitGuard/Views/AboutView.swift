import SwiftUI

enum AppMetadata {
    static let sourceCodeURL = URL(string: "https://github.com/wdudokvanheel/SplitGuard")!

    static var versionText: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, !build.isEmpty {
            return "\(shortVersion) (\(build))"
        }
        return shortVersion
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let store: TunnelStore

    var body: some View {
        VStack(spacing: 0) {
            BrutalistHeaderBar(
                title: "About",
                enableSwipeBack: true,
                leading: {
                    BrutalistBackButton {
                        dismiss()
                    }
                }
            )

            ScrollView {
                VStack(spacing: SGSpacing.large) {
                    appIdentitySection
                    sourceCodeSection
                    attributionSection
                }
                .padding(.horizontal, SGSpacing.medium)
                .padding(.top, SGSpacing.large)
                .padding(.bottom, SGSpacing.xxLarge)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .background(SGColor.surfacePrimary.ignoresSafeArea())
        }
        .background(SGColor.surfacePrimary.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private var appIdentitySection: some View {
        VStack(spacing: SGSpacing.medium) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 144, height: 144)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(SGColor.borderInk, lineWidth: SGBorder.thick)
                )
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(SGColor.shadowSurface)
                        .offset(x: SGShadow.medium, y: SGShadow.medium)
                )
                .accessibilityLabel("SplitGuard App Icon")

            VStack(spacing: SGSpacing.xSmall) {
                HStack(spacing: 4) {
                    Text("SPLIT")
                        .foregroundStyle(SGColor.textPrimary)
                    Text("GUARD")
                        .foregroundStyle(SGColor.popRed)
                }
                .font(SGTypography.displayHero)
                .tracking(1.0)

                Text("VERSION \(AppMetadata.versionText)")
                    .font(SGTypography.monoCompact.weight(.bold))
                    .foregroundStyle(SGColor.inkOnPop)
                    .padding(.horizontal, SGSpacing.small)
                    .padding(.vertical, 5)
                    .background(SGColor.popYellow)
                    .overlay(
                        Rectangle()
                            .strokeBorder(SGColor.borderInk, lineWidth: SGBorder.thin)
                    )

                Text("WireGuard-Go \(store.backendVersion)")
                    .font(SGTypography.monoCompact)
                    .foregroundStyle(SGColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SGSpacing.small)
    }

    private var sourceCodeSection: some View {
        VStack(spacing: SGSpacing.small) {
            BrutalistSectionBar(title: "Source Code")

            Button {
                openURL(AppMetadata.sourceCodeURL)
            } label: {
                HStack(spacing: SGSpacing.small) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.headline.weight(.bold))
                        .frame(width: 34, height: 34)
                        .background(SGColor.pureWhite)
                        .foregroundStyle(SGColor.inkOnPop)
                        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1.5))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("VIEW ON GITHUB")
                            .font(SGTypography.displayCompact)
                            .tracking(0.8)
                        Text("github.com/wdudokvanheel/SplitGuard")
                            .font(SGTypography.monoCompact)
                            .opacity(0.85)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.subheadline.weight(.black))
                }
                .padding(SGSpacing.medium)
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
            .accessibilityAddTraits(.isLink)
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

                NavigationLink(value: AppRoute.licenses) {
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
}
