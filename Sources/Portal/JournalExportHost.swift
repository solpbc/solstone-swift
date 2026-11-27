// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Darwin
import Foundation
import Observation
import os
import UIKit
import UniformTypeIdentifiers
import WebKit

private let exportHostLog = Logger(subsystem: "app.solstone.swift", category: "export-host")

/// The journal's native export-save contract (version 2), packaged alongside `import-host-contract.json`.
nonisolated struct JournalExportHostContract: Decodable, Equatable, Sendable {
    let version: Int
    let capability: String
    let start: String
    let status: String
    let pause: String
    let resume: String
    let cancel: String
    let reveal: String
    let deviceSpace: String
    let event: String
    let unsupported: String

    static func load(bundle: Bundle = Bundle(for: AppDelegate.self)) -> (contract: Self, json: String)? {
        guard let url = bundle.url(forResource: "export-host-contract", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let contract = try? JSONDecoder().decode(Self.self, from: data),
              contract.version == 2,
              !contract.capability.isEmpty,
              !contract.start.isEmpty,
              !contract.status.isEmpty,
              !contract.pause.isEmpty,
              !contract.resume.isEmpty,
              !contract.cancel.isEmpty,
              !contract.reveal.isEmpty,
              !contract.deviceSpace.isEmpty,
              !contract.event.isEmpty,
              !contract.unsupported.isEmpty,
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return (contract, json.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Validated `export.start` request from `/app/export/`.
nonisolated struct JournalExportStartRequest: Equatable, Sendable {
    let exportID: String
    let downloadPath: String
    let filename: String
    let sizeBytes: Int64
    let sha256: String
    let etag: String
    let mode: String?

    static func parse(_ message: [String: Any]) -> Self? {
        guard let exportID = message["export_id"] as? String,
              Self.isSafeExportID(exportID),
              let downloadPath = message["download_path"] as? String,
              downloadPath == "/app/export/api/ready/\(exportID)/download",
              let rawFilename = message["filename"] as? String,
              let sizeNumber = message["size_bytes"] as? NSNumber,
              CFGetTypeID(sizeNumber) != CFBooleanGetTypeID(),
              let sha256 = message["sha256"] as? String,
              Self.isValidSHA256(sha256),
              let etag = message["etag"] as? String, !etag.isEmpty, etag.utf8.count <= 256
        else { return nil }
        let sizeBytes = sizeNumber.int64Value
        guard sizeBytes > 0 else { return nil }
        return Self(
            exportID: exportID,
            downloadPath: downloadPath,
            filename: Self.sanitizeFilename(rawFilename),
            sizeBytes: sizeBytes,
            sha256: sha256.lowercased(),
            etag: etag,
            mode: message["mode"] as? String
        )
    }

    static func isSafeExportID(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count) && value.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
        }
    }

    static func isValidSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.unicodeScalars.allSatisfy {
            ("0"..."9").contains($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0)
        }
    }

    static func sanitizeFilename(_ raw: String) -> String {
        let leaf = (raw as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = !leaf.isEmpty
            && !leaf.hasPrefix(".")
            && leaf.utf8.count <= 200
            && !leaf.contains("/")
            && !leaf.contains(":")
            && !leaf.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        return ok ? leaf : "solstone-journal.zip"
    }
}

/// Snapshot reported to `/app/export/` via reply and `solstone-journal-export-status`.
nonisolated struct JournalExportStatusSnapshot: Equatable, Sendable {
    var exportID: String?
    var phase: String
    var platform: String
    var bytesWritten: Int64 = 0
    var totalBytes: Int64 = 0
    var rateBytesPerSec: Double?
    var transport: String?
    var destinationDisplay: String?
    var canReveal: Bool = false
    var verified: Bool = false
    var pauseReason: String?
    var errorCode: String?
    var requiredBytes: Int64?
    var availableBytes: Int64?
    var mode: String?

    static func idle(platform: String) -> Self {
        Self(phase: "idle", platform: platform)
    }

    func toJSON(replyID: String? = nil) -> [String: Any] {
        var obj: [String: Any] = [
            "phase": self.phase,
            "platform": self.platform,
            "bytes_written": self.bytesWritten,
            "total_bytes": self.totalBytes,
            "can_reveal": self.canReveal,
            "verified": self.verified,
        ]
        if let replyID { obj["id"] = replyID }
        if let exportID { obj["export_id"] = exportID }
        if let rateBytesPerSec, rateBytesPerSec.isFinite, rateBytesPerSec >= 0 {
            obj["rate_bytes_per_sec"] = rateBytesPerSec
        }
        if let transport { obj["transport"] = transport }
        if let destinationDisplay { obj["destination_display"] = destinationDisplay }
        if let pauseReason { obj["pause_reason"] = pauseReason }
        if let errorCode { obj["error_code"] = errorCode }
        if let requiredBytes { obj["required_bytes"] = requiredBytes }
        if let availableBytes { obj["available_bytes"] = availableBytes }
        if let mode { obj["mode"] = mode }
        return obj
    }
}

nonisolated enum JournalExportVolumeSpace {
    /// Returns confirmed available capacity or `nil` when a Files provider withholds capacity.
    static func availableBytes(for folderURL: URL) -> Int64? {
        guard let values = try? folderURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important >= 0 {
            return important
        }
        if let available = values.volumeAvailableCapacity, available >= 0 {
            return Int64(available)
        }
        return nil
    }

    static func requiredBytes(for exportSizeBytes: Int64) -> Int64 {
        let headroom = min(Int64(64 * 1024 * 1024), max(Int64(1 * 1024 * 1024), exportSizeBytes / 100))
        let (sum, overflow) = exportSizeBytes.addingReportingOverflow(headroom)
        return overflow ? Int64.max : sum
    }
}

/// Low-memory streaming HTTP chunk reader backed by `URLSessionDataDelegate`.
private final class IOSExportStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var responseContinuation: CheckedContinuation<(HTTPURLResponse, AsyncThrowingStream<Data, Error>), Error>?
    private var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var stream: AsyncThrowingStream<Data, Error>?
    private var deliveredResponse = false

    nonisolated func awaitResponse() async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        try await withCheckedThrowingContinuation { continuation in
            self.lock.lock()
            let (s, c) = AsyncThrowingStream.makeStream(of: Data.self, throwing: Error.self)
            self.stream = s
            self.streamContinuation = c
            self.responseContinuation = continuation
            self.lock.unlock()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            self.failAll(URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        self.lock.lock()
        let cont = self.responseContinuation
        self.responseContinuation = nil
        let stream = self.stream
        self.deliveredResponse = true
        self.lock.unlock()
        if let cont, let stream {
            cont.resume(returning: (http, stream))
        }
        completionHandler(.allow)
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        self.lock.lock()
        let c = self.streamContinuation
        self.lock.unlock()
        c?.yield(data)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            self.failAll(error)
        } else {
            self.lock.lock()
            if !self.deliveredResponse, let cont = self.responseContinuation {
                self.responseContinuation = nil
                let c = self.streamContinuation
                self.streamContinuation = nil
                self.lock.unlock()
                cont.resume(throwing: URLError(.badServerResponse))
                c?.finish(throwing: URLError(.badServerResponse))
                return
            }
            let c = self.streamContinuation
            self.streamContinuation = nil
            self.lock.unlock()
            c?.finish()
        }
    }

    private nonisolated func failAll(_ error: Error) {
        self.lock.lock()
        let cont = self.responseContinuation
        self.responseContinuation = nil
        let c = self.streamContinuation
        self.streamContinuation = nil
        self.lock.unlock()
        cont?.resume(throwing: error)
        c?.finish(throwing: error)
    }
}

/// Presents the iOS/iPadOS folder picker (`UIDocumentPickerViewController(forOpeningContentTypes: [.folder])`).
@MainActor
final class JournalExportFolderPicker: NSObject, UIDocumentPickerDelegate {
    private var continuation: CheckedContinuation<URL?, Never>?
    private var retainedSelf: JournalExportFolderPicker?

    func present(over presenter: UIViewController?) async -> URL? {
        guard let presenter else { return nil }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = self
        self.retainedSelf = self
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            var top = presenter
            while let presented = top.presentedViewController, !presented.isBeingDismissed {
                top = presented
            }
            top.present(picker, animated: true)
        }
    }

    private func finish(_ url: URL?) {
        guard let continuation = self.continuation else { return }
        self.continuation = nil
        self.retainedSelf = nil
        continuation.resume(returning: url)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        self.finish(urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        self.finish(nil)
    }
}

typealias JournalExportFolderPickerPresenter = @MainActor () async -> URL?
typealias JournalExportVolumeSpaceProbe = @Sendable (_ url: URL) -> Int64?
typealias JournalExportRequestPreparer = @Sendable (_ request: inout URLRequest) -> Void

/// App-scoped manager owning native journal export downloads on iPhone and iPad.
/// Streams directly into a resumable sibling `.part` inside the owner's chosen Files folder
/// with zero app-sandbox double copy, sustains background execution via `BGContinuedProcessingTask`,
/// verifies SHA-256 on disk, and preserves preexisting documents.
@MainActor
@Observable
final class JournalExportTransferManager {
    private struct ActiveTransfer {
        let request: JournalExportStartRequest
        let folderURL: URL
        let accessedSecurityScope: Bool
        let partURL: URL
        let initialTransport: String?
        var bytesWritten: Int64
        var task: Task<Void, Never>?
        var session: URLSession?
        var dataTask: URLSessionDataTask?
        var userPaused = false
        var userCancelled = false
    }

    @ObservationIgnored private let platformName: String
    @ObservationIgnored private let prepareRequest: JournalExportRequestPreparer
    @ObservationIgnored private let volumeSpaceProbe: JournalExportVolumeSpaceProbe
    @ObservationIgnored private var active: ActiveTransfer?
    @ObservationIgnored private var statusListeners: [UUID: @MainActor (JournalExportStatusSnapshot) -> Void] = [:]
    @ObservationIgnored private var lastBaseURLProvider: (@MainActor () -> URL?)?
    @ObservationIgnored private var lastTransportProvider: (@MainActor () -> String?)?
    @ObservationIgnored private var lastExportFilename: String = ""
    @ObservationIgnored weak var backgroundCoordinator: ExportBackgroundDownloadCoordinator?

    private(set) var snapshot: JournalExportStatusSnapshot

    init(
        platformName: String = UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios",
        prepareRequest: @escaping JournalExportRequestPreparer = { $0.attachLoopbackCapability() },
        volumeSpaceProbe: @escaping JournalExportVolumeSpaceProbe = JournalExportVolumeSpace.availableBytes(for:)
    ) {
        self.platformName = platformName
        self.prepareRequest = prepareRequest
        self.volumeSpaceProbe = volumeSpaceProbe
        self.snapshot = .idle(platform: platformName)
    }

    var activeBackgroundTarget: ExportBackgroundDownloadTarget? {
        guard let current = self.active else { return nil }
        return ExportBackgroundDownloadTarget(
            exportID: current.request.exportID,
            filename: current.request.filename,
            bytesWritten: current.bytesWritten,
            bytesTotal: current.request.sizeBytes,
            phase: self.snapshot.phase
        )
    }

    func addStatusListener(_ listener: @escaping @MainActor (JournalExportStatusSnapshot) -> Void) -> UUID {
        let token = UUID()
        self.statusListeners[token] = listener
        return token
    }

    func removeStatusListener(_ token: UUID) {
        self.statusListeners.removeValue(forKey: token)
    }

    private func publish(_ next: JournalExportStatusSnapshot) {
        self.snapshot = next
        if let target = self.activeBackgroundTarget {
            self.backgroundCoordinator?.handleProgress(target)
        } else if let exportID = next.exportID ?? (self.lastExportFilename.isEmpty ? nil : "") {
            self.backgroundCoordinator?.handleProgress(ExportBackgroundDownloadTarget(
                exportID: exportID,
                filename: self.lastExportFilename,
                bytesWritten: next.bytesWritten,
                bytesTotal: max(next.totalBytes, next.bytesWritten),
                phase: next.phase
            ))
        }
        for listener in self.statusListeners.values {
            listener(next)
        }
    }

    nonisolated static func partURL(in folderURL: URL, exportID: String) -> URL {
        folderURL.appendingPathComponent(".solstone-export-\(exportID).part")
    }

    nonisolated static func uniqueDestinationURL(in folderURL: URL, filename: String) -> URL {
        let initial = folderURL.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: initial.path) {
            return initial
        }
        let ext = initial.pathExtension
        let stem = ext.isEmpty ? filename : String(filename.dropLast(ext.count + 1))
        for index in 2...999 {
            let candidateName = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            let candidate = folderURL.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        let fallbackName = ext.isEmpty
            ? "\(stem)-\(UUID().uuidString.prefix(8))"
            : "\(stem)-\(UUID().uuidString.prefix(8)).\(ext)"
        return folderURL.appendingPathComponent(fallbackName)
    }

    func deviceSpaceSnapshot() -> [String: Any] {
        var out: [String: Any] = ["platform": self.platformName]
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let free = self.volumeSpaceProbe(docs) {
            out["free_bytes"] = free
        }
        return out
    }

    func start(
        request: JournalExportStartRequest,
        pickFolder: JournalExportFolderPickerPresenter,
        baseURLProvider: @escaping @MainActor () -> URL?,
        transportProvider: @escaping @MainActor () -> String?
    ) async -> JournalExportStatusSnapshot {
        if let current = self.active, current.request.exportID == request.exportID,
           self.snapshot.phase == "transferring" || self.snapshot.phase == "verifying" {
            return self.snapshot
        }
        if let prior = self.active {
            self.cancelActiveInternal(prior, deletePart: true)
            self.active = nil
        }
        self.lastBaseURLProvider = baseURLProvider
        self.lastTransportProvider = transportProvider
        self.lastExportFilename = request.filename

        self.publish(JournalExportStatusSnapshot(
            exportID: request.exportID,
            phase: "picking",
            platform: self.platformName,
            bytesWritten: 0,
            totalBytes: request.sizeBytes,
            transport: transportProvider(),
            mode: request.mode
        ))

        guard let folderURL = await pickFolder() else {
            self.publish(.idle(platform: self.platformName))
            return self.snapshot
        }

        let accessed = folderURL.startAccessingSecurityScopedResource()
        let required = JournalExportVolumeSpace.requiredBytes(for: request.sizeBytes)
        // Honest Files provider space check: only refuse when the provider reports a concrete capacity below required.
        if let free = self.volumeSpaceProbe(folderURL), free < required {
            if accessed { folderURL.stopAccessingSecurityScopedResource() }
            let failed = JournalExportStatusSnapshot(
                exportID: request.exportID,
                phase: "failed",
                platform: self.platformName,
                bytesWritten: 0,
                totalBytes: request.sizeBytes,
                transport: transportProvider(),
                destinationDisplay: folderURL.lastPathComponent,
                errorCode: "insufficient_device_space",
                requiredBytes: required,
                availableBytes: free,
                mode: request.mode
            )
            self.publish(failed)
            return failed
        }

        let partURL = Self.partURL(in: folderURL, exportID: request.exportID)
        let transfer = ActiveTransfer(
            request: request,
            folderURL: folderURL,
            accessedSecurityScope: accessed,
            partURL: partURL,
            initialTransport: transportProvider(),
            bytesWritten: 0
        )
        self.active = transfer
        if let target = self.activeBackgroundTarget {
            self.backgroundCoordinator?.submitIfNeeded(target: target)
        }
        self.launchStreamingAttempt()
        return self.snapshot
    }

    func pause(exportID: String?, reason: String = "paused") -> JournalExportStatusSnapshot {
        guard var current = self.active else { return self.snapshot }
        if let exportID, !exportID.isEmpty, current.request.exportID != exportID { return self.snapshot }
        guard self.snapshot.phase == "transferring" else { return self.snapshot }
        current.userPaused = true
        current.dataTask?.cancel()
        current.session?.invalidateAndCancel()
        current.task?.cancel()
        current.dataTask = nil
        current.session = nil
        current.task = nil
        self.active = current
        self.publish(JournalExportStatusSnapshot(
            exportID: current.request.exportID,
            phase: "paused",
            platform: self.platformName,
            bytesWritten: current.bytesWritten,
            totalBytes: current.request.sizeBytes,
            transport: self.lastTransportProvider?(),
            destinationDisplay: "\(current.folderURL.lastPathComponent)/\(current.request.filename)",
            pauseReason: reason,
            mode: current.request.mode
        ))
        return self.snapshot
    }

    func resume(
        exportID: String?,
        baseURLProvider: @escaping @MainActor () -> URL?,
        transportProvider: @escaping @MainActor () -> String?
    ) -> JournalExportStatusSnapshot {
        guard var current = self.active else { return self.snapshot }
        if let exportID, !exportID.isEmpty, current.request.exportID != exportID { return self.snapshot }
        guard self.snapshot.phase == "paused" else { return self.snapshot }
        self.lastBaseURLProvider = baseURLProvider
        self.lastTransportProvider = transportProvider
        self.lastExportFilename = current.request.filename
        current.userPaused = false
        current.userCancelled = false
        self.active = current
        if let target = self.activeBackgroundTarget {
            self.backgroundCoordinator?.submitIfNeeded(target: target)
        }
        self.launchStreamingAttempt()
        return self.snapshot
    }

    func cancel(exportID: String?) -> JournalExportStatusSnapshot {
        if let current = self.active {
            if let exportID, !exportID.isEmpty, current.request.exportID != exportID { return self.snapshot }
            self.cancelActiveInternal(current, deletePart: true)
            self.active = nil
        }
        self.publish(.idle(platform: self.platformName))
        return self.snapshot
    }

    func cancelForUnpair() {
        if let current = self.active {
            self.cancelActiveInternal(current, deletePart: true)
            self.active = nil
        }
        self.publish(.idle(platform: self.platformName))
    }

    func handleTransportChange(newTransport: String?) {
        guard let current = self.active, self.snapshot.phase == "transferring" else { return }
        if current.initialTransport == "local", newTransport == "relay" {
            _ = self.pause(exportID: current.request.exportID, reason: "relay_switched")
        }
    }

    func pauseForBackgroundExpiry() {
        guard let current = self.active, self.snapshot.phase == "transferring" else { return }
        _ = self.pause(exportID: current.request.exportID, reason: "paused")
    }

    private func cancelActiveInternal(_ transfer: ActiveTransfer, deletePart: Bool) {
        var mutable = transfer
        mutable.userCancelled = true
        mutable.dataTask?.cancel()
        mutable.session?.invalidateAndCancel()
        mutable.task?.cancel()
        if deletePart {
            Self.coordinatedRemove(at: transfer.partURL)
        }
        if transfer.accessedSecurityScope {
            transfer.folderURL.stopAccessingSecurityScopedResource()
        }
    }

    private func launchStreamingAttempt() {
        guard var current = self.active else { return }
        guard let baseURL = self.lastBaseURLProvider?(),
              let downloadURL = URL(string: current.request.downloadPath, relativeTo: baseURL)?.absoluteURL
        else {
            self.publish(JournalExportStatusSnapshot(
                exportID: current.request.exportID,
                phase: "paused",
                platform: self.platformName,
                bytesWritten: current.bytesWritten,
                totalBytes: current.request.sizeBytes,
                transport: self.lastTransportProvider?(),
                destinationDisplay: "\(current.folderURL.lastPathComponent)/\(current.request.filename)",
                pauseReason: "disconnected",
                mode: current.request.mode
            ))
            return
        }

        let diskOffset = Self.existingPartSize(at: current.partURL)
        let resumeOffset = (diskOffset > 0 && diskOffset < current.request.sizeBytes) ? diskOffset : 0
        current.bytesWritten = resumeOffset

        let request = current.request
        let partURL = current.partURL
        let folderURL = current.folderURL
        let transportNow = self.lastTransportProvider?()
        let prepare = self.prepareRequest

        self.publish(JournalExportStatusSnapshot(
            exportID: request.exportID,
            phase: "transferring",
            platform: self.platformName,
            bytesWritten: resumeOffset,
            totalBytes: request.sizeBytes,
            transport: transportNow,
            destinationDisplay: "\(folderURL.lastPathComponent)/\(request.filename)",
            mode: request.mode
        ))

        let delegate = IOSExportStreamDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 48
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        var urlRequest = URLRequest(url: downloadURL)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if resumeOffset > 0 {
            urlRequest.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
            urlRequest.setValue(request.etag, forHTTPHeaderField: "If-Range")
        }
        prepare(&urlRequest)

        let dataTask = session.dataTask(with: urlRequest)
        current.session = session
        current.dataTask = dataTask

        let task = Task { [weak self] in
            defer { session.finishTasksAndInvalidate() }
            dataTask.resume()
            do {
                let (http, stream) = try await delegate.awaitResponse()
                let status = http.statusCode

                if status == 401 || status == 403 {
                    Self.coordinatedRemove(at: partURL)
                    self?.finishFailure(exportID: request.exportID, code: "export_requester_revoked")
                    return
                }
                if status == 404 || status == 410 {
                    var bodyData = Data()
                    for try await chunk in stream {
                        if bodyData.count < 8192 { bodyData.append(chunk) }
                    }
                    let serverCode = Self.extractErrorCode(from: bodyData)
                    let mapped = (serverCode == "export_invalidated_by_erasure")
                        ? "export_invalidated_by_erasure"
                        : "export_expired"
                    Self.coordinatedRemove(at: partURL)
                    self?.finishFailure(exportID: request.exportID, code: mapped)
                    return
                }
                if status == 416 {
                    Self.coordinatedRemove(at: partURL)
                    self?.finishFailure(exportID: request.exportID, code: "save_failed")
                    return
                }
                guard status == 200 || status == 206 else {
                    self?.handleStreamDrop(exportID: request.exportID, bytesWritten: resumeOffset)
                    return
                }

                let startOffset: Int64
                if status == 206 {
                    guard Self.matchesContentRange(
                        http.value(forHTTPHeaderField: "Content-Range"),
                        expectedStart: resumeOffset,
                        expectedTotal: request.sizeBytes
                    ) else {
                        Self.coordinatedRemove(at: partURL)
                        self?.finishFailure(exportID: request.exportID, code: "save_failed")
                        return
                    }
                    startOffset = resumeOffset
                } else {
                    startOffset = 0
                }

                let writeResult: Result<Int64, Error> = await Task.detached(priority: .userInitiated) { [weak self] in
                    do {
                        let fd = try Self.openPrivatePartFile(at: partURL, truncate: startOffset == 0)
                        defer { Darwin.close(fd) }
                        if startOffset > 0 {
                            guard Darwin.lseek(fd, off_t(startOffset), SEEK_SET) == off_t(startOffset) else {
                                throw POSIXError(.EIO)
                            }
                        }
                        var written = startOffset
                        var windowStart = ContinuousClock.now
                        var windowBytes: Int64 = 0
                        var lastEmit = ContinuousClock.now
                        for try await chunk in stream {
                            try Task.checkCancellation()
                            try Self.writeAll(fd: fd, data: chunk)
                            written += Int64(chunk.count)
                            windowBytes += Int64(chunk.count)
                            let now = ContinuousClock.now
                            if now - lastEmit >= .milliseconds(250) {
                                let elapsed = now - windowStart
                                let secs = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                                let rate = secs > 0.05 ? Double(windowBytes) / secs : nil
                                if secs >= 2.0 {
                                    windowStart = now
                                    windowBytes = 0
                                }
                                lastEmit = now
                                let progress = written
                                await self?.updateProgress(
                                    exportID: request.exportID,
                                    bytesWritten: progress,
                                    rateBytesPerSec: rate
                                )
                            }
                        }
                        if Darwin.fsync(fd) != 0 {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        return .success(written)
                    } catch {
                        return .failure(error)
                    }
                }.value

                switch writeResult {
                case .failure(let error):
                    if Task.isCancelled { return }
                    let onDisk = Self.existingPartSize(at: partURL)
                    if Self.isDiskSpaceError(error) {
                        Self.coordinatedRemove(at: partURL)
                        self?.finishFailure(exportID: request.exportID, code: "dest_write_failed")
                    } else if error is POSIXError {
                        self?.finishFailure(exportID: request.exportID, code: "dest_write_failed")
                    } else {
                        self?.handleStreamDrop(exportID: request.exportID, bytesWritten: onDisk)
                    }
                    return
                case .success(let finalWritten):
                    guard finalWritten == request.sizeBytes else {
                        self?.handleStreamDrop(exportID: request.exportID, bytesWritten: finalWritten)
                        return
                    }
                }

                self?.enterVerifying(exportID: request.exportID, totalBytes: request.sizeBytes)

                let verifyResult: Result<String, Error> = await Task.detached(priority: .userInitiated) {
                    do {
                        return .success(try Self.sha256File(at: partURL))
                    } catch {
                        return .failure(error)
                    }
                }.value

                switch verifyResult {
                case .failure:
                    Self.coordinatedRemove(at: partURL)
                    self?.finishFailure(exportID: request.exportID, code: "dest_write_failed")
                case .success(let actualSHA):
                    guard actualSHA == request.sha256 else {
                        Self.coordinatedRemove(at: partURL)
                        self?.finishFailure(exportID: request.exportID, code: "checksum_mismatch")
                        return
                    }
                    let publishResult: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
                        do {
                            let finalURL = try Self.publishVerifiedPart(
                                partURL: partURL,
                                intoFolder: folderURL,
                                filename: request.filename
                            )
                            return .success(finalURL)
                        } catch {
                            return .failure(error)
                        }
                    }.value
                    switch publishResult {
                    case .success(let finalURL):
                        self?.finishSaved(
                            exportID: request.exportID,
                            finalURL: finalURL,
                            folderName: folderURL.lastPathComponent,
                            totalBytes: request.sizeBytes
                        )
                    case .failure:
                        Self.coordinatedRemove(at: partURL)
                        self?.finishFailure(exportID: request.exportID, code: "dest_write_failed")
                    }
                }
            } catch {
                if Task.isCancelled { return }
                let onDisk = Self.existingPartSize(at: partURL)
                self?.handleStreamDrop(exportID: request.exportID, bytesWritten: onDisk)
            }
        }
        current.task = task
        self.active = current
    }

    private func updateProgress(exportID: String, bytesWritten: Int64, rateBytesPerSec: Double?) {
        guard var current = self.active, current.request.exportID == exportID,
              !current.userPaused, !current.userCancelled,
              self.snapshot.phase == "transferring"
        else { return }
        current.bytesWritten = bytesWritten
        self.active = current
        self.publish(JournalExportStatusSnapshot(
            exportID: exportID,
            phase: "transferring",
            platform: self.platformName,
            bytesWritten: bytesWritten,
            totalBytes: current.request.sizeBytes,
            rateBytesPerSec: rateBytesPerSec,
            transport: self.lastTransportProvider?(),
            destinationDisplay: "\(current.folderURL.lastPathComponent)/\(current.request.filename)",
            mode: current.request.mode
        ))
    }

    private func enterVerifying(exportID: String, totalBytes: Int64) {
        guard var current = self.active, current.request.exportID == exportID,
              !current.userPaused, !current.userCancelled
        else { return }
        current.bytesWritten = totalBytes
        self.active = current
        self.publish(JournalExportStatusSnapshot(
            exportID: exportID,
            phase: "verifying",
            platform: self.platformName,
            bytesWritten: totalBytes,
            totalBytes: totalBytes,
            transport: self.lastTransportProvider?(),
            destinationDisplay: "\(current.folderURL.lastPathComponent)/\(current.request.filename)",
            mode: current.request.mode
        ))
    }

    private func handleStreamDrop(exportID: String, bytesWritten: Int64) {
        guard var current = self.active, current.request.exportID == exportID else { return }
        if current.userPaused || current.userCancelled { return }
        current.bytesWritten = bytesWritten
        current.task = nil
        current.dataTask = nil
        current.session = nil
        self.active = current
        self.publish(JournalExportStatusSnapshot(
            exportID: exportID,
            phase: "paused",
            platform: self.platformName,
            bytesWritten: bytesWritten,
            totalBytes: current.request.sizeBytes,
            transport: self.lastTransportProvider?(),
            destinationDisplay: "\(current.folderURL.lastPathComponent)/\(current.request.filename)",
            pauseReason: "disconnected",
            mode: current.request.mode
        ))
    }

    private func finishFailure(exportID: String, code: String) {
        guard let current = self.active, current.request.exportID == exportID else { return }
        if current.userCancelled { return }
        let dest = "\(current.folderURL.lastPathComponent)/\(current.request.filename)"
        let mode = current.request.mode
        let total = current.request.sizeBytes
        if current.accessedSecurityScope {
            current.folderURL.stopAccessingSecurityScopedResource()
        }
        self.active = nil
        self.publish(JournalExportStatusSnapshot(
            exportID: exportID,
            phase: "failed",
            platform: self.platformName,
            bytesWritten: 0,
            totalBytes: total,
            transport: self.lastTransportProvider?(),
            destinationDisplay: dest,
            errorCode: code,
            mode: mode
        ))
    }

    private func finishSaved(exportID: String, finalURL: URL, folderName: String, totalBytes: Int64) {
        guard let current = self.active, current.request.exportID == exportID else { return }
        let mode = current.request.mode
        if current.accessedSecurityScope {
            current.folderURL.stopAccessingSecurityScopedResource()
        }
        self.active = nil
        self.publish(JournalExportStatusSnapshot(
            exportID: exportID,
            phase: "saved",
            platform: self.platformName,
            bytesWritten: totalBytes,
            totalBytes: totalBytes,
            transport: self.lastTransportProvider?(),
            destinationDisplay: "\(folderName)/\(finalURL.lastPathComponent)",
            canReveal: false,
            verified: true,
            mode: mode
        ))
    }

    // MARK: - Coordinated file helpers

    nonisolated private static func existingPartSize(at url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return max(0, size.int64Value)
    }

    nonisolated private static func coordinatedRemove(at url: URL) {
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordError) { target in
            try? FileManager.default.removeItem(at: target)
        }
        if coordError != nil {
            try? FileManager.default.removeItem(at: url)
        }
    }

    nonisolated private static func openPrivatePartFile(at url: URL, truncate: Bool) throws -> Int32 {
        var flags: Int32 = O_CREAT | O_RDWR | O_NOFOLLOW
        if truncate { flags |= O_TRUNC }
        let fd = url.path.withCString { Darwin.open($0, flags, mode_t(0o600)) }
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        _ = Darwin.fchmod(fd, mode_t(0o600))
        return fd
    }

    nonisolated private static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                written += n
            }
        }
    }

    nonisolated private static func sha256File(at url: URL) throws -> String {
        let fd = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if n == 0 { break }
            buffer.withUnsafeBytes { raw in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: raw.baseAddress, count: n))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func publishVerifiedPart(partURL: URL, intoFolder folderURL: URL, filename: String) throws -> URL {
        // Choose a non-colliding sibling name inside the chosen folder so any existing document is preserved.
        let targetURL = Self.uniqueDestinationURL(in: folderURL, filename: filename)
        var coordError: NSError?
        var moveError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: partURL,
            options: .forMoving,
            writingItemAt: targetURL,
            options: .forReplacing,
            error: &coordError
        ) { src, dst in
            do {
                try FileManager.default.moveItem(at: src, to: dst)
            } catch {
                moveError = error
            }
        }
        if let coordError { throw coordError }
        if let moveError { throw moveError }
        return targetURL
    }

    nonisolated private static func matchesContentRange(_ header: String?, expectedStart: Int64, expectedTotal: Int64) -> Bool {
        guard let header, header.hasPrefix("bytes ") else { return false }
        let rest = header.dropFirst(6)
        let parts = rest.split(separator: "/")
        guard parts.count == 2,
              let total = Int64(parts[1]), total == expectedTotal else { return false }
        let bounds = parts[0].split(separator: "-")
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start == expectedStart,
              end >= start,
              end < expectedTotal else { return false }
        return true
    }

    nonisolated private static func extractErrorCode(from data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let code = obj["code"] as? String else { return nil }
        return code
    }

    nonisolated private static func isDiskSpaceError(_ error: Error) -> Bool {
        if let posix = error as? POSIXError, posix.code == .ENOSPC || posix.code == .EDQUOT {
            return true
        }
        return false
    }
}

