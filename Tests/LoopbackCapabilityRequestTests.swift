// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import SPLTunnel
import XCTest

nonisolated final class LoopbackCapabilityRequestTests: XCTestCase {
    func testLoopbackRequestCarriesTheCapabilityWithCookieHandlingOff() throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:50123/app/network/api/status")))
        request.attachLoopbackCapability()

        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), LoopbackCapability.process.cookieHeaderValue)
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testAnyOtherHostIsLeftUnchanged() throws {
        for address in ["http://192.168.1.20:5015/", "https://review.solstone.app/", "http://localhost:50123/"] {
            var request = URLRequest(url: try XCTUnwrap(URL(string: address)))
            request.attachLoopbackCapability()

            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"), address)
            XCTAssertTrue(request.httpShouldHandleCookies, address)
        }
    }
}
