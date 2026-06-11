// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class ObserverServerURLTests: XCTestCase {
    func testObserverURLsBuildKeylessRoutes() throws {
        let registerURL = try XCTUnwrap(ObserverServerURL.registrationURL(localPort: 7071))
        let ingestURL = try XCTUnwrap(ObserverServerURL.ingestURL(localPort: 7071))
        let manifestURL = try XCTUnwrap(ObserverServerURL.manifestURL(localPort: 7071, day: "20260610"))

        XCTAssertEqual(registerURL.host, "127.0.0.1")
        XCTAssertEqual(registerURL.path, "/app/observer/register")
        XCTAssertEqual(ingestURL.path, "/app/observer/ingest")
        XCTAssertEqual(manifestURL.path, "/app/observer/ingest/manifest/20260610")
    }

    func testDeleteSourceURLBuildsVerifiedPath() throws {
        let url = try XCTUnwrap(ObserverServerURL.deleteSourceURL(
            localPort: 7071,
            source: "import.share"
        ))

        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.path, "/app/observer/source/import.share")
    }
}
