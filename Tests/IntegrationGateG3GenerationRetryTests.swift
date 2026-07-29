// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
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
}
