// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class NetworkStatusTextTests: XCTestCase {
    func testNetworkStatusTextMapsPathStatusToOwnerSafeCopy() {
        let cases: [(NetworkPathStatus?, String)] = [
            (
                NetworkPathStatus(
                    isSatisfied: true,
                    isWiFi: true,
                    isCellular: false,
                    isExpensive: false,
                    isConstrained: false
                ),
                "wifi"
            ),
            (
                NetworkPathStatus(
                    isSatisfied: true,
                    isWiFi: false,
                    isCellular: true,
                    isExpensive: false,
                    isConstrained: false
                ),
                "cellular"
            ),
            (
                NetworkPathStatus(
                    isSatisfied: true,
                    isWiFi: false,
                    isCellular: false,
                    isExpensive: true,
                    isConstrained: true
                ),
                "other"
            ),
            (
                NetworkPathStatus(
                    isSatisfied: false,
                    isWiFi: true,
                    isCellular: false,
                    isExpensive: true,
                    isConstrained: true
                ),
                "wifi · offline"
            ),
            (
                NetworkPathStatus(
                    isSatisfied: false,
                    isWiFi: false,
                    isCellular: true,
                    isExpensive: false,
                    isConstrained: true
                ),
                "cellular · offline"
            ),
            (
                NetworkPathStatus(
                    isSatisfied: false,
                    isWiFi: false,
                    isCellular: false,
                    isExpensive: true,
                    isConstrained: true
                ),
                "offline"
            ),
            (nil, "unknown"),
        ]

        let outputs = cases.map { status, expected in
            let output = networkStatusText(status)
            XCTAssertEqual(output, expected)
            return output
        }
        let combined = outputs.joined(separator: " ")

        XCTAssertFalse(combined.contains("satisfied"))
        XCTAssertFalse(combined.contains("unsatisfied"))
        XCTAssertFalse(combined.contains("expensive"))
        XCTAssertFalse(combined.contains("constrained"))
    }
}
