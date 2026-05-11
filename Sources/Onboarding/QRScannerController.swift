// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import SwiftUI
import UIKit

@MainActor
struct QRScannerController: UIViewControllerRepresentable {
    let onResult: @MainActor (String) -> Void
    let onPermissionDenied: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onResult: self.onResult, onPermissionDenied: self.onPermissionDenied)
    }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, ScannerViewControllerDelegate {
        private let onResult: @MainActor (String) -> Void
        private let onPermissionDenied: @MainActor () -> Void

        init(
            onResult: @escaping @MainActor (String) -> Void,
            onPermissionDenied: @escaping @MainActor () -> Void
        ) {
            self.onResult = onResult
            self.onPermissionDenied = onPermissionDenied
        }

        func scannerViewController(_ controller: ScannerViewController, didScan value: String) {
            self.onResult(value)
        }

        func scannerViewControllerDidDenyPermission(_ controller: ScannerViewController) {
            self.onPermissionDenied()
        }
    }
}

@MainActor
protocol ScannerViewControllerDelegate: AnyObject {
    func scannerViewController(_ controller: ScannerViewController, didScan value: String)
    func scannerViewControllerDidDenyPermission(_ controller: ScannerViewController)
}

@MainActor
final class ScannerViewController: UIViewController {
    weak var delegate: (any ScannerViewControllerDelegate)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasDeliveredCode = false

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .black
        Task {
            await self.configureSession()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        self.previewLayer?.frame = self.view.bounds
    }

    private func configureSession() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            self.startSession()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if granted {
                self.startSession()
            } else {
                self.delegate?.scannerViewControllerDidDenyPermission(self)
            }
        case .denied, .restricted:
            self.delegate?.scannerViewControllerDidDenyPermission(self)
        @unknown default:
            self.delegate?.scannerViewControllerDidDenyPermission(self)
        }
    }

    private func startSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else {
            self.delegate?.scannerViewControllerDidDenyPermission(self)
            return
        }

        self.session.beginConfiguration()
        if self.session.canAddInput(input) {
            self.session.addInput(input)
        }

        let output = AVCaptureMetadataOutput()
        if self.session.canAddOutput(output) {
            self.session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }
        self.session.commitConfiguration()

        let previewLayer = AVCaptureVideoPreviewLayer(session: self.session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = self.view.bounds
        self.view.layer.addSublayer(previewLayer)
        self.previewLayer = previewLayer

        self.session.startRunning()
    }
}

extension ScannerViewController: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let scanned = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
              !scanned.isEmpty
        else { return }

        Task { @MainActor [weak self] in
            guard let self, !self.hasDeliveredCode else { return }

            self.hasDeliveredCode = true
            self.session.stopRunning()
            self.delegate?.scannerViewController(self, didScan: scanned)
        }
    }
}
