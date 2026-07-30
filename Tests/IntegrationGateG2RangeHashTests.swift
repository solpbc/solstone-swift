// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

// criterion 6: G2 range hash classification.
@MainActor
final class IntegrationGateG2RangeHashTests: XCTestCase {
    func testMuxInitialCreditConstantMatchesApprovedMirrorValue() {
        XCTAssertEqual(IntegrationGateConstants.gateMuxInitialCreditBytes, 1 << 20)
    }

    func testBoundaryExactlyOneMiBFailsAndOneMiBPlusOnePasses() {
        let boundary = UInt64(IntegrationGateConstants.gateMuxInitialCreditBytes)
        let digest = Self.digest("a")

        XCTAssertEqual(
            IntegrationGateActionClassifiers.classifyG2(
                Self.facts(byteCount: boundary, rangeEnd: boundary - 1, expectedDigest: digest, actualDigest: digest)
            ).1,
            .rangeTooSmall
        )
        XCTAssertEqual(
            IntegrationGateActionClassifiers.classifyG2(
                Self.facts(byteCount: boundary + 1, rangeEnd: boundary, expectedDigest: digest, actualDigest: digest)
            ).0,
            .pass
        )
    }

    func testStatus200IgnoringRangeFails() {
        let classified = IntegrationGateActionClassifiers.classifyG2(
            Self.facts(statusCode: 200, contentRange: nil)
        )

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .rangeStatusMismatch)
    }

    func testChangedMiddleByteFailsDigest() {
        let classified = IntegrationGateActionClassifiers.classifyG2(
            Self.facts(expectedDigest: Self.digest("a"), actualDigest: Self.digest("b"))
        )

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .digestMismatch)
    }

    func testRepeatedPrefixFailsDigest() {
        let classified = IntegrationGateActionClassifiers.classifyG2(
            Self.facts(expectedDigest: Self.digest("c"), actualDigest: Self.digest("d"))
        )

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .digestMismatch)
    }

    func testTruncatedTailFailsByteCount() {
        let classified = IntegrationGateActionClassifiers.classifyG2(
            Self.facts(byteCount: UInt64(IntegrationGateConstants.gateMuxInitialCreditBytes) + 1, rangeEnd: UInt64(IntegrationGateConstants.gateMuxInitialCreditBytes) + 1)
        )

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .byteCountMismatch)
    }

    func testExtraSuffixFailsByteCount() {
        let classified = IntegrationGateActionClassifiers.classifyG2(
            Self.facts(byteCount: UInt64(IntegrationGateConstants.gateMuxInitialCreditBytes) + 2, rangeEnd: UInt64(IntegrationGateConstants.gateMuxInitialCreditBytes))
        )

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .byteCountMismatch)
    }

    func testTimeoutFailsWithTimeoutReason() {
        let classified = IntegrationGateActionClassifiers.classifyG2(
            Self.facts(statusCode: nil, errorBucket: IntegrationGateReasonCode.requestTimedOut.rawValue)
        )

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .requestTimedOut)
    }

    func testStreamExceedingDeclaredCeilingTerminatesUnsuccessfullyWithFakeClock() {
        let clock = MockObserverClock()
        let ceiling = IntegrationGateOperationCeiling(
            startedAt: clock.now(),
            ceilingMilliseconds: IntegrationGateConstants.streamCeilingMilliseconds
        )

        clock.advance(by: TimeInterval(IntegrationGateConstants.streamCeilingMilliseconds) / 1_000)
        XCTAssertNoThrow(try ceiling.check(at: clock.now()))

        clock.advance(by: 0.001)
        XCTAssertThrowsError(try ceiling.check(at: clock.now())) { error in
            XCTAssertEqual((error as? IntegrationGateValidationError)?.reasonCode, .requestTimedOut)
        }
    }

    func testMalformedRangeFailsWithInvalidRangeReason() {
        let classified = IntegrationGateActionClassifiers.classifyG2(
            Self.facts(statusCode: nil, errorBucket: IntegrationGateReasonCode.invalidRange.rawValue)
        )

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .invalidRange)
    }

    func testContentRangeRejectsWildcardMultipleRangesOverflowAndMismatches() {
        XCTAssertThrowsError(
            try IntegrationGateContentRange.parse(
                "bytes */2048",
                expectedStart: 0,
                expectedLength: 8,
                expectedTotal: 2_048,
                contentLengthHeader: "8"
            )
        )
        XCTAssertThrowsError(
            try IntegrationGateContentRange.parse(
                "bytes 0-7/2048, bytes 8-15/2048",
                expectedStart: 0,
                expectedLength: 8,
                expectedTotal: 2_048,
                contentLengthHeader: "8"
            )
        )
        XCTAssertThrowsError(
            try IntegrationGateContentRange.parse(
                "bytes 0-7/2048",
                expectedStart: UInt64.max,
                expectedLength: 2,
                expectedTotal: 2_048,
                contentLengthHeader: "8"
            )
        )
        XCTAssertThrowsError(
            try IntegrationGateContentRange.parse(
                "bytes 1-8/2048",
                expectedStart: 0,
                expectedLength: 8,
                expectedTotal: 2_048,
                contentLengthHeader: "8"
            )
        )
        XCTAssertThrowsError(
            try IntegrationGateContentRange.parse(
                "bytes 0-7/2048",
                expectedStart: 0,
                expectedLength: 8,
                expectedTotal: 2_048,
                contentLengthHeader: "9"
            )
        )
    }

    private static func facts(
        statusCode: Int? = 206,
        errorBucket: String? = nil,
        byteCount: UInt64 = UInt64(IntegrationGateConstants.gateMuxInitialCreditBytes) + 1,
        rangeEnd: UInt64 = UInt64(IntegrationGateConstants.gateMuxInitialCreditBytes),
        contentRange: IntegrationGateContentRange? = nil,
        expectedDigest: String? = nil,
        actualDigest: String? = nil
    ) -> IntegrationGateG2Facts {
        let resolvedExpectedDigest = expectedDigest ?? Self.digest("a")
        let resolvedActualDigest = actualDigest ?? resolvedExpectedDigest
        let resolvedRange = contentRange ?? IntegrationGateContentRange(
            start: 0,
            end: rangeEnd,
            total: rangeEnd + 1
        )
        return IntegrationGateG2Facts(
            response: IntegrationGateRangeResponse(
                outcome: IntegrationGateHTTPOutcome(
                    statusCode: statusCode,
                    errorBucket: errorBucket,
                    byteCount: byteCount,
                    durationMillis: 1
                ),
                contentRange: contentRange == nil && statusCode == 200 ? nil : resolvedRange,
                sha256Hex: resolvedActualDigest
            ),
            expectedContentLength: resolvedRange.total,
            expectedSHA256Hex: resolvedExpectedDigest
        )
    }

    private static func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }
}
