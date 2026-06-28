// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
@testable import SPLTunnel
import XCTest

nonisolated final class RaceCoordinatorTests: XCTestCase {
    func testGraceExpiredClosesCollectedAndPendingLosersExactlyOnce() async throws {
        let closeLog = CloseLog()
        let relay = URL(string: "wss://relay.example.com")!
        let coordinator = RaceCoordinator<SpyConnection>(
            stagger: .milliseconds(1),
            loserGrace: .milliseconds(30),
            budget: .seconds(1),
            close: { connection in
                await closeLog.close(connection.id)
            }
        ) { endpoint in
            switch endpoint {
            case .lan(let host, _, _):
                if host == "fd00::1" {
                    return SpyConnection(id: 0)
                }
                try await Task.sleep(for: .milliseconds(5))
                return SpyConnection(id: 1)
            case .relay:
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    // Return success after cancellation so the drain must close this pending loser.
                }
                return SpyConnection(id: 2)
            }
        }

        let result = try await coordinator.connect(endpoints: [
            .lan(host: "fd00::1", port: 1234, scope: ""),
            .lan(host: "10.0.0.2", port: 1234, scope: ""),
            .relay(endpoint: relay, instanceID: "instance", deviceToken: "token"),
        ])

        XCTAssertEqual(result.value.id, 0)
        let closeCounts = await closeLog.counts()
        XCTAssertNil(closeCounts[0])
        XCTAssertEqual(closeCounts[1], 1)
        XCTAssertEqual(closeCounts[2], 1)
    }

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

private struct SpyConnection: Sendable {
    let id: Int
}

private actor CloseLog {
    private var closeCounts: [Int: Int] = [:]

    func close(_ id: Int) {
        closeCounts[id, default: 0] += 1
    }

    func counts() -> [Int: Int] {
        closeCounts
    }
}
