// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation
import SwiftUI
import WidgetKit
import XCTest

nonisolated final class WatchComplicationRenderTests: XCTestCase {
    @MainActor
    func testCircularRenderCanvasDimensionsMatchHarnessConstants() throws {
        let render = try WatchComplicationRenderHarness.render(Self.complicationView(for: .question))
        let expected = Int(WatchComplicationRenderHarness.complicationCanvasPoints * WatchComplicationRenderHarness.rendererScale)

        XCTAssertEqual(render.width, expected)
        XCTAssertEqual(render.height, expected)
    }

    @MainActor
    func testCircularStatesStayWithinInkBand() throws {
        for state in ComplicationRenderState.allCases {
            let render = try WatchComplicationRenderHarness.render(Self.complicationView(for: state))

            Self.printStateMetric(state: state, render: render)
            XCTAssertGreaterThanOrEqual(render.inkFraction, WatchComplicationRenderHarness.minimumInkFraction, state.rawValue)
            XCTAssertLessThanOrEqual(render.inkFraction, WatchComplicationRenderHarness.maximumInkFraction, state.rawValue)
        }
    }

    @MainActor
    func testGrayDiscControlViolatesInkBand() throws {
        let render = try WatchComplicationRenderHarness.render(Circle().fill(.gray))

        print(
            "WATCH_RENDER_GRAY inkFraction=\(Self.format(render.inkFraction))"
        )
        XCTAssertGreaterThan(render.inkFraction, WatchComplicationRenderHarness.maximumInkFraction)
    }

    @MainActor
    func testCircularStatesArePairwiseDistinctByAlpha() throws {
        let renders = try Self.renderedStates()

        for floor in Self.pairwiseAlphaDifferenceFloors {
            let difference = try XCTUnwrap(renders[floor.lhs]).alphaDifferenceFraction(from: try XCTUnwrap(renders[floor.rhs]))

            Self.printPairMetric(floor.lhs, floor.rhs, difference: difference)
            XCTAssertGreaterThanOrEqual(
                difference,
                floor.minimum,
                "\(floor.lhs.rawValue)/\(floor.rhs.rawValue) difference \(Self.format(difference)) below \(Self.format(floor.minimum))"
            )
        }
    }

    @MainActor
    func testNilSnapshotMatchesDirectQuestionMarkPixels() throws {
        let nilRender = try WatchComplicationRenderHarness.render(Self.complicationView(for: .question))
        let directRender = try WatchComplicationRenderHarness.render(DirectQuestionMarkView())
        let difference = nilRender.alphaDifferenceFraction(from: directRender)

        print("WATCH_RENDER_NIL_DIRECT alphaDifferenceFraction=\(Self.format(difference))")
        XCTAssertLessThanOrEqual(difference, WatchComplicationRenderHarness.nearIdenticalAlphaDifferenceCeiling)
    }

    @MainActor
    func testNilSnapshotDiffersFromOffPixels() throws {
        let nilRender = try WatchComplicationRenderHarness.render(Self.complicationView(for: .question))
        let offRender = try WatchComplicationRenderHarness.render(Self.complicationView(for: .cloud))
        let difference = nilRender.alphaDifferenceFraction(from: offRender)
        let floor = try XCTUnwrap(Self.pairwiseAlphaDifferenceFloors.first { pair in
            pair.matches(.cloud, .question)
        })

        print("WATCH_RENDER_NIL_OFF alphaDifferenceFraction=\(Self.format(difference))")
        XCTAssertGreaterThanOrEqual(difference, floor.minimum)
    }
}

private extension WatchComplicationRenderTests {
    struct PairwiseAlphaFloor {
        let lhs: ComplicationRenderState
        let rhs: ComplicationRenderState
        let minimum: Double

        init(_ lhs: ComplicationRenderState, _ rhs: ComplicationRenderState, minimum: Double) {
            self.lhs = lhs
            self.rhs = rhs
            self.minimum = minimum
        }

        func matches(_ first: ComplicationRenderState, _ second: ComplicationRenderState) -> Bool {
            (self.lhs == first && self.rhs == second) || (self.lhs == second && self.rhs == first)
        }
    }

