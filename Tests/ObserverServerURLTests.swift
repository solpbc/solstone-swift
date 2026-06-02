// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class ObserverServerURLTests: XCTestCase {
    func testDeleteSourceURLBuildsVerifiedPath() throws {
        let url = try XCTUnwrap(ObserverServerURL.deleteSourceURL(
            localPort: 7071,
            stream: "import.share",
            key: "abc"
        ))

        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.path, "/app/observer/source/import.share/abc")
    }
}
