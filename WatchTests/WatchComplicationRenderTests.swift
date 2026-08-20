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
        let render = try WatchComplicationRenderHarness.render(Self.complicationView(for: .offline))
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
        let nilRender = try WatchComplicationRenderHarness.render(Self.complicationView(for: .offline))
        let directRender = try WatchComplicationRenderHarness.render(DirectOfflineMarkView())
        let difference = nilRender.alphaDifferenceFraction(from: directRender)

        print("WATCH_RENDER_NIL_DIRECT alphaDifferenceFraction=\(Self.format(difference))")
        XCTAssertLessThanOrEqual(difference, WatchComplicationRenderHarness.nearIdenticalAlphaDifferenceCeiling)
    }

    @MainActor
    func testNilSnapshotDiffersFromOffPixels() throws {
        let nilRender = try WatchComplicationRenderHarness.render(Self.complicationView(for: .offline))
        let offRender = try WatchComplicationRenderHarness.render(Self.complicationView(for: .paused))
        let difference = nilRender.alphaDifferenceFraction(from: offRender)
        let floor = try XCTUnwrap(Self.pairwiseAlphaDifferenceFloors.first { pair in
            pair.matches(.paused, .offline)
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
        PairwiseAlphaFloor(.healthy, .attention, minimum: 0.081262), // measured 0.116089
        PairwiseAlphaFloor(.healthy, .paused, minimum: 0.104761), // measured 0.149658
        PairwiseAlphaFloor(.healthy, .connecting, minimum: 0.033026), // measured 0.047180
        PairwiseAlphaFloor(.healthy, .offline, minimum: 0.050287), // measured 0.071838
        PairwiseAlphaFloor(.attention, .paused, minimum: 0.060413), // measured 0.086304
        PairwiseAlphaFloor(.attention, .connecting, minimum: 0.051783), // measured 0.073975
        PairwiseAlphaFloor(.attention, .offline, minimum: 0.073743), // measured 0.105347
        PairwiseAlphaFloor(.paused, .connecting, minimum: 0.072589), // measured 0.103699
        PairwiseAlphaFloor(.paused, .offline, minimum: 0.097412), // measured 0.139160
        PairwiseAlphaFloor(.connecting, .offline, minimum: 0.062549), // measured 0.089355
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
    case healthy
    case attention
    case paused
    case connecting
    case offline

    var snapshot: WatchComplicationSnapshot? {
        switch self {
        case .healthy:
            WatchComplicationSnapshot(
                presentation: WatchCaptureOwnerPresentation(
                    status: .active,
                    queuedCount: 0,
                    isSessionRunning: true,
                    sessionStartedAt: Date(timeIntervalSinceReferenceDate: 0)
                ),
                isReachable: true
            )
        case .attention:
            WatchComplicationSnapshot(
                presentation: WatchCaptureOwnerPresentation(status: .needsAttention(.diskFull), queuedCount: 0),
                isReachable: true
            )
        case .paused:
            WatchComplicationSnapshot(
                presentation: WatchCaptureOwnerPresentation(status: .off, queuedCount: 0),
                isReachable: true
            )
        case .connecting:
            WatchComplicationSnapshot(
                presentation: WatchCaptureOwnerPresentation(status: .enrolling, queuedCount: 0),
                isReachable: true
            )
        case .offline:
            nil
        }
    }
}

private struct DirectOfflineMarkView: View {
    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image("MarkOffline", bundle: #bundle)
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
    // Sparsest real mark is attention at 0.192627: Appendix A's attention glyph is rays
    // plus bang with no inner circle, so it carries less ink than the ring-bearing mark
    // that calibrated the old 0.20. Floor is that measurement retained at 0.70, the same
    // factor the pairwise floors use. A missing Image measures 0.000000 and still fails.
    static let minimumInkFraction = 0.134839
    // Slab guard: a circle inscribed in the square canvas is pi / 4 = 0.7854.
    // The gray-disc control measured 0.787842, matching that geometry. The
    // five mark states sit well below this ceiling, so it stays non-vacuous.
    static let maximumInkFraction = 0.70
    // An opaque-pixel band was evaluated and dropped. It is redundant with the
    // ink band because both named slab failures fill the accessory circle: the
    // gray disc measured ink 0.787842, and an opaque disc plus glyph inks that
    // same disc. Any ceiling would be a magic number fitted between marks near
    // 0.78 and the disc near 0.98, deriving a threshold from the run it gates.
    // This hostless harness also composites AccessoryWidgetBackground at alpha
    // 25 under the marks, pushing near-opaque mark pixels to 255. A bare
    // healthy mark with no chrome still fills most of the disc, so
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
