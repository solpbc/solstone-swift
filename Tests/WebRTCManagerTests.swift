// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class WebRTCManagerTests: XCTestCase {
    @MainActor
    func testDisconnectWithoutConnect() {
        let manager = WebRTCManager()
        manager.disconnect()
    }
}
