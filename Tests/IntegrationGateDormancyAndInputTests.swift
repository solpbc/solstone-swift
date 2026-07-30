// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
import XCTest

// criterion 1: dormant gate and sanitized input errors.
@MainActor
final class IntegrationGateDormancyAndInputTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try Self.resetGateDirectory()
    }

    override func tearDown() async throws {
        try Self.resetGateDirectory()
        try await super.tearDown()
    }

    func testLaunchArgumentIsDormantUnlessExplicitlyPresent() {
        XCTAssertFalse(IntegrationGateDriver.shouldRun(arguments: ["app"]))
        XCTAssertTrue(IntegrationGateDriver.shouldRun(arguments: ["app", IntegrationGateConstants.launchArgument]))
    }

    func testManifestPollingProcessesOnlyNewSequences() {
        XCTAssertTrue(IntegrationGateDriver.shouldProcess(sequence: 1, after: nil))
        XCTAssertFalse(IntegrationGateDriver.shouldProcess(sequence: 1, after: 1))
        XCTAssertTrue(IntegrationGateDriver.shouldProcess(sequence: 2, after: 1))
    }

    func testMalformedManifestWritesOneSanitizedCorrelatedError() async throws {
        let store = IntegrationGateFileStore()
        let directory = try IntegrationGateConstants.gateDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: try store.manifestURL())

        let driver = IntegrationGateDriver(dependencies: Self.dependencies(), fileStore: store) {
            Date(timeIntervalSince1970: 1_000)
        }
        await driver.runOnce()

        let data = try XCTUnwrap(store.readPriorResultData())
        let result = try JSONDecoder().decode(IntegrationGateResult.self, from: data)
        XCTAssertEqual(result.recordState, .terminal)
        XCTAssertEqual(result.verdict, .error)
        XCTAssertEqual(result.reasonCode, .manifestMalformed)
        XCTAssertEqual(result.correlationID, "unavailable")
        XCTAssertNil(result.pairingSnapshot)
    }

    private static func dependencies() -> IntegrationGateDependencies {
        let transport = CFTunnelTransport(loadPairing: { nil })
        let tunnel = TunnelManager(
            transport: transport,
            loadPairing: { nil },
            savePairing: { _ in },
            deletePairing: {}
        )
        let sync = ConnectionSyncModel(clock: SystemObserverClock()) {
            ConnectionSyncInputs(
                tunnelState: tunnel.state,
                reconnectCountdown: tunnel.reconnectCountdown,
                isNetworkSatisfied: tunnel.isNetworkSatisfied,
                confirmedTransferCount: 0,
                recentBytesPerSecond: 0,
                backlogPending: 0,
                backlogFailed: 0
            )
        }
        return IntegrationGateDependencies(
            keychainStore: SPLRuntime.keychainStore,
            tunnelManager: tunnel,
            transport: transport,
            connectionSyncModel: sync
        )
    }

    private static func resetGateDirectory() throws {
        let directory = try IntegrationGateConstants.gateDirectoryURL()
        try? FileManager.default.removeItem(at: directory)
    }
}
