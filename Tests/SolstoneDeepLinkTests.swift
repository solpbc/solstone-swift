// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class SolstoneDeepLinkTests: XCTestCase {
    @MainActor
    func testObserverDeepLinkParses() {
        XCTAssertEqual(SolstoneDeepLink.parse(URL(string: "solstone://observer/stop")!), .observerStop)
        XCTAssertNil(SolstoneDeepLink.parse(URL(string: "solstone://observer/unknown")!))
        XCTAssertNil(SolstoneDeepLink.parse(URL(string: "solstone://random/thing")!))
    }

    @MainActor
    func testJournalDeepLinkParses() {
        XCTAssertEqual(SolstoneDeepLink.parse(URL(string: "solstone://journal")!), .journal)
        XCTAssertNil(SolstoneDeepLink.parse(URL(string: "solstone://journal/open")!))
    }

    @MainActor
    func testPairingUniversalLinkStaysWithUniversalLinkRouter() {
        let url = URL(string: "https://go.solstone.app/p#?")!

        XCTAssertNil(SolstoneDeepLink.parse(url))
        XCTAssertNotNil(UniversalLinkRouter.route(url))
    }

    @MainActor
    func testUnknownCustomURLRoutingSemantics() {
        XCTAssertNil(SolstoneDeepLink.parse(URL(string: "solstone://location/unknown")!))
    }
}
