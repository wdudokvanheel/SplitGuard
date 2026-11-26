import AVFoundation
import SwiftUI
import UIKit

struct QRCameraPreviewView: UIViewControllerRepresentable {
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

final class QRCameraController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
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
                L10n.tr("alert.qr.cameraUnsupported.title", defaultValue: "Camera Unsupported"),
                L10n.tr(
                    "alert.qr.cameraUnsupported.message",
                    defaultValue: "This device is not able to scan QR codes"
                )
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
                L10n.tr("alert.qr.unreadableCode.title", defaultValue: "Invalid Code"),
                L10n.tr(
                    "alert.qr.unreadableCode.message",
                    defaultValue: "The scanned code could not be read"
                )
            )
            return
        }
        onCodeScanned?(stringValue)
    }
}
