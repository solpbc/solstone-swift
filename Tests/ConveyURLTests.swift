// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class ConveyURLTests: XCTestCase {
    func testRootURLUsesConnectedLoopbackRootRoute() throws {
        let url = try XCTUnwrap(ConveyURL.rootURL(activeLocalPort: 8080))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.host, "127.0.0.1")
        XCTAssertEqual(components.port, 8080)
        XCTAssertEqual(components.path, "/")
    }

    func testURLsAreNilWithoutLivePort() {
        XCTAssertNil(ConveyURL.rootURL(activeLocalPort: nil))
    }
}
