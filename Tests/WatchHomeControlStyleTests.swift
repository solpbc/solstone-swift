// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if canImport(solstone_swift)
@testable import solstone_swift
#endif
import XCTest

nonisolated final class WatchHomeControlStyleTests: XCTestCase {
    func testTheControlSaysWhatItWillDo() {
        XCTAssertEqual(watchHomeControlStyle(isRunning: true).label, "stop")
        XCTAssertEqual(watchHomeControlStyle(isRunning: false).label, "start")
    }

    func testOnlyStartIsTheProminentControl() {
        XCTAssertNotNil(watchHomeControlStyle(isRunning: false).tintHex)
        XCTAssertNil(watchHomeControlStyle(isRunning: true).tintHex)
    }
}
