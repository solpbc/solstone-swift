// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// A multipart upload body streamed directly from a custody payload file without
/// materializing a second full-file copy on disk. Its wire byte length is known
/// up front so the request carries an exact `Content-Length` header.
nonisolated struct TransferStreamedBody: Equatable, Sendable {
    static let defaultChunkSize = 64 * 1024

    let prefix: Data
    let fileURL: URL
    let fileLength: Int64
    let suffix: Data

    var contentLength: Int64 {
        Int64(self.prefix.count) + self.fileLength + Int64(self.suffix.count)
    }

    /// Streams `prefix`, `fileURL` in chunks of at most `chunkSize` bytes, and `suffix`
    /// to `write`. Stops and returns `false` if opening or reading the file fails, the file
    /// ends before `fileLength` bytes are read, or `write` returns `false`.
    func stream(
        chunkSize: Int = Self.defaultChunkSize,
        write: (Data) -> Bool
    ) -> Bool {
        guard write(self.prefix) else { return false }
        guard let handle = try? FileHandle(forReadingFrom: self.fileURL) else { return false }
        defer { try? handle.close() }
        var sent: Int64 = 0
        while sent < self.fileLength {
            let want = Int(min(Int64(chunkSize), self.fileLength - sent))
            guard let chunk = try? handle.read(upToCount: want),
                  !chunk.isEmpty,
                  chunk.count <= want
            else {
                return false
            }
            guard write(chunk) else { return false }
            sent += Int64(chunk.count)
        }
        return write(self.suffix)
    }

    /// Materializes the streamed bytes in memory. Intended for test verification only.
    func materialize() throws -> Data {
        var output = Data()
        output.reserveCapacity(Int(min(self.contentLength, Int64(Int.max))))
        let ok = self.stream { chunk in
            output.append(chunk)
            return true
        }
        guard ok else {
            throw TransferBodyBuildError.missingPayload(self.fileURL.lastPathComponent)
        }
        return output
    }
}

nonisolated enum TransferUploadBody: Sendable {
    case file(URL)
    case streamed(TransferStreamedBody)
}

nonisolated final class TransferTransport: @unchecked Sendable {
    private let session: URLSession
    private let sessionDelegate: TransferTransportSessionDelegate
    private let admission: @Sendable (TransferResolvedEndpoint) async -> Bool
    private let requestAdmission: @Sendable (
        TransferResolvedEndpoint,
        @Sendable () -> Void
    ) async -> Bool
    private let localeLanguage: @Sendable () -> String

    init(
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        admission: @escaping @Sendable (TransferResolvedEndpoint) async -> Bool = { _ in true },
        requestAdmission: @escaping @Sendable (
            TransferResolvedEndpoint,
            @Sendable () -> Void
        ) async -> Bool = { _, start in start(); return true },
        localeLanguage: @escaping @Sendable () -> String = { AppStrings.language }
    ) {
        // A stalled request gives up after 60 seconds without data. A whole upload keeps the
        // system's own limit of days, so a long Apple Health export that keeps moving finishes.
        sessionConfiguration.timeoutIntervalForRequest = 60
        let delegate = TransferTransportSessionDelegate()
        self.sessionDelegate = delegate
        self.session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
        self.admission = admission
        self.requestAdmission = requestAdmission
        self.localeLanguage = localeLanguage
    }

    func send(
        item: TransferStoredItem,
        bodyURL: URL,
        endpoint: TransferResolvedEndpoint,
        phase: TransferEndpointPhase
    ) async -> TransferHTTPResult {
        await self.send(item: item, body: .file(bodyURL), endpoint: endpoint, phase: phase)
    }

    func send(
        item: TransferStoredItem,
        body: TransferUploadBody,
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
                        request.attachJournalLocale(language: self.localeLanguage())
                        switch body {
                        case .file(let bodyURL):
                            let task = self.session.uploadTask(with: request, fromFile: bodyURL) { data, response, error in
                                upload.finish(Self.result(data: data, response: response, error: error))
                            }
                            // The production admission callback holds the credential
                            // mutation lock through task publication, without an await
                            // between the ownership check and this resume.
                            upload.start(task)
                        case .streamed(let streamedBody):
                            request.setValue("\(streamedBody.contentLength)", forHTTPHeaderField: "Content-Length")
                            let task = self.session.uploadTask(withStreamedRequest: request)
                            let taskID = task.taskIdentifier
                            self.sessionDelegate.register(taskID: taskID, body: streamedBody, upload: upload)
                            upload.start(task, onCancel: { [sessionDelegate = self.sessionDelegate] in
                                sessionDelegate.cancel(taskID: taskID)
                            })
                        }
                    }
                    if !admitted { upload.finish(TransferHTTPResult(statusCode: nil, issue: .cancelled)) }
                }
            }
        } onCancel: {
            upload.cancel()
        }
    }

    fileprivate static func result(data: Data?, response: URLResponse?, error: Error?) -> TransferHTTPResult {
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
        let httpResponse = response as? HTTPURLResponse
        let loopbackRefused = httpResponse?.value(forHTTPHeaderField: "X-SPL-Loopback-Refused") != nil
        return TransferHTTPResult(
            statusCode: httpResponse?.statusCode,
            data: data ?? Data(),
            loopbackRefused: loopbackRefused
        )
    }

    static func boundary(for itemID: UUID) -> String {
        "Boundary-\(itemID.uuidString)"
    }

    func invalidateAndCancel() {
        self.sessionDelegate.cancelAll()
        self.session.invalidateAndCancel()
    }
}