/// Per-web-view adapter bridging `JournalImportHost` (`window.solstoneJournalHost` v2)
/// to the app-scoped `JournalExportTransferManager`.
@MainActor
final class JournalExportHost {
    let contract: JournalExportHostContract
    let contractJSON: String
    let manager: JournalExportTransferManager
    private let liveBaseURL: @MainActor () -> URL?
    private let transportKind: @MainActor () -> String?
    private let pickFolder: JournalExportFolderPickerPresenter
    private var listenerToken: UUID?
    private var eventEmitter: (@MainActor ([String: Any]) -> Void)?

    init(
        contract: JournalExportHostContract,
        contractJSON: String,
        manager: JournalExportTransferManager,
        liveBaseURL: @escaping @MainActor () -> URL?,
        transportKind: @escaping @MainActor () -> String? = { nil },
        pickFolder: @escaping JournalExportFolderPickerPresenter
    ) {
        self.contract = contract
        self.contractJSON = contractJSON
        self.manager = manager
        self.liveBaseURL = liveBaseURL
        self.transportKind = transportKind
        self.pickFolder = pickFolder
    }

    func attachEventEmitter(_ emitter: @escaping @MainActor ([String: Any]) -> Void) {
        self.detachEventEmitter()
        self.eventEmitter = emitter
        self.listenerToken = self.manager.addStatusListener { [weak self] snapshot in
            self?.eventEmitter?(snapshot.toJSON())
        }
    }

