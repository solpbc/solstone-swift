// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation
import Network
import Observation
import os

nonisolated private let uploaderLog = Logger(subsystem: "app.solstone.swift", category: "uploader")
private let mobileSegmentMaxRequeueAttempts = 5

nonisolated struct ChunkSidecar: Codable, Equatable, Sendable {
    let segment: String
    let day: String
    let chunkIndex: Int
    let startedAt: Date
    let durationS: TimeInterval
    let sessionID: UUID
    let mode: ObserverMode
    let locationJSONL: Data?

    enum CodingKeys: String, CodingKey {
        case segment
        case day
        case chunkIndex = "chunk_index"
        case startedAt = "started_at"
        case durationS = "duration_s"
        case sessionID = "session_id"
        case mode
        case locationJSONL = "location_jsonl"
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

nonisolated struct ObserverIngestMultipartMetadata: Equatable, Sendable {
    let segment: String
    let day: String
    let startedAt: Date
    let durationS: TimeInterval
    let chunkIndex: Int?
    let sessionID: UUID?
    let mode: ObserverMode?
    let segmentID: UUID?
    let sources: [String]
}

nonisolated struct ObserverMobileSegmentTransportFailure: Equatable, Sendable {
    let reason: String
    let httpStatus: Int?
    let transportError: String?
    let attemptCount: Int
    let stage: String
    let lastAttemptAt: Date?
}

nonisolated private struct LegacySegmentKeyMigrationResult: Sendable {
    let count: Int
    let failure: String?
}

nonisolated enum ObserverMobileSegmentTransportResult: Equatable, Sendable {
    case delivered
    case failed(ObserverMobileSegmentTransportFailure)
    case cancelled
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
    private(set) var recentErrorCount = 0
    private let throughputMeter = ThroughputMeter()

    var inFlightCount: Int {
        self.activeTasksByTaskID.count
            + self.retryTasksByChunkID.count
            + self.schedulingChunkIDs.count
            + self.mobileSegmentTaskIDBySegmentID.count
            + self.mobileSegmentRetryTasksBySegmentID.count
            + self.mobileSegmentSchedulingIDs.count
    }

    var confirmedActiveTransferCount: Int {
        self.activeTasksByTaskID.count + self.mobileSegmentTaskIDBySegmentID.count
    }

    @ObservationIgnored private(set) var fullRecountCount = 0
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let cacheRootURL: URL
    @ObservationIgnored private let sessionDelegate: ObserverUploaderSessionDelegate
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let ensureRegistered: @Sendable @MainActor () async throws -> String
    @ObservationIgnored private let isJournalConfigured: @Sendable @MainActor () -> Bool
    @ObservationIgnored private let localPortProvider: @Sendable @MainActor () -> Int?
    @ObservationIgnored private let activeEpochProvider: @Sendable @MainActor () -> UInt64?
    @ObservationIgnored private let registrationPrefixProvider: @Sendable @MainActor () -> String?
    @ObservationIgnored private let urlBuilder: @Sendable (Int) -> URL?
    @ObservationIgnored private let diagnosticLog: DiagnosticLog?
    @ObservationIgnored private let sourceType: String
    @ObservationIgnored private let platform: String
    @ObservationIgnored private let retryDelays: [UInt64]
    @ObservationIgnored private let maxAttempts: Int
    @ObservationIgnored private let requeueStabilityPoll: UInt64
    @ObservationIgnored private let requeueStabilityWindow: UInt64
    @ObservationIgnored private let requeueMaxDeferral: UInt64
    @ObservationIgnored private let sleep: @Sendable (UInt64) async -> Void
    @ObservationIgnored private let cooperator: MaintenanceCooperator
    @ObservationIgnored private let encoder: JSONEncoder
    @ObservationIgnored private let decoder: JSONDecoder
    @ObservationIgnored var onSegmentDelivered: (@MainActor @Sendable (UUID) -> Void)?
    @ObservationIgnored private var backgroundCompletionHandler: (@MainActor @Sendable () -> Void)?
    @ObservationIgnored private var responseDataByTaskID: [Int: Data] = [:]
    @ObservationIgnored private var taskInfoByTaskID: [Int: TaskInfo] = [:]
    @ObservationIgnored private var activeTasksByTaskID: [Int: URLSessionTask] = [:]
    @ObservationIgnored private var activeTaskIDByChunkID: [String: Int] = [:]
    @ObservationIgnored private var schedulingChunkIDs: Set<String> = []
    @ObservationIgnored private var droppedChunkIDs: Set<String> = []
    @ObservationIgnored private var attemptCountByChunkID: [String: Int] = [:]
    @ObservationIgnored private var requeueAttemptCountByChunkID: [String: Int] = [:]
    @ObservationIgnored private var retryTasksByChunkID: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var mobileSegmentTaskInfoByTaskID: [Int: MobileSegmentTaskInfo] = [:]
    @ObservationIgnored private var mobileSegmentTaskByTaskID: [Int: URLSessionTask] = [:]
    @ObservationIgnored private var mobileSegmentTaskIDBySegmentID: [UUID: Int] = [:]
    @ObservationIgnored private var mobileSegmentAttemptCountBySegmentID: [UUID: Int] = [:]
    @ObservationIgnored private var mobileSegmentRequeueAttemptCountBySegmentID: [UUID: Int] = [:]
    @ObservationIgnored private var mobileSegmentRetryTasksBySegmentID: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var mobileSegmentSchedulingIDs: Set<UUID> = []
    @ObservationIgnored private var mobileSegmentDroppedIDs: Set<UUID> = []
    @ObservationIgnored private var mobileSegmentCompletionBySegmentID: [
        UUID: @MainActor @Sendable (ObserverMobileSegmentTransportResult) -> Void
    ] = [:]
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private let pathMonitorQueue = DispatchQueue(label: "app.solstone.swift.observer-uploader")

    var recentBytesPerSecond: Double {
        self.throughputMeter.recentBytesPerSecond
    }

    init(
        cacheRootURL: URL? = nil,
        fileManager: FileManager = .default,
        sessionConfiguration: URLSessionConfiguration? = nil,
        ensureRegistered: @escaping @Sendable @MainActor () async throws -> String = {
            throw ObserverUploaderError.registrationUnavailable
        },
        isJournalConfigured: @escaping @Sendable @MainActor () -> Bool = { true },
        localPortProvider: @escaping @Sendable @MainActor () -> Int? = { nil },
        activeEpochProvider: @escaping @Sendable @MainActor () -> UInt64? = { nil },
        registrationPrefixProvider: @escaping @Sendable @MainActor () -> String? = { nil },
        urlBuilder: @escaping @Sendable (Int) -> URL? = { localPort in
            ObserverServerURL.ingestURL(localPort: localPort)
        },
        diagnosticLog: DiagnosticLog? = nil,
        sourceType: String = "observer-audio",
        platform: String = "ios",
        onSegmentDelivered: (@MainActor @Sendable (UUID) -> Void)? = nil,
        retryDelays: [UInt64] = [2, 4, 8, 16],
        maxAttempts: Int = 5,
        requeueStabilityPoll: UInt64 = 1,
        requeueStabilityWindow: UInt64 = 2,
        requeueMaxDeferral: UInt64 = 6,
        sleep: @escaping @Sendable (UInt64) async -> Void = { delay in
            try? await Task.sleep(for: .seconds(delay))
        },
        startPathMonitor: Bool = true,
        cooperator: MaintenanceCooperator = MaintenanceCooperator()
    ) {
        self.fileManager = fileManager
        self.cacheRootURL = cacheRootURL
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Observer", isDirectory: true)
        self.ensureRegistered = ensureRegistered
        self.isJournalConfigured = isJournalConfigured
        self.localPortProvider = localPortProvider
        self.activeEpochProvider = activeEpochProvider
        self.registrationPrefixProvider = registrationPrefixProvider
        self.urlBuilder = urlBuilder
        self.diagnosticLog = diagnosticLog
        self.sourceType = sourceType
        self.platform = platform
        self.onSegmentDelivered = onSegmentDelivered
        self.retryDelays = retryDelays
        self.maxAttempts = maxAttempts
        self.requeueStabilityPoll = requeueStabilityPoll
        self.requeueStabilityWindow = requeueStabilityWindow
        self.requeueMaxDeferral = requeueMaxDeferral
        self.sleep = sleep
        self.cooperator = cooperator

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
            let pendingAudioExisted = self.fileManager.fileExists(atPath: pendingAudioURL.path)
            var movedNewPendingAudio = false
            if chunkURL != pendingAudioURL {
                if pendingAudioExisted {
                    try self.fileManager.removeItem(at: pendingAudioURL)
                }
                try self.fileManager.moveItem(at: chunkURL, to: pendingAudioURL)
                movedNewPendingAudio = !pendingAudioExisted
            }

            let sidecarURL = self.pendingSidecarURL(sessionID: sidecar.sessionID, chunkID: chunkID)
            let sidecarData = try self.encoder.encode(sidecar)
            try sidecarData.write(to: sidecarURL, options: .atomic)
            uploaderLog.info("observer: chunk enqueued \(chunkID, privacy: .public)")
            if movedNewPendingAudio {
                self.applyCountDelta(pending: 1, failed: 0, step: "enqueue")
            } else {
                self.refreshCounts()
            }
            await self.scheduleUpload(chunkID: chunkID, sessionID: sidecar.sessionID)
        } catch {
            let detail = String(describing: error)
            uploaderLog.error("failed to enqueue observer chunk \(chunkID, privacy: .public): \(detail, privacy: .public)")
            self.lastError = detail
            self.refreshCounts()
        }
    }

    func resumeFromDisk() async {
        guard self.localPortProvider() != nil else { return }

        await self.reconcilePortIfNeeded()

        do {
            try self.fileManager.createDirectory(at: self.cacheRootURL, withIntermediateDirectories: true)
            let sessionDirectories = try self.fileManager.contentsOfDirectory(
                at: self.cacheRootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for sessionDirectory in sessionDirectories {
                if Task.isCancelled { break }
                await self.cooperator.step()
                if Task.isCancelled { break }
                guard let sessionID = UUID(uuidString: sessionDirectory.lastPathComponent) else { continue }
                try self.ensureSessionDirectories(sessionID: sessionID)
                try await self.recoverInProgressFiles(sessionID: sessionID)
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
        let source = DrainSource.audio(self.sourceType)
        let interval = DrainSignpost.begin(.sourceSnapshotScan, source: source)
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
            let sortedItems = OnThisPhoneItemSort.newestFirst(items)
            DrainSignpost.end(
                interval,
                source: source,
                fields: DrainFields(status: "loaded", error: .none, items: sortedItems.count)
            )
            return .loaded(items: sortedItems)
        } catch {
            uploaderLog.error("observer on-this-phone snapshot failed: \(String(describing: error), privacy: .public)")
            DrainSignpost.end(
                interval,
                source: source,
                fields: DrainFields(status: "failed", error: .filesystem, items: 0)
            )
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
        let pendingAudioExisted = self.fileManager.fileExists(atPath: pendingAudioURL.path)

        do {
            for staleURL in [pendingAudioURL, pendingSidecarURL, pendingUploadURL] where self.fileManager.fileExists(atPath: staleURL.path) {
                try self.fileManager.removeItem(at: staleURL)
            }
            try self.fileManager.moveItem(at: failedAudioURL, to: pendingAudioURL)
            try self.fileManager.moveItem(at: failedSidecarURL, to: pendingSidecarURL)
            try? self.fileManager.removeItem(at: self.failureSidecarURL(sessionID: sessionID, chunkID: chunkID))
            if pendingAudioExisted {
                self.refreshCounts()
            } else {
                self.applyCountDelta(pending: 1, failed: -1, step: "requeue")
            }
        } catch {
            self.refreshCounts()
            throw error
        }
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

            sessionLoop: for sessionDirectory in sessionDirectories where self.isDirectory(sessionDirectory) {
                if Task.isCancelled { break }
                await self.cooperator.step()
                if Task.isCancelled { break }
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
                    if Task.isCancelled { break sessionLoop }
                    await self.cooperator.step()
                    if Task.isCancelled { break sessionLoop }
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
        let result = await Self.migrateLegacySegmentKeysOffMain(
            cacheRootURL: self.cacheRootURL,
            fileManager: self.fileManager,
            cooperator: self.cooperator
        )

        if let failure = result.failure {
            uploaderLog.error("legacy segment migration failed for source \(self.sourceType, privacy: .public): \(failure, privacy: .public)")
            return result.count
        }

        if result.count > 0 {
            uploaderLog.info("legacy segment migration: rewrote \(result.count, privacy: .public) sidecar(s) for source \(self.sourceType, privacy: .public)")
        }
        return result.count
    }

    func dropItem(sessionID: UUID, chunkID: String) {
        let hadLiveWork = self.activeTaskIDByChunkID[chunkID] != nil
            || self.schedulingChunkIDs.contains(chunkID)
        if hadLiveWork {
            self.droppedChunkIDs.insert(chunkID)
        }
        self.clearUploadState(chunkID: chunkID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let tasks = await self.sessionTasks()
            for task in tasks {
                guard let descriptor = self.uploadTaskDescriptor(from: task.taskDescription),
                      descriptor.chunkID == chunkID,
                      descriptor.sessionID == sessionID
                else { continue }
                task.cancel()
            }
        }

        let pendingDirectory = self.pendingDirectoryURL(sessionID: sessionID)
        let pendingAudioURL = pendingDirectory.appendingPathComponent("\(chunkID).m4a", isDirectory: false)
        let removedPendingAudio = (try? self.fileManager.removeItem(at: pendingAudioURL)) != nil
        try? self.fileManager.removeItem(at: pendingDirectory.appendingPathComponent("\(chunkID).json", isDirectory: false))
        try? self.fileManager.removeItem(at: pendingDirectory.appendingPathComponent("\(chunkID).upload", isDirectory: false))

        let failedDirectory = self.failedDirectoryURL(sessionID: sessionID)
        let failedAudioURL = failedDirectory.appendingPathComponent("\(chunkID).m4a", isDirectory: false)
        let removedFailedAudio = (try? self.fileManager.removeItem(at: failedAudioURL)) != nil
        try? self.fileManager.removeItem(at: failedDirectory.appendingPathComponent("\(chunkID).json", isDirectory: false))
        try? self.fileManager.removeItem(at: self.failureSidecarURL(sessionID: sessionID, chunkID: chunkID))

        if removedPendingAudio || removedFailedAudio {
            self.applyCountDelta(
                pending: removedPendingAudio ? -1 : 0,
                failed: removedFailedAudio ? -1 : 0,
                step: "drop"
            )
        }
        uploaderLog.info("observer item dropped \(chunkID, privacy: .public)")
    }

    func clearInMemoryUploadStateForTesting() {
        self.responseDataByTaskID.removeAll()
        self.taskInfoByTaskID.removeAll()
        self.activeTasksByTaskID.removeAll()
        self.activeTaskIDByChunkID.removeAll()
        self.droppedChunkIDs.removeAll()
        self.schedulingChunkIDs.removeAll()
        self.attemptCountByChunkID.removeAll()
        self.requeueAttemptCountByChunkID.removeAll()
        for task in self.retryTasksByChunkID.values {
            task.cancel()
        }
        self.retryTasksByChunkID.removeAll()
        self.mobileSegmentTaskInfoByTaskID.removeAll()
        self.mobileSegmentTaskByTaskID.removeAll()
        self.mobileSegmentTaskIDBySegmentID.removeAll()
        self.mobileSegmentDroppedIDs.removeAll()
        self.mobileSegmentSchedulingIDs.removeAll()
        self.mobileSegmentAttemptCountBySegmentID.removeAll()
        self.mobileSegmentRequeueAttemptCountBySegmentID.removeAll()
        self.mobileSegmentCompletionBySegmentID.removeAll()
        for task in self.mobileSegmentRetryTasksBySegmentID.values {
            task.cancel()
        }
        self.mobileSegmentRetryTasksBySegmentID.removeAll()
    }

    func attemptCountForTesting(chunkID: String) -> Int {
        self.attemptCountByChunkID[chunkID, default: 0]
    }

    func requeueAttemptCountForTesting(chunkID: String) -> Int {
        self.requeueAttemptCountByChunkID[chunkID, default: 0]
    }

    func retryTaskCountForTesting() -> Int {
        self.retryTasksByChunkID.count + self.mobileSegmentRetryTasksBySegmentID.count
    }

    func plantDropTombstoneForTesting(chunkID: String) {
        self.droppedChunkIDs.insert(chunkID)
    }

    func isDropTombstonedForTesting(chunkID: String) -> Bool {
        self.droppedChunkIDs.contains(chunkID)
    }

    func hasInFlightTrackingForTesting(chunkID: String) -> Bool {
        if self.schedulingChunkIDs.contains(chunkID) { return true }
        guard let taskID = self.activeTaskIDByChunkID[chunkID] else { return false }
        return self.taskInfoByTaskID[taskID] != nil || self.activeTasksByTaskID[taskID] != nil
    }

    func mobileSegmentHasInFlightTrackingForTesting(segmentID: UUID) -> Bool {
        self.mobileSegmentSchedulingIDs.contains(segmentID)
            || self.mobileSegmentTaskIDBySegmentID[segmentID] != nil
    }

    func plantMobileSegmentDropTombstoneForTesting(segmentID: UUID) {
        self.mobileSegmentDroppedIDs.insert(segmentID)
    }

    func setAllSessionTaskDescriptionsForTesting(_ description: String?) async {
        for task in await self.sessionTasks() {
            task.taskDescription = description
        }
    }

    func sessionTaskDescriptionsForTesting() async -> [String?] {
        await self.sessionTasks().map(\.taskDescription)
    }

    func mobileSegmentAttemptCountForTesting(segmentID: UUID) -> Int {
        self.mobileSegmentAttemptCountBySegmentID[segmentID, default: 0]
    }

    func mobileSegmentRequeueAttemptCountForTesting(segmentID: UUID) -> Int {
        self.mobileSegmentRequeueAttemptCountBySegmentID[segmentID, default: 0]
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

extension ObserverUploader {
    func buildMobileSegmentRequestBody(
        segmentID: UUID,
        metadata: ObserverIngestMultipartMetadata,
        audioURL: URL?,
        locationJSONL: Data?,
        screenURL: URL?
    ) throws -> (requestBodyURL: URL, boundary: String) {
        let directory = self.cacheRootURL.appendingPathComponent("MobileSegmentBackgroundBodies", isDirectory: true)
        try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let requestBodyURL = directory.appendingPathComponent("\(segmentID.uuidString).upload", isDirectory: false)
        let boundary = self.boundary(for: segmentID.uuidString)
        _ = try self.buildObserverIngestMultipartRequestBody(
            audioURL: audioURL,
            locationJSONL: locationJSONL,
            screenURL: screenURL,
            metadata: metadata,
            requestBodyURL: requestBodyURL,
            boundary: boundary,
            drainSource: .observer
        )
        return (requestBodyURL, boundary)
    }

    func uploadMobileSegment(
        segmentID: UUID,
        requestBodyURL: URL,
        boundary: String,
        onComplete: @escaping @MainActor @Sendable (ObserverMobileSegmentTransportResult) -> Void
    ) async {
        self.mobileSegmentCompletionBySegmentID[segmentID] = onComplete
        await self.scheduleMobileSegmentUpload(segmentID: segmentID, requestBodyURL: requestBodyURL, boundary: boundary)
    }

    func cancelMobileSegmentUpload(segmentID: UUID) {
        let hadLiveWork = self.mobileSegmentTaskIDBySegmentID[segmentID] != nil
            || self.mobileSegmentSchedulingIDs.contains(segmentID)
        if hadLiveWork {
            self.mobileSegmentDroppedIDs.insert(segmentID)
        }
        self.clearMobileSegmentUploadState(segmentID: segmentID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let tasks = await self.sessionTasks()
            for task in tasks {
                guard self.mobileSegmentUploadTaskDescriptor(from: task.taskDescription)?.segmentID == segmentID else { continue }
                task.cancel()
            }
        }
    }

    func isMobileSegmentUploading(segmentID: UUID) -> Bool {
        self.mobileSegmentTaskIDBySegmentID[segmentID] != nil
            || self.mobileSegmentSchedulingIDs.contains(segmentID)
            || self.mobileSegmentRetryTasksBySegmentID[segmentID] != nil
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
        let epoch: UInt64?
        let createdAt: Date?
        let prefix: String?
        let sourceType: String
    }

    struct MobileSegmentTaskInfo {
        let segmentID: UUID
        let requestBodyURL: URL
        let boundary: String
        let localPort: Int
        let epoch: UInt64?
        let createdAt: Date?
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
        let epoch: UInt64?
        let createdAt: Date?
        let prefix: String?
    }

    struct MobileSegmentUploadTaskDescriptor: Codable {
        let kind: String
        let sourceType: String
        let segmentID: UUID
        let localPort: Int
        let epoch: UInt64?
        let createdAt: Date?
        let prefix: String?

        enum CodingKeys: String, CodingKey {
            case kind
            case sourceType = "source_type"
            case segmentID = "segment_id"
            case localPort = "local_port"
            case epoch
            case createdAt = "created_at"
            case prefix
        }
    }

    struct CountDelta {
        let pending: Int
        let failed: Int
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
                    sendState: onThisPhoneSendState(location: location, canRetry: location == .failed, isActivelyUploading: isActivelyUploading),
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

    nonisolated static func migrateLegacySegmentKeysOffMain(
        cacheRootURL: URL,
        fileManager: FileManager,
        cooperator: MaintenanceCooperator
    ) async -> LegacySegmentKeyMigrationResult {
        var count = 0
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            try fileManager.createDirectory(at: cacheRootURL, withIntermediateDirectories: true)
            let sessionDirectories = try fileManager.contentsOfDirectory(
                at: cacheRootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for sessionDirectory in sessionDirectories where (try? sessionDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                guard !Task.isCancelled else { return LegacySegmentKeyMigrationResult(count: count, failure: nil) }
                await cooperator.step()
                guard !Task.isCancelled else { return LegacySegmentKeyMigrationResult(count: count, failure: nil) }
                guard UUID(uuidString: sessionDirectory.lastPathComponent) != nil else { continue }
                let failedDirectory = sessionDirectory.appendingPathComponent("failed", isDirectory: true)
                guard fileManager.fileExists(atPath: failedDirectory.path) else { continue }
                let entries = try fileManager.contentsOfDirectory(
                    at: failedDirectory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                for url in entries where url.pathExtension == "json" {
                    guard !Task.isCancelled else { return LegacySegmentKeyMigrationResult(count: count, failure: nil) }
                    await cooperator.step()
                    guard !Task.isCancelled else { return LegacySegmentKeyMigrationResult(count: count, failure: nil) }
                    do {
                        let data = try Data(contentsOf: url)
                        let sidecar = try decoder.decode(ChunkSidecar.self, from: data)
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
                            mode: sidecar.mode,
                            locationJSONL: sidecar.locationJSONL
                        )
                        let encoded = try encoder.encode(migrated)
                        try encoded.write(to: url, options: .atomic)
                        count += 1
                    } catch {
                        uploaderLog.error("legacy segment migration skipped \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                    }
                }
            }
        } catch {
            return LegacySegmentKeyMigrationResult(count: count, failure: String(describing: error))
        }

        return LegacySegmentKeyMigrationResult(count: count, failure: nil)
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
        guard self.localPortProvider() != nil else { return }

        let staleInMemoryTasks = self.taskInfoByTaskID.compactMap { taskID, info -> (Int, TaskInfo, URLSessionTask?)? in
            guard self.isStaleUploadIdentity(port: info.localPort, epoch: info.epoch) else { return nil }
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
            let requestPort = task.originalRequest?.url?.port

            if let descriptor = self.uploadTaskDescriptor(from: task.taskDescription) {
                let isCurrentIdentity = !self.isStaleUploadIdentity(
                    port: descriptor.localPort,
                    epoch: descriptor.epoch,
                    requestPort: requestPort
                )
                let audioURL = self.pendingAudioURL(sessionID: descriptor.sessionID, chunkID: descriptor.chunkID)
                let sidecarURL = self.pendingSidecarURL(sessionID: descriptor.sessionID, chunkID: descriptor.chunkID)
                guard isCurrentIdentity,
                      self.fileManager.fileExists(atPath: audioURL.path),
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
                    epoch: descriptor.epoch,
                    createdAt: descriptor.createdAt,
                    prefix: descriptor.prefix,
                    sourceType: descriptor.sourceType
                )
                self.activeTasksByTaskID[task.taskIdentifier] = task
                self.activeTaskIDByChunkID[descriptor.chunkID] = task.taskIdentifier
                continue
            }

            if let mobile = self.mobileSegmentUploadTaskDescriptor(from: task.taskDescription) {
                let isCurrentIdentity = !self.isStaleUploadIdentity(
                    port: mobile.localPort,
                    epoch: mobile.epoch,
                    requestPort: requestPort
                )
                let bodyURL = self.cacheRootURL
                    .appendingPathComponent("MobileSegmentBackgroundBodies", isDirectory: true)
                    .appendingPathComponent("\(mobile.segmentID.uuidString).upload", isDirectory: false)
                let dropped = self.mobileSegmentDroppedIDs.contains(mobile.segmentID)
                guard isCurrentIdentity,
                      !dropped,
                      self.fileManager.fileExists(atPath: bodyURL.path)
                else {
                    self.clearMobileSegmentTaskState(taskID: task.taskIdentifier, segmentID: mobile.segmentID)
                    task.cancel()
                    continue
                }

                let info = MobileSegmentTaskInfo(
                    segmentID: mobile.segmentID,
                    requestBodyURL: bodyURL,
                    boundary: self.boundary(for: mobile.segmentID.uuidString),
                    localPort: mobile.localPort,
                    epoch: mobile.epoch,
                    createdAt: mobile.createdAt,
                    prefix: mobile.prefix,
                    sourceType: mobile.sourceType
                )
                self.mobileSegmentTaskInfoByTaskID[task.taskIdentifier] = info
                self.mobileSegmentTaskByTaskID[task.taskIdentifier] = task
                self.mobileSegmentTaskIDBySegmentID[mobile.segmentID] = task.taskIdentifier
                continue
            }

            self.clearTaskState(taskID: task.taskIdentifier, chunkID: nil)
            task.cancel()
        }
    }

    func isStaleUploadIdentity(port: Int, epoch: UInt64?, requestPort: Int? = nil) -> Bool {
        self.staleUploadIdentityReason(port: port, epoch: epoch, requestPort: requestPort) != nil
    }

    func staleUploadIdentityReason(port: Int, epoch: UInt64?, requestPort: Int? = nil) -> String? {
        guard let currentPort = self.localPortProvider() else { return "missing-current-port" }
        guard port == currentPort else { return "port-stale" }
        guard let currentEpoch = self.activeEpochProvider() else { return "missing-current-epoch" }
        guard let epoch else { return "missing-epoch" }
        guard epoch == currentEpoch else { return "epoch-stale" }
        if let requestPort, requestPort != currentPort {
            return "request-port-stale"
        }
        return nil
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

    func taskDescription(for descriptor: MobileSegmentUploadTaskDescriptor) -> String? {
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

    func mobileSegmentUploadTaskDescriptor(from taskDescription: String?) -> MobileSegmentUploadTaskDescriptor? {
        guard let taskDescription,
              let data = taskDescription.data(using: .utf8),
              let descriptor = try? JSONDecoder().decode(MobileSegmentUploadTaskDescriptor.self, from: data),
              descriptor.kind == "mobile-segment"
        else {
            return nil
        }
        return descriptor
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

    func clearMobileSegmentTaskState(taskID: Int, segmentID: UUID?) {
        let resolvedSegmentID = segmentID ?? self.mobileSegmentTaskInfoByTaskID[taskID]?.segmentID
        self.mobileSegmentTaskInfoByTaskID.removeValue(forKey: taskID)
        self.mobileSegmentTaskByTaskID.removeValue(forKey: taskID)
        self.responseDataByTaskID.removeValue(forKey: taskID)
        if let resolvedSegmentID,
           self.mobileSegmentTaskIDBySegmentID[resolvedSegmentID] == taskID
        {
            self.mobileSegmentTaskIDBySegmentID.removeValue(forKey: resolvedSegmentID)
        }
    }

    func resolveTaskInfo(for task: URLSessionTask) -> TaskInfo? {
        if let info = self.taskInfoByTaskID.removeValue(forKey: task.taskIdentifier) {
            return info
        }
        guard let descriptor = self.uploadTaskDescriptor(from: task.taskDescription) else { return nil }
        let audioURL = self.pendingAudioURL(sessionID: descriptor.sessionID, chunkID: descriptor.chunkID)
        let sidecarURL = self.pendingSidecarURL(sessionID: descriptor.sessionID, chunkID: descriptor.chunkID)
        guard self.fileManager.fileExists(atPath: audioURL.path),
              self.fileManager.fileExists(atPath: sidecarURL.path)
        else {
            return nil
        }
        let requestBodyURL = self.pendingDirectoryURL(sessionID: descriptor.sessionID)
            .appendingPathComponent("\(descriptor.chunkID).upload", isDirectory: false)
        return TaskInfo(
            chunkID: descriptor.chunkID,
            sessionID: descriptor.sessionID,
            audioURL: audioURL,
            sidecarURL: sidecarURL,
            requestBodyURL: requestBodyURL,
            localPort: descriptor.localPort,
            epoch: descriptor.epoch,
            createdAt: descriptor.createdAt,
            prefix: descriptor.prefix,
            sourceType: descriptor.sourceType
        )
    }

    func resolveMobileSegmentTaskInfo(for task: URLSessionTask) -> MobileSegmentTaskInfo? {
        if let info = self.mobileSegmentTaskInfoByTaskID.removeValue(forKey: task.taskIdentifier) {
            return info
        }
        guard let descriptor = self.mobileSegmentUploadTaskDescriptor(from: task.taskDescription) else { return nil }
        let requestBodyURL = self.cacheRootURL
            .appendingPathComponent("MobileSegmentBackgroundBodies", isDirectory: true)
            .appendingPathComponent("\(descriptor.segmentID.uuidString).upload", isDirectory: false)
        guard self.fileManager.fileExists(atPath: requestBodyURL.path) else { return nil }
        return MobileSegmentTaskInfo(
            segmentID: descriptor.segmentID,
            requestBodyURL: requestBodyURL,
            boundary: self.boundary(for: descriptor.segmentID.uuidString),
            localPort: descriptor.localPort,
            epoch: descriptor.epoch,
            createdAt: descriptor.createdAt,
            prefix: descriptor.prefix,
            sourceType: descriptor.sourceType
        )
    }

    func clearUploadState(chunkID: String) {
        self.retryTasksByChunkID[chunkID]?.cancel()
        self.retryTasksByChunkID.removeValue(forKey: chunkID)
        self.attemptCountByChunkID.removeValue(forKey: chunkID)
        self.requeueAttemptCountByChunkID.removeValue(forKey: chunkID)
        if let taskID = self.activeTaskIDByChunkID.removeValue(forKey: chunkID) {
            self.activeTasksByTaskID[taskID]?.cancel()
            self.taskInfoByTaskID.removeValue(forKey: taskID)
            self.activeTasksByTaskID.removeValue(forKey: taskID)
            self.responseDataByTaskID.removeValue(forKey: taskID)
        }
    }

    func clearMobileSegmentUploadState(segmentID: UUID) {
        self.mobileSegmentRetryTasksBySegmentID[segmentID]?.cancel()
        self.mobileSegmentRetryTasksBySegmentID.removeValue(forKey: segmentID)
        self.mobileSegmentAttemptCountBySegmentID.removeValue(forKey: segmentID)
        self.mobileSegmentRequeueAttemptCountBySegmentID.removeValue(forKey: segmentID)
        self.mobileSegmentSchedulingIDs.remove(segmentID)
        if let taskID = self.mobileSegmentTaskIDBySegmentID.removeValue(forKey: segmentID) {
            self.mobileSegmentTaskByTaskID[taskID]?.cancel()
            self.mobileSegmentTaskInfoByTaskID.removeValue(forKey: taskID)
            self.mobileSegmentTaskByTaskID.removeValue(forKey: taskID)
            self.responseDataByTaskID.removeValue(forKey: taskID)
        }
        self.deleteMobileSegmentBody(for: segmentID)
    }

    private func deleteMobileSegmentBody(for segmentID: UUID) {
        let bodyURL = self.cacheRootURL
            .appendingPathComponent("MobileSegmentBackgroundBodies", isDirectory: true)
            .appendingPathComponent("\(segmentID.uuidString).upload", isDirectory: false)
        try? self.fileManager.removeItem(at: bodyURL)
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
            guard !Task.isCancelled else { return }
            await self.cooperator.step()
            guard !Task.isCancelled else { return }
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
                guard self.activeTaskIDByChunkID[chunkID] == nil,
                      !self.schedulingChunkIDs.contains(chunkID)
                else { continue }
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

    func recoverInProgressFiles(sessionID: UUID) async throws {
        let inProgressDirectory = self.inProgressDirectoryURL(sessionID: sessionID)
        let entries = try self.fileManager.contentsOfDirectory(
            at: inProgressDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var recoveredCount = 0
        var zeroByteRemovedCount = 0
        var parkedCount = 0

        for audioURL in entries where audioURL.pathExtension == "m4a" {
            guard !Task.isCancelled else { return }
            await self.cooperator.step()
            guard !Task.isCancelled else { return }

            let chunkID = audioURL.deletingPathExtension().lastPathComponent
            guard let byteCount = self.byteCountIfAvailable(at: audioURL) else {
                parkedCount += 1
                continue
            }
            if byteCount == 0 {
                try self.fileManager.removeItem(at: audioURL)
                zeroByteRemovedCount += 1
                continue
            }

            guard let chunkIndex = self.chunkIndex(fromChunkID: chunkID, sessionID: sessionID),
                  let duration = self.decodableAudioDuration(at: audioURL),
                  let startedAt = self.startedAtForRecoveredChunk(at: audioURL, duration: duration)
            else {
                parkedCount += 1
                continue
            }

            // Omi is the only writer that creates recoverable in-progress chunks today.
            let sidecar = ChunkSidecar(
                segment: ObserverSegmentNaming.segmentString(for: startedAt, durationSeconds: duration),
                day: ObserverSegmentNaming.dayString(for: startedAt),
                chunkIndex: chunkIndex,
                startedAt: startedAt,
                durationS: duration,
                sessionID: sessionID,
                mode: .meeting,
                locationJSONL: nil
            )
            await self.enqueue(chunkURL: audioURL, sidecar: sidecar)
            if self.fileManager.fileExists(atPath: audioURL.path) {
                parkedCount += 1
            } else {
                recoveredCount += 1
            }
        }

        if recoveredCount > 0 || zeroByteRemovedCount > 0 || parkedCount > 0 {
            uploaderLog.info(
                "observer in-progress recovery session=\(sessionID.uuidString, privacy: .public) recovered=\(recoveredCount, privacy: .public) zero-byte-removed=\(zeroByteRemovedCount, privacy: .public) parked=\(parkedCount, privacy: .public)"
            )
        }
    }

    func chunkIndex(fromChunkID chunkID: String, sessionID: UUID) -> Int? {
        let prefix = "\(sessionID.uuidString.lowercased())-"
        guard chunkID.hasPrefix(prefix) else { return nil }
        return Int(chunkID.dropFirst(prefix.count))
    }

    func decodableAudioDuration(at url: URL) -> Double? {
        do {
            let file = try AVAudioFile(forReading: url)
            let sampleRate = file.fileFormat.sampleRate
            let frameCount = file.length
            guard sampleRate > 0, frameCount > 0 else { return nil }
            return Double(frameCount) / sampleRate
        } catch {
            return nil
        }
    }

    func startedAtForRecoveredChunk(at url: URL, duration: TimeInterval) -> Date? {
        guard let attributes = try? self.fileManager.attributesOfItem(atPath: url.path) else {
            return nil
        }
        if let creationDate = attributes[.creationDate] as? Date {
            return creationDate
        }
        if let modificationDate = attributes[.modificationDate] as? Date {
            return modificationDate.addingTimeInterval(-duration)
        }
        return nil
    }

    func scheduleUpload(chunkID: String, sessionID: UUID) async {
        guard self.activeTaskIDByChunkID[chunkID] == nil else { return }
        guard !self.schedulingChunkIDs.contains(chunkID) else { return }
        self.schedulingChunkIDs.insert(chunkID)
        defer { self.schedulingChunkIDs.remove(chunkID) }

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
            return
        }

        guard let localPort = self.localPortProvider() else {
            uploaderLog.debug("observer upload held: local port unavailable")
            self.lastError = nil
            return
        }

        let handle: String
        do {
            handle = try await self.ensureRegistered()
        } catch {
            if self.droppedChunkIDs.remove(chunkID) != nil {
                uploaderLog.info("observer drop consumed during registration window (throw) \(chunkID, privacy: .public)")
                self.lastError = nil
                return
            }
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
        if self.droppedChunkIDs.remove(chunkID) != nil {
            uploaderLog.info("observer drop consumed during registration window (success) \(chunkID, privacy: .public)")
            self.lastError = nil
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
            let createResumeStart = DispatchTime.now().uptimeNanoseconds
            var request = ObserverAuthorizedRequest.make(url: url, handle: handle, method: "POST")
            request.setValue("multipart/form-data; boundary=\(self.boundary(for: chunkID))", forHTTPHeaderField: "Content-Type")

            guard self.droppedChunkIDs.remove(chunkID) == nil else {
                try? self.fileManager.removeItem(at: requestBodyURL)
                self.lastError = nil
                return
            }
            let createdAt = Date()
            let epoch = self.activeEpochProvider()
            let task = self.session.uploadTask(with: request, fromFile: requestBodyURL)
            task.taskDescription = self.taskDescription(for: UploadTaskDescriptor(
                sourceType: self.sourceType,
                chunkID: chunkID,
                sessionID: sessionID,
                localPort: localPort,
                epoch: epoch,
                createdAt: createdAt,
                prefix: prefix
            ))
            self.taskInfoByTaskID[task.taskIdentifier] = TaskInfo(
                chunkID: chunkID,
                sessionID: sessionID,
                audioURL: audioURL,
                sidecarURL: sidecarURL,
                requestBodyURL: requestBodyURL,
                localPort: localPort,
                epoch: epoch,
                createdAt: createdAt,
                prefix: prefix,
                sourceType: self.sourceType
            )
            self.activeTasksByTaskID[task.taskIdentifier] = task
            self.activeTaskIDByChunkID[chunkID] = task.taskIdentifier
            task.resume()
            DrainSignpost.event(
                .taskCreateResume,
                source: DrainSource.audio(self.sourceType),
                fields: DrainFields(
                    status: "resumed",
                    durationMs: DrainSignpost.durationMs(since: createResumeStart)
                )
            )
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

    func scheduleMobileSegmentUpload(segmentID: UUID, requestBodyURL: URL, boundary: String) async {
        guard self.mobileSegmentTaskIDBySegmentID[segmentID] == nil else { return }
        guard !self.mobileSegmentSchedulingIDs.contains(segmentID) else { return }
        self.mobileSegmentSchedulingIDs.insert(segmentID)
        defer { self.mobileSegmentSchedulingIDs.remove(segmentID) }

        guard self.fileManager.fileExists(atPath: requestBodyURL.path) else {
            await self.handleMobileSegmentUploadFailure(
                segmentID: segmentID,
                requestBodyURL: requestBodyURL,
                boundary: boundary,
                reason: "mobile segment request body missing",
                context: UploadFailureContext(
                    stage: "no-request-created",
                    severity: .warning,
                    sourceType: self.sourceType,
                    localPort: self.localPortProvider(),
                    prefix: self.registrationPrefixProvider(),
                    httpStatus: nil,
                    transportError: nil
                ),
                forceTerminal: false
            )
            return
        }

        guard self.isJournalConfigured() else {
            uploaderLog.debug("mobile segment upload held: journal unavailable")
            self.lastError = nil
            return
        }

        guard let localPort = self.localPortProvider() else {
            uploaderLog.debug("mobile segment upload held: local port unavailable")
            self.lastError = nil
            return
        }

        let handle: String
        do {
            handle = try await self.ensureRegistered()
        } catch {
            if self.mobileSegmentDroppedIDs.remove(segmentID) != nil {
                uploaderLog.info("mobile segment drop consumed during registration window (throw) \(segmentID.uuidString, privacy: .public)")
                self.lastError = nil
                self.deleteMobileSegmentBody(for: segmentID)
                self.mobileSegmentCompletionBySegmentID.removeValue(forKey: segmentID)?(.cancelled)
                return
            }
            await self.handleMobileSegmentUploadFailure(
                segmentID: segmentID,
                requestBodyURL: requestBodyURL,
                boundary: boundary,
                reason: String(describing: error),
                context: UploadFailureContext(
                    stage: "no-request-created",
                    severity: .warning,
                    sourceType: self.sourceType,
                    localPort: localPort,
                    prefix: self.registrationPrefixProvider(),
                    httpStatus: nil,
                    transportError: nil
                ),
                forceTerminal: false
            )
            return
        }
        if self.mobileSegmentDroppedIDs.remove(segmentID) != nil {
            uploaderLog.info("mobile segment drop consumed during registration window (success) \(segmentID.uuidString, privacy: .public)")
            self.lastError = nil
            self.deleteMobileSegmentBody(for: segmentID)
            self.mobileSegmentCompletionBySegmentID.removeValue(forKey: segmentID)?(.cancelled)
            return
        }
        let prefix = self.registrationPrefixProvider()

        guard let url = self.urlBuilder(localPort) else {
            await self.handleMobileSegmentUploadFailure(
                segmentID: segmentID,
                requestBodyURL: requestBodyURL,
                boundary: boundary,
                reason: "mobile segment upload unavailable: invalid url",
                context: UploadFailureContext(
                    stage: "no-request-created",
                    severity: .warning,
                    sourceType: self.sourceType,
                    localPort: localPort,
                    prefix: prefix,
                    httpStatus: nil,
                    transportError: nil
                ),
                forceTerminal: false
            )
            return
        }

        var request = ObserverAuthorizedRequest.make(url: url, handle: handle, method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        guard self.mobileSegmentDroppedIDs.remove(segmentID) == nil else {
            self.lastError = nil
            self.deleteMobileSegmentBody(for: segmentID)
            self.mobileSegmentCompletionBySegmentID.removeValue(forKey: segmentID)?(.cancelled)
            return
        }

        let createResumeStart = DispatchTime.now().uptimeNanoseconds
        let createdAt = Date()
        let epoch = self.activeEpochProvider()
        let task = self.session.uploadTask(with: request, fromFile: requestBodyURL)
        task.taskDescription = self.taskDescription(for: MobileSegmentUploadTaskDescriptor(
            kind: "mobile-segment",
            sourceType: self.sourceType,
            segmentID: segmentID,
            localPort: localPort,
            epoch: epoch,
            createdAt: createdAt,
            prefix: prefix
        ))
        self.mobileSegmentTaskInfoByTaskID[task.taskIdentifier] = MobileSegmentTaskInfo(
            segmentID: segmentID,
            requestBodyURL: requestBodyURL,
            boundary: boundary,
            localPort: localPort,
            epoch: epoch,
            createdAt: createdAt,
            prefix: prefix,
            sourceType: self.sourceType
        )
        self.mobileSegmentTaskByTaskID[task.taskIdentifier] = task
        self.mobileSegmentTaskIDBySegmentID[segmentID] = task.taskIdentifier
        task.resume()
        DrainSignpost.event(
            .taskCreateResume,
            source: .observer,
            fields: DrainFields(
                status: "resumed",
                durationMs: DrainSignpost.durationMs(since: createResumeStart)
            )
        )
    }

    func appendResponseData(_ data: Data, for taskIdentifier: Int) {
        self.responseDataByTaskID[taskIdentifier, default: Data()].append(data)
    }

    func armChunkReconnectRequeue(
        _ info: TaskInfo,
        httpStatus: Int? = nil,
        transportError: String? = nil,
        staleReason: String? = nil
    ) {
        let attempt = self.requeueAttemptCountByChunkID[info.chunkID, default: 0] + 1
        self.requeueAttemptCountByChunkID[info.chunkID] = attempt
        let delayIndex = min(attempt - 1, max(self.retryDelays.count - 1, 0))
        let requeueDelay = self.retryDelays.isEmpty ? 0 : self.retryDelays[delayIndex]
        // Re-enqueue correctness assumes a chunk that reached the server before reconnect
        // re-uploads to 2xx (sha256 dedup -> 200 duplicate). This branch owns
        // a delayed, un-counted re-drive; revisit if ingest ever returns 4xx
        // for duplicates.
        self.appendUploadDiagnostic(
            stage: "reconnect-requeued",
            severity: .info,
            sourceType: info.sourceType,
            chunkID: info.chunkID,
            prefix: info.prefix,
            localPort: info.localPort,
            epoch: info.epoch,
            currentPort: self.localPortProvider(),
            currentEpoch: self.activeEpochProvider(),
            staleReason: staleReason,
            taskAgeSeconds: info.createdAt.map { Date().timeIntervalSince($0) },
            httpStatus: httpStatus,
            transportError: transportError,
            attempt: attempt,
            reason: "reconnect requeued",
            isRequeue: true
        )
        self.retryTasksByChunkID[info.chunkID]?.cancel()
        self.retryTasksByChunkID[info.chunkID] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sleep(requeueDelay)
            guard !Task.isCancelled else { return }
            var waited: UInt64 = 0
            var lastPort = self.localPortProvider()
            var stableFor: UInt64 = 0
            while waited < self.requeueMaxDeferral {
                await self.sleep(self.requeueStabilityPoll)
                guard !Task.isCancelled else { return }
                waited += self.requeueStabilityPoll
                let port = self.localPortProvider()
                if let port, port == lastPort {
                    stableFor += self.requeueStabilityPoll
                    if stableFor >= self.requeueStabilityWindow { break }
                } else {
                    stableFor = 0
                    lastPort = port
                }
            }
            let held = self.localPortProvider() == nil || !self.isJournalConfigured()
            if held {
                self.armChunkReconnectRequeue(info, staleReason: staleReason)
                return
            }
            // Every reassignment cancels the previous retry first, so a non-cancelled retry is the current tracked entry; removing by key cannot delete a successor.
            self.retryTasksByChunkID.removeValue(forKey: info.chunkID)
            await self.scheduleUpload(chunkID: info.chunkID, sessionID: info.sessionID)
        }
    }

    func armMobileSegmentReconnectRequeue(
        _ info: MobileSegmentTaskInfo,
        httpStatus: Int? = nil,
        transportError: String? = nil,
        staleReason: String? = nil
    ) async {
        let attempt = self.mobileSegmentRequeueAttemptCountBySegmentID[info.segmentID, default: 0] + 1
        self.mobileSegmentRequeueAttemptCountBySegmentID[info.segmentID] = attempt
        if attempt >= mobileSegmentMaxRequeueAttempts {
            await self.handleMobileSegmentUploadFailure(
                segmentID: info.segmentID,
                requestBodyURL: info.requestBodyURL,
                boundary: info.boundary,
                reason: "requeue_cap_exceeded",
                context: UploadFailureContext(
                    stage: "reconnect-requeued",
                    severity: .error,
                    sourceType: info.sourceType,
                    localPort: info.localPort,
                    prefix: info.prefix,
                    httpStatus: nil,
                    transportError: "requeue_cap_exceeded"
                ),
                forceTerminal: true
            )
            self.mobileSegmentRetryTasksBySegmentID.removeValue(forKey: info.segmentID)
            return
        }
        let delayIndex = min(attempt - 1, max(self.retryDelays.count - 1, 0))
        let requeueDelay = self.retryDelays.isEmpty ? 0 : self.retryDelays[delayIndex]
        self.appendUploadDiagnostic(
            stage: "reconnect-requeued",
            severity: .info,
            sourceType: info.sourceType,
            chunkID: info.segmentID.uuidString,
            idLabel: "segmentID",
            prefix: info.prefix,
            localPort: info.localPort,
            epoch: info.epoch,
            currentPort: self.localPortProvider(),
            currentEpoch: self.activeEpochProvider(),
            staleReason: staleReason,
            taskAgeSeconds: info.createdAt.map { Date().timeIntervalSince($0) },
            httpStatus: httpStatus,
            transportError: transportError,
            attempt: attempt,
            reason: "reconnect requeued",
            isRequeue: true
        )
        self.mobileSegmentRetryTasksBySegmentID[info.segmentID]?.cancel()
        self.mobileSegmentRetryTasksBySegmentID[info.segmentID] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sleep(requeueDelay)
            guard !Task.isCancelled else { return }
            var waited: UInt64 = 0
            var lastPort = self.localPortProvider()
            var stableFor: UInt64 = 0
            while waited < self.requeueMaxDeferral {
                await self.sleep(self.requeueStabilityPoll)
                guard !Task.isCancelled else { return }
                waited += self.requeueStabilityPoll
                let port = self.localPortProvider()
                if let port, port == lastPort {
                    stableFor += self.requeueStabilityPoll
                    if stableFor >= self.requeueStabilityWindow { break }
                } else {
                    stableFor = 0
                    lastPort = port
                }
            }
            let held = self.localPortProvider() == nil || !self.isJournalConfigured()
            if held {
                await self.armMobileSegmentReconnectRequeue(info, staleReason: staleReason)
                return
            }
            self.mobileSegmentRetryTasksBySegmentID.removeValue(forKey: info.segmentID)
            // Reconnect requeues reuse the existing background request body.
            await self.scheduleMobileSegmentUpload(
                segmentID: info.segmentID,
                requestBodyURL: info.requestBodyURL,
                boundary: info.boundary
            )
        }
    }

    func handleCompletion(for task: URLSessionTask, error: (any Error)?) async {
        let start = DispatchTime.now().uptimeNanoseconds
        if let mobileDescriptor = self.mobileSegmentUploadTaskDescriptor(from: task.taskDescription) {
            let segmentID = mobileDescriptor.segmentID
            if self.mobileSegmentDroppedIDs.remove(segmentID) != nil {
                self.clearMobileSegmentTaskState(taskID: task.taskIdentifier, segmentID: segmentID)
                self.deleteMobileSegmentBody(for: segmentID)
                uploaderLog.info("mobile segment completion ignored after drop \(segmentID.uuidString, privacy: .public)")
                self.mobileSegmentCompletionBySegmentID.removeValue(forKey: segmentID)?(.cancelled)
                return
            }

            guard let info = self.resolveMobileSegmentTaskInfo(for: task) else {
                uploaderLog.error("mobile segment completion could not be reconciled to a known segment (task \(task.taskIdentifier, privacy: .public))")
                return
            }
            self.mobileSegmentTaskByTaskID.removeValue(forKey: task.taskIdentifier)
            if self.mobileSegmentTaskIDBySegmentID[info.segmentID] == task.taskIdentifier {
                self.mobileSegmentTaskIDBySegmentID.removeValue(forKey: info.segmentID)
            }
            let responseData = self.responseDataByTaskID.removeValue(forKey: task.taskIdentifier) ?? Data()
            await self.handleMobileSegmentCompletion(
                task: task,
                info: info,
                responseData: responseData,
                error: error,
                start: start
            )
            return
        }

        let descriptor = self.uploadTaskDescriptor(from: task.taskDescription)
        let resolvedChunkID = descriptor?.chunkID ?? self.taskInfoByTaskID[task.taskIdentifier]?.chunkID
        if let resolvedChunkID, self.droppedChunkIDs.remove(resolvedChunkID) != nil {
            self.clearTaskState(taskID: task.taskIdentifier, chunkID: resolvedChunkID)
            uploaderLog.info("observer dropped-chunk completion ignored \(resolvedChunkID, privacy: .public)")
            return
        }

        guard let info = self.resolveTaskInfo(for: task) else {
            uploaderLog.error("observer completion could not be reconciled to a known chunk (task \(task.taskIdentifier, privacy: .public))")
            return
        }
        let drainSource = DrainSource.audio(info.sourceType)
        self.activeTasksByTaskID.removeValue(forKey: task.taskIdentifier)
        if self.activeTaskIDByChunkID[info.chunkID] == task.taskIdentifier {
            self.activeTaskIDByChunkID.removeValue(forKey: info.chunkID)
        }
        let responseData = self.responseDataByTaskID.removeValue(forKey: task.taskIdentifier) ?? Data()

        if let error {
            let ns = error as NSError
            let isCancelled = ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
            let staleReason = self.staleUploadIdentityReason(port: info.localPort, epoch: info.epoch)
            let isStale = staleReason != nil
            if isCancelled || isStale {
                self.armChunkReconnectRequeue(
                    info,
                    httpStatus: (task.response as? HTTPURLResponse)?.statusCode,
                    transportError: String(describing: error),
                    staleReason: staleReason ?? "cancelled"
                )
                return
            }
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
            DrainSignpost.event(
                .uploadCompletion,
                source: drainSource,
                fields: DrainFields(
                    status: "transportFailure",
                    error: .transport,
                    durationMs: DrainSignpost.durationMs(since: start)
                )
            )
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
            let uploadedBytes = ThroughputMeter.byteCount(of: info.requestBodyURL)
            self.throughputMeter.record(
                bytes: uploadedBytes > 0 ? uploadedBytes : ThroughputMeter.byteCount(of: info.audioURL)
            )
            let removedAudio = (try? self.fileManager.removeItem(at: info.audioURL)) != nil
            try? self.fileManager.removeItem(at: info.sidecarURL)
            try? self.fileManager.removeItem(at: info.requestBodyURL)
            self.onSegmentDelivered?(info.sessionID)
            self.attemptCountByChunkID.removeValue(forKey: info.chunkID)
            self.requeueAttemptCountByChunkID.removeValue(forKey: info.chunkID)
            self.retryTasksByChunkID.removeValue(forKey: info.chunkID)
            self.lastUploadAt = Date()
            self.lastError = nil
            self.recentErrorCount = 0
            uploaderLog.info("observer chunk uploaded \(info.chunkID, privacy: .public)")
            if removedAudio {
                self.applyCountDelta(pending: -1, failed: 0, step: "completion")
            } else {
                self.refreshCounts()
            }
            DrainSignpost.event(
                .uploadCompletion,
                source: drainSource,
                fields: DrainFields(
                    status: "success",
                    error: .none,
                    durationMs: DrainSignpost.durationMs(since: start)
                )
            )
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
        DrainSignpost.event(
            .uploadCompletion,
            source: drainSource,
            fields: DrainFields(
                status: "httpFailure",
                error: .http,
                durationMs: DrainSignpost.durationMs(since: start),
                httpStatusClass: DrainSignpost.httpStatusClass(statusCode)
            )
        )
    }

    func handleMobileSegmentCompletion(
        task: URLSessionTask,
        info: MobileSegmentTaskInfo,
        responseData: Data,
        error: (any Error)?,
        start: UInt64
    ) async {
        if let error {
            let ns = error as NSError
            let isCancelled = ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
            let staleReason = self.staleUploadIdentityReason(port: info.localPort, epoch: info.epoch)
            let isStale = staleReason != nil
            if isCancelled || isStale {
                await self.armMobileSegmentReconnectRequeue(
                    info,
                    httpStatus: (task.response as? HTTPURLResponse)?.statusCode,
                    transportError: String(describing: error),
                    staleReason: staleReason ?? "cancelled"
                )
                return
            }
            await self.handleMobileSegmentUploadFailure(
                segmentID: info.segmentID,
                requestBodyURL: info.requestBodyURL,
                boundary: info.boundary,
                reason: String(describing: error),
                context: UploadFailureContext(
                    stage: "transport-failure",
                    severity: .warning,
                    sourceType: info.sourceType,
                    localPort: info.localPort,
                    prefix: info.prefix,
                    httpStatus: (task.response as? HTTPURLResponse)?.statusCode,
                    transportError: String(describing: error)
                ),
                forceTerminal: false
            )
            DrainSignpost.event(
                .uploadCompletion,
                source: .observer,
                fields: DrainFields(
                    status: "transportFailure",
                    error: .transport,
                    durationMs: DrainSignpost.durationMs(since: start)
                )
            )
            return
        }

        let statusCode = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if 200..<300 ~= statusCode {
            self.appendUploadDiagnostic(
                stage: "success",
                severity: .info,
                sourceType: info.sourceType,
                chunkID: info.segmentID.uuidString,
                idLabel: "segmentID",
                prefix: info.prefix,
                localPort: info.localPort,
                httpStatus: statusCode,
                transportError: nil,
                attempt: self.mobileSegmentAttemptCountBySegmentID[info.segmentID, default: 0] + 1,
                reason: "uploaded"
            )
            self.throughputMeter.record(bytes: ThroughputMeter.byteCount(of: info.requestBodyURL))
            self.mobileSegmentAttemptCountBySegmentID.removeValue(forKey: info.segmentID)
            self.mobileSegmentRequeueAttemptCountBySegmentID.removeValue(forKey: info.segmentID)
            self.mobileSegmentRetryTasksBySegmentID.removeValue(forKey: info.segmentID)
            self.lastUploadAt = Date()
            self.lastError = nil
            self.recentErrorCount = 0
            uploaderLog.info("mobile segment uploaded \(info.segmentID.uuidString, privacy: .public)")
            self.deleteMobileSegmentBody(for: info.segmentID)
            self.mobileSegmentCompletionBySegmentID.removeValue(forKey: info.segmentID)?(.delivered)
            DrainSignpost.event(
                .uploadCompletion,
                source: .observer,
                fields: DrainFields(
                    status: "success",
                    error: .none,
                    durationMs: DrainSignpost.durationMs(since: start)
                )
            )
            return
        }

        let body = self.httpFailureBodySnippet(from: responseData)
        await self.handleMobileSegmentUploadFailure(
            segmentID: info.segmentID,
            requestBodyURL: info.requestBodyURL,
            boundary: info.boundary,
            reason: body.map { "HTTP \(statusCode): \($0)" } ?? "HTTP \(statusCode)",
            context: UploadFailureContext(
                stage: "http-failure",
                severity: .warning,
                sourceType: info.sourceType,
                localPort: info.localPort,
                prefix: info.prefix,
                httpStatus: statusCode,
                transportError: nil
            ),
            forceTerminal: false
        )
        DrainSignpost.event(
            .uploadCompletion,
            source: .observer,
            fields: DrainFields(
                status: "httpFailure",
                error: .http,
                durationMs: DrainSignpost.durationMs(since: start),
                httpStatusClass: DrainSignpost.httpStatusClass(statusCode)
            )
        )
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
            redacted.replaceSubrange(bearerRange.lowerBound..<end, with: "[redacted bearer]")
        }
        return redacted
    }

    func handleMobileSegmentUploadFailure(
        segmentID: UUID,
        requestBodyURL: URL,
        boundary: String,
        reason: String,
        context: UploadFailureContext,
        forceTerminal: Bool
    ) async {
        self.mobileSegmentRequeueAttemptCountBySegmentID.removeValue(forKey: segmentID)
        let nextAttempt = self.mobileSegmentAttemptCountBySegmentID[segmentID, default: 0] + 1
        self.mobileSegmentAttemptCountBySegmentID[segmentID] = nextAttempt
        self.lastError = self.redactedFailureDetail(reason)
        self.recentErrorCount = min(self.recentErrorCount + 1, 99)
        self.appendUploadDiagnostic(
            stage: context.stage,
            severity: context.severity,
            sourceType: context.sourceType,
            chunkID: segmentID.uuidString,
            idLabel: "segmentID",
            prefix: context.prefix,
            localPort: context.localPort,
            httpStatus: context.httpStatus,
            transportError: context.transportError,
            attempt: nextAttempt,
            reason: reason
        )

        if forceTerminal || nextAttempt >= self.maxAttempts {
            self.appendUploadDiagnostic(
                stage: "retry-exhausted",
                severity: .error,
                sourceType: context.sourceType,
                chunkID: segmentID.uuidString,
                idLabel: "segmentID",
                prefix: context.prefix,
                localPort: context.localPort,
                httpStatus: context.httpStatus,
                transportError: context.transportError,
                attempt: nextAttempt,
                reason: reason
            )
            self.mobileSegmentRetryTasksBySegmentID[segmentID]?.cancel()
            self.mobileSegmentRetryTasksBySegmentID.removeValue(forKey: segmentID)
            self.mobileSegmentAttemptCountBySegmentID.removeValue(forKey: segmentID)
            let failure = ObserverMobileSegmentTransportFailure(
                reason: self.persistedFailureReason(
                    reason: reason,
                    context: context,
                    attemptCount: nextAttempt
                ),
                httpStatus: context.httpStatus,
                transportError: context.transportError.map { self.redactedFailureDetail($0) },
                attemptCount: nextAttempt,
                stage: context.stage,
                lastAttemptAt: Date()
            )
            self.deleteMobileSegmentBody(for: segmentID)
            self.mobileSegmentCompletionBySegmentID.removeValue(forKey: segmentID)?(.failed(failure))
            return
        }

        let delayIndex = min(nextAttempt - 1, max(self.retryDelays.count - 1, 0))
        let delay = self.retryDelays.isEmpty ? 0 : self.retryDelays[delayIndex]
        uploaderLog.error("mobile segment upload failed \(segmentID.uuidString, privacy: .public): \(self.redactedFailureDetail(reason), privacy: .public)")
        self.appendUploadDiagnostic(
            stage: "retry-scheduled",
            severity: .info,
            sourceType: context.sourceType,
            chunkID: segmentID.uuidString,
            idLabel: "segmentID",
            prefix: context.prefix,
            localPort: context.localPort,
            httpStatus: context.httpStatus,
            transportError: context.transportError,
            attempt: nextAttempt,
            reason: reason
        )
        self.mobileSegmentRetryTasksBySegmentID[segmentID]?.cancel()
        self.mobileSegmentRetryTasksBySegmentID[segmentID] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sleep(delay)
            guard !Task.isCancelled else { return }
            self.mobileSegmentRetryTasksBySegmentID.removeValue(forKey: segmentID)
            // Scheduled retries reuse the existing background request body.
            await self.scheduleMobileSegmentUpload(
                segmentID: segmentID,
                requestBodyURL: requestBodyURL,
                boundary: boundary
            )
        }
    }

    func handleUploadFailure(
        chunkID: String,
        sessionID: UUID,
        audioURL: URL,
        sidecarURL: URL,
        reason: String,
        context: UploadFailureContext
    ) async {
        self.requeueAttemptCountByChunkID.removeValue(forKey: chunkID)
        let nextAttempt = self.attemptCountByChunkID[chunkID, default: 0] + 1
        self.attemptCountByChunkID[chunkID] = nextAttempt
        self.lastError = self.redactedFailureDetail(reason)
        self.recentErrorCount = min(self.recentErrorCount + 1, 99)
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
                let delta = try self.movePendingPairToFailed(
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
                if delta.pending != 0 || delta.failed != 0 {
                    self.applyCountDelta(pending: delta.pending, failed: delta.failed, step: "exhaustion")
                }
            } catch {
                self.lastError = String(describing: error)
                self.refreshCounts()
            }
            self.retryTasksByChunkID[chunkID]?.cancel()
            self.retryTasksByChunkID.removeValue(forKey: chunkID)
            self.attemptCountByChunkID.removeValue(forKey: chunkID)
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
            // Every reassignment cancels the previous retry first, so a non-cancelled retry is the current tracked entry; removing by key cannot delete a successor.
            self.retryTasksByChunkID.removeValue(forKey: chunkID)
            await self.scheduleUpload(chunkID: chunkID, sessionID: sessionID)
        }
    }

    func appendUploadDiagnostic(
        stage: String,
        severity: DiagnosticSeverity,
        sourceType: String? = nil,
        chunkID: String,
        idLabel: String = "chunkID",
        prefix: String?,
        localPort: Int?,
        epoch: UInt64? = nil,
        currentPort: Int? = nil,
        currentEpoch: UInt64? = nil,
        staleReason: String? = nil,
        taskAgeSeconds: Double? = nil,
        httpStatus: Int?,
        transportError: String?,
        attempt: Int,
        reason: String,
        isRequeue: Bool = false
    ) {
        let source = sourceType ?? self.sourceType
        let safeTransportError = transportError.map { self.redactedFailureDetail($0) }
        let safeReason = self.redactedFailureDetail(reason)
        let detail = [
            "source=\(source)",
            "\(idLabel)=\(chunkID)",
            "prefix=\(prefix?.isEmpty == false ? prefix! : "unknown")",
            "localPort=\(localPort.map(String.init) ?? "none")",
            "epoch=\(epoch.map(String.init) ?? "none")",
            "currentPort=\(currentPort.map(String.init) ?? "none")",
            "currentEpoch=\(currentEpoch.map(String.init) ?? "none")",
            "staleReason=\(staleReason?.isEmpty == false ? staleReason! : "none")",
            "taskAgeSeconds=\(taskAgeSeconds.map { String(format: "%.1f", $0) } ?? "none")",
            "httpStatus=\(httpStatus.map(String.init) ?? "none")",
            "transportError=\(safeTransportError?.isEmpty == false ? safeTransportError! : "none")",
            isRequeue ? "requeueAttempt=\(attempt)" : "attempt=\(attempt)/\(self.maxAttempts)",
            "reason=\(safeReason)",
        ].joined(separator: " ")
        self.diagnosticLog?.append(
            category: .upload,
            severity: severity,
            message: stage == "success" ? "synced to your journal" : "\(source) upload \(stage)",
            detail: detail
        )
    }

    @discardableResult
    func movePendingPairToFailed(
        sessionID: UUID,
        chunkID: String,
        audioURL: URL?,
        sidecarURL: URL?,
        reason: String,
        failureSidecar: ObserverUploadFailureSidecar? = nil
    ) throws -> CountDelta {
        let failedDirectory = self.failedDirectoryURL(sessionID: sessionID)
        try self.fileManager.createDirectory(at: failedDirectory, withIntermediateDirectories: true)
        var delta = CountDelta(pending: 0, failed: 0)

        if let audioURL, self.fileManager.fileExists(atPath: audioURL.path) {
            let target = failedDirectory.appendingPathComponent(audioURL.lastPathComponent, isDirectory: false)
            let targetExisted = self.fileManager.fileExists(atPath: target.path)
            if targetExisted {
                try self.fileManager.removeItem(at: target)
            }
            try self.fileManager.moveItem(at: audioURL, to: target)
            delta = CountDelta(pending: -1, failed: targetExisted ? 0 : 1)
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
        return delta
    }

    func buildMultipartRequestBody(audioURL: URL, sidecar: ChunkSidecar) throws -> URL {
        let chunkID = audioURL.deletingPathExtension().lastPathComponent
        let requestBodyURL = self.pendingDirectoryURL(sessionID: sidecar.sessionID)
            .appendingPathComponent("\(chunkID).upload", isDirectory: false)
        return try self.buildObserverIngestMultipartRequestBody(
            audioURL: audioURL,
            locationJSONL: sidecar.locationJSONL,
            screenURL: nil,
            metadata: ObserverIngestMultipartMetadata(
                segment: sidecar.segment,
                day: sidecar.day,
                startedAt: sidecar.startedAt,
                durationS: sidecar.durationS,
                chunkIndex: sidecar.chunkIndex,
                sessionID: sidecar.sessionID,
                mode: sidecar.mode,
                segmentID: nil,
                sources: ["audio"]
            ),
            requestBodyURL: requestBodyURL,
            boundary: self.boundary(for: chunkID),
            drainSource: DrainSource.audio(self.sourceType)
        )
    }

    func buildObserverIngestMultipartRequestBody(
        audioURL: URL?,
        locationJSONL: Data?,
        screenURL: URL?,
        metadata: ObserverIngestMultipartMetadata,
        requestBodyURL: URL,
        boundary: String,
        drainSource source: DrainSource
    ) throws -> URL {
        guard audioURL != nil || locationJSONL != nil || screenURL != nil else {
            throw ObserverUploaderError.missingUploadArtifact
        }

        let interval = DrainSignpost.begin(.multipartBodyBuild, source: source)
        do {
            var body = Data()
            body.append(self.multipartField(named: "segment", value: metadata.segment, boundary: boundary))
            body.append(self.multipartField(named: "day", value: metadata.day, boundary: boundary))
            body.append(self.multipartField(named: "platform", value: self.platform, boundary: boundary))

            var metaObject: [String: Any] = [
                "segment": metadata.segment,
                "day": metadata.day,
                "started_at": ISO8601DateFormatter().string(from: metadata.startedAt),
                "duration_s": metadata.durationS,
                "sources": metadata.sources,
            ]
            if let chunkIndex = metadata.chunkIndex {
                metaObject["chunk_index"] = chunkIndex
            }
            if let sessionID = metadata.sessionID {
                metaObject["session_id"] = sessionID.uuidString
            }
            if let mode = metadata.mode {
                metaObject["mode"] = mode.rawValue
            }
            if let segmentID = metadata.segmentID {
                metaObject["segment_id"] = segmentID.uuidString
            }
            let meta = try JSONSerialization.data(withJSONObject: metaObject, options: [.sortedKeys])
            body.append(self.multipartField(
                named: "meta",
                value: String(decoding: meta, as: UTF8.self),
                boundary: boundary
            ))

            if let audioURL {
                let audioData = try Data(contentsOf: audioURL)
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                // audio.m4a filename is a hard server-side invariant — pipeline globs audio.* downstream (observe/transcribe, think/cluster, transcripts, retention)
                body.append("Content-Disposition: form-data; name=\"\(ObserverServerURL.filesFieldName)\"; filename=\"audio.m4a\"\r\n".data(using: .utf8)!)
                body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
                body.append(audioData)
                body.append("\r\n".data(using: .utf8)!)
            }
            if let locationJSONL {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"\(ObserverServerURL.filesFieldName)\"; filename=\"location.jsonl\"\r\n".data(using: .utf8)!)
                body.append("Content-Type: application/x-ndjson\r\n\r\n".data(using: .utf8)!)
                body.append(locationJSONL)
                body.append("\r\n".data(using: .utf8)!)
            }
            if let screenURL {
                let screenData = try Data(contentsOf: screenURL)
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"\(ObserverServerURL.filesFieldName)\"; filename=\"screen.mp4\"\r\n".data(using: .utf8)!)
                body.append("Content-Type: video/mp4\r\n\r\n".data(using: .utf8)!)
                body.append(screenData)
                body.append("\r\n".data(using: .utf8)!)
            }
            body.append("--\(boundary)--\r\n".data(using: .utf8)!)
            let byteCount = body.count
            try body.write(to: requestBodyURL, options: .atomic)
            DrainSignpost.end(
                interval,
                source: source,
                fields: DrainFields(status: "success", error: .none, bytes: byteCount)
            )
            return requestBodyURL
        } catch {
            DrainSignpost.end(
                interval,
                source: source,
                fields: DrainFields(status: "failure", error: .filesystem)
            )
            throw error
        }
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
        self.fullRecountCount += 1
        let start = DispatchTime.now().uptimeNanoseconds
        self.pendingCount = self.countFiles(named: "pending", withExtension: "m4a")
        self.failedCount = self.countFiles(named: "failed", withExtension: "m4a")
        DrainSignpost.event(
            .countRefresh,
            source: DrainSource.audio(self.sourceType),
            fields: DrainFields(
                status: "success",
                pending: self.pendingCount,
                failed: self.failedCount,
                durationMs: DrainSignpost.durationMs(since: start)
            )
        )
    }

    // Observer/Omi/Watch audio counts track pending/failed .m4a files;
    // share and location keep their full-scan count paths.
    func applyCountDelta(pending: Int, failed: Int, step: String) {
        guard pending != 0 || failed != 0 else { return }
        self.pendingCount = max(0, self.pendingCount + pending)
        self.failedCount = max(0, self.failedCount + failed)
        DrainSignpost.event(
            .countDelta,
            source: DrainSource.audio(self.sourceType),
            fields: DrainFields(
                status: "success",
                pending: self.pendingCount,
                failed: self.failedCount,
                step: step
            )
        )
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
    case missingUploadArtifact
}