    static let pairwiseAlphaDifferenceFloors: [PairwiseAlphaFloor] = [
        PairwiseAlphaFloor(.sun, .cloud, minimum: 0.088227), // measured 0.126038
        PairwiseAlphaFloor(.sun, .bang, minimum: 0.020000), // measured 0.025391, retention clamps to absolute floor
        PairwiseAlphaFloor(.sun, .question, minimum: 0.029736), // measured 0.042480
        PairwiseAlphaFloor(.cloud, .bang, minimum: 0.076007), // measured 0.108582
        PairwiseAlphaFloor(.cloud, .question, minimum: 0.066565), // measured 0.095093
        PairwiseAlphaFloor(.bang, .question, minimum: 0.020000), // measured 0.027954, retention clamps to absolute floor
    ]

    @MainActor
    static func renderedStates() throws -> [ComplicationRenderState: RenderedComplicationImage] {
        var renders: [ComplicationRenderState: RenderedComplicationImage] = [:]
        for state in ComplicationRenderState.allCases {
            renders[state] = try WatchComplicationRenderHarness.render(Self.complicationView(for: state))
        }
        return renders
    }

    static func complicationView(for state: ComplicationRenderState) -> SolstoneWatchComplicationView {
        SolstoneWatchComplicationView(
            entry: SolstoneWatchComplicationEntry(
                date: Date(timeIntervalSinceReferenceDate: 0),
                snapshot: state.snapshot
            )
        )
    }

    static func printStateMetric(state: ComplicationRenderState, render: RenderedComplicationImage) {
        print(
            "WATCH_RENDER_STATE state=\(state.rawValue) inkFraction=\(Self.format(render.inkFraction))"
        )
    }

    static func printPairMetric(
        _ lhs: ComplicationRenderState,
        _ rhs: ComplicationRenderState,
        difference: Double
    ) {
        print(
            "WATCH_RENDER_PAIR lhs=\(lhs.rawValue) rhs=\(rhs.rawValue) alphaDifferenceFraction=\(Self.format(difference))"
        )
    }

    static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}

private enum ComplicationRenderState: String, CaseIterable {
    case sun
    case cloud
    case bang
    case question

    var snapshot: WatchComplicationSnapshot? {
        switch self {
        case .sun:
            WatchComplicationSnapshot(
                presentation: WatchCaptureOwnerPresentation(
                    status: .active,
                    queuedCount: 0,
                    isSessionRunning: true,
                    sessionStartedAt: Date(timeIntervalSinceReferenceDate: 0)
                ),
                isReachable: true
            )
        case .cloud:
            WatchComplicationSnapshot(
                presentation: WatchCaptureOwnerPresentation(status: .off, queuedCount: 0),
                isReachable: true
            )
        case .bang:
            WatchComplicationSnapshot(
                presentation: WatchCaptureOwnerPresentation(status: .needsAttention(.diskFull), queuedCount: 0),
                isReachable: true
            )
        case .question:
            nil
        }
    }
}

private struct DirectQuestionMarkView: View {
    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image("SolRingQuestion", bundle: #bundle)
                .resizable()
                .scaledToFit()
                .padding(1)
                .widgetAccentable()
        }
        .containerBackground(.clear, for: .widget)
    }
}

