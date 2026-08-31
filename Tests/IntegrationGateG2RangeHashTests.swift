// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Crypto
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
            return IntegrationGateRangeHeaderURLProtocolPayload(response: response, chunks: [])
        }
        let configuration = IntegrationGateHTTPClient.productionSessionConfiguration()
        configuration.protocolClasses = [IntegrationGateRangeHeaderURLProtocol.self]
        let tunnelManager = TunnelManager(transport: MockCFTunnelTransport())
        tunnelManager.forceConnected(port: 5151, via: .remote)
        let client = IntegrationGateHTTPClient(tunnelManager: tunnelManager, sessionConfiguration: configuration)
        defer { client.shutdown() }

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

    func testDefaultClientOwnsNonSharedSession() {
        let tunnelManager = TunnelManager(transport: MockCFTunnelTransport())
        let client = IntegrationGateHTTPClient(tunnelManager: tunnelManager)
        defer { client.shutdown() }

        XCTAssertFalse(client.session === URLSession.shared)
    }

    func testProductionConfigurationShapeSupportsProtocolInjection() async throws {
        let data = Self.data(length: UInt64(IntegrationGateConstants.gateMuxInitialCreditBytes) + 17)
        let digest = Self.sha256Hex(data)
        IntegrationGateRangeHeaderURLProtocol.handler = { request in
            let response = Self.partialResponse(request: request, rangeStart: 0, rangeLength: UInt64(data.count), expectedTotal: UInt64(data.count))
            return IntegrationGateRangeHeaderURLProtocolPayload(response: response, chunks: [data])
        }
        let configuration = IntegrationGateHTTPClient.productionSessionConfiguration()
        configuration.protocolClasses = [IntegrationGateRangeHeaderURLProtocol.self]
        let tunnelManager = TunnelManager(transport: MockCFTunnelTransport())
        tunnelManager.forceConnected(port: 5151, via: .remote)
        let client = IntegrationGateHTTPClient(tunnelManager: tunnelManager, sessionConfiguration: configuration)
        defer { client.shutdown() }

        let response = try await client.rangedStreamingRequest(
            routeLabel: .gateRange,
            rangeStart: 0,
            rangeLength: UInt64(data.count),
            expectedTotal: UInt64(data.count)
        )

        XCTAssertEqual(response.outcome.byteCount, UInt64(data.count))
        XCTAssertEqual(response.sha256Hex, digest)
    }

    func testDriverSourceKeepsDefaultHTTPClientConstruction() throws {
        let text = try Self.sourceText("Sources/IntegrationGate/IntegrationGateDriver.swift")
        let start = try XCTUnwrap(text.range(of: "let httpClient = IntegrationGateHTTPClient("))
        let end = try XCTUnwrap(text.range(of: "let clock = SystemObserverClock()", range: start.upperBound..<text.endIndex))
        let construction = text[start.lowerBound..<end.lowerBound]

        XCTAssertTrue(construction.contains("tunnelManager: dependencies.tunnelManager"))
        XCTAssertTrue(construction.contains("now: { self.now() }"))
        XCTAssertFalse(construction.contains("sessionConfiguration:"))
    }

    func testMidBodyTransportErrorThrowsRequestFailedInsteadOfShortSuccessfulBody() async throws {
        let chunk = Data(repeating: 0x42, count: 64 * 1024)
        IntegrationGateRangeHeaderURLProtocol.handler = { request in
            let response = Self.partialResponse(request: request, rangeStart: 0, rangeLength: UInt64(chunk.count * 5), expectedTotal: UInt64(chunk.count * 5))
            return IntegrationGateRangeHeaderURLProtocolPayload(
                response: response,
                chunks: [chunk, chunk, chunk],
                failureAfterChunks: true
            )
        }
        let client = Self.client()
        defer { client.shutdown() }

        do {
            _ = try await client.rangedStreamingRequest(
                routeLabel: .gateRange,
                rangeStart: 0,
                rangeLength: UInt64(chunk.count * 5),
                expectedTotal: UInt64(chunk.count * 5)
            )
            XCTFail("request unexpectedly succeeded")
        } catch let error as IntegrationGateValidationError {
            XCTAssertEqual(error.reasonCode, .requestFailed)
        }
    }

    func testChunkBoundariesProduceWholeBodyDigestAndByteCount() async throws {
        let data = Self.data(length: UInt64(IntegrationGateConstants.gateMuxInitialCreditBytes) + 123)
        let digest = Self.sha256Hex(data)
        let variants: [[Data]] = [
            [data],
            Self.chunks(data, size: 4 * 1024),
            Self.chunks(data, size: 10 * 1024),
            Self.chunks(data, size: 64 * 1024),
        ]

        for chunks in variants {
            IntegrationGateRangeHeaderURLProtocol.reset()
            IntegrationGateRangeHeaderURLProtocol.handler = { request in
                let response = Self.partialResponse(request: request, rangeStart: 0, rangeLength: UInt64(data.count), expectedTotal: UInt64(data.count))
                return IntegrationGateRangeHeaderURLProtocolPayload(response: response, chunks: chunks)
            }
            let client = Self.client()
            defer { client.shutdown() }

            let response = try await client.rangedStreamingRequest(
                routeLabel: .gateRange,
                rangeStart: 0,
                rangeLength: UInt64(data.count),
                expectedTotal: UInt64(data.count)
            )

            XCTAssertEqual(response.outcome.byteCount, UInt64(data.count))
            XCTAssertEqual(response.sha256Hex, digest)
        }
    }

    func testEarlyProgressFailureCancelsTaskAndRestoresAccounting() async throws {
        let chunk = Data(repeating: 0x33, count: 64 * 1024)
        IntegrationGateRangeHeaderURLProtocol.handler = { request in
            let response = Self.partialResponse(request: request, rangeStart: 0, rangeLength: UInt64(chunk.count), expectedTotal: UInt64(chunk.count))
            return IntegrationGateRangeHeaderURLProtocolPayload(
                response: response,
                chunks: [chunk],
                finishesLoading: false
            )
        }
        let client = Self.client()
        defer { client.shutdown() }
        XCTAssertEqual(client.activeGateIssuedRequestCount, 0)

        do {
            _ = try await client.rangedStreamingRequest(
                routeLabel: .gateRange,
                rangeStart: 0,
                rangeLength: UInt64(chunk.count),
                expectedTotal: UInt64(chunk.count),
                progress: { _ in
                    throw IntegrationGateValidationError(.requestTimedOut)
                }
            )
            XCTFail("request unexpectedly succeeded")
        } catch let error as IntegrationGateValidationError {
            XCTAssertEqual(error.reasonCode, .requestTimedOut)
        }
        XCTAssertEqual(client.activeGateIssuedRequestCount, 0)
        try await Self.waitForStopLoadingCount(1)
    }

    func testStreamCeilingExceededMidBodyCancelsTaskAndRestoresAccounting() async throws {
        let clock = MockObserverClock()
        let chunk = Data(repeating: 0x44, count: 64 * 1024)
        let totalLength = UInt64(chunk.count * 3)
        IntegrationGateRangeHeaderURLProtocol.handler = { request in
            let response = Self.partialResponse(request: request, rangeStart: 0, rangeLength: totalLength, expectedTotal: totalLength)
            return IntegrationGateRangeHeaderURLProtocolPayload(
                response: response,
                chunks: [chunk, chunk, chunk],
                finishesLoading: false
            )
        }
        let configuration = IntegrationGateHTTPClient.productionSessionConfiguration()
        configuration.protocolClasses = [IntegrationGateRangeHeaderURLProtocol.self]
        let tunnelManager = TunnelManager(transport: MockCFTunnelTransport())
        tunnelManager.forceConnected(port: 5151, via: .remote)
        let client = IntegrationGateHTTPClient(
            tunnelManager: tunnelManager,
            sessionConfiguration: configuration,
            now: { clock.now() }
        )
        defer { client.shutdown() }
        XCTAssertEqual(client.activeGateIssuedRequestCount, 0)

        do {
            _ = try await client.rangedStreamingRequest(
                routeLabel: .gateRange,
                rangeStart: 0,
                rangeLength: totalLength,
                expectedTotal: totalLength,
                progress: { byteCount in
                    if byteCount == UInt64(chunk.count) {
                        clock.advance(by: TimeInterval(IntegrationGateConstants.streamCeilingMilliseconds) / 1_000 + 0.001)
                    }
                }
            )
            XCTFail("request unexpectedly succeeded")
        } catch let error as IntegrationGateValidationError {
            XCTAssertEqual(error.reasonCode, .requestTimedOut)
        }
        XCTAssertEqual(client.activeGateIssuedRequestCount, 0)
        try await Self.waitForStopLoadingCount(1)
    }

    func testParentTaskCancellationCancelsTaskAndRestoresAccounting() async throws {
        let rangeLength: UInt64 = 64 * 1024
        IntegrationGateRangeHeaderURLProtocol.handler = { request in
            let response = Self.partialResponse(request: request, rangeStart: 0, rangeLength: rangeLength, expectedTotal: rangeLength)
            return IntegrationGateRangeHeaderURLProtocolPayload(
                response: response,
                chunks: [],
                finishesLoading: false
            )
        }
        let client = Self.client()
        defer { client.shutdown() }
        XCTAssertEqual(client.activeGateIssuedRequestCount, 0)

        let task = Task { () -> (any Error)? in
            do {
                _ = try await client.rangedStreamingRequest(
                    routeLabel: .gateRange,
                    rangeStart: 0,
                    rangeLength: rangeLength,
                    expectedTotal: rangeLength
                )
                return nil
            } catch {
                return error
            }
        }
        await Self.drainUntil {
            client.activeGateIssuedRequestCount == 1 && !IntegrationGateRangeHeaderURLProtocol.capturedRequests.isEmpty
        }
        task.cancel()

        let maybeError = await task.value
        let error = try XCTUnwrap(maybeError)

        XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(String(describing: error))")
        XCTAssertEqual(client.activeGateIssuedRequestCount, 0)
        try await Self.waitForStopLoadingCount(1)
    }

    func testProgressFiresWithCumulativeTransportChunkCount() async throws {
        let chunk = Data(repeating: 0x24, count: 64 * 1024)
        let totalLength = UInt64(chunk.count * 20)
        IntegrationGateRangeHeaderURLProtocol.handler = { request in
            let response = Self.partialResponse(request: request, rangeStart: 0, rangeLength: totalLength, expectedTotal: totalLength)
            return IntegrationGateRangeHeaderURLProtocolPayload(
                response: response,
                chunks: Array(repeating: chunk, count: 20)
            )
        }
        let client = Self.client()
        defer { client.shutdown() }
        var firstPublished: UInt64?

        _ = try await client.rangedStreamingRequest(
            routeLabel: .gateRange,
            rangeStart: 0,
            rangeLength: totalLength,
            expectedTotal: totalLength,
            progress: { byteCount in
                if firstPublished == nil,
                   byteCount > UInt64(IntegrationGateConstants.gateMuxInitialCreditBytes),
                   byteCount < totalLength {
                    firstPublished = byteCount
                }
            }
        )

        let published = try XCTUnwrap(firstPublished)
        XCTAssertGreaterThan(published, UInt64(IntegrationGateConstants.gateMuxInitialCreditBytes))
        XCTAssertLessThan(published, totalLength)
        XCTAssertEqual(published % UInt64(chunk.count), 0)
    }

    func testProgressGuardCanPublishWhenFinalRangeChunkIsBelowExpectedTotal() async throws {
        let rangeLength = UInt64(IntegrationGateConstants.gateMuxInitialCreditBytes) + 64
        let expectedTotal = rangeLength * 4
        let data = Self.data(length: rangeLength)
        IntegrationGateRangeHeaderURLProtocol.handler = { request in
            let response = Self.partialResponse(
                request: request,
                rangeStart: 0,
                rangeLength: rangeLength,
                expectedTotal: expectedTotal
            )
            return IntegrationGateRangeHeaderURLProtocolPayload(response: response, chunks: [data])
        }
        let client = Self.client()
        defer { client.shutdown() }
        var published: UInt64?

        _ = try await client.rangedStreamingRequest(
            routeLabel: .gateRange,
            rangeStart: 0,
            rangeLength: rangeLength,
            expectedTotal: expectedTotal,
            progress: { byteCount in
                if published == nil,
                   byteCount > UInt64(IntegrationGateConstants.gateMuxInitialCreditBytes),
                   byteCount < expectedTotal {
                    published = byteCount
                }
            }
        )

        XCTAssertEqual(published, rangeLength)
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

    static func client() -> IntegrationGateHTTPClient {
        let configuration = IntegrationGateHTTPClient.productionSessionConfiguration()
        configuration.protocolClasses = [IntegrationGateRangeHeaderURLProtocol.self]
        let tunnelManager = TunnelManager(transport: MockCFTunnelTransport())
        tunnelManager.forceConnected(port: 5151, via: .remote)
        return IntegrationGateHTTPClient(tunnelManager: tunnelManager, sessionConfiguration: configuration)
    }

    nonisolated static func partialResponse(
        request: URLRequest,
        rangeStart: UInt64,
        rangeLength: UInt64,
        expectedTotal: UInt64
    ) -> HTTPURLResponse {
        let rangeEnd = rangeStart + rangeLength - 1
        return HTTPURLResponse(
            url: request.url!,
            statusCode: 206,
            httpVersion: nil,
            headerFields: [
                "Content-Range": "bytes \(rangeStart)-\(rangeEnd)/\(expectedTotal)",
                "Content-Length": "\(rangeLength)",
            ]
        )!
    }

    nonisolated static func data(length: UInt64) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Int(length))
        for index in 0..<length {
            bytes.append(UInt8(index % 251))
        }
        return Data(bytes)
    }

    nonisolated static func chunks(_ data: Data, size: Int) -> [Data] {
        var chunks: [Data] = []
        var start = data.startIndex
        while start < data.endIndex {
            let end = data.index(start, offsetBy: min(size, data.distance(from: start, to: data.endIndex)))
            chunks.append(data[start..<end])
            start = end
        }
        return chunks
    }

    nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sourceText(_ relativePath: String) throws -> String {
        let url = StringLiteralGrepSupport.worktreeRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
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

    private static func waitForStopLoadingCount(_ expected: Int) async throws {
        for _ in 0..<50 {
            if IntegrationGateRangeHeaderURLProtocol.stopLoadingCount == expected {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for stopLoadingCount \(expected)")
    }
}

struct IntegrationGateRangeHeaderURLProtocolPayload: Sendable {
    var response: HTTPURLResponse
    var chunks: [Data]
    var failureAfterChunks: Bool
    var finishesLoading: Bool

    init(
        response: HTTPURLResponse,
        chunks: [Data],
        failureAfterChunks: Bool = false,
        finishesLoading: Bool = true
    ) {
        self.response = response
        self.chunks = chunks
        self.failureAfterChunks = failureAfterChunks
        self.finishesLoading = finishesLoading
    }
}

final class IntegrationGateRangeHeaderURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> IntegrationGateRangeHeaderURLProtocolPayload

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    private static let capturedRequestsBox = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])
    private static let stopLoadingCountBox = OSAllocatedUnfairLock(initialState: 0)
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    static var handler: Handler? {
        get { self.handlerBox.withLock { $0 } }
        set { self.handlerBox.withLock { $0 = newValue } }
    }

    static var capturedRequests: [URLRequest] {
        get { self.capturedRequestsBox.withLock { $0 } }
        set { self.capturedRequestsBox.withLock { $0 = newValue } }
    }

    static var stopLoadingCount: Int {
        self.stopLoadingCountBox.withLock { $0 }
    }

    static func reset() {
        self.handler = nil
        self.capturedRequests = []
        self.stopLoadingCountBox.withLock { $0 = 0 }
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
            let payload = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: payload.response, cacheStoragePolicy: .notAllowed)
            self.deliver(payload: payload, index: 0)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        self.stopped.withLock { $0 = true }
        Self.stopLoadingCountBox.withLock { $0 += 1 }
    }

    private func deliver(payload: IntegrationGateRangeHeaderURLProtocolPayload, index: Int) {
        guard !self.stopped.withLock({ $0 }) else { return }
        guard index < payload.chunks.count else {
            if payload.failureAfterChunks {
                self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            } else if payload.finishesLoading {
                self.client?.urlProtocolDidFinishLoading(self)
            }
            return
        }
        self.client?.urlProtocol(self, didLoad: payload.chunks[index])
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(1)) {
            self.deliver(payload: payload, index: index + 1)
        }
    }
}
