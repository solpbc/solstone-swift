// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Network
import Observation
import os

private let uploaderLog = Logger(subsystem: "app.solstone.swift", category: "uploader")

struct ChunkSidecar: Codable, Equatable, Sendable {
    let segment: String
    let day: String
    let chunkIndex: Int
    let startedAt: Date
    let durationS: TimeInterval
    let sessionID: UUID
    let mode: ObserverMode

    enum CodingKeys: String, CodingKey {
        case segment
        case day
        case chunkIndex = "chunk_index"
        case startedAt = "started_at"
        case durationS = "duration_s"
        case sessionID = "session_id"
        case mode
    }
}

final class ObserverUploaderSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate {
    private struct WeakOwner: Sendable {
        weak var value: ObserverUploader?
    }

    private let ownerBox = OSAllocatedUnfairLock<WeakOwner>(initialState: WeakOwner())

    func setOwner(_ owner: ObserverUploader?) {
        self.ownerBox.withLock { $0.value = owner }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        Task { @MainActor [weak self] in
            guard let owner = self?.ownerBox.withLock({ $0.value }) else { return }
            owner.appendResponseData(data, for: dataTask.taskIdentifier)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        Task { @MainActor [weak self] in
            guard let owner = self?.ownerBox.withLock({ $0.value }) else { return }
            await owner.handleCompletion(for: task, error: error)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            guard let owner = self?.ownerBox.withLock({ $0.value }) else { return }
            owner.finishBackgroundEvents()
        }
    }
}

@MainActor
@Observable
final class ObserverUploader {
    nonisolated static let backgroundSessionIdentifier = "app.solstone.swift.observer-upload"

    var pendingCount = 0
    var failedCount = 0
    var lastUploadAt: Date?
    var lastError: String?

    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let cacheRootURL: URL
    @ObservationIgnored private let sessionDelegate: ObserverUploaderSessionDelegate
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let ensureRegistered: @Sendable @MainActor () async throws -> String
    @ObservationIgnored private let isJournalConfigured: @Sendable @MainActor () -> Bool
    @ObservationIgnored private let localPortProvider: @Sendable @MainActor () -> Int?
    @ObservationIgnored private let urlBuilder: @Sendable (Int, String) -> URL?
    @ObservationIgnored private let retryDelays: [UInt64]
    @ObservationIgnored private let maxAttempts: Int
    @ObservationIgnored private let sleep: @Sendable (UInt64) async -> Void
    @ObservationIgnored private let encoder: JSONEncoder
    @ObservationIgnored private let decoder: JSONDecoder
    @ObservationIgnored private var backgroundCompletionHandler: (@MainActor @Sendable () -> Void)?
    @ObservationIgnored private var responseDataByTaskID: [Int: Data] = [:]
    @ObservationIgnored private var taskInfoByTaskID: [Int: TaskInfo] = [:]
    @ObservationIgnored private var activeTaskIDByChunkID: [String: Int] = [:]
    @ObservationIgnored private var attemptCountByChunkID: [String: Int] = [:]
    @ObservationIgnored private var retryTasksByChunkID: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private let pathMonitorQueue = DispatchQueue(label: "app.solstone.swift.observer-uploader")

    init(
        cacheRootURL: URL? = nil,
        fileManager: FileManager = .default,
        sessionConfiguration: URLSessionConfiguration? = nil,
        ensureRegistered: @escaping @Sendable @MainActor () async throws -> String = {
            throw ObserverUploaderError.registrationUnavailable
        },
        isJournalConfigured: @escaping @Sendable @MainActor () -> Bool = { true },
        localPortProvider: @escaping @Sendable @MainActor () -> Int? = { nil },
        urlBuilder: @escaping @Sendable (Int, String) -> URL? = { localPort, key in
            ObserverServerURL.ingestURL(localPort: localPort, key: key)
        },
        retryDelays: [UInt64] = [2, 4, 8, 16],
        maxAttempts: Int = 5,
        sleep: @escaping @Sendable (UInt64) async -> Void = { delay in
            try? await Task.sleep(for: .seconds(delay))
        },
        startPathMonitor: Bool = true
    ) {
        self.fileManager = fileManager
        self.cacheRootURL = cacheRootURL
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Observer", isDirectory: true)
        self.ensureRegistered = ensureRegistered
        self.isJournalConfigured = isJournalConfigured
        self.localPortProvider = localPortProvider
        self.urlBuilder = urlBuilder
        self.retryDelays = retryDelays
        self.maxAttempts = maxAttempts
        self.sleep = sleep

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        self.sessionDelegate = ObserverUploaderSessionDelegate()
        let configuration = sessionConfiguration ?? {
            let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
            config.waitsForConnectivity = true
            return config
        }()
        self.session = URLSession(configuration: configuration, delegate: self.sessionDelegate, delegateQueue: nil)
        self.sessionDelegate.setOwner(self)

        try? self.fileManager.createDirectory(at: self.cacheRootURL, withIntermediateDirectories: true)
        self.refreshCounts()

        if startPathMonitor {
            self.startPathMonitor()
        }
    }

