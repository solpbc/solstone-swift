// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class ObserverLiveActivitySubtitleTests: XCTestCase {
    func testObserverModeLabelAlwaysReturnsListening() {
        for rawMode in ["meeting", "voice_memo", "anything_else", ""] {
            XCTAssertEqual(observerModeLabel(for: rawMode), "listening")
            XCTAssertNotEqual(observerModeLabel(for: rawMode), "Meeting")
            XCTAssertNotEqual(observerModeLabel(for: rawMode), "Voice memo")
        }
    }
}
