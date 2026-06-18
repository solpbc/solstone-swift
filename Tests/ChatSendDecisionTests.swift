// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class ChatSendDecisionTests: XCTestCase {
    func testReturnAppendSendsWhenShiftWasNotInserted() {
        var shiftJustInserted = false

        XCTAssertTrue(ChatSendDecision.isReturnSend(
            old: "hi",
            new: "hi\n",
            shiftJustInserted: &shiftJustInserted
        ))
        XCTAssertFalse(shiftJustInserted)
    }

    func testShiftReturnDoesNotSendAndResetsFlag() {
        var shiftJustInserted = true

        XCTAssertFalse(ChatSendDecision.isReturnSend(
            old: "hi",
            new: "hi\n",
            shiftJustInserted: &shiftJustInserted
        ))
        XCTAssertFalse(shiftJustInserted)
    }

    func testNonReturnEditsDoNotSend() {
        var shiftJustInserted = false
        XCTAssertFalse(ChatSendDecision.isReturnSend(old: "hi", new: "hi\nthere", shiftJustInserted: &shiftJustInserted))
        XCTAssertFalse(ChatSendDecision.isReturnSend(old: "hi", new: "h\ni", shiftJustInserted: &shiftJustInserted))
        XCTAssertFalse(ChatSendDecision.isReturnSend(old: "hi", new: "h", shiftJustInserted: &shiftJustInserted))
        XCTAssertFalse(ChatSendDecision.isReturnSend(old: "hi", new: "hi!", shiftJustInserted: &shiftJustInserted))
    }

    func testCanSendRequiresNonWhitespaceText() {
        XCTAssertFalse(ChatSendDecision.canSend(""))
        XCTAssertFalse(ChatSendDecision.canSend(" \n\t "))
        XCTAssertTrue(ChatSendDecision.canSend("hi"))
    }
}