private nonisolated final class TransferOutputStreamBox: @unchecked Sendable {
    let stream: OutputStream
    init(_ stream: OutputStream) {
        self.stream = stream
    }
}

private nonisolated final class TransferTransportSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let maximumResponseBytes = 1024 * 1024

    private struct StreamedTaskEntry {
        let body: TransferStreamedBody
        let upload: TransferUploadContinuation
        var handedOver = false
        var inputStream: InputStream?
        var response: URLResponse?
        var data = Data()
        var overflowed = false
    }

    private let lock = NSLock()
    private var streamedTasks: [Int: StreamedTaskEntry] = [:]

    func register(taskID: Int, body: TransferStreamedBody, upload: TransferUploadContinuation) {
        self.lock.withLock {
            self.streamedTasks[taskID] = StreamedTaskEntry(body: body, upload: upload)
        }
    }

    func cancel(taskID: Int) {
        let inputStream: InputStream? = self.lock.withLock {
            self.streamedTasks.removeValue(forKey: taskID)?.inputStream
        }
        inputStream?.close()
    }

    func cancelAll() {
        let entries: [StreamedTaskEntry] = self.lock.withLock {
            let values = Array(self.streamedTasks.values)
            self.streamedTasks.removeAll()
            return values
        }
        for entry in entries {
            entry.inputStream?.close()
            entry.upload.finish(TransferHTTPResult(statusCode: nil, issue: .cancelled))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping (InputStream?) -> Void
    ) {
        let taskID = task.taskIdentifier
        let body: TransferStreamedBody? = self.lock.withLock {
            guard var entry = self.streamedTasks[taskID], !entry.handedOver else {
                return nil
            }
            entry.handedOver = true
            self.streamedTasks[taskID] = entry
            return entry.body
        }
        guard let body else {
            completionHandler(nil)
            return
        }

        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(
            withBufferSize: TransferStreamedBody.defaultChunkSize,
            inputStream: &input,
            outputStream: &output
        )
        guard let input, let output else {
            completionHandler(nil)
            return
        }

        let stillActive: Bool = self.lock.withLock {
            guard var entry = self.streamedTasks[taskID] else { return false }
            entry.inputStream = input
            self.streamedTasks[taskID] = entry
            return true
        }
        guard stillActive else {
            input.close()
            output.close()
            completionHandler(nil)
            return
        }

        let box = TransferOutputStreamBox(output)
        let writer = Thread {
            let output = box.stream
            output.open()
            defer { output.close() }
            _ = body.stream { chunk in
                var offset = 0
                while offset < chunk.count {
                    let written = chunk.withUnsafeBytes { raw -> Int in
                        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                        return output.write(base + offset, maxLength: chunk.count - offset)
                    }
                    if written <= 0 { return false }
                    offset += written
                }
                return true
            }
        }
        writer.name = "solstone.transfer.stream-body"
        writer.start()
        completionHandler(input)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        self.lock.withLock {
            self.streamedTasks[dataTask.taskIdentifier]?.response = response
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let shouldCancel: Bool = self.lock.withLock {
            guard var entry = self.streamedTasks[dataTask.taskIdentifier] else { return false }
            if entry.data.count + data.count > Self.maximumResponseBytes {
                entry.overflowed = true
                self.streamedTasks[dataTask.taskIdentifier] = entry
                return true
            }
            entry.data.append(data)
            self.streamedTasks[dataTask.taskIdentifier] = entry
            return false
        }
        if shouldCancel {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let entry: StreamedTaskEntry? = self.lock.withLock {
            self.streamedTasks.removeValue(forKey: task.taskIdentifier)
        }
        guard let entry else { return }
        entry.inputStream?.close()
        if entry.overflowed {
            entry.upload.finish(TransferHTTPResult(statusCode: nil, issue: .transport("response too large")))
            return
        }
        entry.upload.finish(TransferTransport.result(data: entry.data, response: entry.response, error: error))
    }
}

/// Bridges Foundation's resumable upload task to the async transport API. The
/// task must start synchronously inside credential admission; cancellation and
/// completion exchange the continuation once under this lock.
private nonisolated final class TransferUploadContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TransferHTTPResult, Never>?
    private var task: URLSessionUploadTask?
    private var cancelCleanup: (@Sendable () -> Void)?
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

    func start(_ task: URLSessionUploadTask, onCancel: (@Sendable () -> Void)? = nil) {
        let alreadyCompleted: Bool = self.lock.withLock {
            guard !self.completed else { return true }
            self.task = task
            self.cancelCleanup = onCancel
            task.resume()
            return false
        }
        if alreadyCompleted {
            onCancel?()
            task.cancel()
        }
    }

    func finish(_ result: TransferHTTPResult) {
        let continuation = self.lock.withLock {
            guard !self.completed else { return nil as CheckedContinuation<TransferHTTPResult, Never>? }
            self.completed = true
            self.task = nil
            self.cancelCleanup = nil
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }

    func cancel() {
        let pending = self.lock.withLock {
            guard !self.completed else {
                return (
                    nil as URLSessionUploadTask?,
                    nil as (@Sendable () -> Void)?,
                    nil as CheckedContinuation<TransferHTTPResult, Never>?
                )
            }
            self.completed = true
            let pending = (self.task, self.cancelCleanup, self.continuation)
            self.task = nil
            self.cancelCleanup = nil
            self.continuation = nil
            return pending
        }
        pending.1?()
        pending.0?.cancel()
        pending.2?.resume(returning: TransferHTTPResult(statusCode: nil, issue: .cancelled))
    }
}
