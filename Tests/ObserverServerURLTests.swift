// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class ObserverServerURLTests: XCTestCase {
    func testObserverURLsBuildKeylessRoutes() throws {
        let registerURL = try XCTUnwrap(ObserverServerURL.registrationURL(localPort: 7071))
        let manifestURL = try XCTUnwrap(ObserverServerURL.manifestURL(localPort: 7071, source: "mobile-segment"))
        let manifestDayURL = try XCTUnwrap(ObserverServerURL.manifestDayURL(
            localPort: 7071,
            source: "mobile-segment",
            day: "20260610"
        ))
        let segmentsURL = try XCTUnwrap(ObserverServerURL.segmentsURL(
            localPort: 7071,
            source: "mobile-segment",
            day: "20260610"
        ))

        XCTAssertEqual(registerURL.host, "127.0.0.1")
        XCTAssertEqual(registerURL.path, "/app/devices/register")
        XCTAssertEqual(manifestURL.path, "/app/devices/ingest/manifest")
        XCTAssertEqual(manifestDayURL.path, "/app/devices/ingest/manifest/20260610")
        XCTAssertEqual(segmentsURL.path, "/app/devices/ingest/segments/20260610")
        XCTAssertEqual(manifestURL.query, "source=mobile-segment")
        XCTAssertEqual(manifestDayURL.query, "source=mobile-segment")
        XCTAssertEqual(segmentsURL.query, "source=mobile-segment")
        XCTAssertEqual(ObserverServerURL.ingestProtocolVersion, "3")
    }

    func testDeleteSourceURLBuildsVerifiedPath() throws {
        let url = try XCTUnwrap(ObserverServerURL.deleteSourceURL(
            localPort: 7071,
            source: "location"
        ))

        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.path, "/app/devices/source/location")
    }

    func testHealthURLBuildsObserverHealthRoute() throws {
        let url = try XCTUnwrap(ObserverServerURL.healthURL(localPort: 7071))

        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.path, "/app/devices/health")
    }

    func testImporterURLsBuildKeylessRoutes() throws {
        XCTAssertEqual(ImporterServerURL.savePath, "/app/import/api/save")
        XCTAssertEqual(ImporterServerURL.startPath, "/app/import/api/start")
    }
}
