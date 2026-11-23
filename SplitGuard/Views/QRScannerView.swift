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
    @State private var tunnelName = ""
    @State private var scanError: AlertItem?

    private enum CameraAuthorizationState {
        case checking
        case authorized
        case denied
        case unavailable
    }

    var body: some View {
        NavigationStack {
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
                    cameraDeniedView
                case .unavailable:
                    cameraUnavailableView
                }
            }
            .navigationTitle(tr("scanQRCodeViewTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("actionCancel")) {
                        dismiss()
                    }
                }
            }
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
                nameScannedTunnelSheet
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

                RoundedRectangle(cornerRadius: SGRadius.large + 4, style: .continuous)
                    .strokeBorder(.white.opacity(0.9), lineWidth: 2.5)
                    .frame(width: 248, height: 248)
                    .background(
                        RoundedRectangle(cornerRadius: SGRadius.large + 4, style: .continuous)
                            .fill(.black.opacity(0.08))
                    )

                Text(tr("scanQRCodeTipText"))
                    .font(SGTypography.subheadline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, SGSpacing.medium)
                    .padding(.vertical, SGSpacing.xSmall)
                    .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                    .padding(.horizontal, SGSpacing.large)

                Spacer()
            }
        }
    }

    private var cameraDeniedView: some View {
        ContentUnavailableView {
            Label("Camera Access Needed", systemImage: "camera.fill")
        } description: {
            Text("Allow camera access in Settings to scan configuration QR codes.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)

            Button("Paste Configuration Instead", action: onSwitchToPaste)
                .buttonStyle(.bordered)
        }
        .background(SGColor.surfacePrimary)
    }

    private var cameraUnavailableView: some View {
        ContentUnavailableView {
            Label(tr("alertScanQRCodeCameraUnsupportedTitle"), systemImage: "camera.metering.unknown")
        } description: {
            Text(tr("alertScanQRCodeCameraUnsupportedMessage"))
        } actions: {
            Button("Paste Configuration Instead", action: onSwitchToPaste)
                .buttonStyle(.borderedProminent)
        }
        .background(SGColor.surfacePrimary)
    }

    private var nameScannedTunnelSheet: some View {
        NavigationStack {
            Form {
                Section(tr("alertScanQRCodeNamePromptTitle")) {
                    TextField("e.g. Home VPN", text: $tunnelName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                if let config = scannedConfiguration {
                    Section("Detected Configuration") {
                        if let endpoint = config.peers.first?.endpoint?.stringRepresentation {
                            LabeledContent("Endpoint", value: endpoint)
                        }
                        if !config.interface.dns.isEmpty {
                            LabeledContent(
                                "DNS",
                                value: config.interface.dns.map(\.stringRepresentation).joined(separator: ", ")
                            )
                        }
                    }
                }
            }
            .navigationTitle("Name Tunnel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("actionCancel")) {
                        scannedConfiguration = nil
                        tunnelName = ""
                        isScanningPaused = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("actionSave")) {
                        saveScannedTunnel()
                    }
                    .disabled(tunnelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
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

        let feedback = UINotificationFeedbackGenerator()
        feedback.notificationOccurred(.success)
        scannedConfiguration = config
    }

    private func saveScannedTunnel() {
        guard let config = scannedConfiguration else { return }
        let name = tunnelName.trimmingCharacters(in: .whitespacesAndNewlines)
        store.addConfiguration(config, named: name) { succeeded in
            if succeeded {
                scannedConfiguration = nil
                dismiss()
            } else {
                scannedConfiguration = nil
                tunnelName = ""
                isScanningPaused = false
            }
        }
    }
}

private struct QRCameraPreviewView: UIViewControllerRepresentable {
    let isPaused: Bool
    let onCodeScanned: (String) -> Void
    let onFailure: (String, String) -> Void

    func makeUIViewController(context: Context) -> QRCameraController {
        let controller = QRCameraController()
        controller.onCodeScanned = onCodeScanned
        controller.onFailure = onFailure
        return controller
    }

    func updateUIViewController(_ uiViewController: QRCameraController, context: Context) {
        uiViewController.setPaused(isPaused)
    }
}

private final class QRCameraController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCodeScanned: ((String) -> Void)?
    var onFailure: ((String, String) -> Void)?

    private let captureSession = AVCaptureSession()
    private let metadataOutput = AVCaptureMetadataOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isConfigured = false
    private var isPaused = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateRunningState()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        updateRunningState()
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input),
              captureSession.canAddOutput(metadataOutput) else {
            onFailure?(
                tr("alertScanQRCodeCameraUnsupportedTitle"),
                tr("alertScanQRCodeCameraUnsupportedMessage")
            )
            return
        }

        captureSession.addInput(input)
        captureSession.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
        metadataOutput.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
        isConfigured = true
        updateRunningState()
    }

    private func updateRunningState() {
        guard isConfigured else { return }
        if isPaused {
            stopSession()
        } else if !captureSession.isRunning {
            let session = captureSession
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
            }
        }
    }

    private func stopSession() {
        guard captureSession.isRunning else { return }
        let session = captureSession
        DispatchQueue.global(qos: .userInitiated).async {
            session.stopRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !isPaused else { return }
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let stringValue = object.stringValue else {
            onFailure?(
                tr("alertScanQRCodeUnreadableQRCodeTitle"),
                tr("alertScanQRCodeUnreadableQRCodeMessage")
            )
            return
        }
        onCodeScanned?(stringValue)
    }
}
