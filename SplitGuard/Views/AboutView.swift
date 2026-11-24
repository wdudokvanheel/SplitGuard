import SwiftUI

enum AppMetadata {
    static let sourceCodeURL = URL(string: "https://github.com/wdudokvanheel/SplitGuard")!

    static var versionText: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    static let wireGuardAppleAttribution = """
    WireGuard for Apple (commit 2fec12a6)

    Derived components: wg-quick configuration parser, NetworkExtension \
    settings builder, and endpoint resolver.

    Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

    Permission is hereby granted, free of charge, to any person obtaining a \
    copy of this software and associated documentation files (the "Software"), \
    to deal in the Software without restriction, including without limitation \
    the rights to use, copy, modify, merge, publish, distribute, sublicense, \
    and/or sell copies of the Software, and to permit persons to whom the \
    Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in \
    all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING \
    FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER \
    DEALINGS IN THE SOFTWARE.
    """
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showingNotices = false

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
                    acknowledgementsSection
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
        .sheet(isPresented: $showingNotices) {
            ThirdPartyNoticesSheet()
        }
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

    private var acknowledgementsSection: some View {
        VStack(spacing: SGSpacing.small) {
            BrutalistSectionBar(title: "Acknowledgements")

            Button {
                showingNotices = true
            } label: {
                HStack(spacing: SGSpacing.small) {
                    Image(systemName: "doc.plaintext.fill")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(SGColor.inkOnPop)
                        .frame(width: 34, height: 34)
                        .background(SGColor.popYellow)
                        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: 1.5))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("THIRD-PARTY NOTICES")
                            .font(SGTypography.displayCompact)
                            .tracking(0.8)
                            .foregroundStyle(SGColor.textPrimary)
                        Text("WireGuard for Apple • MIT License • © 2018-2023 WireGuard LLC")
                            .font(SGTypography.caption)
                            .foregroundStyle(SGColor.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
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
}

private struct ThirdPartyNoticesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            BrutalistHeaderBar(
                title: "Third-Party Notices",
                trailing: {
                    BrutalistHeaderButton(
                        title: String(localized: "action.ok", defaultValue: "OK"),
                        fill: SGColor.popYellow,
                        foreground: SGColor.inkOnPop
                    ) {
                        dismiss()
                    }
                }
            )

            ScrollView {
                VStack(spacing: 0) {
                    BrutalistSectionBar(title: "WireGuard for Apple", trailingText: "MIT")

                    Text(AppMetadata.wireGuardAppleAttribution)
                        .font(SGTypography.monoCompact)
                        .foregroundStyle(SGColor.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(SGSpacing.medium)
                        .background(SGColor.surfaceCard)
                }
                .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
                .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
                .padding(SGSpacing.medium)
                .padding(.bottom, SGSpacing.large)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .background(SGColor.surfacePrimary.ignoresSafeArea())
        }
        .background(SGColor.surfacePrimary.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}