    func enqueue(chunkURL: URL, sidecar: ChunkSidecar) async {
        let chunkID = chunkURL.deletingPathExtension().lastPathComponent

        do {
            try self.ensureSessionDirectories(sessionID: sidecar.sessionID)
            let pendingAudioURL = self.pendingAudioURL(sessionID: sidecar.sessionID, chunkID: chunkID)
            if chunkURL != pendingAudioURL {
                if self.fileManager.fileExists(atPath: pendingAudioURL.path) {
                    try self.fileManager.removeItem(at: pendingAudioURL)
                }
                try self.fileManager.moveItem(at: chunkURL, to: pendingAudioURL)
            }

            let sidecarURL = self.pendingSidecarURL(sessionID: sidecar.sessionID, chunkID: chunkID)
            let sidecarData = try self.encoder.encode(sidecar)
            try sidecarData.write(to: sidecarURL, options: .atomic)
            uploaderLog.info("observer: chunk enqueued \(chunkID, privacy: .public)")
            self.refreshCounts()
            await self.scheduleUpload(chunkID: chunkID, sessionID: sidecar.sessionID)
        } catch {
            let detail = String(describing: error)
            uploaderLog.error("failed to enqueue observer chunk \(chunkID, privacy: .public): \(detail, privacy: .public)")
            self.lastError = detail
            self.refreshCounts()
        }
    }

