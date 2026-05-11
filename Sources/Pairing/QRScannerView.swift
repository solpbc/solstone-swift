// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import VisionKit

struct QRScannerView: UIViewControllerRepresentable {
    let onURL: @MainActor (URL) -> Void
    let onUnavailable: @MainActor () -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
            onUnavailable()
            return
        }
        try? controller.startScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onURL: onURL)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onURL: @MainActor (URL) -> Void

        init(onURL: @escaping @MainActor (URL) -> Void) {
            self.onURL = onURL
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            routeFirstURL(in: addedItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            routeFirstURL(in: [item])
        }

        private func routeFirstURL(in items: [RecognizedItem]) {
            for item in items {
                guard case .barcode(let barcode) = item,
                      let payload = barcode.payloadStringValue,
                      let url = URL(string: payload) else {
                    continue
                }
                Task { @MainActor in
                    self.onURL(url)
                }
                return
            }
        }
    }
}
