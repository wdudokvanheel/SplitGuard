// SPDX-License-Identifier: MIT

import SplitGuardCore
import SwiftUI
import UIKit

struct HealthAlertsEditorCard: View {
    @Bindable var viewModel: TunnelEditorViewModel

    var body: some View {
        VStack(spacing: 0) {
            BrutalistSectionBar(
                title: "Health Alerts",
                trailingText: viewModel.isHealthAlertsEnabled ? "ON" : "OFF",
                trailingFill: viewModel.isHealthAlertsEnabled ? SGColor.popGreen : SGColor.surfaceElevated,
                trailingForeground: viewModel.isHealthAlertsEnabled ? SGColor.inkOnPop : SGColor.textPrimary
            )

            VStack(alignment: .leading, spacing: SGSpacing.small) {
                BrutalistFormToggleRow(
                    title: "Connection health alerts",
                    subtitle: "Notify when no handshake succeeds while the app is closed",
                    isOn: Binding(
                        get: { viewModel.isHealthAlertsEnabled },
                        set: { newValue in
                            Task {
                                await viewModel.setHealthAlertsEnabled(newValue)
                            }
                        }
                    ),
                    activeTint: SGColor.popGreen
                )

                if viewModel.isHealthAlertsEnabled {
                    Rectangle().fill(SGColor.borderSubtle).frame(height: 1)

                    delayPicker

                    if viewModel.notificationAuthorizationState == .denied {
                        deniedPermissionBox
                    }

                    noteBox(
                        "Stored only on this device and not included in exports. "
                            + "A recovery alert is also sent once the handshake succeeds again."
                    )
                }
            }
            .padding(SGSpacing.medium)
            .background(SGColor.surfaceCard)
        }
        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
        .task {
            await viewModel.refreshNotificationAuthorization()
        }
    }

    private var delayPicker: some View {
        VStack(alignment: .leading, spacing: SGSpacing.xxSmall) {
            Text("ALERT AFTER")
                .font(SGTypography.metricLabel)
                .tracking(0.6)
                .foregroundStyle(SGColor.textSecondary)

            HStack(spacing: SGSpacing.xSmall) {
                ForEach(TunnelLocalSettings.HealthAlerts.supportedDelaySeconds, id: \.self) { seconds in
                    let isSelected = viewModel.healthAlertDelaySeconds == seconds
                    Button {
                        viewModel.healthAlertDelaySeconds = seconds
                    } label: {
                        Text(Self.shortDelayLabel(seconds))
                            .font(SGTypography.badge)
                            .tracking(0.5)
                            .foregroundStyle(isSelected ? SGColor.inkOnPop : SGColor.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(isSelected ? SGColor.popYellow : SGColor.surfaceElevated)
                            .overlay(
                                Rectangle()
                                    .strokeBorder(SGColor.borderInk, lineWidth: isSelected ? SGBorder.regular : SGBorder.thin)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Alert after \(Self.longDelayLabel(seconds))")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    private var deniedPermissionBox: some View {
        VStack(alignment: .leading, spacing: SGSpacing.xSmall) {
            HStack(alignment: .top, spacing: SGSpacing.xSmall) {
                Image(systemName: "bell.slash.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SGColor.inkOnPop)
                    .padding(.top, 2)
                Text("Notifications are turned off for SplitGuard in iOS Settings. Allow notifications to receive health alerts.")
                    .font(SGTypography.caption)
                    .foregroundStyle(SGColor.inkOnPop)
            }

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("OPEN SETTINGS")
                    .font(SGTypography.displayCompact)
                    .tracking(0.8)
                    .padding(.horizontal, SGSpacing.small)
                    .padding(.vertical, 6)
            }
            .buttonStyle(
                BrutalistButtonStyle(
                    fill: SGColor.pureWhite,
                    foreground: SGColor.inkOnPop,
                    borderWidth: SGBorder.thin,
                    shadowOffset: SGShadow.small
                )
            )
        }
        .padding(SGSpacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SGColor.popYellow)
        .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.thin))
    }

    private func noteBox(_ message: String) -> some View {
        HStack(alignment: .top, spacing: SGSpacing.xSmall) {
            Image(systemName: "info.circle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(SGColor.textSecondary)
                .padding(.top, 2)
            Text(message)
                .font(SGTypography.caption)
                .foregroundStyle(SGColor.textSecondary)
        }
        .padding(SGSpacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SGColor.surfaceElevated)
        .overlay(Rectangle().strokeBorder(SGColor.borderSubtle, lineWidth: 1))
    }

    static func shortDelayLabel(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)S"
        }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return remainder == 0 ? "\(minutes)M" : "\(minutes)M \(remainder)S"
    }

    static func longDelayLabel(_ seconds: Int) -> String {
        if seconds < 60 {
            return seconds == 1 ? "1 second" : "\(seconds) seconds"
        }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if remainder == 0 {
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return "\(minutes)m \(remainder)s"
    }
}