    func resumeFromDisk() async {
        do {
            try self.fileManager.createDirectory(at: self.cacheRootURL, withIntermediateDirectories: true)
            let sessionDirectories = try self.fileManager.contentsOfDirectory(
                at: self.cacheRootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for sessionDirectory in sessionDirectories {
                guard let sessionID = UUID(uuidString: sessionDirectory.lastPathComponent) else { continue }
                try self.ensureSessionDirectories(sessionID: sessionID)
                try await self.resumePendingFiles(sessionID: sessionID)
            }
        } catch {
            let detail = String(describing: error)
            uploaderLog.error("observer resume failed: \(detail, privacy: .public)")
            self.lastError = detail
        }

        self.refreshCounts()
    }

    func onThisPhoneSnapshot() -> OnThisPhoneSourceResult {
        do {
            let sessionDirectories = try self.fileManager.contentsOfDirectory(
                at: self.cacheRootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            var items: [OnThisPhoneItem] = []
            for sessionDirectory in sessionDirectories where self.isDirectory(sessionDirectory) {
                guard let sessionID = UUID(uuidString: sessionDirectory.lastPathComponent) else { continue }
                items.append(contentsOf: try self.onThisPhoneItems(
                    sessionID: sessionID,
                    directory: self.pendingDirectoryURL(sessionID: sessionID),
                    location: .pending
                ))
                items.append(contentsOf: try self.onThisPhoneItems(
                    sessionID: sessionID,
                    directory: self.failedDirectoryURL(sessionID: sessionID),
                    location: .failed
                ))
            }
            return .loaded(items: OnThisPhoneItemSort.newestFirst(items))
        } catch {
            uploaderLog.error("observer on-this-phone snapshot failed: \(String(describing: error), privacy: .public)")
            return .failed
        }
    }

    func handleBackgroundURLSessionEvents(completionHandler: @escaping @MainActor @Sendable () -> Void) {
        self.backgroundCompletionHandler = completionHandler
    }

    func dropItem(sessionID: UUID, chunkID: String) {
        self.retryTasksByChunkID[chunkID]?.cancel()
        self.retryTasksByChunkID.removeValue(forKey: chunkID)
        self.attemptCountByChunkID.removeValue(forKey: chunkID)
        if let taskID = self.activeTaskIDByChunkID.removeValue(forKey: chunkID) {
            self.taskInfoByTaskID.removeValue(forKey: taskID)
            self.responseDataByTaskID.removeValue(forKey: taskID)
        }

        let pendingDirectory = self.pendingDirectoryURL(sessionID: sessionID)
        try? self.fileManager.removeItem(at: pendingDirectory.appendingPathComponent("\(chunkID).m4a", isDirectory: false))
        try? self.fileManager.removeItem(at: pendingDirectory.appendingPathComponent("\(chunkID).json", isDirectory: false))
        try? self.fileManager.removeItem(at: pendingDirectory.appendingPathComponent("\(chunkID).upload", isDirectory: false))

        let failedDirectory = self.failedDirectoryURL(sessionID: sessionID)
        try? self.fileManager.removeItem(at: failedDirectory.appendingPathComponent("\(chunkID).m4a", isDirectory: false))
        try? self.fileManager.removeItem(at: failedDirectory.appendingPathComponent("\(chunkID).json", isDirectory: false))

        self.refreshCounts()
        uploaderLog.info("observer item dropped \(chunkID, privacy: .public)")
    }

    func inProgressChunkURL(sessionID: UUID, chunkID: String) throws -> URL {
        try self.ensureSessionDirectories(sessionID: sessionID)
        return self.inProgressDirectoryURL(sessionID: sessionID)
            .appendingPathComponent("\(chunkID).m4a", isDirectory: false)
    }

    func handlePathStatus(_ status: NWPath.Status) {
        guard status == .satisfied else { return }
        Task { @MainActor [weak self] in
            await self?.resumeFromDisk()
        }
    }

    func finishBackgroundEvents() {
        guard let completionHandler = self.backgroundCompletionHandler else { return }
        self.backgroundCompletionHandler = nil
        completionHandler()
    }
}

private extension ObserverUploader {
    struct TaskInfo {
        let chunkID: String
        let sessionID: UUID
        let audioURL: URL
        let sidecarURL: URL
        let requestBodyURL: URL
    }

    func onThisPhoneItems(
        sessionID: UUID,
        directory: URL,
        location: OnThisPhoneLocation
    ) throws -> [OnThisPhoneItem] {
        guard self.fileManager.fileExists(atPath: directory.path) else {
            return []
        }
        let entries = try self.fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var items: [OnThisPhoneItem] = []
        for sidecarURL in entries where sidecarURL.pathExtension == "json" {
            let chunkID = sidecarURL.deletingPathExtension().lastPathComponent
            let audioURL = directory.appendingPathComponent("\(chunkID).m4a", isDirectory: false)
            guard self.fileManager.fileExists(atPath: audioURL.path) else {
                uploaderLog.debug("observer on-this-phone item skipped: missing audio")
                continue
            }

            do {
                let sidecar = try self.loadSidecar(from: sidecarURL)
                let isActivelyUploading = location == .pending && self.activeTaskIDByChunkID[chunkID] != nil
                items.append(OnThisPhoneItem(
                    id: "audio:\(sessionID.uuidString):\(chunkID)",
                    sourceKind: .audio,
                    sendState: onThisPhoneSendState(location: location, isActivelyUploading: isActivelyUploading),
                    contentType: "audio/mp4",
                    filename: audioURL.lastPathComponent,
                    bytes: self.byteCountIfAvailable(at: audioURL),
                    originApp: nil,
                    basis: nil,
                    itemTime: sidecar.startedAt,
                    targetJournal: nil,
                    stream: nil,
                    day: sidecar.day,
                    segment: sidecar.segment,
                    deliveredAt: nil,
                    rawFileURL: audioURL,
                    audioDurationS: sidecar.durationS
                ))
            } catch {
                uploaderLog.debug("observer on-this-phone item skipped: sidecar unavailable")
            }
        }
        return items
    }

    func byteCountIfAvailable(at url: URL) -> Int64? {
        guard let size = try? self.fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handlePathStatus(path.status)
            }
        }
        monitor.start(queue: self.pathMonitorQueue)
        self.pathMonitor = monitor
    }

