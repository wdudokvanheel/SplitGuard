import SwiftUI

enum AppMetadata {
    static let sourceCodeURL = URL(string: "https://github.com/wdudokvanheel/SplitGuard")!

    static var versionText: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

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
                VStack(spacing: SGSpacing.medium) {
                    appIdentitySection
                    sourceCodeSection
                }
                .padding(.horizontal, SGSpacing.medium)
                .padding(.top, SGSpacing.medium)
                .padding(.bottom, SGSpacing.large)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .background(SGColor.surfacePrimary.ignoresSafeArea())
        }
        .background(SGColor.surfacePrimary.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private var appIdentitySection: some View {
        VStack(spacing: SGSpacing.small) {
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

                versionBadge
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SGSpacing.xxSmall)
    }

    private var versionBadge: some View {
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
                    fill: SGColor.popPurple,
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
}
