// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class DrainSignpostTests: XCTestCase {
    func testAudioSourceTypeMappingUsesPublicLabels() {
        XCTAssertEqual(DrainSource.audio("observer-audio"), .observer)
        XCTAssertEqual(DrainSource.audio("omi-audio"), .omi)
        XCTAssertEqual(DrainSource.audio("watch-audio"), .watch)
        XCTAssertEqual(DrainSource.audio("observer-audio").rawValue, "observer")
        XCTAssertEqual(DrainSource.audio("omi-audio").rawValue, "omi")
        XCTAssertEqual(DrainSource.audio("watch-audio").rawValue, "watch")
    }

    func testUnknownAudioSourceTypeDoesNotExposeRawValue() {
        let rawSourceType = "private-source-type"

        let source = DrainSource.audio(rawSourceType)

        XCTAssertEqual(source, .unknown)
        XCTAssertEqual(source.rawValue, "unknown")
        XCTAssertNotEqual(source.rawValue, rawSourceType)
    }

    func testErrorCategorizationBucketsTransportHTTPFilesystemDecodeUnknown() {
        XCTAssertEqual(DrainErrorCategory.classify(URLError(.timedOut)), .transport)
        XCTAssertEqual(DrainErrorCategory.http.rawValue, "http")
        XCTAssertEqual(DrainSignpost.httpStatusClass(404), "4xx")
        XCTAssertEqual(DrainSignpost.httpStatusClass(503), "5xx")
        XCTAssertEqual(DrainSignpost.httpStatusClass(302), "other")
        XCTAssertEqual(DrainErrorCategory.classify(CocoaError(.fileNoSuchFile)), .filesystem)
        XCTAssertEqual(
            DrainErrorCategory.classify(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad data"))),
            .decode
        )
        XCTAssertEqual(DrainErrorCategory.classify(TestError()), .unknown)
    }

    func testCountDeltaBoundaryAndStepFieldArePubliclyNamed() {
        XCTAssertEqual(String(describing: DrainBoundary.countDelta.name), "drain.count_delta")
        XCTAssertEqual(DrainFields(step: "completion").publicDescription, "step=completion")
    }
}

private struct TestError: Error {}
