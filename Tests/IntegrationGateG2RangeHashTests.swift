// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

// criterion 6: G2 range hash classification.
@MainActor
final class IntegrationGateG2RangeHashTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        IntegrationGateRangeHeaderURLProtocol.reset()
    }

    override func tearDown() async throws {
        IntegrationGateRangeHeaderURLProtocol.reset()
        try await super.tearDown()
    }

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

    func testContentRangeAllowsZeroStartMuxCrossingRangeAndRejectsMismatch() throws {
        let parsed = try IntegrationGateContentRange.parse(
            "bytes 0-2097168/2097169",
            expectedStart: 0,
            expectedLength: 2_097_169,
            expectedTotal: 2_097_169,
            contentLengthHeader: "2097169"
        )

        XCTAssertEqual(parsed.start, 0)
        XCTAssertEqual(parsed.end, 2_097_168)
        XCTAssertEqual(parsed.total, 2_097_169)
        XCTAssertThrowsError(
            try IntegrationGateContentRange.parse(
                "bytes 1-2097169/2097169",
                expectedStart: 0,
                expectedLength: 2_097_169,
                expectedTotal: 2_097_169,
                contentLengthHeader: "2097169"
            )
        ) { error in
            XCTAssertEqual((error as? IntegrationGateValidationError)?.reasonCode, .contentRangeMismatch)
        }
    }

    func testRangedStreamingRequestSendsZeroStartRangeHeaderAndFailsClosedOnNonPartialResponse() async throws {
        let rangeLength = UInt64(2 * 1024 * 1024 + 17)
        IntegrationGateRangeHeaderURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 416,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IntegrationGateRangeHeaderURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let tunnelManager = TunnelManager(transport: MockCFTunnelTransport())
        tunnelManager.forceConnected(port: 5151, via: .remote)
        let client = IntegrationGateHTTPClient(tunnelManager: tunnelManager, session: session)

        let response = try await client.rangedStreamingRequest(
            routeLabel: .gateRange,
            rangeStart: 0,
            rangeLength: rangeLength,
            expectedTotal: rangeLength
        )

        let request = try XCTUnwrap(IntegrationGateRangeHeaderURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.url?.path, IntegrationGateConstants.transcriptsServeFilePath)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-2097168")
        XCTAssertEqual(response.outcome.statusCode, 416)
        XCTAssertEqual(response.outcome.errorBucket, IntegrationGateReasonCode.rangeStatusMismatch.rawValue)
        XCTAssertEqual(response.outcome.byteCount, 0)
        XCTAssertNil(response.contentRange)
        XCTAssertEqual(response.sha256Hex, "")
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

private final class IntegrationGateRangeHeaderURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    private static let capturedRequestsBox = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])

    static var handler: Handler? {
        get { self.handlerBox.withLock { $0 } }
        set { self.handlerBox.withLock { $0 = newValue } }
    }

    static var capturedRequests: [URLRequest] {
        get { self.capturedRequestsBox.withLock { $0 } }
        set { self.capturedRequestsBox.withLock { $0 = newValue } }
    }

    static func reset() {
        self.handler = nil
        self.capturedRequests = []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.capturedRequestsBox.withLock { $0.append(self.request) }

        guard let handler = Self.handler else {
            XCTFail("IntegrationGateRangeHeaderURLProtocol handler not set")
            return
        }

        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
