// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

// criterion 3: manifest, correlation, fixed paths, and durable result behavior.
@MainActor
final class IntegrationGateManifestCorrelationTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try Self.resetGateDirectory()
    }

    override func tearDown() async throws {
        try Self.resetGateDirectory()
        try await super.tearDown()
    }

    func testManifestRejectsInvalidInputsBeforeNetworkWork() throws {
        try Self.assertManifest(Self.baseManifest(mutating: { $0["schemaVersion"] = 2 }), failsWith: .schemaMismatch)
        try Self.assertManifest(Self.baseManifest(mutating: { $0["action"] = "https://example.test/path" }), failsWith: .malformedRouteInput)
        try Self.assertManifest(Self.baseManifest(mutating: { $0["action"] = "../gateRange" }), failsWith: .malformedRouteInput)
        try Self.assertManifest(Self.baseManifest(mutating: { $0["action"] = "missingAction" }), failsWith: .unknownAction)
        try Self.assertManifest(Self.baseManifest(mutating: { $0["sequence"] = 0 }), failsWith: .invalidSequence)
        try Self.assertManifest(Self.baseManifest(mutating: { $0["unknownField"] = true }), failsWith: .unknownField)
        try Self.assertManifest(Self.baseManifest(mutating: { manifest in
            var pairing = manifest["expectedPairing"] as? [String: Any] ?? [:]
            pairing["fingerprintSHA256Hex"] = "bad"
            manifest["expectedPairing"] = pairing
        }), failsWith: .invalidDigest)
        try Self.assertManifest(Self.baseManifest(mutating: { manifest in
            manifest["action"] = "rangeHash"
            manifest["expectedContentLength"] = 64
            manifest["expectedSHA256Hex"] = Self.digest("b")
            manifest["rangeStart"] = 0
            manifest["rangeLength"] = 8
        }), failsWith: .invalidRange)
    }

    func testGenerationRetryRequiresContentExpectationsButNotRange() throws {
        let valid = Self.baseManifest { manifest in
            manifest["action"] = "generationRetry"
            manifest["expectedContentLength"] = 64
            manifest["expectedSHA256Hex"] = Self.digest("b")
        }
        XCTAssertNoThrow(try IntegrationGateManifest.decodeAndValidate(Self.data(valid)))

        let withRange = Self.baseManifest { manifest in
            manifest["action"] = "generationRetry"
            manifest["expectedContentLength"] = 64
            manifest["expectedSHA256Hex"] = Self.digest("b")
            manifest["rangeStart"] = 1
            manifest["rangeLength"] = 4
        }
        try Self.assertManifest(withRange, failsWith: .invalidRange)
    }

    func testReplayRejectsStaleSequenceAndRepeatedNonce() throws {
        let store = IntegrationGateFileStore()
        let prior = IntegrationGateResult.terminalError(
            sequence: 5,
            nonce: "old-nonce",
            correlationID: "old-nonce",
            reasonCode: .none,
            startedAtUnixMillis: 1,
            updatedAtUnixMillis: 2
        )
        try store.writeResult(prior)
        let data = try XCTUnwrap(store.readPriorResultData())
        let decoded = try JSONDecoder().decode(IntegrationGatePriorResult.self, from: data)
        XCTAssertEqual(decoded.sequence, 5)
        XCTAssertEqual(decoded.nonce, "old-nonce")
    }

    func testDriverReplayRejectionsKeepManifestCorrelation() async throws {
        try await Self.assertDriverReplayRejects(
            priorSequence: 5,
            priorNonce: "old-nonce",
            manifestSequence: 4,
            manifestNonce: "new-nonce",
            reason: .staleSequence
        )
        try Self.resetGateDirectory()
        try await Self.assertDriverReplayRejects(
            priorSequence: 0,
            priorNonce: "repeat-nonce",
            manifestSequence: 1,
            manifestNonce: "repeat-nonce",
            reason: .repeatedNonce
        )
    }

    func testSymlinkManifestIsRejectedBeforeDecode() throws {
        let store = IntegrationGateFileStore()
        let directory = try IntegrationGateConstants.gateDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: try store.manifestURL(), withDestinationURL: target)

        XCTAssertThrowsError(try store.readManifestData()) { error in
            XCTAssertEqual((error as? IntegrationGateValidationError)?.reasonCode, .symlinkRejected)
        }
    }

    func testManifestCannotSelectPathsOrKeychainSelectors() throws {
        let text = try Self.sourceText("Sources/IntegrationGate/IntegrationGateManifest.swift")
        XCTAssertFalse(text.contains("applicationSupportDirectory"))
        XCTAssertFalse(text.contains("keychain"))
        XCTAssertFalse(text.contains("SPLRuntime"))
    }

    private static func assertManifest(_ manifest: [String: Any], failsWith reason: IntegrationGateReasonCode) throws {
        XCTAssertThrowsError(try IntegrationGateManifest.decodeAndValidate(Self.data(manifest))) { error in
            XCTAssertEqual((error as? IntegrationGateValidationError)?.reasonCode, reason)
        }
    }

    private static func baseManifest(mutating: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
        var manifest: [String: Any] = [
            "schemaVersion": IntegrationGateConstants.schemaVersion,
            "sequence": 1,
            "nonce": "synthetic-gate-nonce",
            "action": "canary",
            "createdAtUnixMillis": 1_000,
            "expiresAtUnixMillis": 2_000,
            "expectedPairing": [
                "instanceID": "synthetic-gate-instance",
                "fingerprintSHA256Hex": Self.digest("a"),
                "pairedAtNotBeforeUnixMillis": 1,
            ],
            "expectedBuild": [
                "sourceCommit": "synthetic-source",
                "splSwiftRevision": "synthetic-spl",
            ],
        ]
        mutating(&manifest)
        return manifest
    }

    private static func data(_ manifest: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    }

    private static func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private static func sourceText(_ relativePath: String) throws -> String {
        let url = StringLiteralGrepSupport.worktreeRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func assertDriverReplayRejects(
        priorSequence: UInt64,
        priorNonce: String,
        manifestSequence: UInt64,
        manifestNonce: String,
        reason: IntegrationGateReasonCode
    ) async throws {
        let store = IntegrationGateFileStore()
        let prior = IntegrationGateResult.terminalError(
            sequence: priorSequence,
            nonce: priorNonce,
            correlationID: "\(priorSequence)-\(priorNonce)",
            reasonCode: .none,
            startedAtUnixMillis: 1,
            updatedAtUnixMillis: 2
        )
        try store.writeResult(prior)
        try Self.data(Self.baseManifest { manifest in
            manifest["sequence"] = manifestSequence
            manifest["nonce"] = manifestNonce
        }).write(to: try store.manifestURL())

        let driver = IntegrationGateDriver(dependencies: Self.dependencies(), fileStore: store) {
            Date(timeIntervalSince1970: 1)
        }
        await driver.run()

        let resultData = try XCTUnwrap(store.readPriorResultData())
        let result = try JSONDecoder().decode(IntegrationGateResult.self, from: resultData)
        XCTAssertEqual(result.sequence, manifestSequence)
        XCTAssertEqual(result.nonce, manifestNonce)
        XCTAssertEqual(result.correlationID, "\(manifestSequence)-\(manifestNonce)")
        XCTAssertEqual(result.reasonCode, reason)
        XCTAssertEqual(result.verdict, .error)
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
