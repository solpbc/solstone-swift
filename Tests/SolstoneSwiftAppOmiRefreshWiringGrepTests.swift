// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class SolstoneSwiftAppOmiRefreshWiringGrepTests: XCTestCase {
    func testOmiRefreshUsesBothTunnelObservationSitesAndOnlyOmiClosure() throws {
        let appURL = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("Sources/SolstoneSwiftApp.swift")
        let text = try String(contentsOf: appURL, encoding: .utf8)

        let initialBody = try Self.slice(
            in: text,
            from: "// Initial connected state needs the same Omi registration edge observation.",
            to: ".onChange(of: self.scenePhase)"
        )
        XCTAssertTrue(initialBody.contains("self.omiRegistrationRefreshCoordinator.observe(tunnelState: self.tunnelManager.state)"))

        let tunnelChangeBody = try Self.slice(
            in: text,
            from: ".onChange(of: self.tunnelManager.state)",
            to: ".onChange(of: self.observerManager.state)"
        )
        XCTAssertTrue(tunnelChangeBody.contains("self.omiRegistrationRefreshCoordinator.observe(tunnelState: newState)"))

        let closure = try Self.slice(
            in: text,
            from: "let omiRegistrationRefreshCoordinator = OmiRegistrationRefreshCoordinator",
            to: "let transferEndpointResolver"
        )
        XCTAssertTrue(closure.contains("guard !Self.isIntegrationMode, !Self.isUITest else { return }"))
        XCTAssertTrue(closure.contains("omiRegistration.activeLocalPort = port"))
        XCTAssertTrue(closure.contains("omiRegistration.refreshRegistration()"))
        XCTAssertFalse(closure.contains("observerRegistration.refreshRegistration()"))
        XCTAssertFalse(closure.contains("watchRegistration.refreshRegistration()"))

        let revalidationBody = try Self.slice(
            in: text,
            from: "// cold-launch-into-connected:",
            to: "// Initial connected state needs the same Omi registration edge observation."
        )
        XCTAssertFalse(revalidationBody.contains("refreshRegistration"))
        XCTAssertFalse(revalidationBody.contains("omiRegistrationRefreshCoordinator"))
    }

    private static func slice(in text: String, from startToken: String, to endToken: String) throws -> Substring {
        let start = try XCTUnwrap(text.range(of: startToken))
        let remaining = text[start.lowerBound...]
        let end = try XCTUnwrap(remaining.range(of: endToken))
        return text[start.lowerBound..<end.lowerBound]
    }
}