    func resumePendingFiles(sessionID: UUID) async throws {
        let pendingDirectory = self.pendingDirectoryURL(sessionID: sessionID)
        let entries = try self.fileManager.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        let audioByChunkID = Dictionary(uniqueKeysWithValues: entries
            .filter { $0.pathExtension == "m4a" }
            .map { ($0.deletingPathExtension().lastPathComponent, $0) })
        let sidecarByChunkID = Dictionary(uniqueKeysWithValues: entries
            .filter { $0.pathExtension == "json" }
            .map { ($0.deletingPathExtension().lastPathComponent, $0) })
        let chunkIDs = Set(audioByChunkID.keys).union(sidecarByChunkID.keys)

        for chunkID in chunkIDs.sorted() {
            guard let audioURL = audioByChunkID[chunkID],
                  let sidecarURL = sidecarByChunkID[chunkID]
            else {
                try self.movePendingPairToFailed(
                    sessionID: sessionID,
                    chunkID: chunkID,
                    audioURL: audioByChunkID[chunkID],
                    sidecarURL: sidecarByChunkID[chunkID],
                    reason: "pending chunk missing companion file"
                )
                continue
            }

            do {
                _ = try self.loadSidecar(from: sidecarURL)
                await self.scheduleUpload(chunkID: chunkID, sessionID: sessionID)
            } catch {
                try self.movePendingPairToFailed(
                    sessionID: sessionID,
                    chunkID: chunkID,
                    audioURL: audioURL,
                    sidecarURL: sidecarURL,
                    reason: "pending chunk sidecar decode failed"
                )
            }
        }
    }

    func scheduleUpload(chunkID: String, sessionID: UUID) async {
        guard self.activeTaskIDByChunkID[chunkID] == nil else { return }

        let audioURL = self.pendingAudioURL(sessionID: sessionID, chunkID: chunkID)
        let sidecarURL = self.pendingSidecarURL(sessionID: sessionID, chunkID: chunkID)
        guard self.fileManager.fileExists(atPath: audioURL.path),
              self.fileManager.fileExists(atPath: sidecarURL.path)
        else {
            return
        }

        guard self.isJournalConfigured() else {
            uploaderLog.debug("observer upload held: journal unavailable")
            self.lastError = nil
            self.refreshCounts()
            return
        }

        guard let localPort = self.localPortProvider() else {
            uploaderLog.debug("observer upload held: local port unavailable")
            self.lastError = nil
            self.refreshCounts()
            return
        }

        let key: String
        do {
            key = try await self.ensureRegistered()
        } catch {
            await self.handleUploadFailure(
                chunkID: chunkID,
                sessionID: sessionID,
                audioURL: audioURL,
                sidecarURL: sidecarURL,
                reason: String(describing: error)
            )
            return
        }

        guard let url = self.urlBuilder(localPort, key) else {
            await self.handleUploadFailure(
                chunkID: chunkID,
                sessionID: sessionID,
                audioURL: audioURL,
                sidecarURL: sidecarURL,
                reason: "observer upload unavailable: invalid url"
            )
            return
        }

        do {
            let sidecar = try self.loadSidecar(from: sidecarURL)
            let requestBodyURL = try self.buildMultipartRequestBody(
                audioURL: audioURL,
                sidecar: sidecar
            )
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(self.boundary(for: chunkID))", forHTTPHeaderField: "Content-Type")

            let task = self.session.uploadTask(with: request, fromFile: requestBodyURL)
            self.taskInfoByTaskID[task.taskIdentifier] = TaskInfo(
                chunkID: chunkID,
                sessionID: sessionID,
                audioURL: audioURL,
                sidecarURL: sidecarURL,
                requestBodyURL: requestBodyURL
            )
            self.activeTaskIDByChunkID[chunkID] = task.taskIdentifier
            task.resume()
        } catch {
            await self.handleUploadFailure(
                chunkID: chunkID,
                sessionID: sessionID,
                audioURL: audioURL,
                sidecarURL: sidecarURL,
                reason: String(describing: error)
            )
        }
    }

    func appendResponseData(_ data: Data, for taskIdentifier: Int) {
        self.responseDataByTaskID[taskIdentifier, default: Data()].append(data)
    }

