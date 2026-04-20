// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

final class SidebandNotifierTests: XCTestCase {
    func testNotifyConstructsCorrectRequest() async {
        let notifier = SidebandNotifier()
        await notifier.notify(callId: "test-call-id", localPort: 99999)
    }
}
