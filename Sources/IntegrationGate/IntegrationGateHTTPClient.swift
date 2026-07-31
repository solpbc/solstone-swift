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

nonisolated private struct IntegrationGateHTTPStreamResponse: Sendable, Equatable {
    var statusCode: Int
    var headers: [String: String]

    init(_ response: HTTPURLResponse) {
        self.statusCode = response.statusCode
        var normalized: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            normalized[String(describing: key).lowercased()] = String(describing: value)
        }
        self.headers = normalized
    }

    func value(forHTTPHeaderField field: String) -> String? {
        self.headers[field.lowercased()]
    }
}

nonisolated private enum IntegrationGateHTTPStreamFailure: Error, Sendable, Equatable {
    case requestFailed
    case cancelled

    var error: any Error {
        switch self {
        case .requestFailed:
            return IntegrationGateValidationError(.requestFailed)
        case .cancelled:
            return CancellationError()
        }
    }
}

nonisolated private struct IntegrationGateHTTPStreamState: Sendable {
    var task: URLSessionDataTask?
    var response: IntegrationGateHTTPStreamResponse?
    var responseFailure: IntegrationGateHTTPStreamFailure?
    var responseContinuation: CheckedContinuation<IntegrationGateHTTPStreamResponse, any Error>?
    var bodyContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    var finished = false
}

