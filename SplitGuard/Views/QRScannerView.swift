import AVFoundation
import SwiftUI
import UIKit
import WireGuardKit

struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let store: TunnelStore
    let onSwitchToPaste: () -> Void

    @State private var cameraState: CameraAuthorizationState = .checking
    @State private var isScanningPaused = false
    @State private var scannedConfiguration: TunnelConfiguration?
    @State private var scannedSplitDNS: SplitDNSConfiguration = .allDomains
    @State private var tunnelName = ""
    @State private var scanError: AlertItem?

    private enum CameraAuthorizationState {
        case checking
        case authorized
        case denied
        case unavailable
    }

    var body: some View {
        VStack(spacing: 0) {
            BrutalistHeaderBar(
                title: tr("scanQRCodeViewTitle"),
                leading: {
                    BrutalistHeaderButton(
                        title: tr("actionCancel"),
                        fill: SGColor.surfaceCard,
                        foreground: SGColor.textPrimary
                    ) {
                        dismiss()
                    }
                }
            )

            Group {
                switch cameraState {
                case .checking:
                    ProgressView("Preparing camera…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                        .foregroundStyle(.white)
                case .authorized:
                    scannerContent
                case .denied:
                    QRScannerCameraFallbackView(isDenied: true, onSwitchToPaste: onSwitchToPaste)
                case .unavailable:
                    QRScannerCameraFallbackView(isDenied: false, onSwitchToPaste: onSwitchToPaste)
                }
            }
        }
        .background(SGColor.surfacePrimary.ignoresSafeArea())
        .task {
            await checkCameraAvailability()
        }
        .sheet(
            isPresented: Binding(
                get: { scannedConfiguration != nil },
                set: { isPresented in
                    if !isPresented {
                        scannedConfiguration = nil
                        tunnelName = ""
                        isScanningPaused = false
                    }
                }
            )
        ) {
            QRNameScannedTunnelSheet(
                tunnelName: $tunnelName,
                scannedConfiguration: scannedConfiguration,
                scannedSplitDNS: scannedSplitDNS,
                onCancel: {
                    scannedConfiguration = nil
                    tunnelName = ""
                    isScanningPaused = false
                },
                onSave: saveScannedTunnel
            )
        }
        .alert(
            scanError?.title ?? "",
            isPresented: Binding(
                get: { scanError != nil },
                set: { isPresented in
                    if !isPresented {
                        scanError = nil
                        isScanningPaused = false
                    }
                }
            )
        ) {
            Button(tr("actionOK"), role: .cancel) {
                scanError = nil
                isScanningPaused = false
            }
        } message: {
            Text(scanError?.message ?? "")
        }
    }

    private var scannerContent: some View {
        ZStack {
            QRCameraPreviewView(isPaused: isScanningPaused) { payload in
                handleScannedPayload(payload)
            } onFailure: { title, message in
                scanError = AlertItem(title: title, message: message)
            }
            .ignoresSafeArea()

            VStack(spacing: SGSpacing.xLarge) {
                Spacer()

                Rectangle()
                    .strokeBorder(SGColor.popYellow, lineWidth: 4)
                    .frame(width: 248, height: 248)
                    .background(SGColor.pureBlack.opacity(0.08))
                    .overlay(
                        Rectangle()
                            .strokeBorder(SGColor.pureBlack, lineWidth: 1.5)
                            .padding(-2)
                    )

                Text(tr("scanQRCodeTipText").uppercased())
                    .font(SGTypography.badge)
                    .tracking(0.8)
                    .foregroundStyle(SGColor.inkOnPop)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, SGSpacing.medium)
                    .padding(.vertical, SGSpacing.xSmall + 2)
                    .background(SGColor.creme)
                    .overlay(Rectangle().strokeBorder(SGColor.pureBlack, lineWidth: SGBorder.regular))
                    .background(
                        Rectangle()
                            .fill(SGColor.pureBlack)
                            .offset(x: SGShadow.small, y: SGShadow.small)
                    )
                    .padding(.horizontal, SGSpacing.large)

                Spacer()
            }
        }
    }

    private func checkCameraAvailability() async {
        guard AVCaptureDevice.default(for: .video) != nil else {
            cameraState = .unavailable
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraState = .authorized
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            cameraState = granted ? .authorized : .denied
        case .denied, .restricted:
            cameraState = .denied
        @unknown default:
            cameraState = .unavailable
        }
    }

    private func handleScannedPayload(_ payload: String) {
        guard !isScanningPaused else { return }
        isScanningPaused = true

        guard let config = try? TunnelConfiguration(fromWgQuickConfig: payload, called: "Scanned") else {
            scanError = AlertItem(
                title: tr("alertScanQRCodeInvalidQRCodeTitle"),
                message: tr("alertScanQRCodeInvalidQRCodeMessage")
            )
            return
        }

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        scannedSplitDNS = SplitDNSConfigCodec.extract(from: payload)
        scannedConfiguration = config
    }

    private func saveScannedTunnel() {
        guard let config = scannedConfiguration else { return }
        let name = tunnelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let splitDNS = scannedSplitDNS
        store.addConfiguration(config, splitDNSConfiguration: splitDNS, named: name) { succeeded in
            scannedConfiguration = nil
            scannedSplitDNS = .allDomains
            if succeeded {
                dismiss()
            } else {
                tunnelName = ""
                isScanningPaused = false
            }
        }
    }
}