    func detachEventEmitter() {
        if let token = self.listenerToken {
            self.manager.removeStatusListener(token)
            self.listenerToken = nil
        }
        self.eventEmitter = nil
    }

    func handles(type: String) -> Bool {
        type == self.contract.start
            || type == self.contract.status
            || type == self.contract.pause
            || type == self.contract.resume
            || type == self.contract.cancel
            || type == self.contract.reveal
            || type == self.contract.deviceSpace
    }

    func handle(_ message: [String: Any], type: String) async -> [String: Any] {
        let id = (message["id"] as? String) ?? ""
        switch type {
        case self.contract.deviceSpace:
            var reply = self.manager.deviceSpaceSnapshot()
            reply["id"] = id
            return reply
        case self.contract.status:
            return self.manager.snapshot.toJSON(replyID: id)
        case self.contract.start:
            guard let request = JournalExportStartRequest.parse(message) else {
                exportHostLog.notice("export-host: refused invalid export.start payload")
                return ["type": self.contract.unsupported, "id": id]
            }
            let snap = await self.manager.start(
                request: request,
                pickFolder: self.pickFolder,
                baseURLProvider: self.liveBaseURL,
                transportProvider: self.transportKind
            )
            return snap.toJSON(replyID: id)
        case self.contract.pause:
            let exportID = message["export_id"] as? String
            return self.manager.pause(exportID: exportID).toJSON(replyID: id)
        case self.contract.resume:
            let exportID = message["export_id"] as? String
            return self.manager.resume(
                exportID: exportID,
                baseURLProvider: self.liveBaseURL,
                transportProvider: self.transportKind
            ).toJSON(replyID: id)
        case self.contract.cancel:
            let exportID = message["export_id"] as? String
            return self.manager.cancel(exportID: exportID).toJSON(replyID: id)
        case self.contract.reveal:
            return ["id": id, "revealed": false]
        default:
            return ["type": self.contract.unsupported, "id": id]
        }
    }
}
