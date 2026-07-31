// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
@testable import SPLTunnel
import Foundation
import os
import XCTest

// criterion 7: G3 generation retry classification and Option-A accounting.
@MainActor
final class IntegrationGateG3GenerationRetryTests: XCTestCase {
    func testReleaseProofAndNewerGenerationRetryPasses() {
        let classified = IntegrationGateActionClassifiers.classifyG3(Self.facts())

        XCTAssertEqual(classified.0, .pass)
        XCTAssertEqual(classified.1, .none)
    }

    func testEarlyFaultFails() {
        let classified = IntegrationGateActionClassifiers.classifyG3(
            Self.facts(firstProgressBytes: UInt64(IntegrationGateConstants.gateMuxInitialCreditBytes))
        )

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .earlyFault)
    }

    func testProgressAtOrBeyondTotalFailsBeforeRetry() {
        let total = UInt64(IntegrationGateConstants.gateMuxInitialCreditBytes) + 64
        let classified = IntegrationGateActionClassifiers.classifyG3(
            Self.facts(firstProgressBytes: total, expectedContentLength: total)
        )

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .earlyFault)
    }

    func testCompletedFirstAttemptFails() {
        let classified = IntegrationGateActionClassifiers.classifyG3(
            Self.facts(firstAttemptCompleted: true)
        )

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .completedFirstAttempt)
    }

    func testHungInterruptionFails() {
        let classified = IntegrationGateActionClassifiers.classifyG3(
            Self.facts(firstAttemptTerminated: false)
        )

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .hungInterruption)
    }

    func testSameGenerationRetryFails() {
        let classified = IntegrationGateActionClassifiers.classifyG3(
            Self.facts(retryGeneration: 3)
        )

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .sameGenerationRetry)
    }

    func testOverlappingRetryFails() {
        let classified = IntegrationGateActionClassifiers.classifyG3(
            Self.facts(retryStartedActiveRequestCount: 1)
        )

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .overlappingRetry)
    }

    func testBytesWithoutReleaseProofFails() {
        let classified = IntegrationGateActionClassifiers.classifyG3(
            Self.facts(activeGateIssuedRequestAfterFirstAttempt: 1)
        )

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .releaseProofMissing)
    }

    func testOldGenerationMustBeClosed() {
        let classified = IntegrationGateActionClassifiers.classifyG3(
            Self.facts(lastClosedGeneration: nil)
        )

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .oldGenerationNotClosed)
    }

    func testRetryDigestMismatchFails() {
        let classified = IntegrationGateActionClassifiers.classifyG3(
            Self.facts(retryResponse: Self.response(actualDigest: Self.digest("b")))
        )

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .digestMismatch)
    }

    func testOptionAAccountingFieldsAreSpecificToGateIssuedRequest() {
        let facts = Self.facts(activeGateIssuedRequestFinal: 0)

        XCTAssertEqual(facts.activeGateIssuedRequestBaseline, 0)
        XCTAssertEqual(facts.activeGateIssuedRequestAfterFirstAttempt, 0)
        XCTAssertEqual(facts.activeGateIssuedRequestFinal, 0)
    }

    func testRunningRecordWriteFailureReasonIsTerminalErrorOnly() {
        let result = IntegrationGateActionRunResult(
            verdict: .error,
            reasonCode: .runningRecordWriteFailed,
            httpOutcome: nil,
            accounting: .zero,
            samples: [],
            generation: IntegrationGateResultGeneration(currentGeneration: 1, activeGeneration: 1, lastClosedGeneration: nil),
            transportStages: [],
            reconnectReasonBuckets: []
        )

        XCTAssertEqual(result.verdict, .error)
        XCTAssertEqual(result.reasonCode, .runningRecordWriteFailed)
    }

    func testGenerationRetryUsesManifestRangeForBothAttemptsAndPublishesRunningAtChunkSeventeen() async throws {
        IntegrationGateRangeHeaderURLProtocol.reset()
        defer { IntegrationGateRangeHeaderURLProtocol.reset() }
        let rangeStart: UInt64 = 256
        let rangeLength: UInt64 = 2_097_169
        let expectedTotal: UInt64 = 8_388_625
        let retryData = IntegrationGateG2RangeHashTests.data(length: rangeLength)
        let expectedDigest = IntegrationGateG2RangeHashTests.sha256Hex(retryData)
        let firstAttemptChunk = Data(repeating: 0x7a, count: 64 * 1024)
        let requestCount = OSAllocatedUnfairLock(initialState: 0)
        IntegrationGateRangeHeaderURLProtocol.handler = { request in
            let index = requestCount.withLock { count in
                count += 1
                return count
            }
            let response = IntegrationGateG2RangeHashTests.partialResponse(
                request: request,
                rangeStart: rangeStart,
                rangeLength: rangeLength,
                expectedTotal: expectedTotal
            )
            if index == 1 {
                return IntegrationGateRangeHeaderURLProtocolPayload(
                    response: response,
                    chunks: Array(repeating: firstAttemptChunk, count: 17),
                    failureAfterChunks: true
                )
            }
            return IntegrationGateRangeHeaderURLProtocolPayload(
                response: response,
                chunks: IntegrationGateG2RangeHashTests.chunks(retryData, size: 64 * 1024)
            )
        }

        let clock = MockObserverClock()
        let transport = MockCFTunnelTransport()
        transport.generationSnapshot = TransportGenerationSnapshot(
            currentGeneration: 3,
            activeGeneration: 3,
            lastClosedGeneration: nil
        )
        let manager = TunnelManager(transport: transport)
        manager.forceConnected(port: 5151, via: .remote)
        let configuration = IntegrationGateHTTPClient.productionSessionConfiguration()
        configuration.protocolClasses = [IntegrationGateRangeHeaderURLProtocol.self]
        let httpClient = IntegrationGateHTTPClient(
            tunnelManager: manager,
            sessionConfiguration: configuration,
            now: { clock.now() }
        )
        defer { httpClient.shutdown() }
        let sync = ConnectionSyncModel(clock: clock) {
            ConnectionSyncInputs(
                tunnelState: manager.state,
                reconnectCountdown: manager.reconnectCountdown,
                isNetworkSatisfied: manager.isNetworkSatisfied,
                confirmedTransferCount: 0,
                recentBytesPerSecond: 0,
                backlogPending: 0,
                backlogFailed: 0
            )
        }
        let sampler = IntegrationGateSampler(
            tunnelManager: manager,
            connectionSyncModel: sync,
            httpClient: httpClient,
            clock: clock
        )
        var runningResults: [IntegrationGateActionRunResult] = []
        let actions = IntegrationGateActions(
            tunnelManager: manager,
            httpClient: httpClient,
            sampler: sampler,
            clock: clock,
            writeRunning: { result in
                runningResults.append(result)
                transport.generationSnapshot = TransportGenerationSnapshot(
                    currentGeneration: 4,
                    activeGeneration: 4,
                    lastClosedGeneration: 3
                )
            }
        )
        let result = await actions.run(
            manifest: Self.manifest(
                expectedContentLength: expectedTotal,
                expectedDigest: expectedDigest,
                rangeStart: rangeStart,
                rangeLength: rangeLength
            )
        )

        XCTAssertEqual(result.verdict, .pass)
        XCTAssertEqual(result.reasonCode, .none)
        XCTAssertEqual(runningResults.first?.httpOutcome?.byteCount, 1_114_112)
        XCTAssertEqual(result.httpOutcome?.byteCount, rangeLength)
        let requests = IntegrationGateRangeHeaderURLProtocol.capturedRequests
        XCTAssertEqual(requests.count, 2)
        let rangeEnd = rangeStart + rangeLength - 1
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Range"), "bytes=\(rangeStart)-\(rangeEnd)")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Range"), "bytes=\(rangeStart)-\(rangeEnd)")
    }

    private static func facts(
        oldGeneration: UInt64? = 3,
        firstProgressBytes: UInt64 = UInt64(IntegrationGateConstants.gateMuxInitialCreditBytes) + 1,
        expectedContentLength: UInt64 = UInt64(IntegrationGateConstants.gateMuxInitialCreditBytes) + 64,
        firstAttemptCompleted: Bool = false,
        firstAttemptTerminated: Bool = true,
        activeGateIssuedRequestBaseline: Int = 0,
        activeGateIssuedRequestAfterFirstAttempt: Int = 0,
        lastClosedGeneration: UInt64? = 3,
        retryStartedActiveRequestCount: Int = 0,
        retryGeneration: UInt64? = 4,
        retryResponse: IntegrationGateRangeResponse? = nil,
        activeGateIssuedRequestFinal: Int = 0,
        expectedSHA256Hex: String? = nil
    ) -> IntegrationGateG3Facts {
        let resolvedExpectedDigest = expectedSHA256Hex ?? Self.digest("a")
        let resolvedRetryResponse = retryResponse ?? Self.response()
        return IntegrationGateG3Facts(
            oldGeneration: oldGeneration,
            firstProgressBytes: firstProgressBytes,
            expectedContentLength: expectedContentLength,
            firstAttemptCompleted: firstAttemptCompleted,
            firstAttemptTerminated: firstAttemptTerminated,
            activeGateIssuedRequestBaseline: activeGateIssuedRequestBaseline,
            activeGateIssuedRequestAfterFirstAttempt: activeGateIssuedRequestAfterFirstAttempt,
            lastClosedGeneration: lastClosedGeneration,
            retryStartedActiveRequestCount: retryStartedActiveRequestCount,
            retryGeneration: retryGeneration,
            retryResponse: resolvedRetryResponse,
            activeGateIssuedRequestFinal: activeGateIssuedRequestFinal,
            expectedSHA256Hex: resolvedExpectedDigest
        )
    }

    private static func response(actualDigest: String? = nil) -> IntegrationGateRangeResponse {
        let total = UInt64(IntegrationGateConstants.gateMuxInitialCreditBytes) + 64
        return IntegrationGateRangeResponse(
            outcome: IntegrationGateHTTPOutcome(
                statusCode: 206,
                errorBucket: nil,
                byteCount: total,
                durationMillis: 1
            ),
            contentRange: IntegrationGateContentRange(start: 0, end: total - 1, total: total),
            sha256Hex: actualDigest ?? Self.digest("a")
        )
    }

    private static func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private static func manifest(
        expectedContentLength: UInt64,
        expectedDigest: String,
        rangeStart: UInt64,
        rangeLength: UInt64
    ) -> IntegrationGateManifest {
        IntegrationGateManifest(
            schemaVersion: IntegrationGateConstants.schemaVersion,
            sequence: 1,
            nonce: "synthetic-g3-nonce",
            action: .generationRetry,
            createdAtUnixMillis: 1,
            expiresAtUnixMillis: 2_000,
            expectedPairing: .init(
                instanceID: "synthetic-instance",
                fingerprintSHA256Hex: Self.digest("c"),
                pairedAtNotBeforeUnixMillis: 1
            ),
            expectedBuild: .init(sourceCommit: "synthetic-source", splSwiftRevision: "synthetic-spl"),
            expectedContentLength: expectedContentLength,
            expectedSHA256Hex: expectedDigest,
            rangeStart: rangeStart,
            rangeLength: rangeLength
        )
    }
}
