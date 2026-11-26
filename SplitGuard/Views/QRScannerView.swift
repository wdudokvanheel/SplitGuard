import AVFoundation
import SplitGuardCore
import SwiftUI
import UIKit

struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let store: TunnelStore
    let onSwitchToPaste: () -> Void
    var onCompleted: (() -> Void)?

    @State private var cameraState: CameraAuthorizationState = .checking
    @State private var isScanningPaused = false
    @State private var scannedProfile: TunnelProfile?
    @State private var tunnelName = ""
    @State private var isSaving = false
    @State private var scanError: AlertItem?

    private enum CameraAuthorizationState {
        case checking
        case authorized
        case denied
        case unavailable
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                BrutalistHeaderBar(
                    title: L10n.tr("qr.scan.title", defaultValue: "Scan QR code"),
                    enableSwipeBack: scannedProfile == nil,
                    leading: {
                        BrutalistBackButton {
                            dismiss()
                        }
                    }
                )

                Group {
                    switch cameraState {
                    case .checking:
                        ProgressView(L10n.tr("qr.scan.preparingCamera", defaultValue: "Preparing camera…"))
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

            if let scannedProfile {
                NameImportedTunnelView(
                    promptTitle: L10n.tr(
                        "qr.scan.namePromptTitle",
                        defaultValue: "Please name the scanned tunnel"
                    ),
                    tunnelName: $tunnelName,
                    profile: scannedProfile,
                    isSaving: isSaving,
                    onCancel: {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                            self.scannedProfile = nil
                            tunnelName = ""
                            isScanningPaused = false
                        }
                    },
                    onSave: saveScannedTunnel
                )
                .transition(.move(edge: .trailing))
                .zIndex(1)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: scannedProfile != nil)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await checkCameraAvailability()
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
            Button(L10n.tr("action.ok", defaultValue: "OK"), role: .cancel) {
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

                Text(
                    L10n.tr(
                        "qr.scan.tip",
                        defaultValue: "Tip: Generate with `qrencode -t ansiutf8 < tunnel.conf`"
                    ).uppercased()
                )
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

        guard let profile = try? TunnelProfileCodec.parse(payload, name: "Scanned") else {
            scanError = AlertItem(
                title: L10n.tr("alert.qr.invalidCode.title", defaultValue: "Invalid QR Code"),
                message: L10n.tr(
                    "alert.qr.invalidCode.message",
                    defaultValue: "The scanned QR code is not a valid WireGuard configuration"
                )
            )
            return
        }

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            scannedProfile = profile
        }
    }

    private func saveScannedTunnel() {
        guard !isSaving, let profile = scannedProfile else { return }
        let name = tunnelName.trimmingCharacters(in: .whitespacesAndNewlines)
        isSaving = true
        Task {
            let succeeded = await store.addProfile(profile, named: name)
            isSaving = false
            if succeeded {
                scannedProfile = nil
                if let onCompleted {
                    onCompleted()
                } else {
                    dismiss()
                }
            }
        }
    }
}

private struct QRScannerCameraFallbackView: View {
    let isDenied: Bool
    let onSwitchToPaste: () -> Void

    var body: some View {
        VStack(spacing: SGSpacing.medium) {
            BrutalistUnavailableCard(
                title: isDenied
                    ? L10n.tr("qr.scan.cameraAccessNeeded.title", defaultValue: "Camera Access Needed")
                    : L10n.tr("alert.qr.cameraUnsupported.title", defaultValue: "Camera Unsupported"),
                message: isDenied
                    ? L10n.tr(
                        "qr.scan.cameraAccessNeeded.message",
                        defaultValue: "Allow camera access in Settings to scan configuration QR codes."
                    )
                    : L10n.tr(
                        "alert.qr.cameraUnsupported.message",
                        defaultValue: "This device is not able to scan QR codes"
                    ),
                systemImage: isDenied ? "camera.fill" : "camera.metering.unknown",
                accent: isDenied ? SGColor.popYellow : SGColor.popBlue
            )

            VStack(spacing: SGSpacing.small) {
                if isDenied {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Text(L10n.tr("action.openSettings", defaultValue: "Open Settings").uppercased())
                            .font(SGTypography.displayButton)
                            .tracking(0.8)
                            .padding(.vertical, 12)
                            .padding(.horizontal, SGSpacing.medium)
                    }
                    .buttonStyle(BrutalistButtonStyle(fill: SGColor.popPurple, fullWidth: true))
                }

                Button(action: onSwitchToPaste) {
                    Text(L10n.tr("qr.scan.pasteInstead", defaultValue: "Paste configuration instead").uppercased())
                        .font(isDenied ? SGTypography.displayCompact : SGTypography.displayButton)
                        .tracking(0.8)
                        .padding(.vertical, 12)
                        .padding(.horizontal, SGSpacing.medium)
                }
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