    func handleCompletion(for task: URLSessionTask, error: (any Error)?) async {
        guard let info = self.taskInfoByTaskID.removeValue(forKey: task.taskIdentifier) else { return }
        self.activeTaskIDByChunkID.removeValue(forKey: info.chunkID)
        let responseData = self.responseDataByTaskID.removeValue(forKey: task.taskIdentifier) ?? Data()

        if let error {
            await self.handleUploadFailure(
                chunkID: info.chunkID,
                sessionID: info.sessionID,
                audioURL: info.audioURL,
                sidecarURL: info.sidecarURL,
                reason: String(describing: error)
            )
            try? self.fileManager.removeItem(at: info.requestBodyURL)
            return
        }

        let statusCode = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if 200..<300 ~= statusCode {
            try? self.fileManager.removeItem(at: info.audioURL)
            try? self.fileManager.removeItem(at: info.sidecarURL)
            try? self.fileManager.removeItem(at: info.requestBodyURL)
            self.attemptCountByChunkID.removeValue(forKey: info.chunkID)
            self.lastUploadAt = Date()
            self.lastError = nil
            uploaderLog.info("observer chunk uploaded \(info.chunkID, privacy: .public)")
            self.refreshCounts()
            return
        }

        let body = String(data: responseData, encoding: .utf8) ?? ""
        await self.handleUploadFailure(
            chunkID: info.chunkID,
            sessionID: info.sessionID,
            audioURL: info.audioURL,
            sidecarURL: info.sidecarURL,
            reason: body.isEmpty ? "HTTP \(statusCode)" : "HTTP \(statusCode): \(body)"
        )
        try? self.fileManager.removeItem(at: info.requestBodyURL)
    }

    func handleUploadFailure(
        chunkID: String,
        sessionID: UUID,
        audioURL: URL,
        sidecarURL: URL,
        reason: String
    ) async {
        let nextAttempt = self.attemptCountByChunkID[chunkID, default: 0] + 1
        self.attemptCountByChunkID[chunkID] = nextAttempt
        self.lastError = reason

        if nextAttempt >= self.maxAttempts {
            do {
                try self.movePendingPairToFailed(
                    sessionID: sessionID,
                    chunkID: chunkID,
                    audioURL: audioURL,
                    sidecarURL: sidecarURL,
                    reason: reason
                )
            } catch {
                self.lastError = String(describing: error)
            }
            self.retryTasksByChunkID[chunkID]?.cancel()
            self.retryTasksByChunkID.removeValue(forKey: chunkID)
            self.attemptCountByChunkID.removeValue(forKey: chunkID)
            self.refreshCounts()
            return
        }

        let delayIndex = min(nextAttempt - 1, max(self.retryDelays.count - 1, 0))
        let delay = self.retryDelays.isEmpty ? 0 : self.retryDelays[delayIndex]
        uploaderLog.error("observer chunk upload failed \(chunkID, privacy: .public): \(reason, privacy: .public)")
        self.retryTasksByChunkID[chunkID]?.cancel()
        self.retryTasksByChunkID[chunkID] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sleep(delay)
            guard !Task.isCancelled else { return }
            await self.scheduleUpload(chunkID: chunkID, sessionID: sessionID)
        }
        self.refreshCounts()
    }

    func movePendingPairToFailed(
        sessionID: UUID,
        chunkID: String,
        audioURL: URL?,
        sidecarURL: URL?,
        reason: String
    ) throws {
        let failedDirectory = self.failedDirectoryURL(sessionID: sessionID)
        try self.fileManager.createDirectory(at: failedDirectory, withIntermediateDirectories: true)

        if let audioURL, self.fileManager.fileExists(atPath: audioURL.path) {
            let target = failedDirectory.appendingPathComponent(audioURL.lastPathComponent, isDirectory: false)
            if self.fileManager.fileExists(atPath: target.path) {
                try self.fileManager.removeItem(at: target)
            }
            try self.fileManager.moveItem(at: audioURL, to: target)
        }

        if let sidecarURL, self.fileManager.fileExists(atPath: sidecarURL.path) {
            let target = failedDirectory.appendingPathComponent(sidecarURL.lastPathComponent, isDirectory: false)
            if self.fileManager.fileExists(atPath: target.path) {
                try self.fileManager.removeItem(at: target)
            }
            try self.fileManager.moveItem(at: sidecarURL, to: target)
        }

        uploaderLog.error("observer chunk moved to failed \(chunkID, privacy: .public): \(reason, privacy: .public)")
        self.lastError = reason
    }

