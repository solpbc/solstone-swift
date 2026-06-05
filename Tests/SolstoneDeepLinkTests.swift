// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class SolstoneDeepLinkTests: XCTestCase {
    @MainActor
    func testObserverAndLocationDeepLinksParse() {
        XCTAssertEqual(SolstoneDeepLink.parse(URL(string: "solstone://observer/stop")!), .observerStop)
        XCTAssertEqual(SolstoneDeepLink.parse(URL(string: "solstone://location/pause")!), .locationPause)
        XCTAssertNil(SolstoneDeepLink.parse(URL(string: "solstone://observer/unknown")!))
        XCTAssertNil(SolstoneDeepLink.parse(URL(string: "solstone://random/thing")!))
    }

    @MainActor
    func testPairingUniversalLinkStaysWithUniversalLinkRouter() {
        let url = URL(string: "https://link.solpbc.org/p#?")!

        XCTAssertNil(SolstoneDeepLink.parse(url))
        XCTAssertNotNil(UniversalLinkRouter.route(url))
    }

    @MainActor
    func testLocationPauseAndUnknownCustomURLRoutingSemantics() {
        XCTAssertEqual(SolstoneDeepLink.parse(URL(string: "solstone://location/pause")!), .locationPause)
        XCTAssertNil(SolstoneDeepLink.parse(URL(string: "solstone://location/unknown")!))
    }
}