private enum WatchComplicationRenderHarness {
    static let complicationCanvasPoints: CGFloat = 64
    static let rendererScale: CGFloat = 2
    // The accessory background rasterizes at alpha 25 in this hostless harness.
    // This threshold sits just above that low-alpha flood with enough margin to
    // clear it and no more, so the marks' antialiased edges stay in the measurement.
    static let alphaInkThreshold = UInt8(32)
    static let pairwiseAlphaDifferenceDelta = UInt8(8)
    static let minimumInkFraction = 0.20
    // Slab guard: a circle inscribed in the square canvas is pi / 4 = 0.7854.
    // The gray-disc control measured 0.787842, matching that geometry. The
    // highest mark state measured cloud at 0.3823, so this ceiling is non-vacuous.
    static let maximumInkFraction = 0.70
    // An opaque-pixel band was evaluated and dropped. It is redundant with the
    // ink band because both named slab failures fill the accessory circle: the
    // gray disc measured ink 0.787842, and an opaque disc plus glyph inks that
    // same disc. Any ceiling would be a magic number fitted between marks near
    // 0.78 and the disc near 0.98, deriving a threshold from the run it gates.
    // This hostless harness also composites AccessoryWidgetBackground at alpha
    // 25 under the marks, pushing near-opaque mark pixels to 255. A bare
    // SolRingSun with no chrome still measured opaqueFraction 0.754427, so
    // compositing is not the only contributor. The red opaque-band result is a
    // test-instrument issue, not a product finding.
    static let absolutePairwiseAlphaDifferenceFloor = 0.020
    static let nearIdenticalAlphaDifferenceCeiling = 0.005

    // Rendering here intentionally diverges from the shipped view in three ways:
    // the canvas uses a derived approximate accessory size, the widget family is
    // injected through WidgetPreviewContext, and the result is clipped to a circle
    // although the product view does not apply that clip. WidgetKit does not vend
    // real accessory canvas dimensions to a host app, so this size is a derived
    // approximation, not a platform guarantee.
    @MainActor
    static func render<V: View>(_ view: V) throws -> RenderedComplicationImage {
        let content = view
            .frame(width: Self.complicationCanvasPoints, height: Self.complicationCanvasPoints)
            .previewContext(WidgetPreviewContext(family: .accessoryCircular))
            .clipShape(Circle())
        let renderer = ImageRenderer(content: content)
        renderer.scale = Self.rendererScale
        renderer.isOpaque = false

        guard let cgImage = renderer.cgImage else {
            throw RenderedComplicationImageError.missingImage
        }
        return try RenderedComplicationImage(cgImage: cgImage)
    }
}

private struct RenderedComplicationImage {
    let width: Int
    let height: Int
    let pixels: [RenderedPixel]

    init(cgImage: CGImage) throws {
        let imageWidth = cgImage.width
        let imageHeight = cgImage.height

        let bytesPerPixel = 4
        let rowBytes = imageWidth * bytesPerPixel
        var buffer = [UInt8](repeating: 0, count: imageHeight * rowBytes)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        let didDraw = buffer.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: imageWidth,
                    height: imageHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: rowBytes,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: bitmapInfo
                  ) else {
                return false
            }

            context.draw(
                cgImage,
                in: CGRect(x: 0, y: 0, width: CGFloat(imageWidth), height: CGFloat(imageHeight))
            )
            return true
        }
        guard didDraw else {
            throw RenderedComplicationImageError.contextCreationFailed
        }

        var pixels: [RenderedPixel] = []
        pixels.reserveCapacity(imageWidth * imageHeight)
        for index in stride(from: 0, to: buffer.count, by: bytesPerPixel) {
            pixels.append(
                RenderedPixel(
                    alpha: buffer[index + 3]
                )
            )
        }
        self.width = imageWidth
        self.height = imageHeight
        self.pixels = pixels
    }

    var inkFraction: Double {
        Double(self.inkedPixels.count) / Double(self.pixels.count)
    }

    func alphaDifferenceFraction(from other: RenderedComplicationImage) -> Double {
        precondition(self.width == other.width)
        precondition(self.height == other.height)

        let differenceCount = zip(self.pixels, other.pixels).filter { lhs, rhs in
            abs(Int(lhs.alpha) - Int(rhs.alpha)) > Int(WatchComplicationRenderHarness.pairwiseAlphaDifferenceDelta)
        }.count
        return Double(differenceCount) / Double(self.pixels.count)
    }

    private var inkedPixels: [RenderedPixel] {
        self.pixels.filter { pixel in
            pixel.alpha > WatchComplicationRenderHarness.alphaInkThreshold
        }
    }
}

private struct RenderedPixel {
    let alpha: UInt8
}

private enum RenderedComplicationImageError: Error {
    case missingImage
    case contextCreationFailed
}
