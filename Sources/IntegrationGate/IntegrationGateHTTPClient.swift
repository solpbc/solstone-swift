// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation
import os

#if DEBUG && targetEnvironment(simulator)
private let log = Logger(subsystem: "app.solstone.swift", category: "integration-gate-http")

struct IntegrationGateContentRange: Sendable, Equatable {
    var start: UInt64
    var end: UInt64
    var total: UInt64

    var byteCount: UInt64 {
        self.end - self.start + 1
    }

    static func parse(
        _ value: String,
        expectedStart: UInt64,
        expectedLength: UInt64,
        expectedTotal: UInt64,
        contentLengthHeader: String?
    ) throws -> IntegrationGateContentRange {
        guard value.hasPrefix("bytes "),
              !value.contains("*"),
              !value.contains(",")
        else {
            throw IntegrationGateValidationError(.contentRangeMalformed)
        }
        let rest = String(value.dropFirst("bytes ".count))
        let totalParts = rest.split(separator: "/", omittingEmptySubsequences: false)
        guard totalParts.count == 2,
              let total = UInt64(totalParts[1])
        else {
            throw IntegrationGateValidationError(.contentRangeMalformed)
        }
        let rangeParts = totalParts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard rangeParts.count == 2,
              let start = UInt64(rangeParts[0]),
              let end = UInt64(rangeParts[1]),
              start <= end
        else {
            throw IntegrationGateValidationError(.contentRangeMalformed)
        }
        guard expectedLength > 0,
              expectedStart <= UInt64.max - (expectedLength - 1)
        else {
            throw IntegrationGateValidationError(.invalidRange)
        }
        let expectedEnd = expectedStart + expectedLength - 1
        guard start == expectedStart,
              end == expectedEnd,
              total == expectedTotal
        else {
            throw IntegrationGateValidationError(.contentRangeMismatch)
        }
        if let contentLengthHeader {
            guard let contentLength = UInt64(contentLengthHeader),
                  contentLength == expectedLength
            else {
                throw IntegrationGateValidationError(.contentLengthMismatch)
            }
        }
        return IntegrationGateContentRange(start: start, end: end, total: total)
    }
}

struct IntegrationGateRangeResponse: Sendable, Equatable {
    var outcome: IntegrationGateHTTPOutcome
    var contentRange: IntegrationGateContentRange?
    var sha256Hex: String
}

struct IntegrationGateOperationCeiling: Sendable, Equatable {
    var startedAt: Date
    var ceilingMilliseconds: UInt64

    func check(at now: Date) throws {
        let ceilingSeconds = TimeInterval(ceilingMilliseconds) / 1_000
        guard now.timeIntervalSince(startedAt) <= ceilingSeconds else {
            throw IntegrationGateValidationError(.requestTimedOut)
        }
    }

    func elapsedMillis(at now: Date) -> UInt64 {
        IntegrationGateHTTPClient.durationMillis(from: startedAt, to: now)
    }
}

@MainActor
final class IntegrationGateHTTPClient {
    private let tunnelManager: TunnelManager
    private let session: URLSession
    private let now: @MainActor @Sendable () -> Date
    private(set) var activeGateIssuedRequestCount = 0

    init(
        tunnelManager: TunnelManager,
        session: URLSession = .shared,
        now: @escaping @MainActor @Sendable () -> Date = Date.init
    ) {
        self.tunnelManager = tunnelManager
        self.session = session
        self.now = now
    }

    func canary(routeLabel: IntegrationGateRouteLabel) async -> IntegrationGateHTTPOutcome {
        let startedAt = self.now()
        let ceiling = IntegrationGateOperationCeiling(
            startedAt: startedAt,
            ceilingMilliseconds: IntegrationGateConstants.canaryCeilingMilliseconds
        )
        do {
            let request = try self.request(
                for: routeLabel,
                timeoutMilliseconds: IntegrationGateConstants.canaryCeilingMilliseconds
            )
            self.activeGateIssuedRequestCount += 1
            defer {
                self.activeGateIssuedRequestCount -= 1
            }
            try ceiling.check(at: self.now())
            let (_, response) = try await session.data(for: request)
            try ceiling.check(at: self.now())
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            return IntegrationGateHTTPOutcome(
                statusCode: statusCode,
                errorBucket: statusCode == 200 ? nil : "httpStatusMismatch",
                byteCount: 0,
                durationMillis: Self.durationMillis(from: startedAt, to: self.now())
            )
        } catch let error as IntegrationGateValidationError {
            return IntegrationGateHTTPOutcome(
                statusCode: nil,
                errorBucket: error.reasonCode.rawValue,
                byteCount: 0,
                durationMillis: Self.durationMillis(from: startedAt, to: self.now())
            )
        } catch is CancellationError {
            return IntegrationGateHTTPOutcome(
                statusCode: nil,
                errorBucket: IntegrationGateReasonCode.requestTimedOut.rawValue,
                byteCount: 0,
                durationMillis: Self.durationMillis(from: startedAt, to: self.now())
            )
        } catch {
            return IntegrationGateHTTPOutcome(
                statusCode: nil,
                errorBucket: IntegrationGateReasonCode.requestFailed.rawValue,
                byteCount: 0,
                durationMillis: Self.durationMillis(from: startedAt, to: self.now())
            )
        }
    }

