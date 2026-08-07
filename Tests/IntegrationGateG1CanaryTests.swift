// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
@testable import SPLTunnel
import Foundation
import XCTest

// criterion 5: G1 canary action classification.
@MainActor
final class IntegrationGateG1CanaryTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try Self.resetGateDirectory()
        IntegrationGateRangeHeaderURLProtocol.reset()
    }

    override func tearDown() async throws {
        IntegrationGateRangeHeaderURLProtocol.reset()
        try Self.resetGateDirectory()
        try await super.tearDown()
    }

    func testRemoteConnectedCanaryPassesWithPositiveCoBoundSampleAndBalancedAccounting() {
        let facts = Self.facts()
        let classified = IntegrationGateActionClassifiers.classifyG1(facts)

        XCTAssertEqual(classified.0, .pass)
        XCTAssertEqual(classified.1, .none)
    }

    func testCanaryActionUsesRealHomePulseRoute() {
        XCTAssertEqual(IntegrationGateAction.canary.routeLabel, .homePulse)
        XCTAssertEqual(IntegrationGateAction.canary.routeLabel.path, IntegrationGateConstants.homePulsePath)
    }

    func testLanEndpointFailsClosed() {
        let classified = IntegrationGateActionClassifiers.classifyG1(Self.facts(endpointKind: "lan"))

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .selectedLanEndpoint)
    }

    func testNonTwoHundredCanaryFailsClosed() {
        let classified = IntegrationGateActionClassifiers.classifyG1(Self.facts(httpStatusCode: 503))

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .canaryFailed)
    }

    func testMissingGenerationFailsClosed() {
        let classified = IntegrationGateActionClassifiers.classifyG1(Self.facts(activeGeneration: nil))

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .noActiveGeneration)
    }

    func testUnbalancedGateIssuedRequestCountFailsClosed() {
        let classified = IntegrationGateActionClassifiers.classifyG1(
            Self.facts(
                accounting: IntegrationGateAccounting(
                    activeGateIssuedRequestBaseline: 0,
                    activeGateIssuedRequestFinal: 1,
                    activeGateIssuedRequestReturnedToBaseline: false
                )
            )
        )

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .accountingLeak)
    }

    func testMissingPositiveOwnerTransitionFailsClosed() {
        let classified = IntegrationGateActionClassifiers.classifyG1(
            Self.facts(sample: Self.observation(rawStatus: "reconnecting", publishedStatus: "reconnecting"))
        )

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .missingPositiveTransition)
    }

    func testNonPublishedPositiveCoBoundFailureKeepsOriginalReason() {
        let classified = IntegrationGateActionClassifiers.classifyG1(
            Self.facts(sample: Self.observation(
                rawStatus: "connectedIdle",
                publishedStatus: "offline",
                coBoundFailure: .canaryFailed
            ))
        )

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .canaryFailed)
    }

    func testPublishedPositiveCoBoundCanaryFailureUsesPublishedHealthyReason() {
        let classified = IntegrationGateActionClassifiers.classifyG1(
            Self.facts(sample: Self.observation(
                rawStatus: "connectedIdle",
                publishedStatus: "connectedIdle",
                coBoundFailure: .canaryFailed
            ))
        )

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .publishedHealthyCanaryFailed)
    }

    func testCanaryActionWindowPassesOnThirdPositiveSampleAndExportsAllSamples() async throws {
        Self.installTwoHundredCanaryHandler()
        let harness = Self.actionHarness(initialInputs: Self.inputs(status: .offline))
        defer { harness.httpClient.shutdown() }

        let task = Task {
            await harness.actions.run(manifest: Self.manifest())
        }
        await Self.drainUntil { harness.clock.pendingSleeperCount == 1 }
        harness.clock.advance(by: 1)
        await Self.drainUntil { harness.clock.pendingSleeperCount == 1 }
        harness.inputs.current = Self.inputs(status: .connectedIdle)
        // Converge the owner-visible label at the same moment the transport comes up.
        // G1 now waits for the PUBLISHED status, because sampling the instant raw goes
        // positive reads the 2.5s publish debounce every time and reports it as
        // `false_healthy` -- an app under-claiming its own health.
        harness.sync.refreshNow()
        harness.clock.advance(by: 1)
        await Self.drainUntil { harness.clock.pendingSleeperCount == 1 }
        harness.clock.advance(by: 2)

        let result = await task.value

        XCTAssertEqual(result.verdict, .pass)
        XCTAssertEqual(result.reasonCode, .none)
        XCTAssertEqual(result.samples.map(\.sampleIndex), [0, 1, 2])
        XCTAssertEqual(result.samples.map(\.rawConnectionSyncStatus), ["offline", "offline", "connectedIdle"])
        XCTAssertEqual(result.samples.last?.canaryStatusCode, 200)
    }

    func testCanaryActionKeepsSamplingUntilTheOwnerLabelCatchesUp() async throws {
        // The behaviour the window exists for, and the one nothing else here pins.
        // Raw goes positive while the published label is still catching up -- the
        // designed 2.5s debounce. Breaking there hands the verifier a sample it is
        // guaranteed to reject and G1 reports `false_healthy` about an app that was
        // under-claiming its own health. Run 20260731T2135Z did exactly this: one
        // sample, raw=connectedIdle, pub=waitingForHome, published never positive.
        Self.installTwoHundredCanaryHandler()
        let harness = Self.actionHarness(initialInputs: Self.inputs(status: .offline))
        defer { harness.httpClient.shutdown() }

        let task = Task {
            await harness.actions.run(manifest: Self.manifest())
        }
        await Self.drainUntil { harness.clock.pendingSleeperCount == 1 }
        harness.clock.advance(by: 1)
        await Self.drainUntil { harness.clock.pendingSleeperCount == 1 }

        // Transport up, label NOT yet converged.
        harness.inputs.current = Self.inputs(status: .connectedIdle)
        harness.clock.advance(by: 1)
        // Reaching another sleeper is the assertion: the window did not stop on a
        // raw-positive sample whose label was still behind.
        await Self.drainUntil { harness.clock.pendingSleeperCount == 1 }

        harness.sync.refreshNow()
        harness.clock.advance(by: 1)
        await Self.drainUntil { harness.clock.pendingSleeperCount == 1 }
        harness.clock.advance(by: 2)

        let result = await task.value

        XCTAssertEqual(result.verdict, .pass)
        XCTAssertEqual(result.reasonCode, .none)
        XCTAssertEqual(result.samples.map(\.sampleIndex), [0, 1, 2, 3])
        XCTAssertEqual(
            result.samples.map(\.rawConnectionSyncStatus),
            ["offline", "offline", "connectedIdle", "connectedIdle"]
        )
        // The selected sample is the converged one, which is what the verifier reads.
        XCTAssertEqual(result.samples.last?.publishedConnectionSyncStatus, "connectedIdle")
        XCTAssertEqual(result.samples[2].publishedConnectionSyncStatus, "offline")
    }

    func testCanaryActionSamplesPersistThroughResultJSONBoundary() throws {
        let samples = [
            Self.sample(index: 0, rawStatus: "offline"),
            Self.sample(index: 1, rawStatus: "offline"),
            Self.sample(index: 2, rawStatus: "connectedIdle"),
        ]
        let result = IntegrationGateResult(
            schemaVersion: IntegrationGateConstants.schemaVersion,
            sequence: 1,
            nonce: "synthetic-g1-nonce",
            correlationID: "1-synthetic-g1-nonce",
            recordState: .terminal,
            verdict: .pass,
            reasonCode: .none,
            startedAtUnixMillis: 1,
            updatedAtUnixMillis: 2,
            finishedAtUnixMillis: 2,
            durationMillis: 1,
            buildMetadata: .current,
            pairingSnapshot: nil,
            routeLabel: .homePulse,
            generation: IntegrationGateResultGeneration(
                currentGeneration: 7,
                activeGeneration: 7,
                lastClosedGeneration: nil
            ),
            httpOutcome: nil,
            accounting: .zero,
            samples: samples,
            transportStages: [],
            reconnectReasonBuckets: []
        )
        let store = IntegrationGateFileStore()

        try store.writeResult(result)
        let data = try XCTUnwrap(store.readPriorResultData())
        let decoded = try JSONDecoder().decode(IntegrationGateResult.self, from: data)
        let driverText = try Self.sourceText("Sources/IntegrationGate/IntegrationGateDriver.swift")

        XCTAssertTrue(driverText.contains("samples: actionResult.samples"))
        XCTAssertEqual(decoded.samples.map(\.sampleIndex), [0, 1, 2])
        XCTAssertEqual(decoded.samples.map(\.rawConnectionSyncStatus), ["offline", "offline", "connectedIdle"])
    }

    func testCanaryActionChecksElapsedWindowBeforeIssuingNextSample() async throws {
        Self.installTwoHundredCanaryHandler()
        let harness = Self.actionHarness(initialInputs: Self.inputs(status: .offline))
        defer { harness.httpClient.shutdown() }

        let task = Task {
            await harness.actions.run(manifest: Self.manifest())
        }
        await Self.drainUntil { harness.clock.pendingSleeperCount == 1 }
        harness.clock.advance(by: 11)

        let result = await task.value

        XCTAssertEqual(result.verdict, .fail)
        XCTAssertEqual(result.reasonCode, .missingPositiveTransition)
        XCTAssertEqual(result.samples.map(\.sampleIndex), [0])
    }

    private static func facts(
        endpointKind: String = "remote",
        managerConnectionEpoch: UInt64 = 1,
        activeGeneration: UInt64? = 7,
        httpStatusCode: Int? = 200,
        accounting: IntegrationGateAccounting = .zero,
        sample: IntegrationGateSampleObservation? = nil
    ) -> IntegrationGateG1Facts {
        IntegrationGateG1Facts(
            endpointKind: endpointKind,
            managerConnectionEpoch: managerConnectionEpoch,
            activeGeneration: activeGeneration,
            httpStatusCode: httpStatusCode,
            accounting: accounting,
            sample: sample ?? Self.observation()
        )
    }

    private static func observation(
        rawStatus: String = "connectedIdle",
        publishedStatus: String = "connectedIdle",
        coBoundFailure: IntegrationGateReasonCode? = nil
    ) -> IntegrationGateSampleObservation {
        IntegrationGateSampleObservation(
            sample: IntegrationGateSample(
                sampleIndex: 0,
                wallClockUnixMillis: 1,
                monotonicMillis: 1,
                managerConnectionEpoch: 1,
                transportGeneration: 7,
                endpointKind: "remote",
                rawConnectionSyncStatus: rawStatus,
                publishedConnectionSyncStatus: publishedStatus,
                httpStatusCode: 200,
                httpErrorBucket: nil,
                requestDurationMillis: 1,
                reconnectCount: 0,
                activeGateIssuedRequestCount: 0,
                activeProductionUploadCount: 0,
                transportStage: "loopbackReady",
                reconnectReasonBucket: nil,
                canaryGeneration: 7,
                canaryStatusCode: 200,
                canarySkewMillis: 1
            ),
            coBoundFailure: coBoundFailure
        )
    }

    private static func sample(index: UInt64, rawStatus: String) -> IntegrationGateSample {
        var sample = Self.observation(rawStatus: rawStatus, publishedStatus: rawStatus).sample
        sample.sampleIndex = index
        return sample
    }

    private static func manifest() -> IntegrationGateManifest {
        IntegrationGateManifest(
            schemaVersion: IntegrationGateConstants.schemaVersion,
            sequence: 1,
            nonce: "synthetic-g1-nonce",
            action: .canary,
            createdAtUnixMillis: 1,
            expiresAtUnixMillis: 2_000,
            expectedPairing: .init(
                instanceID: "synthetic-instance",
                fingerprintSHA256Hex: Self.digest("b"),
                pairedAtNotBeforeUnixMillis: 1
            ),
            expectedBuild: .init(sourceCommit: "synthetic-source", splSwiftRevision: "synthetic-spl"),
            expectedContentLength: nil,
            expectedSHA256Hex: nil,
            rangeStart: nil,
            rangeLength: nil
        )
    }

    private static func actionHarness(initialInputs: ConnectionSyncInputs) -> G1ActionHarness {
        let clock = MockObserverClock()
        let transport = MockCFTunnelTransport()
        transport.generationSnapshot = TransportGenerationSnapshot(
            currentGeneration: 7,
            activeGeneration: 7,
            lastClosedGeneration: nil
        )
        let manager = TunnelManager(transport: transport)
        manager.forceConnected(port: 5151, via: .remote)
        let inputs = G1InputBox(initialInputs)
        let configuration = IntegrationGateHTTPClient.productionSessionConfiguration()
        configuration.protocolClasses = [IntegrationGateRangeHeaderURLProtocol.self]
        let httpClient = IntegrationGateHTTPClient(
            tunnelManager: manager,
            sessionConfiguration: configuration,
            now: { clock.now() }
        )
        let sync = ConnectionSyncModel(clock: clock) {
            inputs.current
        }
        let sampler = IntegrationGateSampler(
            tunnelManager: manager,
            connectionSyncModel: sync,
            httpClient: httpClient,
            clock: clock
        )
        let actions = IntegrationGateActions(
            tunnelManager: manager,
            httpClient: httpClient,
            sampler: sampler,
            clock: clock,
            writeRunning: { _ in }
        )
        return G1ActionHarness(
            clock: clock,
            inputs: inputs,
            httpClient: httpClient,
            actions: actions,
            sync: sync
        )
    }

    private static func inputs(status: ConnectionSyncStatus) -> ConnectionSyncInputs {
        switch status {
        case .offline:
            return ConnectionSyncInputs(
                tunnelState: .disconnected,
                reconnectCountdown: nil,
                isNetworkSatisfied: true,
                confirmedTransferCount: 0,
                recentBytesPerSecond: 0,
                backlogPending: 0,
                backlogFailed: 0
            )
        case .connectedIdle:
            return ConnectionSyncInputs(
                tunnelState: .connected(localPort: 5151, via: .remote),
                reconnectCountdown: nil,
                isNetworkSatisfied: true,
                confirmedTransferCount: 0,
                recentBytesPerSecond: 0,
                backlogPending: 0,
                backlogFailed: 0
            )
        case .connectedWaiting:
            return ConnectionSyncInputs(
                tunnelState: .connected(localPort: 5151, via: .remote),
                reconnectCountdown: nil,
                isNetworkSatisfied: true,
                confirmedTransferCount: 0,
                recentBytesPerSecond: 0,
                backlogPending: 1,
                backlogFailed: 0
            )
        case .connectedTransferring:
            return ConnectionSyncInputs(
                tunnelState: .connected(localPort: 5151, via: .remote),
                reconnectCountdown: nil,
                isNetworkSatisfied: true,
                confirmedTransferCount: 1,
                recentBytesPerSecond: 1,
                backlogPending: 1,
                backlogFailed: 0
            )
        case .connecting:
            return ConnectionSyncInputs(
                tunnelState: .connecting,
                reconnectCountdown: nil,
                isNetworkSatisfied: true,
                confirmedTransferCount: 0,
                recentBytesPerSecond: 0,
                backlogPending: 0,
                backlogFailed: 0
            )
        case .waitingForHome:
            return ConnectionSyncInputs(
                tunnelState: .waitingForHome,
                reconnectCountdown: nil,
                isNetworkSatisfied: true,
                confirmedTransferCount: 0,
                recentBytesPerSecond: 0,
                backlogPending: 0,
                backlogFailed: 0
            )
        case .reconnecting:
            return ConnectionSyncInputs(
                tunnelState: .error(.muxTeardown),
                reconnectCountdown: 1,
                isNetworkSatisfied: true,
                confirmedTransferCount: 0,
                recentBytesPerSecond: 0,
                backlogPending: 0,
                backlogFailed: 0
            )
        case .unreachable:
            return ConnectionSyncInputs(
                tunnelState: .error(.unreachable),
                reconnectCountdown: nil,
                isNetworkSatisfied: true,
                confirmedTransferCount: 0,
                recentBytesPerSecond: 0,
                backlogPending: 0,
                backlogFailed: 0
            )
        }
    }

    private static func installTwoHundredCanaryHandler() {
        IntegrationGateRangeHeaderURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return IntegrationGateRangeHeaderURLProtocolPayload(response: response, chunks: [])
        }
    }

    private static func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private static func sourceText(_ relativePath: String) throws -> String {
        let url = StringLiteralGrepSupport.worktreeRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func resetGateDirectory() throws {
        let directory = try IntegrationGateConstants.gateDirectoryURL()
        try? FileManager.default.removeItem(at: directory)
    }

    private static func drainUntil(
        timeoutIterations: Int = 200,
        _ condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<timeoutIterations {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("condition did not become true")
    }

    private final class G1InputBox {
        var current: ConnectionSyncInputs

        init(_ current: ConnectionSyncInputs) {
            self.current = current
        }
    }

    private struct G1ActionHarness {
        let clock: MockObserverClock
        let inputs: G1InputBox
        let httpClient: IntegrationGateHTTPClient
        let actions: IntegrationGateActions
        // The published status is what G1 now waits for, so a harness that cannot move
        // it cannot exercise G1 at all. `ConnectionSyncModel.run()` is deliberately NOT
        // started here -- it would add poll and debounce sleepers to every test's
        // hand-cranked clock accounting. `refreshNow()` publishes synchronously, so a
        // test can converge the label at the exact point it chooses, with no clock ticks.
        let sync: ConnectionSyncModel
    }
}
