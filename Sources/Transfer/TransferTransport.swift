// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated final class TransferTransport: @unchecked Sendable {
    private let session: URLSession
    private let admission: @Sendable (TransferResolvedEndpoint) async -> Bool
    private let requestAdmission: @Sendable (
        TransferResolvedEndpoint,
        @Sendable () -> Void
    ) async -> Bool

    init(
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        admission: @escaping @Sendable (TransferResolvedEndpoint) async -> Bool = { _ in true },
        requestAdmission: @escaping @Sendable (
            TransferResolvedEndpoint,
            @Sendable () -> Void
        ) async -> Bool = { _, start in start(); return true }
    ) {
        sessionConfiguration.timeoutIntervalForRequest = 60
        sessionConfiguration.timeoutIntervalForResource = 30 * 60
        self.session = URLSession(configuration: sessionConfiguration)
        self.admission = admission
        self.requestAdmission = requestAdmission
    }

    func send(
        item: TransferStoredItem,
        bodyURL: URL,
        endpoint: TransferResolvedEndpoint,
        phase: TransferEndpointPhase
    ) async -> TransferHTTPResult {
        guard await self.admission(endpoint) else {
            return TransferHTTPResult(statusCode: nil, issue: .cancelled)
        }
        let path: String
        switch phase {
        case .observerIngest, .save:
            path = item.manifest.endpoint.path
        case .start:
            path = item.manifest.endpoint.startPath ?? item.manifest.endpoint.path
        }
        guard let url = endpoint.url(path: path) else {
            return TransferHTTPResult(statusCode: nil, issue: .transport("invalid url"))
        }

        guard await self.admission(endpoint) else {
            return TransferHTTPResult(statusCode: nil, issue: .cancelled)
        }
        let upload = TransferUploadContinuation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard upload.install(continuation) else { return }
                Task {
                    let admitted = await self.requestAdmission(endpoint) {
                        var request = URLRequest(url: url)
                        request.httpMethod = "POST"
                        switch phase {
                        case .observerIngest, .save:
                            request.setValue(
                                "multipart/form-data; boundary=\(Self.boundary(for: item.manifest.itemID))",
                                forHTTPHeaderField: "Content-Type"
                            )
                            if phase == .observerIngest {
                                request.setValue(
                                    ObserverServerURL.ingestProtocolVersion,
                                    forHTTPHeaderField: ObserverServerURL.protocolVersionHeaderName
                                )
                            }
                        case .start:
                            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        }
                        request.attachLoopbackCapability()
                        let task = self.session.uploadTask(with: request, fromFile: bodyURL) { data, response, error in
                            upload.finish(Self.result(data: data, response: response, error: error))
                        }
                        // The production admission callback holds the credential
                        // mutation lock through task publication, without an await
                        // between the ownership check and this resume.
                        upload.start(task)
                    }
                    if !admitted { upload.finish(TransferHTTPResult(statusCode: nil, issue: .cancelled)) }
                }
            }
        } onCancel: {
            upload.cancel()
        }
    }

    private static func result(data: Data?, response: URLResponse?, error: Error?) -> TransferHTTPResult {
        if let error {
            if let urlError = error as? URLError {
                switch urlError.code {
                case .timedOut:
                    return TransferHTTPResult(statusCode: nil, issue: .timeout)
                case .cancelled:
                    return TransferHTTPResult(statusCode: nil, issue: .cancelled)
                default:
                    return TransferHTTPResult(statusCode: nil, issue: .transport(urlError.localizedDescription))
                }
            }
            return TransferHTTPResult(statusCode: nil, issue: .transport(String(describing: error)))
        }
        return TransferHTTPResult(statusCode: (response as? HTTPURLResponse)?.statusCode, data: data ?? Data())
    }

    static func boundary(for itemID: UUID) -> String {
        "Boundary-\(itemID.uuidString)"
    }
}

/// Bridges Foundation's resumable upload task to the async transport API. The
/// task must start synchronously inside credential admission; cancellation and
/// completion exchange the continuation once under this lock.
private nonisolated final class TransferUploadContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TransferHTTPResult, Never>?
    private var task: URLSessionUploadTask?
    private var completed = false

    func install(_ continuation: CheckedContinuation<TransferHTTPResult, Never>) -> Bool {
        let installed = self.lock.withLock {
            guard !self.completed else { return false }
            self.continuation = continuation
            return true
        }
        if !installed { continuation.resume(returning: TransferHTTPResult(statusCode: nil, issue: .cancelled)) }
        return installed
    }

    func start(_ task: URLSessionUploadTask) {
        self.lock.withLock {
            guard !self.completed else { task.cancel(); return }
            self.task = task
            task.resume()
        }
    }

    func finish(_ result: TransferHTTPResult) {
        let continuation = self.lock.withLock {
            guard !self.completed else { return nil as CheckedContinuation<TransferHTTPResult, Never>? }
            self.completed = true
            self.task = nil
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }

    func cancel() {
        let pending = self.lock.withLock {
            guard !self.completed else { return (nil as URLSessionUploadTask?, nil as CheckedContinuation<TransferHTTPResult, Never>?) }
            self.completed = true
            let pending = (self.task, self.continuation)
            self.task = nil
            self.continuation = nil
            return pending
        }
        pending.0?.cancel()
        pending.1?.resume(returning: TransferHTTPResult(statusCode: nil, issue: .cancelled))
    }
}