    func rangedStreamingRequest(
        routeLabel: IntegrationGateRouteLabel,
        rangeStart: UInt64,
        rangeLength: UInt64,
        expectedTotal: UInt64,
        ceilingMilliseconds: UInt64 = IntegrationGateConstants.streamCeilingMilliseconds,
        progress: (@MainActor (UInt64) async throws -> Void)? = nil
    ) async throws -> IntegrationGateRangeResponse {
        let startedAt = self.now()
        let ceiling = IntegrationGateOperationCeiling(
            startedAt: startedAt,
            ceilingMilliseconds: ceilingMilliseconds
        )
        var request = try self.request(for: routeLabel, timeoutMilliseconds: ceilingMilliseconds)
        guard rangeLength > 0,
              rangeStart <= UInt64.max - (rangeLength - 1)
        else {
            throw IntegrationGateValidationError(.invalidRange)
        }
        let rangeEnd = rangeStart + rangeLength - 1
        request.setValue("bytes=\(rangeStart)-\(rangeEnd)", forHTTPHeaderField: "Range")

        self.activeGateIssuedRequestCount += 1
        defer {
            self.activeGateIssuedRequestCount -= 1
        }

        try ceiling.check(at: self.now())
        let (bytes, response) = try await session.bytes(for: request)
        try ceiling.check(at: self.now())
        guard let httpResponse = response as? HTTPURLResponse else {
            throw IntegrationGateValidationError(.requestFailed)
        }
        guard httpResponse.statusCode == 206 else {
            return IntegrationGateRangeResponse(
                outcome: IntegrationGateHTTPOutcome(
                    statusCode: httpResponse.statusCode,
                    errorBucket: IntegrationGateReasonCode.rangeStatusMismatch.rawValue,
                    byteCount: 0,
                    durationMillis: Self.durationMillis(from: startedAt, to: self.now())
                ),
                contentRange: nil,
                sha256Hex: ""
            )
        }
        guard let contentRangeHeader = httpResponse.value(forHTTPHeaderField: "Content-Range") else {
            throw IntegrationGateValidationError(.contentRangeMalformed)
        }
        let parsedRange = try IntegrationGateContentRange.parse(
            contentRangeHeader,
            expectedStart: rangeStart,
            expectedLength: rangeLength,
            expectedTotal: expectedTotal,
            contentLengthHeader: httpResponse.value(forHTTPHeaderField: "content-length")
        )

        var hasher = SHA256()
        var byteCount: UInt64 = 0
        var buffer: [UInt8] = []
        buffer.reserveCapacity(16 * 1024)
        for try await byte in bytes {
            try ceiling.check(at: self.now())
            byteCount += 1
            buffer.append(byte)
            if buffer.count == 16 * 1024 {
                hasher.update(data: Data(buffer))
                buffer.removeAll(keepingCapacity: true)
            }
            if let progress {
                try await progress(byteCount)
            }
        }
        try ceiling.check(at: self.now())
        if !buffer.isEmpty {
            hasher.update(data: Data(buffer))
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return IntegrationGateRangeResponse(
            outcome: IntegrationGateHTTPOutcome(
                statusCode: httpResponse.statusCode,
                errorBucket: nil,
                byteCount: byteCount,
                durationMillis: Self.durationMillis(from: startedAt, to: self.now())
            ),
            contentRange: parsedRange,
            sha256Hex: digest
        )
    }

    private func request(for routeLabel: IntegrationGateRouteLabel, timeoutMilliseconds: UInt64) throws -> URLRequest {
        guard let activeConnection = tunnelManager.activeConnection else {
            throw IntegrationGateValidationError(.noActiveConnection)
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = activeConnection.port
        components.path = routeLabel.path
        guard let url = components.url else {
            throw IntegrationGateValidationError(.malformedRouteInput)
        }
        return URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: TimeInterval(timeoutMilliseconds) / 1_000
        )
    }

    nonisolated static func durationMillis(from start: Date, to end: Date) -> UInt64 {
        UInt64(max(0, Int64((end.timeIntervalSince1970 - start.timeIntervalSince1970) * 1_000)))
    }
}
#endif
