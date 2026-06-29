// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import CoreGraphics
import Foundation
import XCTest

nonisolated final class ScreencastWriterPolicyTests: XCTestCase {
    func testPTSOneFPSAcceptance() {
        var lastAccepted: Double?
        let samples: [(Double, Bool)] = [
            (0.0, true),
            (0.5, false),
            (0.999, false),
            (1.0, true),
            (1.999, false),
            (2.0, true),
        ]

        for (pts, expected) in samples {
            let accepted = MobileSegmentScreencastFramePolicy.acceptsVideoFrame(
                ptsSeconds: pts,
                lastAcceptedPTSSeconds: lastAccepted
            )
            XCTAssertEqual(accepted, expected, "PTS \(pts)")
            if accepted {
                lastAccepted = pts
            }
        }
    }

    func testRejectsNonFinitePTS() {
        for pts in [Double.nan, .infinity, -.infinity] {
            XCTAssertFalse(MobileSegmentScreencastFramePolicy.acceptsVideoFrame(
                ptsSeconds: pts,
                lastAcceptedPTSSeconds: nil
            ))
        }
    }

    func testPortraitLandscapeOutputDimensions() {
        XCTAssertEqual(
            MobileSegmentScreencastGeometry.outputDimensions(
                sourceWidth: 1_170,
                sourceHeight: 2_532,
                orientation: .up
            ),
            MobileSegmentScreencastCanvasDimensions(width: 720, height: 1280)
        )
        XCTAssertEqual(
            MobileSegmentScreencastGeometry.outputDimensions(
                sourceWidth: 2_532,
                sourceHeight: 1_170,
                orientation: .up
            ),
            MobileSegmentScreencastCanvasDimensions(width: 1280, height: 720)
        )
        XCTAssertEqual(
            MobileSegmentScreencastGeometry.outputDimensions(
                sourceWidth: 2_532,
                sourceHeight: 1_170,
                orientation: .right
            ),
            MobileSegmentScreencastCanvasDimensions(width: 720, height: 1280)
        )
    }

    func testAspectFitOffsets() {
        let fit = MobileSegmentScreencastGeometry.aspectFit(
            sourceWidth: 1_000,
            sourceHeight: 500,
            canvasWidth: 1_280,
            canvasHeight: 720
        )

        XCTAssertEqual(fit.scale, 1.28, accuracy: 0.0001)
        XCTAssertEqual(fit.offsetX, 0, accuracy: 0.0001)
        XCTAssertEqual(fit.offsetY, 40, accuracy: 0.0001)
        XCTAssertEqual(fit.transform.tx, 0, accuracy: 0.0001)
        XCTAssertEqual(fit.transform.ty, 40, accuracy: 0.0001)
    }

    func testInFlightCapDropsAndResumes() {
        XCTAssertFalse(MobileSegmentScreencastFramePolicy.shouldDropFrame(inFlightFrameCount: 0))
        XCTAssertFalse(MobileSegmentScreencastFramePolicy.shouldDropFrame(inFlightFrameCount: 1))
        XCTAssertTrue(MobileSegmentScreencastFramePolicy.shouldDropFrame(inFlightFrameCount: 2))
        XCTAssertFalse(MobileSegmentScreencastFramePolicy.shouldDropFrame(inFlightFrameCount: 1))
    }

    func testFinalizedMp4HasNoAudioTrack() throws {
        XCTAssertFalse(MobileSegmentScreencastWriterConfiguration.writesAudioTrack)
        let writer = try Self.extensionSource(named: "ScreencastBroadcastWriter.swift")

        XCTAssertTrue(writer.contains("AVAssetWriterInput(mediaType: .video"))
        XCTAssertFalse(writer.contains("mediaType: .audio"))
        XCTAssertFalse(writer.contains("writer.add(audio"))
    }

    func testAudioSampleTypesIgnored() throws {
        XCTAssertTrue(MobileSegmentScreencastSamplePolicy.accepts(.video))
        XCTAssertFalse(MobileSegmentScreencastSamplePolicy.accepts(.audioMic))
        XCTAssertFalse(MobileSegmentScreencastSamplePolicy.accepts(.audioApp))
        XCTAssertFalse(MobileSegmentScreencastSamplePolicy.accepts(.unknown))

        let handler = try Self.extensionSource(named: "SampleHandler.swift")
        XCTAssertTrue(handler.contains("guard MobileSegmentScreencastSamplePolicy.accepts(kind) else { return }"))
        XCTAssertTrue(handler.contains("self.writer.appendVideo(sampleBuffer"))
    }

    func testExtensionWriterUsesApprovedImports() throws {
        let allowedImports: Set<String> = [
            "AVFoundation",
            "CoreGraphics",
            "CoreMedia",
            "CoreVideo",
            "Foundation",
            "ReplayKit",
            "os",
        ]
        for filename in ["SampleHandler.swift", "ScreencastBroadcastWriter.swift"] {
            let source = try Self.extensionSource(named: filename)
            let imports = source
                .split(separator: "\n")
                .filter { $0.hasPrefix("import ") }
                .map { String($0.dropFirst("import ".count)) }
            XCTAssertFalse(imports.isEmpty, filename)
            XCTAssertTrue(Set(imports).isSubset(of: allowedImports), "\(filename): \(imports)")
        }
    }
}

private extension ScreencastWriterPolicyTests {
    static func extensionSource(named filename: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SolstoneBroadcastExtension")
            .appendingPathComponent(filename)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