nonisolated private final class IntegrationGateHTTPStreamStateBox: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: IntegrationGateHTTPStreamState())

    func setTask(_ task: URLSessionDataTask) {
        let shouldCancel = self.lock.withLock { state in
            guard !state.finished else {
                return true
            }
            state.task = task
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func setBodyContinuation(_ continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        let failure = self.lock.withLock { state -> IntegrationGateHTTPStreamFailure? in
            if let responseFailure = state.responseFailure {
                return responseFailure
            }
            guard !state.finished else { return nil }
            state.bodyContinuation = continuation
            return nil
        }
        if let failure {
            continuation.finish(throwing: failure.error)
        }
    }

    func waitForResponse() async throws -> IntegrationGateHTTPStreamResponse {
        try await withCheckedThrowingContinuation { continuation in
            let immediate = self.lock.withLock { state -> Result<IntegrationGateHTTPStreamResponse, IntegrationGateHTTPStreamFailure>? in
                if let response = state.response {
                    return .success(response)
                }
                if let failure = state.responseFailure {
                    return .failure(failure)
                }
                state.responseContinuation = continuation
                return nil
            }
            if let immediate {
                switch immediate {
                case .success(let response):
                    continuation.resume(returning: response)
                case .failure(let failure):
                    continuation.resume(throwing: failure.error)
                }
            }
        }
    }

    func receive(response: IntegrationGateHTTPStreamResponse) {
        let continuation = self.lock.withLock { state -> CheckedContinuation<IntegrationGateHTTPStreamResponse, any Error>? in
            guard !state.finished, state.response == nil, state.responseFailure == nil else {
                return nil
            }
            state.response = response
            let continuation = state.responseContinuation
            state.responseContinuation = nil
            return continuation
        }
        continuation?.resume(returning: response)
    }

    func receive(data: Data) {
        self.lock.withLock { state in
            guard !state.finished, let continuation = state.bodyContinuation else {
                return
            }
            _ = continuation.yield(data)
        }
    }

    func cancelTask(throwing failure: IntegrationGateHTTPStreamFailure) {
        let task = self.lock.withLock { state in
            state.task
        }
        task?.cancel()
        self.finish(throwing: failure)
    }

    func finish(throwing failure: IntegrationGateHTTPStreamFailure? = nil) {
        let completions = self.lock.withLock { state -> (
            AsyncThrowingStream<Data, Error>.Continuation?,
            CheckedContinuation<IntegrationGateHTTPStreamResponse, any Error>?,
            IntegrationGateHTTPStreamFailure?
        ) in
            guard !state.finished else {
                return (nil, nil, nil)
            }
            state.finished = true
            state.task = nil
            let bodyContinuation = state.bodyContinuation
            state.bodyContinuation = nil

            let responseContinuation: CheckedContinuation<IntegrationGateHTTPStreamResponse, any Error>?
            let responseFailure: IntegrationGateHTTPStreamFailure?
            if state.response == nil {
                responseFailure = failure ?? .requestFailed
                state.responseFailure = responseFailure
                responseContinuation = state.responseContinuation
                state.responseContinuation = nil
            } else {
                responseFailure = failure
                responseContinuation = nil
            }
            return (bodyContinuation, responseContinuation, responseFailure)
        }

        if let failure = completions.2 {
            completions.0?.finish(throwing: failure.error)
            completions.1?.resume(throwing: failure.error)
        } else {
            completions.0?.finish()
        }
    }
}

nonisolated private struct IntegrationGateHTTPDataTaskReader: Sendable {
    var task: URLSessionDataTask
    var stream: AsyncThrowingStream<Data, Error>
    private let state: IntegrationGateHTTPStreamStateBox
    private let delegate: IntegrationGateHTTPStreamDelegate

    init(
        task: URLSessionDataTask,
        stream: AsyncThrowingStream<Data, Error>,
        state: IntegrationGateHTTPStreamStateBox,
        delegate: IntegrationGateHTTPStreamDelegate
    ) {
        self.task = task
        self.stream = stream
        self.state = state
        self.delegate = delegate
    }

    func start() {
        self.task.resume()
    }

    func response() async throws -> IntegrationGateHTTPStreamResponse {
        try await self.state.waitForResponse()
    }

    func cancel(throwing failure: IntegrationGateHTTPStreamFailure) {
        self.task.cancel()
        self.state.finish(throwing: failure)
        self.delegate.unregister(taskIdentifier: self.task.taskIdentifier)
    }
}

// NSObject URLSession delegates cross executor boundaries; all mutable state and
// yield-vs-finish decisions are serialized behind Sendable unfair-lock boxes
// keyed by task identifier.
nonisolated private final class IntegrationGateHTTPStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let states = OSAllocatedUnfairLock(initialState: [Int: IntegrationGateHTTPStreamStateBox]())

    func reader(for request: URLRequest, session: URLSession) -> IntegrationGateHTTPDataTaskReader {
        let state = IntegrationGateHTTPStreamStateBox()
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            state.setBodyContinuation(continuation)
            continuation.onTermination = { @Sendable _ in
                state.cancelTask(throwing: .cancelled)
            }
        }
        let task = session.dataTask(with: request)
        state.setTask(task)
        self.states.withLock { states in
            states[task.taskIdentifier] = state
        }
        return IntegrationGateHTTPDataTaskReader(
            task: task,
            stream: stream,
            state: state,
            delegate: self
        )
    }

    func unregister(taskIdentifier: Int) {
        self.states.withLock { states in
            states.removeValue(forKey: taskIdentifier)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let state = self.state(for: dataTask) else {
            completionHandler(.allow)
            return
        }
        guard let response = response as? HTTPURLResponse else {
            state.finish(throwing: .requestFailed)
            completionHandler(.cancel)
            return
        }
        state.receive(response: IntegrationGateHTTPStreamResponse(response))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        self.state(for: dataTask)?.receive(data: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let state = self.removeState(for: task) else { return }
        if error == nil {
            state.finish()
        } else {
            state.finish(throwing: .requestFailed)
        }
    }

    private func state(for task: URLSessionTask) -> IntegrationGateHTTPStreamStateBox? {
        self.states.withLock { states in
            states[task.taskIdentifier]
        }
    }

    private func removeState(for task: URLSessionTask) -> IntegrationGateHTTPStreamStateBox? {
        self.states.withLock { states in
            states.removeValue(forKey: task.taskIdentifier)
        }
    }
}

@MainActor
final class IntegrationGateHTTPClient {
    private let tunnelManager: TunnelManager
    private let streamDelegate: IntegrationGateHTTPStreamDelegate
    private(set) var session: URLSession
    private let now: @MainActor @Sendable () -> Date
    private(set) var activeGateIssuedRequestCount = 0

    static func productionSessionConfiguration() -> URLSessionConfiguration {
        .ephemeral
    }

    init(
        tunnelManager: TunnelManager,
        sessionConfiguration: URLSessionConfiguration = IntegrationGateHTTPClient.productionSessionConfiguration(),
        now: @escaping @MainActor @Sendable () -> Date = Date.init
    ) {
        self.tunnelManager = tunnelManager
        let streamDelegate = IntegrationGateHTTPStreamDelegate()
        self.streamDelegate = streamDelegate
        self.session = URLSession(
            configuration: sessionConfiguration,
            delegate: streamDelegate,
            delegateQueue: nil
        )
        self.now = now
    }

    func shutdown() {
        self.session.invalidateAndCancel()
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
        let reader = self.streamDelegate.reader(for: request, session: self.session)
        reader.start()
        defer {
            reader.cancel(throwing: .requestFailed)
        }

        let response = try await withTaskCancellationHandler {
            try await reader.response()
        } onCancel: {
            reader.cancel(throwing: .cancelled)
        }
        try ceiling.check(at: self.now())
        guard response.statusCode == 206 else {
            return IntegrationGateRangeResponse(
                outcome: IntegrationGateHTTPOutcome(
                    statusCode: response.statusCode,
                    errorBucket: IntegrationGateReasonCode.rangeStatusMismatch.rawValue,
                    byteCount: 0,
                    durationMillis: Self.durationMillis(from: startedAt, to: self.now())
                ),
                contentRange: nil,
                sha256Hex: ""
            )
        }
        guard let contentRangeHeader = response.value(forHTTPHeaderField: "Content-Range") else {
            throw IntegrationGateValidationError(.contentRangeMalformed)
        }
        let parsedRange = try IntegrationGateContentRange.parse(
            contentRangeHeader,
            expectedStart: rangeStart,
            expectedLength: rangeLength,
            expectedTotal: expectedTotal,
            contentLengthHeader: response.value(forHTTPHeaderField: "content-length")
        )

        var hasher = SHA256()
        var byteCount: UInt64 = 0
        try await withTaskCancellationHandler {
            for try await chunk in reader.stream {
                guard !chunk.isEmpty else { continue }
                try ceiling.check(at: self.now())
                byteCount += UInt64(chunk.count)
                var start = chunk.startIndex
                while start < chunk.endIndex {
                    let remaining = chunk.distance(from: start, to: chunk.endIndex)
                    let end = chunk.index(start, offsetBy: min(16 * 1024, remaining))
                    hasher.update(data: chunk[start..<end])
                    start = end
                    try ceiling.check(at: self.now())
                }
                if let progress {
                    try await progress(byteCount)
                }
            }
        } onCancel: {
            reader.cancel(throwing: .cancelled)
        }
        try ceiling.check(at: self.now())
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return IntegrationGateRangeResponse(
            outcome: IntegrationGateHTTPOutcome(
                statusCode: response.statusCode,
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
