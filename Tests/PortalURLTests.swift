// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class PortalURLTests: XCTestCase {
    func testDefaultBaseURLUsesServicesHost() {
        XCTAssertEqual(PortalURL.baseURL(arguments: []), URL(string: "https://services.solstone.app")!)
    }

    func testDebugPortalURLOverrideIsRespected() {
        let url = PortalURL.baseURL(arguments: ["app", "--portal-url=http://127.0.0.1:9090"])
#if DEBUG
        XCTAssertEqual(url, URL(string: "http://127.0.0.1:9090")!)
#else
        XCTAssertEqual(url, URL(string: "https://services.solstone.app")!)
#endif
    }

    func testEnablePushURLContainsExpectedQueryItems() throws {
        let url = try XCTUnwrap(PortalURL.enablePushURL(
            nonce: "ABC+123",
            deviceToken: "deadbeef",
            arguments: ["app", "--portal-url=http://127.0.0.1:9090"]
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/enable/push")
        XCTAssertEqual(Self.queryValue("nonce", in: components), "ABC+123")
        XCTAssertEqual(Self.queryValue("device_token", in: components), "deadbeef")
        XCTAssertEqual(Self.queryValue("platform", in: components), "ios")
        XCTAssertEqual(Self.queryValue("bundle_id", in: components), "app.solstone.swift")
    }

    func testHandoffPushURLContainsExpectedQueryItems() throws {
        let url = try XCTUnwrap(PortalURL.handoffPushURL(
            nonce: "ABC+123",
            arguments: ["app", "--portal-url=http://127.0.0.1:9090"]
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/handoff/push")
        XCTAssertEqual(Self.queryValue("nonce", in: components), "ABC+123")
    }

    private static func queryValue(_ name: String, in components: URLComponents) -> String? {
        components.queryItems?.first { $0.name == name }?.value
    }
}
