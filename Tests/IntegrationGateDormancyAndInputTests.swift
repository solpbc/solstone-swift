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

    func testRelayOnlyPolicyLifetimeWrapsStableDriverLoop() throws {
        let sourceURL = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("Sources/IntegrationGate/IntegrationGateDriver.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let runStart = try XCTUnwrap(source.range(of: "func run() async {"))
        let runOnceStart = try XCTUnwrap(source.range(of: "func runOnce() async {"))
        let manifestRunStart = try XCTUnwrap(
            source.range(of: "private func run(manifest:")
        )
        let validateReplayStart = try XCTUnwrap(
            source.range(of: "private func validateReplay(")
        )

        let stableLoop = source[runStart.lowerBound..<runOnceStart.lowerBound]
        XCTAssertTrue(stableLoop.contains("installIntegrationGateRelayOnlyCandidatePolicy()"))
        XCTAssertTrue(stableLoop.contains("clearIntegrationGateRelayOnlyCandidatePolicy()"))
        XCTAssertTrue(stableLoop.contains("while !Task.isCancelled"))

        let perManifest = source[
            manifestRunStart.lowerBound..<validateReplayStart.lowerBound
        ]
        XCTAssertFalse(perManifest.contains("installIntegrationGateRelayOnlyCandidatePolicy()"))
        XCTAssertFalse(perManifest.contains("clearIntegrationGateRelayOnlyCandidatePolicy()"))
    }

    func testResultEncodingKeepsClosedSchemaKeysWhenOptionalsAreNil() throws {
        let result = IntegrationGateResult.terminalError(
            sequence: nil,
            nonce: nil,
            correlationID: "unavailable",
            reasonCode: .manifestMissing,
            startedAtUnixMillis: 1_000,
            updatedAtUnixMillis: 1_001
        )

        let encoded = try JSONEncoder().encode(result)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(
            Set(object.keys),
            [
                "schemaVersion",
                "sequence",
                "nonce",
                "correlationID",
                "recordState",
                "verdict",
                "reasonCode",
                "startedAtUnixMillis",
                "updatedAtUnixMillis",
                "finishedAtUnixMillis",
                "durationMillis",
                "buildMetadata",
                "pairingSnapshot",
                "routeLabel",
                "generation",
                "httpOutcome",
                "accounting",
                "samples",
                "transportStages",
                "reconnectReasonBuckets",
            ]
        )
        XCTAssertTrue(object["sequence"] is NSNull)
        XCTAssertTrue(object["nonce"] is NSNull)
        XCTAssertTrue(object["pairingSnapshot"] is NSNull)
        XCTAssertTrue(object["routeLabel"] is NSNull)
        XCTAssertTrue(object["generation"] is NSNull)
        XCTAssertTrue(object["httpOutcome"] is NSNull)
    }

    func testNestedResultEncodingKeepsClosedSchemaKeysWhenOptionalsAreNil() throws {
        let generation = try Self.encodedObject(
            IntegrationGateResultGeneration(
                currentGeneration: 1,
                activeGeneration: nil,
                lastClosedGeneration: nil
            )
        )
        XCTAssertEqual(
            Set(generation.keys),
            ["currentGeneration", "activeGeneration", "lastClosedGeneration"]
        )
        XCTAssertTrue(generation["activeGeneration"] is NSNull)
        XCTAssertTrue(generation["lastClosedGeneration"] is NSNull)

        let outcome = try Self.encodedObject(
            IntegrationGateHTTPOutcome(
                statusCode: 200,
                errorBucket: nil,
                byteCount: 0,
                durationMillis: 1
            )
        )
        XCTAssertEqual(
            Set(outcome.keys),
            ["statusCode", "errorBucket", "byteCount", "durationMillis"]
        )
        XCTAssertTrue(outcome["errorBucket"] is NSNull)

        let sample = try Self.encodedObject(
            IntegrationGateSample(
                sampleIndex: 0,
                wallClockUnixMillis: 1,
                monotonicMillis: 1,
                managerConnectionEpoch: 1,
                transportGeneration: nil,
                endpointKind: "none",
                rawConnectionSyncStatus: "offline",
                publishedConnectionSyncStatus: "offline",
                httpStatusCode: nil,
                httpErrorBucket: nil,
                requestDurationMillis: nil,
                reconnectCount: 0,
                activeGateIssuedRequestCount: 0,
                activeProductionUploadCount: 0,
                transportStage: nil,
                reconnectReasonBucket: nil,
                canaryGeneration: nil,
                canaryStatusCode: nil,
                canarySkewMillis: nil
            )
        )
        XCTAssertEqual(
            Set(sample.keys),
            [
                "sampleIndex",
                "wallClockUnixMillis",
                "monotonicMillis",
                "managerConnectionEpoch",
                "transportGeneration",
                "endpointKind",
                "rawConnectionSyncStatus",
                "publishedConnectionSyncStatus",
                "httpStatusCode",
                "httpErrorBucket",
                "requestDurationMillis",
                "reconnectCount",
                "activeGateIssuedRequestCount",
                "activeProductionUploadCount",
                "transportStage",
                "reconnectReasonBucket",
                "canaryGeneration",
                "canaryStatusCode",
                "canarySkewMillis",
            ]
        )
        for key in [
            "transportGeneration",
            "httpStatusCode",
            "httpErrorBucket",
            "requestDurationMillis",
            "transportStage",
            "reconnectReasonBucket",
            "canaryGeneration",
            "canaryStatusCode",
            "canarySkewMillis",
        ] {
            XCTAssertTrue(sample[key] is NSNull, "\(key) should encode as null")
        }
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

    private static func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let encoded = try JSONEncoder().encode(value)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
    }

    private static func resetGateDirectory() throws {
        let directory = try IntegrationGateConstants.gateDirectoryURL()
        try? FileManager.default.removeItem(at: directory)
    }
}
