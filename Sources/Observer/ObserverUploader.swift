// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Network
import Observation
import os

private let uploaderLog = Logger(subsystem: "app.solstone.swift", category: "uploader")

nonisolated struct ChunkSidecar: Codable, Equatable, Sendable {
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

    nonisolated static func segmentString(for date: Date, durationSeconds: Double) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "HHmmss"
        return "\(formatter.string(from: date))_\(max(1, Int(durationSeconds.rounded())))"
    }
}

nonisolated struct ObserverUploadFailureSidecar: Codable, Equatable, Sendable {
    let reason: String
    let httpStatus: Int?
    let transportError: String?
    let attemptCount: Int
    let stage: String
    let sourceType: String
    let lastAttemptAt: Date?
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
    @ObservationIgnored private let registrationPrefixProvider: @Sendable @MainActor () -> String?
    @ObservationIgnored private let urlBuilder: @Sendable (Int) -> URL?
    @ObservationIgnored private let diagnosticLog: DiagnosticLog?
    @ObservationIgnored private let sourceType: String
    @ObservationIgnored private let retryDelays: [UInt64]
    @ObservationIgnored private let maxAttempts: Int
    @ObservationIgnored private let sleep: @Sendable (UInt64) async -> Void
    @ObservationIgnored private let encoder: JSONEncoder
    @ObservationIgnored private let decoder: JSONDecoder
    @ObservationIgnored private var backgroundCompletionHandler: (@MainActor @Sendable () -> Void)?
    @ObservationIgnored private var responseDataByTaskID: [Int: Data] = [:]
    @ObservationIgnored private var taskInfoByTaskID: [Int: TaskInfo] = [:]
    @ObservationIgnored private var activeTasksByTaskID: [Int: URLSessionTask] = [:]
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
        registrationPrefixProvider: @escaping @Sendable @MainActor () -> String? = { nil },
        urlBuilder: @escaping @Sendable (Int) -> URL? = { localPort in
            ObserverServerURL.ingestURL(localPort: localPort)
        },
        diagnosticLog: DiagnosticLog? = nil,
        sourceType: String = "observer-audio",
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
        self.registrationPrefixProvider = registrationPrefixProvider
        self.urlBuilder = urlBuilder
        self.diagnosticLog = diagnosticLog
        self.sourceType = sourceType
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
        await self.reconcilePortIfNeeded()

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

    func reconcilePortAndResume() async {
        await self.resumeFromDisk()
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

    func requeueFailedItem(sessionID: UUID, chunkID: String) async throws {
        let failedAudioURL = self.failedDirectoryURL(sessionID: sessionID)
            .appendingPathComponent("\(chunkID).m4a", isDirectory: false)
        let failedSidecarURL = self.failedDirectoryURL(sessionID: sessionID)
            .appendingPathComponent("\(chunkID).json", isDirectory: false)
        guard self.fileManager.fileExists(atPath: failedAudioURL.path),
              self.fileManager.fileExists(atPath: failedSidecarURL.path)
        else {
            throw ObserverUploaderError.missingRequiredArtifact(sessionID: sessionID, chunkID: chunkID)
        }

        try self.ensureSessionDirectories(sessionID: sessionID)
        self.clearUploadState(chunkID: chunkID)

        let pendingAudioURL = self.pendingAudioURL(sessionID: sessionID, chunkID: chunkID)
        let pendingSidecarURL = self.pendingSidecarURL(sessionID: sessionID, chunkID: chunkID)
        let pendingUploadURL = self.pendingDirectoryURL(sessionID: sessionID)
            .appendingPathComponent("\(chunkID).upload", isDirectory: false)
        for staleURL in [pendingAudioURL, pendingSidecarURL, pendingUploadURL] where self.fileManager.fileExists(atPath: staleURL.path) {
            try self.fileManager.removeItem(at: staleURL)
        }

        try self.fileManager.moveItem(at: failedAudioURL, to: pendingAudioURL)
        try self.fileManager.moveItem(at: failedSidecarURL, to: pendingSidecarURL)
        try? self.fileManager.removeItem(at: self.failureSidecarURL(sessionID: sessionID, chunkID: chunkID))
        self.refreshCounts()
        await self.scheduleUpload(chunkID: chunkID, sessionID: sessionID)
    }

    func retryFailed() async {
        do {
            try self.fileManager.createDirectory(at: self.cacheRootURL, withIntermediateDirectories: true)
            let sessionDirectories = try self.fileManager.contentsOfDirectory(
                at: self.cacheRootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for sessionDirectory in sessionDirectories where self.isDirectory(sessionDirectory) {
                guard let sessionID = UUID(uuidString: sessionDirectory.lastPathComponent) else { continue }
                let failedDirectory = self.failedDirectoryURL(sessionID: sessionID)
                guard self.fileManager.fileExists(atPath: failedDirectory.path) else { continue }
                let entries = try self.fileManager.contentsOfDirectory(
                    at: failedDirectory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                let audioChunkIDs = entries
                    .filter { $0.pathExtension == "m4a" }
                    .map { $0.deletingPathExtension().lastPathComponent }
                    .sorted()
                for chunkID in audioChunkIDs {
                    let sidecarURL = failedDirectory.appendingPathComponent("\(chunkID).json", isDirectory: false)
                    guard self.fileManager.fileExists(atPath: sidecarURL.path) else { continue }
                    do {
                        try await self.requeueFailedItem(sessionID: sessionID, chunkID: chunkID)
                    } catch {
                        self.lastError = String(describing: error)
                    }
                }
            }
        } catch {
            let detail = String(describing: error)
            uploaderLog.error("observer retry failed move failed: \(detail, privacy: .public)")
            self.lastError = detail
        }

        self.refreshCounts()
    }

    func migrateLegacySegmentKeys() async -> Int {
        var count = 0

        do {
            try self.fileManager.createDirectory(at: self.cacheRootURL, withIntermediateDirectories: true)
            let sessionDirectories = try self.fileManager.contentsOfDirectory(
                at: self.cacheRootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for sessionDirectory in sessionDirectories where self.isDirectory(sessionDirectory) {
                guard let sessionID = UUID(uuidString: sessionDirectory.lastPathComponent) else { continue }
                let failedDirectory = self.failedDirectoryURL(sessionID: sessionID)
                guard self.fileManager.fileExists(atPath: failedDirectory.path) else { continue }
                let entries = try self.fileManager.contentsOfDirectory(
                    at: failedDirectory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                for url in entries where url.pathExtension == "json" {
                    do {
                        let data = try Data(contentsOf: url)
                        let sidecar = try self.decoder.decode(ChunkSidecar.self, from: data)
                        if sidecar.segment.wholeMatch(of: /^\d{6}_\d+$/) != nil {
                            continue
                        }

                        let migrated = ChunkSidecar(
                            segment: ChunkSidecar.segmentString(for: sidecar.startedAt, durationSeconds: sidecar.durationS),
                            day: sidecar.day,
                            chunkIndex: sidecar.chunkIndex,
                            startedAt: sidecar.startedAt,
                            durationS: sidecar.durationS,
                            sessionID: sidecar.sessionID,
                            mode: sidecar.mode
                        )
                        let encoded = try self.encoder.encode(migrated)
                        try encoded.write(to: url, options: .atomic)
                        count += 1
                    } catch {
                        uploaderLog.error("legacy segment migration skipped \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                    }
                }
            }
        } catch {
            uploaderLog.error("legacy segment migration failed for source \(self.sourceType, privacy: .public): \(String(describing: error), privacy: .public)")
            return count
        }

        if count > 0 {
            uploaderLog.info("legacy segment migration: rewrote \(count, privacy: .public) sidecar(s) for source \(self.sourceType, privacy: .public)")
        }
        return count
    }

    func dropItem(sessionID: UUID, chunkID: String) {
        self.clearUploadState(chunkID: chunkID)

        let pendingDirectory = self.pendingDirectoryURL(sessionID: sessionID)
        try? self.fileManager.removeItem(at: pendingDirectory.appendingPathComponent("\(chunkID).m4a", isDirectory: false))
        try? self.fileManager.removeItem(at: pendingDirectory.appendingPathComponent("\(chunkID).json", isDirectory: false))
        try? self.fileManager.removeItem(at: pendingDirectory.appendingPathComponent("\(chunkID).upload", isDirectory: false))

        let failedDirectory = self.failedDirectoryURL(sessionID: sessionID)
        try? self.fileManager.removeItem(at: failedDirectory.appendingPathComponent("\(chunkID).m4a", isDirectory: false))
        try? self.fileManager.removeItem(at: failedDirectory.appendingPathComponent("\(chunkID).json", isDirectory: false))
        try? self.fileManager.removeItem(at: self.failureSidecarURL(sessionID: sessionID, chunkID: chunkID))

        self.refreshCounts()
        uploaderLog.info("observer item dropped \(chunkID, privacy: .public)")
    }

    func clearInMemoryUploadStateForTesting() {
        self.responseDataByTaskID.removeAll()
        self.taskInfoByTaskID.removeAll()
        self.activeTasksByTaskID.removeAll()
        self.activeTaskIDByChunkID.removeAll()
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
        let localPort: Int
        let prefix: String?
        let sourceType: String
    }

    struct UploadFailureContext {
        let stage: String
        let severity: DiagnosticSeverity
        let sourceType: String
        let localPort: Int?
        let prefix: String?
        let httpStatus: Int?
        let transportError: String?
    }

    struct UploadTaskDescriptor: Codable {
        let sourceType: String
        let chunkID: String
        let sessionID: UUID
        let localPort: Int
        let prefix: String?
    }

    var audioSource: OnThisPhoneAudioSource {
        guard let source = OnThisPhoneAudioSource(sourceType: self.sourceType) else {
            uploaderLog.error("observer uploader configured with unknown sourceType \(self.sourceType, privacy: .public)")
            return .observer
        }
        return source
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
        let audioSource = self.audioSource
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
                let failure = location == .failed
                    ? self.loadFailureSidecarIfAvailable(sessionID: sessionID, chunkID: chunkID)
                    : nil
                items.append(OnThisPhoneItem(
                    id: "\(audioSource.idPrefix):\(sessionID.uuidString):\(chunkID)",
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
                    audioDurationS: sidecar.durationS,
                    failureReason: failure?.reason,
                    failureAttemptCount: failure?.attemptCount,
                    sourceLabel: audioSource.sourceLabel,
                    retryAvailable: location == .failed,
                    lastAttemptAt: failure?.lastAttemptAt
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

    func reconcilePortIfNeeded() async {
        guard let currentPort = self.localPortProvider() else { return }

        let staleInMemoryTasks = self.taskInfoByTaskID.compactMap { taskID, info -> (Int, TaskInfo, URLSessionTask?)? in
            guard info.localPort != currentPort else { return nil }
            return (taskID, info, self.activeTasksByTaskID[taskID])
        }
        for (taskID, info, task) in staleInMemoryTasks {
            self.clearTaskState(taskID: taskID, chunkID: info.chunkID)
            task?.cancel()
            await self.scheduleUpload(chunkID: info.chunkID, sessionID: info.sessionID)
        }

        let tasks = await self.sessionTasks()
        guard !tasks.isEmpty else { return }

        for task in tasks {
            let descriptor = self.uploadTaskDescriptor(from: task.taskDescription)
            let requestPort = task.originalRequest?.url?.port
            let isCurrentPort = descriptor?.localPort == currentPort
                && (requestPort == nil || requestPort == currentPort)

            guard isCurrentPort, let descriptor else {
                self.clearTaskState(taskID: task.taskIdentifier, chunkID: descriptor?.chunkID)
                task.cancel()
                continue
            }

            let audioURL = self.pendingAudioURL(sessionID: descriptor.sessionID, chunkID: descriptor.chunkID)
            let sidecarURL = self.pendingSidecarURL(sessionID: descriptor.sessionID, chunkID: descriptor.chunkID)
            guard self.fileManager.fileExists(atPath: audioURL.path),
                  self.fileManager.fileExists(atPath: sidecarURL.path)
            else {
                self.clearTaskState(taskID: task.taskIdentifier, chunkID: descriptor.chunkID)
                task.cancel()
                continue
            }

            let requestBodyURL = self.pendingDirectoryURL(sessionID: descriptor.sessionID)
                .appendingPathComponent("\(descriptor.chunkID).upload", isDirectory: false)
            self.taskInfoByTaskID[task.taskIdentifier] = TaskInfo(
                chunkID: descriptor.chunkID,
                sessionID: descriptor.sessionID,
                audioURL: audioURL,
                sidecarURL: sidecarURL,
                requestBodyURL: requestBodyURL,
                localPort: descriptor.localPort,
                prefix: descriptor.prefix,
                sourceType: descriptor.sourceType
            )
            self.activeTasksByTaskID[task.taskIdentifier] = task
            self.activeTaskIDByChunkID[descriptor.chunkID] = task.taskIdentifier
        }
    }

    func sessionTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            self.session.getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }
    }

    func taskDescription(for descriptor: UploadTaskDescriptor) -> String? {
        guard let data = try? JSONEncoder().encode(descriptor) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func uploadTaskDescriptor(from taskDescription: String?) -> UploadTaskDescriptor? {
        guard let taskDescription,
              let data = taskDescription.data(using: .utf8)
        else {
            return nil
        }
        return try? JSONDecoder().decode(UploadTaskDescriptor.self, from: data)
    }

    func clearTaskState(taskID: Int, chunkID: String?) {
        let resolvedChunkID = chunkID ?? self.taskInfoByTaskID[taskID]?.chunkID
        self.taskInfoByTaskID.removeValue(forKey: taskID)
        self.activeTasksByTaskID.removeValue(forKey: taskID)
        self.responseDataByTaskID.removeValue(forKey: taskID)
        if let resolvedChunkID {
            if self.activeTaskIDByChunkID[resolvedChunkID] == taskID {
                self.activeTaskIDByChunkID.removeValue(forKey: resolvedChunkID)
            }
        }
    }

    func clearUploadState(chunkID: String) {
        self.retryTasksByChunkID[chunkID]?.cancel()
        self.retryTasksByChunkID.removeValue(forKey: chunkID)
        self.attemptCountByChunkID.removeValue(forKey: chunkID)
        if let taskID = self.activeTaskIDByChunkID.removeValue(forKey: chunkID) {
            self.taskInfoByTaskID.removeValue(forKey: taskID)
            self.activeTasksByTaskID.removeValue(forKey: taskID)
            self.responseDataByTaskID.removeValue(forKey: taskID)
        }
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
            self.appendUploadDiagnostic(
                stage: "no-request-created",
                severity: .warning,
                chunkID: chunkID,
                prefix: self.registrationPrefixProvider(),
                localPort: nil,
                httpStatus: nil,
                transportError: nil,
                attempt: self.attemptCountByChunkID[chunkID, default: 0],
                reason: "local port unavailable"
            )
            self.lastError = nil
            self.refreshCounts()
            return
        }

        let handle: String
        do {
            handle = try await self.ensureRegistered()
        } catch {
            await self.handleUploadFailure(
                chunkID: chunkID,
                sessionID: sessionID,
                audioURL: audioURL,
                sidecarURL: sidecarURL,
                reason: String(describing: error),
                context: UploadFailureContext(
                    stage: "no-request-created",
                    severity: .warning,
                    sourceType: self.sourceType,
                    localPort: localPort,
                    prefix: self.registrationPrefixProvider(),
                    httpStatus: nil,
                    transportError: nil
                )
            )
            return
        }
        let prefix = self.registrationPrefixProvider()

        guard let url = self.urlBuilder(localPort) else {
            await self.handleUploadFailure(
                chunkID: chunkID,
                sessionID: sessionID,
                audioURL: audioURL,
                sidecarURL: sidecarURL,
                reason: "observer upload unavailable: invalid url",
                context: UploadFailureContext(
                    stage: "no-request-created",
                    severity: .warning,
                    sourceType: self.sourceType,
                    localPort: localPort,
                    prefix: prefix,
                    httpStatus: nil,
                    transportError: nil
                )
            )
            return
        }

        do {
            let sidecar = try self.loadSidecar(from: sidecarURL)
            let requestBodyURL = try self.buildMultipartRequestBody(
                audioURL: audioURL,
                sidecar: sidecar
            )
            var request = ObserverAuthorizedRequest.make(url: url, handle: handle, method: "POST")
            request.setValue("multipart/form-data; boundary=\(self.boundary(for: chunkID))", forHTTPHeaderField: "Content-Type")

            let task = self.session.uploadTask(with: request, fromFile: requestBodyURL)
            task.taskDescription = self.taskDescription(for: UploadTaskDescriptor(
                sourceType: self.sourceType,
                chunkID: chunkID,
                sessionID: sessionID,
                localPort: localPort,
                prefix: prefix
            ))
            self.taskInfoByTaskID[task.taskIdentifier] = TaskInfo(
                chunkID: chunkID,
                sessionID: sessionID,
                audioURL: audioURL,
                sidecarURL: sidecarURL,
                requestBodyURL: requestBodyURL,
                localPort: localPort,
                prefix: prefix,
                sourceType: self.sourceType
            )
            self.activeTasksByTaskID[task.taskIdentifier] = task
            self.activeTaskIDByChunkID[chunkID] = task.taskIdentifier
            task.resume()
        } catch {
            await self.handleUploadFailure(
                chunkID: chunkID,
                sessionID: sessionID,
                audioURL: audioURL,
                sidecarURL: sidecarURL,
                reason: String(describing: error),
                context: UploadFailureContext(
                    stage: "no-request-created",
                    severity: .warning,
                    sourceType: self.sourceType,
                    localPort: localPort,
                    prefix: prefix,
                    httpStatus: nil,
                    transportError: String(describing: error)
                )
            )
        }
    }

    func appendResponseData(_ data: Data, for taskIdentifier: Int) {
        self.responseDataByTaskID[taskIdentifier, default: Data()].append(data)
    }

    func handleCompletion(for task: URLSessionTask, error: (any Error)?) async {
        guard let info = self.taskInfoByTaskID.removeValue(forKey: task.taskIdentifier) else { return }
        self.activeTasksByTaskID.removeValue(forKey: task.taskIdentifier)
        self.activeTaskIDByChunkID.removeValue(forKey: info.chunkID)
        let responseData = self.responseDataByTaskID.removeValue(forKey: task.taskIdentifier) ?? Data()

        if let error {
            await self.handleUploadFailure(
                chunkID: info.chunkID,
                sessionID: info.sessionID,
                audioURL: info.audioURL,
                sidecarURL: info.sidecarURL,
                reason: String(describing: error),
                context: UploadFailureContext(
                    stage: "transport-failure",
                    severity: .warning,
                    sourceType: info.sourceType,
                    localPort: info.localPort,
                    prefix: info.prefix,
                    httpStatus: (task.response as? HTTPURLResponse)?.statusCode,
                    transportError: String(describing: error)
                )
            )
            try? self.fileManager.removeItem(at: info.requestBodyURL)
            return
        }

        let statusCode = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if 200..<300 ~= statusCode {
            self.appendUploadDiagnostic(
                stage: "success",
                severity: .info,
                sourceType: info.sourceType,
                chunkID: info.chunkID,
                prefix: info.prefix,
                localPort: info.localPort,
                httpStatus: statusCode,
                transportError: nil,
                attempt: self.attemptCountByChunkID[info.chunkID, default: 0] + 1,
                reason: "uploaded"
            )
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

        let body = self.httpFailureBodySnippet(from: responseData)
        await self.handleUploadFailure(
            chunkID: info.chunkID,
            sessionID: info.sessionID,
            audioURL: info.audioURL,
            sidecarURL: info.sidecarURL,
            reason: body.map { "HTTP \(statusCode): \($0)" } ?? "HTTP \(statusCode)",
            context: UploadFailureContext(
                stage: "http-failure",
                severity: .warning,
                sourceType: info.sourceType,
                localPort: info.localPort,
                prefix: info.prefix,
                httpStatus: statusCode,
                transportError: nil
            )
        )
        try? self.fileManager.removeItem(at: info.requestBodyURL)
    }

    func httpFailureBodySnippet(from data: Data) -> String? {
        guard !data.isEmpty,
              let body = String(data: data, encoding: .utf8),
              !body.isEmpty
        else {
            return nil
        }
        return String(body.prefix(200))
    }

    func persistedFailureReason(
        reason: String,
        context: UploadFailureContext,
        attemptCount: Int
    ) -> String {
        if context.httpStatus != nil {
            return self.redactedFailureDetail(reason)
        }
        if let transportError = context.transportError, !transportError.isEmpty {
            return self.redactedFailureDetail(transportError)
        }
        return SourceVocabulary.onThisPhoneFailureAttemptStatus(count: attemptCount)
    }

    func redactedFailureDetail(_ detail: String) -> String {
        var redacted = detail.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if let authorizationRange = redacted.range(of: "Authorization:", options: [.caseInsensitive]) {
            redacted = String(redacted[..<authorizationRange.lowerBound]) + "Authorization: [redacted]"
        }
        while let bearerRange = redacted.range(of: "Bearer ") {
            var end = bearerRange.upperBound
            while end < redacted.endIndex, !redacted[end].isWhitespace {
                end = redacted.index(after: end)
            }
            redacted.replaceSubrange(bearerRange.lowerBound..<end, with: "Bearer [redacted]")
        }
        return redacted
    }

    func handleUploadFailure(
        chunkID: String,
        sessionID: UUID,
        audioURL: URL,
        sidecarURL: URL,
        reason: String,
        context: UploadFailureContext
    ) async {
        let nextAttempt = self.attemptCountByChunkID[chunkID, default: 0] + 1
        self.attemptCountByChunkID[chunkID] = nextAttempt
        self.lastError = self.redactedFailureDetail(reason)
        self.appendUploadDiagnostic(
            stage: context.stage,
            severity: context.severity,
            sourceType: context.sourceType,
            chunkID: chunkID,
            prefix: context.prefix,
            localPort: context.localPort,
            httpStatus: context.httpStatus,
            transportError: context.transportError,
            attempt: nextAttempt,
            reason: reason
        )

        if nextAttempt >= self.maxAttempts {
            self.appendUploadDiagnostic(
                stage: "retry-exhausted",
                severity: .error,
                sourceType: context.sourceType,
                chunkID: chunkID,
                prefix: context.prefix,
                localPort: context.localPort,
                httpStatus: context.httpStatus,
                transportError: context.transportError,
                attempt: nextAttempt,
                reason: reason
            )
            do {
                try self.movePendingPairToFailed(
                    sessionID: sessionID,
                    chunkID: chunkID,
                    audioURL: audioURL,
                    sidecarURL: sidecarURL,
                    reason: reason,
                    failureSidecar: ObserverUploadFailureSidecar(
                        reason: self.persistedFailureReason(
                            reason: reason,
                            context: context,
                            attemptCount: nextAttempt
                        ),
                        httpStatus: context.httpStatus,
                        transportError: context.transportError.map { self.redactedFailureDetail($0) },
                        attemptCount: nextAttempt,
                        stage: context.stage,
                        sourceType: context.sourceType,
                        lastAttemptAt: Date()
                    )
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
        uploaderLog.error("observer chunk upload failed \(chunkID, privacy: .public): \(self.redactedFailureDetail(reason), privacy: .public)")
        self.appendUploadDiagnostic(
            stage: "retry-scheduled",
            severity: .info,
            sourceType: context.sourceType,
            chunkID: chunkID,
            prefix: context.prefix,
            localPort: context.localPort,
            httpStatus: context.httpStatus,
            transportError: context.transportError,
            attempt: nextAttempt,
            reason: reason
        )
        self.retryTasksByChunkID[chunkID]?.cancel()
        self.retryTasksByChunkID[chunkID] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sleep(delay)
            guard !Task.isCancelled else { return }
            await self.scheduleUpload(chunkID: chunkID, sessionID: sessionID)
        }
        self.refreshCounts()
    }

    func appendUploadDiagnostic(
        stage: String,
        severity: DiagnosticSeverity,
        sourceType: String? = nil,
        chunkID: String,
        prefix: String?,
        localPort: Int?,
        httpStatus: Int?,
        transportError: String?,
        attempt: Int,
        reason: String
    ) {
        let source = sourceType ?? self.sourceType
        let safeTransportError = transportError.map { self.redactedFailureDetail($0) }
        let safeReason = self.redactedFailureDetail(reason)
        let detail = [
            "source=\(source)",
            "chunkID=\(chunkID)",
            "prefix=\(prefix?.isEmpty == false ? prefix! : "unknown")",
            "localPort=\(localPort.map(String.init) ?? "none")",
            "httpStatus=\(httpStatus.map(String.init) ?? "none")",
            "transportError=\(safeTransportError?.isEmpty == false ? safeTransportError! : "none")",
            "attempt=\(attempt)/\(self.maxAttempts)",
            "reason=\(safeReason)",
        ].joined(separator: " ")
        self.diagnosticLog?.append(
            category: .upload,
            severity: severity,
            message: "\(source) upload \(stage)",
            detail: detail
        )
    }

    func movePendingPairToFailed(
        sessionID: UUID,
        chunkID: String,
        audioURL: URL?,
        sidecarURL: URL?,
        reason: String,
        failureSidecar: ObserverUploadFailureSidecar? = nil
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

        if let failureSidecar {
            let data = try self.encoder.encode(failureSidecar)
            try data.write(to: self.failureSidecarURL(sessionID: sessionID, chunkID: chunkID), options: .atomic)
        }

        let safeReason = self.redactedFailureDetail(reason)
        uploaderLog.error("observer chunk moved to failed \(chunkID, privacy: .public): \(safeReason, privacy: .public)")
        self.lastError = safeReason
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

    func loadFailureSidecarIfAvailable(sessionID: UUID, chunkID: String) -> ObserverUploadFailureSidecar? {
        let url = self.failureSidecarURL(sessionID: sessionID, chunkID: chunkID)
        guard self.fileManager.fileExists(atPath: url.path) else { return nil }
        return try? self.decoder.decode(ObserverUploadFailureSidecar.self, from: Data(contentsOf: url))
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

    func failureSidecarURL(sessionID: UUID, chunkID: String) -> URL {
        self.failedDirectoryURL(sessionID: sessionID).appendingPathComponent("\(chunkID).failure", isDirectory: false)
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
    case missingRequiredArtifact(sessionID: UUID, chunkID: String)
}
