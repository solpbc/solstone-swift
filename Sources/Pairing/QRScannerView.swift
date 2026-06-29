// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import VisionKit

struct QRScannerView: View {
    let onURL: @MainActor (URL) -> Void
    let onUnavailable: @MainActor () -> Void

    var body: some View {
        ZStack {
            DataScannerRepresentable(onURL: self.onURL, onUnavailable: self.onUnavailable)

            QRScannerOverlay()
                .allowsHitTesting(false)
        }
    }
}

private struct DataScannerRepresentable: UIViewControllerRepresentable {
    let onURL: @MainActor (URL) -> Void
    let onUnavailable: @MainActor () -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: false,
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

private struct QRScannerOverlay: View {
    var body: some View {
        ZStack {
            GeometryReader { geometry in
                let side = min(260, min(geometry.size.width, geometry.size.height) * 0.64)

                QRScannerReticle()
                    .stroke(
                        .white.opacity(0.9),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: side, height: side)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }

            VStack {
                Spacer()
                Text("point your phone at the code")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.65), radius: 3, x: 0, y: 1)
                    .padding(.bottom, 32)
            }
        }
    }
}

private struct QRScannerReticle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let length = min(rect.width, rect.height) * 0.24

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))

        path.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))

        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - length))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - length, y: rect.maxY))

        path.move(to: CGPoint(x: rect.minX + length, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - length))

        return path
    }
}
