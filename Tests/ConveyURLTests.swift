// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class ConveyURLTests: XCTestCase {
    func testDayURLUsesConnectedLoopbackDayRoute() throws {
        let url = try XCTUnwrap(ConveyURL.dayURL(activeLocalPort: 8080, day: "20260602"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "http")
        XCTAssertEqual(components.host, "127.0.0.1")
        XCTAssertEqual(components.port, 8080)
        XCTAssertEqual(components.path, "/app/home/20260602")
        XCTAssertNil(components.queryItems)
    }

    func testRootURLUsesConnectedLoopbackRootRoute() throws {
        let url = try XCTUnwrap(ConveyURL.rootURL(activeLocalPort: 8080))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.host, "127.0.0.1")
        XCTAssertEqual(components.port, 8080)
        XCTAssertEqual(components.path, "/")
    }

    func testURLsAreNilWithoutLivePort() {
        XCTAssertNil(ConveyURL.dayURL(activeLocalPort: nil, day: "20260602"))
        XCTAssertNil(ConveyURL.rootURL(activeLocalPort: nil))
    }

    func testDayURLRequiresDay() {
        XCTAssertNil(ConveyURL.dayURL(activeLocalPort: 8080, day: nil))
        XCTAssertNil(ConveyURL.dayURL(activeLocalPort: 8080, day: ""))
    }

    func testDayURLIsDayLevelRegardlessOfSegment() throws {
        // `dayURL` has no segment parameter by design; convey addresses the day.
        let url = try XCTUnwrap(ConveyURL.dayURL(activeLocalPort: 8080, day: "20260602"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.path, "/app/home/20260602")
    }
}