    func buildMultipartRequestBody(audioURL: URL, sidecar: ChunkSidecar) throws -> URL {
        let chunkID = audioURL.deletingPathExtension().lastPathComponent
        let boundary = self.boundary(for: chunkID)
        let requestBodyURL = self.pendingDirectoryURL(sessionID: sidecar.sessionID)
            .appendingPathComponent("\(chunkID).upload", isDirectory: false)

        var body = Data()
        body.append(self.multipartField(named: "segment", value: sidecar.segment, boundary: boundary))
        body.append(self.multipartField(named: "day", value: sidecar.day, boundary: boundary))
        body.append(self.multipartField(named: "platform", value: "ios", boundary: boundary))

        let meta = try JSONSerialization.data(withJSONObject: [
            "segment": sidecar.segment,
            "day": sidecar.day,
            "chunk_index": sidecar.chunkIndex,
            "started_at": ISO8601DateFormatter().string(from: sidecar.startedAt),
            "duration_s": sidecar.durationS,
            "session_id": sidecar.sessionID.uuidString,
            "mode": sidecar.mode.rawValue,
        ], options: [.sortedKeys])
        body.append(self.multipartField(
            named: "meta",
            value: String(decoding: meta, as: UTF8.self),
            boundary: boundary
        ))

        let audioData = try Data(contentsOf: audioURL)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        // audio.m4a filename is a hard server-side invariant — pipeline globs audio.* downstream (observe/transcribe, think/cluster, transcripts, retention)
        body.append("Content-Disposition: form-data; name=\"files[]\"; filename=\"audio.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        try body.write(to: requestBodyURL, options: .atomic)
        return requestBodyURL
    }

    func multipartField(named name: String, value: String, boundary: String) -> Data {
        Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
    }

    func boundary(for chunkID: String) -> String {
        "Boundary-\(chunkID)"
    }

    func loadSidecar(from url: URL) throws -> ChunkSidecar {
        try self.decoder.decode(ChunkSidecar.self, from: Data(contentsOf: url))
    }

    func ensureSessionDirectories(sessionID: UUID) throws {
        try self.fileManager.createDirectory(at: self.inProgressDirectoryURL(sessionID: sessionID), withIntermediateDirectories: true)
        try self.fileManager.createDirectory(at: self.pendingDirectoryURL(sessionID: sessionID), withIntermediateDirectories: true)
        try self.fileManager.createDirectory(at: self.failedDirectoryURL(sessionID: sessionID), withIntermediateDirectories: true)
    }

    func inProgressDirectoryURL(sessionID: UUID) -> URL {
        self.sessionDirectoryURL(sessionID: sessionID).appendingPathComponent("in-progress", isDirectory: true)
    }

    func pendingDirectoryURL(sessionID: UUID) -> URL {
        self.sessionDirectoryURL(sessionID: sessionID).appendingPathComponent("pending", isDirectory: true)
    }

    func failedDirectoryURL(sessionID: UUID) -> URL {
        self.sessionDirectoryURL(sessionID: sessionID).appendingPathComponent("failed", isDirectory: true)
    }

    func sessionDirectoryURL(sessionID: UUID) -> URL {
        self.cacheRootURL.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    func pendingAudioURL(sessionID: UUID, chunkID: String) -> URL {
        self.pendingDirectoryURL(sessionID: sessionID).appendingPathComponent("\(chunkID).m4a", isDirectory: false)
    }

    func pendingSidecarURL(sessionID: UUID, chunkID: String) -> URL {
        self.pendingDirectoryURL(sessionID: sessionID).appendingPathComponent("\(chunkID).json", isDirectory: false)
    }

    func refreshCounts() {
        self.pendingCount = self.countFiles(named: "pending", withExtension: "m4a")
        self.failedCount = self.countFiles(named: "failed", withExtension: "m4a")
    }

    func countFiles(named directoryName: String, withExtension pathExtension: String) -> Int {
        guard let enumerator = self.fileManager.enumerator(at: self.cacheRootURL, includingPropertiesForKeys: nil) else {
            return 0
        }

        var count = 0
        for case let url as URL in enumerator {
            if url.pathExtension == pathExtension,
               url.deletingLastPathComponent().lastPathComponent == directoryName
            {
                count += 1
            }
        }
        return count
    }
}

enum ObserverUploaderError: Error {
    case registrationUnavailable
}
