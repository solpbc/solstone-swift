// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
@testable import SPLTunnel
import XCTest

nonisolated final class RaceCoordinatorTests: XCTestCase {
    func testRelayTokenExpiredSurvivesFailedRaceAggregation() async throws {
        let coordinator = RaceCoordinator<Int>(
            stagger: .milliseconds(1),
            loserGrace: .milliseconds(1),
            budget: .milliseconds(50)
        ) { endpoint in
            if case .relay = endpoint {
                throw DialError.relayTokenExpired
            }
            throw SessionError.unreachable
        }

        do {
            _ = try await coordinator.connect(endpoints: [
                .lan(host: "127.0.0.1", port: 1234, scope: ""),
                .relay(endpoint: URL(string: "wss://relay.example.com")!, instanceID: "instance", deviceToken: "token")
            ])
            XCTFail("expected tokenExpired")
        } catch let error as SessionError {
            XCTAssertEqual(error, .tokenExpired)
        }
    }
}
