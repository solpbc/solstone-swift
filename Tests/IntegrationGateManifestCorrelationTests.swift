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
            manifest["rangeLength"] = 0
        }), failsWith: .invalidRange)
        try Self.assertManifest(Self.baseManifest(mutating: { manifest in
            manifest["action"] = "rangeHash"
            manifest["expectedContentLength"] = 64
            manifest["expectedSHA256Hex"] = Self.digest("b")
            manifest["rangeStart"] = 0
        }), failsWith: .invalidRange)
        try Self.assertManifest(Self.baseManifest(mutating: { manifest in
            manifest["action"] = "rangeHash"
            manifest["expectedContentLength"] = 64
            manifest["expectedSHA256Hex"] = Self.digest("b")
            manifest["rangeStart"] = -1
            manifest["rangeLength"] = 8
        }), failsWith: .missingField)
        try Self.assertManifest(Self.baseManifest(mutating: { manifest in
            manifest["action"] = "rangeHash"
            manifest["expectedContentLength"] = 64
            manifest["expectedSHA256Hex"] = Self.digest("b")
            manifest["rangeStart"] = UInt64.max
            manifest["rangeLength"] = UInt64(1)
        }), failsWith: .invalidRange)
    }

    func testRangeHashManifestAllowsZeroStartMuxCrossingRange() throws {
        let rangeLength = UInt64(2 * 1024 * 1024 + 17)
        let decoded = try IntegrationGateManifest.decodeAndValidate(
            Self.data(Self.baseManifest { manifest in
                manifest["action"] = "rangeHash"
                manifest["expectedContentLength"] = rangeLength
                manifest["expectedSHA256Hex"] = Self.digest("b")
                manifest["rangeStart"] = UInt64(0)
                manifest["rangeLength"] = rangeLength
            })
        )

        XCTAssertEqual(decoded.action, .rangeHash)
        XCTAssertEqual(decoded.rangeStart, 0)
        XCTAssertEqual(decoded.rangeLength, rangeLength)
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

    // G2 and G3 both read the fixed journal transcripts serve_file route, so the
    // coordinator provisions one deterministic body at the decomposed chronicle path.
    func testMediaActionsResolveToTheFixedTranscriptsServeFileRoute() throws {
        let rangePath = IntegrationGateAction.rangeHash.routeLabel.path
        let retryPath = IntegrationGateAction.generationRetry.routeLabel.path
        let serveFilePrefix = "/app/transcripts/api/serve_file/"
        let expectedRelativePath = "integration-gate/122500_300/ios-spl-gate-260729.m4a"

        XCTAssertEqual(IntegrationGateAction.rangeHash.routeLabel, .gateRange)
        XCTAssertEqual(IntegrationGateAction.generationRetry.routeLabel, .gateRetry)
        XCTAssertEqual(rangePath, IntegrationGateConstants.transcriptsServeFilePath)
        XCTAssertEqual(retryPath, IntegrationGateConstants.transcriptsServeFilePath)
        XCTAssertEqual(rangePath, retryPath)
        for path in [rangePath, retryPath] {
            XCTAssertTrue(path.hasPrefix("/"))
            XCTAssertTrue(path.contains("20260729"))
            XCTAssertTrue(path.contains("ios-spl-gate-260729.m4a"))
            XCTAssertFalse(path.contains("://"))
            XCTAssertFalse(path.contains("?"))
            XCTAssertFalse(path.contains(".."))
            XCTAssertTrue(path.hasPrefix(serveFilePrefix))
        }

        guard rangePath.hasPrefix(serveFilePrefix) else {
            XCTFail("media route does not use transcripts serve_file prefix")
            return
        }
        let remainder = String(rangePath.dropFirst(serveFilePrefix.count))
        let daySeparator = try XCTUnwrap(remainder.firstIndex(of: "/"))
        let day = String(remainder[..<daySeparator])
        let relativePath = String(remainder[remainder.index(after: daySeparator)...])
        XCTAssertEqual(day, "20260729")
        XCTAssertEqual(relativePath, expectedRelativePath)
    }

    // retained evidence names route labels, never raw routes, so the label set stays allowlisted
    // and every label resolves to a fixed relative path.
    func testRouteLabelAllowlistResolvesToFixedRelativePaths() {
        XCTAssertEqual(
            Set(IntegrationGateRouteLabel.allCases.map(\.rawValue)),
            ["networkStatus", "homePulse", "gateRange", "gateRetry"]
        )
        for label in IntegrationGateRouteLabel.allCases {
            XCTAssertTrue(label.path.hasPrefix("/"), label.rawValue)
            XCTAssertFalse(label.path.contains("://"), label.rawValue)
            XCTAssertFalse(label.path.contains("?"), label.rawValue)
            XCTAssertFalse(label.path.contains(".."), label.rawValue)
        }
    }

    // the schema carries no path, url, host, or port field, so a coordinator can choose which
    // action runs but never which route it reaches.
    func testManifestCannotInfluenceTheRouteItReaches() throws {
        for injected in ["path", "url", "host", "port", "route", "routeLabel"] {
            try Self.assertManifest(
                Self.baseManifest { $0[injected] = IntegrationGateConstants.homePulsePath },
                failsWith: .unknownField
            )
        }
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
        await driver.runOnce()

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
