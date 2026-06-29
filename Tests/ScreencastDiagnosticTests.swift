// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class ScreencastDiagnosticTests: XCTestCase {
    func testAllSixReasonsMapToResolution() {
        XCTAssertEqual(
            screencastDiagnosticResolution(for: .noVideo, hasSegment: true),
            .noArtifact(reason: "no_video")
        )
        XCTAssertEqual(
            screencastDiagnosticResolution(for: .finalizeTimeout, hasSegment: true),
            .failedToFinalize(reason: "finalize_timeout")
        )
        XCTAssertEqual(
            screencastDiagnosticResolution(for: .writerFailure, hasSegment: true),
            .failedToFinalize(reason: "writer_failure")
        )
        XCTAssertEqual(
            screencastDiagnosticResolution(for: .staleOrMissingPointer, hasSegment: true),
            .failedToFinalize(reason: "stale_or_missing_pointer")
        )
        XCTAssertEqual(
            screencastDiagnosticResolution(for: .filesystemHandoffFailure, hasSegment: true),
            .failedToFinalize(reason: "filesystem_handoff_failure")
        )
        XCTAssertEqual(
            screencastDiagnosticResolution(for: .appGroupUnavailable, hasSegment: true),
            .runtimeAttention(.appGroupUnavailable)
        )
    }
}