private struct QRNameScannedTunnelSheet: View {
    @Binding var tunnelName: String
    let scannedConfiguration: TunnelConfiguration?
    let scannedSplitDNS: SplitDNSConfiguration
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            BrutalistHeaderBar(
                title: "Name Tunnel",
                leading: {
                    BrutalistHeaderButton(
                        title: tr("actionCancel"),
                        fill: SGColor.surfaceCard,
                        foreground: SGColor.textPrimary,
                        action: onCancel
                    )
                },
                trailing: {
                    BrutalistHeaderButton(
                        title: tr("actionSave"),
                        fill: SGColor.popGreen,
                        foreground: SGColor.inkOnPop,
                        showGrain: true,
                        action: onSave
                    )
                    .disabled(tunnelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            )

            ScrollView {
                VStack(spacing: SGSpacing.medium) {
                    VStack(spacing: 0) {
                        BrutalistSectionBar(title: tr("alertScanQRCodeNamePromptTitle"))
                        TextField("e.g. Home VPN", text: $tunnelName)
                            .font(SGTypography.body)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(.horizontal, SGSpacing.xSmall)
                            .padding(.vertical, 10)
                            .background(SGColor.surfaceElevated)
                            .overlay(Rectangle().strokeBorder(SGColor.borderInk, lineWidth: SGBorder.thin))
                            .padding(SGSpacing.medium)
                            .background(SGColor.surfaceCard)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
                    .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)

                    if let config = scannedConfiguration {
                        VStack(spacing: 0) {
                            BrutalistSectionBar(title: "Detected Configuration")
                            VStack(alignment: .leading, spacing: SGSpacing.xSmall) {
                                if let endpoint = config.peers.first?.endpoint?.stringRepresentation {
                                    detectedInfoRow(label: "ENDPOINT", value: endpoint)
                                }
                                if !config.interface.dns.isEmpty {
                                    detectedInfoRow(
                                        label: "DNS",
                                        value: config.interface.dns.map(\.stringRepresentation).joined(separator: ", ")
                                    )
                                }
                                if scannedSplitDNS.mode == .onlyDomains && !scannedSplitDNS.normalizedDomainNames.isEmpty {
                                    detectedInfoRow(
                                        label: "SPLIT DNS",
                                        value: scannedSplitDNS.normalizedDomainNames.joined(separator: ", ")
                                    )
                                }
                            }
                            .padding(SGSpacing.medium)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(SGColor.surfaceCard)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: SGRadius.small, style: .continuous))
                        .brutalistCard(fill: SGColor.surfaceCard, borderWidth: SGBorder.regular, shadowOffset: SGShadow.small)
                    }
                }
                .padding(SGSpacing.medium)
            }
            .background(SGColor.surfacePrimary.ignoresSafeArea())
        }
        .background(SGColor.surfacePrimary.ignoresSafeArea())
        .presentationDetents([.medium])
    }

    private func detectedInfoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(SGTypography.metricLabel)
                .foregroundStyle(SGColor.textSecondary)
            Spacer()
            Text(value)
                .font(SGTypography.monoCompact.weight(.semibold))
                .foregroundStyle(SGColor.textPrimary)
        }
    }
}

private struct QRScannerCameraFallbackView: View {
    let isDenied: Bool
    let onSwitchToPaste: () -> Void

    var body: some View {
        VStack(spacing: SGSpacing.medium) {
            BrutalistUnavailableCard(
                title: isDenied ? "Camera Access Needed" : tr("alertScanQRCodeCameraUnsupportedTitle"),
                message: isDenied
                    ? "Allow camera access in Settings to scan configuration QR codes."
                    : tr("alertScanQRCodeCameraUnsupportedMessage"),
                systemImage: isDenied ? "camera.fill" : "camera.metering.unknown",
                accent: isDenied ? SGColor.popYellow : SGColor.popPurple
            )

            VStack(spacing: SGSpacing.small) {
                if isDenied {
                    Button("OPEN SETTINGS") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(SGTypography.displayButton)
                    .padding(.vertical, 12)
                    .buttonStyle(BrutalistButtonStyle(fill: SGColor.popBlue, fullWidth: true))
                }

                Button("PASTE CONFIGURATION INSTEAD", action: onSwitchToPaste)
                    .font(isDenied ? SGTypography.displayCompact : SGTypography.displayButton)
                    .padding(.vertical, 12)
                    .buttonStyle(
                        BrutalistButtonStyle(
                            fill: isDenied ? SGColor.surfaceCard : SGColor.popPink,
                            foreground: isDenied ? SGColor.textPrimary : SGColor.pureWhite,
                            fullWidth: true
                        )
                    )
            }
            .padding(.horizontal, SGSpacing.medium)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SGColor.surfacePrimary.ignoresSafeArea())
    }
}
