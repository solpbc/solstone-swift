// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class SolstoneSwiftAppBootstrapTransferTests: XCTestCase {
    @MainActor
    func testOrdersInitializeMigrateReconcileThenEnable() async {
        var events: [String] = []
        var failureCount = 0

        await SolstoneSwiftApp.bootstrapTransfer(
            initialize: {
                events.append("initialize")
            },
            appGroupRoot: {
                URL(fileURLWithPath: "/tmp/bootstrap-transfer-root")
            },
            cachesRootURL: URL(fileURLWithPath: "/tmp/bootstrap-transfer-caches"),
            migrate: { _, _ in
                events.append("migrate")
            },
            reconcile: { _ in
                events.append("reconcile")
            },
            enableDispatch: {
                events.append("enable")
            },
            openOmiReadiness: {
                events.append("omi-readiness")
            },
            reportFailure: { _, _ in
                failureCount += 1
            }
        )

        XCTAssertEqual(events, ["initialize", "migrate", "reconcile", "enable", "omi-readiness"])
        XCTAssertEqual(failureCount, 0)
        XCTAssertEqual(events.filter { $0 == "enable" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "omi-readiness" }.count, 1)
    }

    @MainActor
    func testDoesNotEnableDispatchAfterInitializeFailure() async {
        var events: [String] = []
        var failureCount = 0

        await SolstoneSwiftApp.bootstrapTransfer(
            initialize: {
                events.append("initialize")
                throw BootstrapTransferTestError.expected
            },
            appGroupRoot: {
                XCTFail("app-group root should not be requested after initialization failure")
                return URL(fileURLWithPath: "/tmp/bootstrap-transfer-root")
            },
            cachesRootURL: nil,
            migrate: { _, _ in
                XCTFail("migration should not run after initialization failure")
            },
            reconcile: { _ in
                XCTFail("reconciliation should not run after initialization failure")
            },
            conservativelyGateOmi: {
                events.append("gate")
            },
            enableDispatch: {
                events.append("enable")
            },
            openOmiReadiness: {
                events.append("omi-readiness")
            },
            reportFailure: { _, _ in
                failureCount += 1
            }
        )

        XCTAssertEqual(events, ["initialize", "omi-readiness"])
        XCTAssertEqual(failureCount, 1)
        XCTAssertEqual(events.filter { $0 == "enable" }.count, 0)
        XCTAssertEqual(events.filter { $0 == "omi-readiness" }.count, 1)
    }

    @MainActor
    func testEnablesDispatchWhenAppGroupUnavailable() async {
        var events: [String] = []
        var failureCount = 0

        await SolstoneSwiftApp.bootstrapTransfer(
            initialize: {
                events.append("initialize")
            },
            appGroupRoot: {
                throw BootstrapTransferTestError.expected
            },
            cachesRootURL: nil,
            migrate: { _, _ in
                XCTFail("migration should not run without an app-group root")
            },
            reconcile: { _ in
                XCTFail("reconciliation should not run without an app-group root")
            },
            conservativelyGateOmi: {
                events.append("gate")
            },
            enableDispatch: {
                events.append("enable")
            },
            openOmiReadiness: {
                events.append("omi-readiness")
            },
            reportFailure: { _, _ in
                failureCount += 1
            }
        )

        XCTAssertEqual(events, ["initialize", "gate", "enable", "omi-readiness"])
        XCTAssertEqual(failureCount, 1)
        XCTAssertEqual(events.filter { $0 == "enable" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "omi-readiness" }.count, 1)
    }

    @MainActor
    func testEnablesDispatchAfterMigrationOrReconciliationFailure() async {
        for failurePoint in [BootstrapFailurePoint.migration, .reconciliation] {
            var events: [String] = []
            var failureCount = 0

            await SolstoneSwiftApp.bootstrapTransfer(
                initialize: {
                    events.append("initialize")
                },
                appGroupRoot: {
                    URL(fileURLWithPath: "/tmp/bootstrap-transfer-root")
                },
                cachesRootURL: nil,
                migrate: { _, _ in
                    events.append("migrate")
                    if failurePoint == .migration {
                        throw BootstrapTransferTestError.expected
                    }
                },
                reconcile: { _ in
                    events.append("reconcile")
                    if failurePoint == .reconciliation {
                        throw BootstrapTransferTestError.expected
                    }
                },
                conservativelyGateOmi: {
                    events.append("gate")
                },
                enableDispatch: {
                    events.append("enable")
                },
                openOmiReadiness: {
                    events.append("omi-readiness")
                },
                reportFailure: { _, _ in
                    failureCount += 1
                }
            )

            let expectedEvents = failurePoint == .migration
                ? ["initialize", "migrate", "gate", "enable", "omi-readiness"]
                : ["initialize", "migrate", "reconcile", "gate", "enable", "omi-readiness"]
            XCTAssertEqual(events, expectedEvents, "failure point: \(failurePoint)")
            XCTAssertEqual(failureCount, 1, "failure point: \(failurePoint)")
            XCTAssertEqual(events.filter { $0 == "enable" }.count, 1, "failure point: \(failurePoint)")
            XCTAssertEqual(events.filter { $0 == "omi-readiness" }.count, 1, "failure point: \(failurePoint)")
        }
    }

    @MainActor
    func testSuccessfulInitializationStillDispatchesQueuedItemAfterBootstrapFailures() async {
        for failurePoint in [BootstrapFailurePoint.appGroup, .migration, .reconciliation] {
            var events: [String] = []
            await SolstoneSwiftApp.bootstrapTransfer(
                initialize: { events.append("initialize") },
                appGroupRoot: {
                    if failurePoint == .appGroup { throw BootstrapTransferTestError.expected }
                    return URL(fileURLWithPath: "/tmp/bootstrap-transfer-root")
                },
                cachesRootURL: nil,
                migrate: { _, _ in
                    if failurePoint == .migration { throw BootstrapTransferTestError.expected }
                },
                reconcile: { _ in
                    if failurePoint == .reconciliation { throw BootstrapTransferTestError.expected }
                },
                conservativelyGateOmi: { events.append("gate") },
                enableDispatch: { events.append("queued-item-sent") },
                openOmiReadiness: { events.append("omi-readiness") },
                reportFailure: { _, _ in events.append("failure") }
            )
            guard let gateIndex = events.firstIndex(of: "gate"),
                  let dispatchIndex = events.firstIndex(of: "queued-item-sent")
            else {
                return XCTFail("failure path did not gate before dispatch")
            }
            XCTAssertLessThan(gateIndex, dispatchIndex, "failure point: \(failurePoint)")
            XCTAssertTrue(events.contains("queued-item-sent"), "failure point: \(failurePoint)")
            XCTAssertTrue(events.contains("omi-readiness"), "failure point: \(failurePoint)")
        }
    }
}

private enum BootstrapFailurePoint: Sendable {
    case appGroup
    case migration
    case reconciliation
}

private enum BootstrapTransferTestError: Error {
    case expected
}
