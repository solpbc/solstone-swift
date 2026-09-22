// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if canImport(solstone_swift)
@testable import solstone_swift
#endif
import XCTest

nonisolated final class WatchComplicationLiteralTests: XCTestCase {
    func testComplicationSnapshotLiterals() {
        let activeSnapshot = WatchComplicationSnapshot(
            presentation: WatchCaptureOwnerPresentation(status: .active, queuedCount: 0),
            isReachable: true
        )
        XCTAssertEqual(activeSnapshot.role, .live)
        XCTAssertTrue(activeSnapshot.showsElapsed)

        let enrollingSnapshot = WatchComplicationSnapshot(
            presentation: WatchCaptureOwnerPresentation(status: .enrolling, queuedCount: 0),
            isReachable: true
        )
        XCTAssertEqual(enrollingSnapshot.role, .live)
        XCTAssertFalse(enrollingSnapshot.showsElapsed)

        let offSnapshot = WatchComplicationSnapshot(
            presentation: WatchCaptureOwnerPresentation(status: .off, queuedCount: 0),
            isReachable: true
        )
        XCTAssertEqual(offSnapshot.role, .calm)
        XCTAssertFalse(offSnapshot.showsElapsed)

        let attentionSnapshot = WatchComplicationSnapshot(
            presentation: WatchCaptureOwnerPresentation(status: .needsAttention(.diskFull), queuedCount: 0),
            isReachable: true
        )
        XCTAssertEqual(attentionSnapshot.role, .alert)
        XCTAssertFalse(attentionSnapshot.showsElapsed)
    }
}
