// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Network
import Observation
import os
import UniformTypeIdentifiers

private let importQueueLog = Logger(subsystem: "app.solstone.swift", category: "import-queue")

final class ImportQueueSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate {
    private struct WeakOwner: Sendable {
        weak var value: ImportQueue?
    }

    private let ownerBox = OSAllocatedUnfairLock<WeakOwner>(initialState: WeakOwner())
    private let responseBufferLock = OSAllocatedUnfairLock<[Int: Data]>(initialState: [:])

    func setOwner(_ owner: ImportQueue?) {
        self.ownerBox.withLock { $0.value = owner }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        self.responseBufferLock.withLock { $0[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let responseData = self.responseBufferLock.withLock { $0.removeValue(forKey: task.taskIdentifier) ?? Data() }
        Task { @MainActor [weak self] in
            guard let owner = self?.ownerBox.withLock({ $0.value }) else { return }
            await owner.handleCompletion(for: task, responseData: responseData, error: error)
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
final class ImportQueue {
    nonisolated static let backgroundSessionIdentifier = "app.solstone.swift.share-upload"
    // Keep one reconnecting source from launching storm-scale concurrency; TF35 saw 160 concurrent uploads.
    nonisolated static let maxInFlightPerSource = 3

    nonisolated static func makeBackgroundConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        config.waitsForConnectivity = true
        config.sharedContainerIdentifier = AppGroupContainer.identifier
        return config
    }

    var pendingCount = 0
    var failedCount = 0
    var lastDeliveredAt: Date?
    var lastError: String?
    private let throughputMeter = ThroughputMeter()

    var inFlightCount: Int {
        self.uploadTaskByItemID.count + self.retryTasksByItemID.count + self.schedulingItemIDs.count
    }

    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let cacheRootURL: URL
    @ObservationIgnored private let sessionDelegate: ImportQueueSessionDelegate
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let ensureRegistered: @Sendable @MainActor () async throws -> String
    @ObservationIgnored private let isJournalConfigured: @Sendable @MainActor () -> Bool
    @ObservationIgnored private let localPortProvider: @Sendable @MainActor () -> Int?
    @ObservationIgnored private let saveURLBuilder: @Sendable (Int) -> URL?
    @ObservationIgnored private let startURLBuilder: @Sendable (Int) -> URL?
    @ObservationIgnored private let retryDelays: [UInt64]
    @ObservationIgnored private let maxAttempts: Int
    @ObservationIgnored private let sleep: @Sendable (UInt64) async -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private let decoder = JSONDecoder()
    @ObservationIgnored private var backgroundCompletionHandler: (@MainActor @Sendable () -> Void)?
    @ObservationIgnored private var taskInfoByTaskID: [Int: TaskInfo] = [:]
    @ObservationIgnored private var activeTaskIDByItemID: [String: Int] = [:]
    @ObservationIgnored private var uploadTaskByItemID: [String: URLSessionTask] = [:]
    @ObservationIgnored private var attemptCountByItemID: [String: Int] = [:]
    @ObservationIgnored private var retryTasksByItemID: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var schedulingItemIDs: Set<String> = []
    @ObservationIgnored private var inFlightItemIDsBySource: [String: Set<String>] = [:]
    @ObservationIgnored private var waitingItemIDsBySource: [String: [String]] = [:]
    @ObservationIgnored private var sourceByItemID: [String: String] = [:]
    @ObservationIgnored private var droppedItemIDs: Set<String> = []
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private let pathMonitorQueue = DispatchQueue(label: "app.solstone.swift.import-queue")

    var recentBytesPerSecond: Double {
        self.throughputMeter.recentBytesPerSecond
    }

    init(
        cacheRootURL: URL? = nil,
        fileManager: FileManager = .default,
        sessionConfiguration: URLSessionConfiguration? = nil,
        ensureRegistered: @escaping @Sendable @MainActor () async throws -> String = {
            throw ImportQueueError.registrationUnavailable
        },
        isJournalConfigured: @escaping @Sendable @MainActor () -> Bool = { true },
        localPortProvider: @escaping @Sendable @MainActor () -> Int? = { nil },
        saveURLBuilder: @escaping @Sendable (Int) -> URL? = { ImporterServerURL.saveURL(localPort: $0) },
        startURLBuilder: @escaping @Sendable (Int) -> URL? = { ImporterServerURL.startURL(localPort: $0) },
        retryDelays: [UInt64] = [2, 4, 8, 16],
        maxAttempts: Int = 5,
        sleep: @escaping @Sendable (UInt64) async -> Void = { delay in
            try? await Task.sleep(for: .seconds(delay))
        },
        startPathMonitor: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileManager = fileManager
        self.cacheRootURL = cacheRootURL ?? Self.defaultCacheRootURL(fileManager: fileManager)
        self.ensureRegistered = ensureRegistered
        self.isJournalConfigured = isJournalConfigured
        self.localPortProvider = localPortProvider
        self.saveURLBuilder = saveURLBuilder
        self.startURLBuilder = startURLBuilder
        self.retryDelays = retryDelays
        self.maxAttempts = maxAttempts
        self.sleep = sleep
        self.now = now

        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder.dateDecodingStrategy = .iso8601

        self.sessionDelegate = ImportQueueSessionDelegate()
        let configuration = sessionConfiguration ?? Self.makeBackgroundConfiguration()
        self.session = URLSession(configuration: configuration, delegate: self.sessionDelegate, delegateQueue: nil)
        self.sessionDelegate.setOwner(self)

        try? self.ensureRootDirectories()
        self.refreshCounts()

        if startPathMonitor {
            self.startPathMonitor()
        }
    }

    func enqueue(
        fileURL: URL,
        source: String,
        targetJournal: String,
        contentType: String,
        originalFilename: String? = nil,
        originApp: String? = nil
    ) async throws -> UUID {
        let itemID = UUID()
        let itemIDString = Self.itemIDString(itemID)
        let itemDirectory = self.pendingItemDirectoryURL(itemID: itemIDString)

        do {
            try self.ensureRootDirectories()
            let placement = try self.resolvePlacement(for: fileURL)
            let rawInfo = Self.rawFileInfo(for: contentType)
            let rawBytes = try self.rawByteCount(fileURL: fileURL)
            let note = FrozenNote(
                source: source,
                originApp: originApp,
                contentType: contentType,
                filename: originalFilename,
                bytes: rawBytes,
                basis: placement.basis,
                itemTime: Self.iso8601String(for: placement.itemTime),
                targetJournal: targetJournal,
                itemID: itemIDString
            )
            let noteData = try Self.orderedNoteData(note)
            let descriptor = RequestDescriptor(
                source: source,
                filename: rawInfo.filename,
                contentType: rawInfo.mimeType
            )
            let descriptorData = try self.encoder.encode(descriptor)

            try self.fileManager.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
            try self.fileManager.copyItem(at: fileURL, to: self.rawURL(itemID: itemIDString, status: .pending))
            guard self.fileManager.createFile(
                atPath: self.noteURL(itemID: itemIDString, status: .pending).path,
                contents: noteData,
                attributes: nil
            ) else {
                throw ImportQueueError.writeFailed(path: self.noteURL(itemID: itemIDString, status: .pending).path)
            }
            guard self.fileManager.createFile(
                atPath: self.descriptorURL(itemID: itemIDString, status: .pending).path,
                contents: descriptorData,
                attributes: nil
            ) else {
                throw ImportQueueError.writeFailed(path: self.descriptorURL(itemID: itemIDString, status: .pending).path)
            }

            importQueueLog.info("import item enqueued \(itemIDString, privacy: .public)")
            self.refreshCounts()
            await self.scheduleUpload(itemID: itemIDString)
            return itemID
        } catch {
            try? self.fileManager.removeItem(at: itemDirectory)
            let detail = String(describing: error)
            importQueueLog.error("failed to enqueue import item \(itemIDString, privacy: .public): \(detail, privacy: .public)")
            self.lastError = detail
            self.refreshCounts()
            throw error
        }
    }

    func resumeFromDisk() async {
        do {
            try self.ensureRootDirectories()
            let ledger = try self.loadLedger()
            await self.reconcilePortIfNeeded()
            let itemDirectories = try self.fileManager.contentsOfDirectory(
                at: self.pendingDirectoryURL(),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for itemDirectory in itemDirectories {
                let itemID = itemDirectory.lastPathComponent
                guard self.isDirectory(itemDirectory) else { continue }

                if ledger[itemID] != nil {
                    try? self.fileManager.removeItem(at: itemDirectory)
                    continue
                }

                guard self.requiredFilesExist(itemID: itemID, status: .pending) else {
                    try self.movePendingItemToFailed(
                        itemID: itemID,
                        reason: "import item missing required artifact"
                    )
                    continue
                }

                // Skip items with a live upload task or an in-progress scheduling reservation; resume must not delete a body a live URLSessionTask is streaming.
                guard self.activeTaskIDByItemID[itemID] == nil,
                      !self.schedulingItemIDs.contains(itemID) else { continue }
                try? self.fileManager.removeItem(at: self.saveUploadURL(itemID: itemID, status: .pending))
                try? self.fileManager.removeItem(at: self.startUploadURL(itemID: itemID, status: .pending))
                await self.scheduleUpload(itemID: itemID)
            }
        } catch {
            let detail = String(describing: error)
            importQueueLog.error("import queue resume failed: \(detail, privacy: .public)")
            self.lastError = detail
        }

        self.refreshCounts()
    }

    func requeueFailedItem(itemID: UUID) async throws {
        let itemIDString = Self.itemIDString(itemID)
        let failedURL = self.failedItemDirectoryURL(itemID: itemIDString)
        let pendingURL = self.pendingItemDirectoryURL(itemID: itemIDString)
        guard self.requiredFilesExist(itemID: itemIDString, status: .failed) else {
            throw ImportQueueError.missingRequiredArtifact(itemID: itemIDString)
        }

        try self.ensureRootDirectories()
        if self.fileManager.fileExists(atPath: pendingURL.path) {
            try self.fileManager.removeItem(at: pendingURL)
        }
        try self.fileManager.moveItem(at: failedURL, to: pendingURL)
        self.attemptCountByItemID.removeValue(forKey: itemIDString)
        self.retryTasksByItemID[itemIDString]?.cancel()
        self.retryTasksByItemID.removeValue(forKey: itemIDString)
        self.refreshCounts()
        await self.scheduleUpload(itemID: itemIDString)
    }

    @MainActor
    func retryFailed() async {
        let failedDirectories = (try? self.fileManager.contentsOfDirectory(
            at: self.failedDirectoryURL(),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let sortedDirectories = failedDirectories.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for directory in sortedDirectories where self.isDirectory(directory) {
            guard let itemID = UUID(uuidString: directory.lastPathComponent) else { continue }
            do {
                try await self.requeueFailedItem(itemID: itemID)
            } catch {
                self.lastError = String(describing: error)
            }
        }

        self.refreshCounts()
    }

    func dropItem(itemID: UUID) {
        let itemIDString = Self.itemIDString(itemID)
        self.removeWaitingSlot(itemID: itemIDString)
        if self.sourceByItemID[itemIDString] != nil {
            Task { @MainActor [weak self] in
                await self?.releaseInFlightSlot(itemID: itemIDString)
            }
        }
        let hadLiveWork = self.uploadTaskByItemID[itemIDString] != nil
            || self.activeTaskIDByItemID[itemIDString] != nil
            || self.schedulingItemIDs.contains(itemIDString)
        if hadLiveWork {
            self.droppedItemIDs.insert(itemIDString)
        }
        self.uploadTaskByItemID[itemIDString]?.cancel()
        self.retryTasksByItemID[itemIDString]?.cancel()
        self.retryTasksByItemID.removeValue(forKey: itemIDString)
        self.attemptCountByItemID.removeValue(forKey: itemIDString)
        if let taskID = self.activeTaskIDByItemID.removeValue(forKey: itemIDString) {
            self.taskInfoByTaskID.removeValue(forKey: taskID)
        }
        try? self.fileManager.removeItem(at: self.pendingItemDirectoryURL(itemID: itemIDString))
        try? self.fileManager.removeItem(at: self.failedItemDirectoryURL(itemID: itemIDString))
        self.uploadTaskByItemID.removeValue(forKey: itemIDString)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let tasks = await self.sessionTasks()
            for task in tasks where task.taskDescription == itemIDString {
                task.cancel()
            }
        }
        self.refreshCounts()
        importQueueLog.info("import item dropped \(itemIDString, privacy: .public)")
    }

    func attemptCountForTesting(itemID: String) -> Int {
        self.attemptCountByItemID[itemID, default: 0]
    }

    func isDropTombstonedForTesting(itemID: String) -> Bool {
        self.droppedItemIDs.contains(itemID)
    }

    func plantDropTombstoneForTesting(itemID: String) {
        self.droppedItemIDs.insert(itemID)
    }

    func onThisPhoneSourceSnapshot() -> OnThisPhoneSourceResult {
        let interval = DrainSignpost.begin(.sourceSnapshotScan, source: .share)
        let ledger: [String: LedgerEntry]
        do {
            ledger = try self.loadLedger()
        } catch {
            DrainSignpost.end(
                interval,
                source: .share,
                fields: DrainFields(
                    status: "failed",
                    error: DrainErrorCategory.classify(error),
                    items: 0
                )
            )
            return .failed
        }

        var items: [OnThisPhoneItem] = []
        let pendingDirectories = (try? self.fileManager.contentsOfDirectory(
            at: self.pendingDirectoryURL(),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for directory in pendingDirectories where self.isDirectory(directory) {
            let itemID = directory.lastPathComponent
            guard ledger[itemID] == nil else { continue }
            items.append(self.localOnThisPhoneItem(
                itemID: itemID,
                status: .pending,
                location: .pending,
                isActivelyUploading: self.activeTaskIDByItemID[itemID] != nil
            ))
        }

        let failedDirectories = (try? self.fileManager.contentsOfDirectory(
            at: self.failedDirectoryURL(),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for directory in failedDirectories where self.isDirectory(directory) {
            let itemID = directory.lastPathComponent
            guard ledger[itemID] == nil else { continue }
            items.append(self.localOnThisPhoneItem(
                itemID: itemID,
                status: .failed,
                location: .failed,
                isActivelyUploading: false
            ))
        }

        for (itemID, entry) in ledger {
            items.append(self.deliveredOnThisPhoneItem(itemID: itemID, entry: entry))
        }

        let sortedItems = items.sorted { lhs, rhs in
            (lhs.deliveredAt ?? lhs.itemTime ?? .distantPast) > (rhs.deliveredAt ?? rhs.itemTime ?? .distantPast)
        }
        DrainSignpost.end(
            interval,
            source: .share,
            fields: DrainFields(status: "loaded", error: .none, items: sortedItems.count)
        )
        return .loaded(items: sortedItems)
    }

    func handleBackgroundURLSessionEvents(completionHandler: @escaping @MainActor @Sendable () -> Void) {
        self.backgroundCompletionHandler = completionHandler
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

private extension ImportQueue {
    enum ItemStatus {
        case pending
        case failed
    }

    enum TaskStep: Sendable {
        case save
        case start

        var drainLabel: String {
            switch self {
            case .save:
                "save"
            case .start:
                "start"
            }
        }
    }

    struct TaskInfo {
        let itemID: String
        let itemDirectoryURL: URL
        let bodyURL: URL
        let step: TaskStep
        let descriptor: RequestDescriptor
        let ledgerStub: LedgerStub
        let saveResult: SaveResult?
    }

    struct Placement {
        let basis: String
        let itemTime: Date
    }

    struct RawFileInfo {
        let filename: String
        let mimeType: String
    }

    struct FrozenNote {
        let source: String
        let originApp: String?
        let contentType: String
        let filename: String?
        let bytes: Int64
        let basis: String
        let itemTime: String
        let targetJournal: String
        let itemID: String
    }

    struct RequestDescriptor: Codable, Equatable, Sendable {
        let source: String
        let filename: String
        let contentType: String

        enum CodingKeys: String, CodingKey {
            case source
            case filename
            case contentType = "content_type"
        }
    }

    struct LedgerStub {
        let basis: String
        let contentType: String
        let targetJournal: String
        let filename: String?
        let originApp: String?
        let itemTime: String?
    }

    struct LedgerEntry: Codable, Equatable, Sendable {
        let itemID: String
        let basis: String
        let contentType: String
        let targetJournal: String
        let serverPath: String?
        let serverTimestamp: String?
        let deliveredAt: Date
        let filename: String?
        let originApp: String?
        let itemTime: String?

        enum CodingKeys: String, CodingKey {
            case itemID = "item_id"
            case basis
            case contentType = "content_type"
            case targetJournal = "target_journal"
            case serverPath = "server_path"
            case serverTimestamp = "server_timestamp"
            case deliveredAt = "delivered_at"
            case filename
            case originApp = "origin_app"
            case itemTime = "item_time"
        }
    }

    enum RecommendedAction: String, Decodable {
        case start
        case doNotStart = "do_not_start"
    }

    struct SaveResult: Codable, Equatable, Sendable {
        let path: String
        let timestamp: String
        let recommendedAction: String
        let source: String?

        enum CodingKeys: String, CodingKey {
            case path
            case timestamp
            case source
            case recommendedAction = "recommended_action"
        }
    }

    struct SaveResponse: Decodable {
        let status: String?
        let replay: Bool?
        let path: String?
        let timestamp: String?
        let clientItemID: String
        let source: String?
        let recommendedAction: RecommendedAction

        enum CodingKeys: String, CodingKey {
            case status
            case replay
            case path
            case timestamp
            case source
            case clientItemID = "client_item_id"
            case recommendedAction = "recommended_action"
        }
    }

    struct StartResponse: Decodable {
        let status: String?
        let taskID: String?

        enum CodingKeys: String, CodingKey {
            case status
            case taskID = "task_id"
        }
    }

    struct StartErrorResponse: Decodable {
        let reasonCode: String?

        enum CodingKeys: String, CodingKey {
            case reasonCode = "reason_code"
        }
    }

    struct StartRequest: Encodable {
        let path: String
        let timestamp: String
    }

    static func defaultCacheRootURL(fileManager: FileManager) -> URL {
        do {
            return try AppGroupContainer.rootURL(fileManager: fileManager)
                .appendingPathComponent("ImportQueue", isDirectory: true)
        } catch {
            preconditionFailure("app group container unavailable: \(error)")
        }
    }

    nonisolated static func itemIDString(_ itemID: UUID) -> String {
        itemID.uuidString.lowercased()
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
        let tasks = await self.sessionTasks()
        guard !self.taskInfoByTaskID.isEmpty || !tasks.isEmpty else { return }
        guard let currentPort = self.localPortProvider() else { return }

        let staleInMemoryTasks = self.taskInfoByTaskID.compactMap { taskID, info -> (Int, TaskInfo, URLSessionTask)? in
            guard let task = self.uploadTaskByItemID[info.itemID],
                  let requestPort = task.originalRequest?.url?.port,
                  requestPort != currentPort
            else {
                return nil
            }
            return (taskID, info, task)
        }
        for (taskID, info, task) in staleInMemoryTasks {
            self.taskInfoByTaskID.removeValue(forKey: taskID)
            if self.activeTaskIDByItemID[info.itemID] == taskID {
                self.activeTaskIDByItemID.removeValue(forKey: info.itemID)
            }
            if self.uploadTaskByItemID[info.itemID]?.taskIdentifier == taskID {
                self.uploadTaskByItemID.removeValue(forKey: info.itemID)
            }
            task.cancel()
            await self.scheduleUpload(itemID: info.itemID)
        }

        guard !tasks.isEmpty else { return }

        for task in tasks {
            guard let itemID = task.taskDescription,
                  !itemID.isEmpty,
                  task.originalRequest?.url?.port == currentPort,
                  let info = try? self.reconstructTaskInfo(itemID: itemID)
            else {
                task.cancel()
                continue
            }

            self.taskInfoByTaskID[task.taskIdentifier] = info
            self.activeTaskIDByItemID[itemID] = task.taskIdentifier
            self.uploadTaskByItemID[itemID] = task
        }
    }

    func sessionTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            self.session.getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }
    }

    func reconstructTaskInfo(itemID: String) throws -> TaskInfo? {
        guard self.requiredFilesExist(itemID: itemID, status: .pending) else { return nil }

        let descriptor = try self.loadDescriptor(itemID: itemID, status: .pending)
        let ledgerStub = try self.loadLedgerStub(itemID: itemID, status: .pending)
        let itemDirectoryURL = self.pendingItemDirectoryURL(itemID: itemID)
        let saveResult = try self.loadSaveResultIfPresent(itemID: itemID, status: .pending)
        let step: TaskStep
        let bodyURL: URL
        let taskSaveResult: SaveResult?

        if let saveResult {
            guard saveResult.recommendedAction == RecommendedAction.start.rawValue else { return nil }
            step = .start
            bodyURL = self.startUploadURL(itemID: itemID, status: .pending)
            taskSaveResult = saveResult
        } else {
            step = .save
            bodyURL = self.saveUploadURL(itemID: itemID, status: .pending)
            taskSaveResult = nil
        }

        guard self.fileManager.fileExists(atPath: bodyURL.path) else { return nil }
        return TaskInfo(
            itemID: itemID,
            itemDirectoryURL: itemDirectoryURL,
            bodyURL: bodyURL,
            step: step,
            descriptor: descriptor,
            ledgerStub: ledgerStub,
            saveResult: taskSaveResult
        )
    }

    func reserveInFlightSlot(itemID: String, source: String) -> Bool {
        if self.inFlightItemIDsBySource[source]?.contains(itemID) == true {
            return true
        }

        let inFlightCount = self.inFlightItemIDsBySource[source]?.count ?? 0
        guard inFlightCount < Self.maxInFlightPerSource else {
            var waiting = self.waitingItemIDsBySource[source, default: []]
            if !waiting.contains(itemID) {
                waiting.append(itemID)
                self.waitingItemIDsBySource[source] = waiting
            }
            importQueueLog.debug("import upload held: per-source cap")
            return false
        }

        self.inFlightItemIDsBySource[source, default: []].insert(itemID)
        self.sourceByItemID[itemID] = source
        return true
    }

    func releaseInFlightSlot(itemID: String) async {
        guard let source = self.sourceByItemID.removeValue(forKey: itemID) else { return }

        self.inFlightItemIDsBySource[source]?.remove(itemID)
        if self.inFlightItemIDsBySource[source]?.isEmpty == true {
            self.inFlightItemIDsBySource.removeValue(forKey: source)
        }

        guard var waiting = self.waitingItemIDsBySource[source], !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        if waiting.isEmpty {
            self.waitingItemIDsBySource.removeValue(forKey: source)
        } else {
            self.waitingItemIDsBySource[source] = waiting
        }
        await self.scheduleUpload(itemID: next)
    }

    func removeWaitingSlot(itemID: String) {
        for source in Array(self.waitingItemIDsBySource.keys) {
            self.waitingItemIDsBySource[source]?.removeAll { $0 == itemID }
            if self.waitingItemIDsBySource[source]?.isEmpty == true {
                self.waitingItemIDsBySource.removeValue(forKey: source)
            }
        }
    }

    func scheduleUpload(itemID: String) async {
        guard self.activeTaskIDByItemID[itemID] == nil else { return }
        guard !self.schedulingItemIDs.contains(itemID) else { return }
        self.schedulingItemIDs.insert(itemID)
        defer { self.schedulingItemIDs.remove(itemID) }
        guard self.requiredFilesExist(itemID: itemID, status: .pending) else { return }

        guard self.isJournalConfigured() else {
            importQueueLog.debug("import upload held: journal unavailable")
            self.lastError = nil
            self.refreshCounts()
            return
        }

        guard let localPort = self.localPortProvider() else {
            importQueueLog.debug("import upload held: local port unavailable")
            self.lastError = nil
            self.refreshCounts()
            return
        }

        let cachedSource = self.sourceByItemID[itemID]
        let preloadedDescriptor = cachedSource == nil ? try? self.loadDescriptor(itemID: itemID, status: .pending) : nil
        let source = cachedSource ?? preloadedDescriptor?.source ?? "unknown"
        guard self.reserveInFlightSlot(itemID: itemID, source: source) else {
            self.refreshCounts()
            return
        }

        do {
            let descriptor: RequestDescriptor
            if let preloadedDescriptor {
                descriptor = preloadedDescriptor
            } else {
                descriptor = try self.loadDescriptor(itemID: itemID, status: .pending)
            }
            let ledgerStub = try self.loadLedgerStub(itemID: itemID, status: .pending)
            let itemDirectoryURL = self.pendingItemDirectoryURL(itemID: itemID)
            let saveResult = try self.loadSaveResultIfPresent(itemID: itemID, status: .pending)

            let bodyURL: URL
            let step: TaskStep
            let taskSaveResult: SaveResult?
            var request: URLRequest

            if let saveResult {
                guard saveResult.recommendedAction == RecommendedAction.start.rawValue else {
                    await self.handleUploadFailure(itemID: itemID, reason: "persisted save result is not startable")
                    try? self.fileManager.removeItem(at: self.saveUploadURL(itemID: itemID, status: .pending))
                    try? self.fileManager.removeItem(at: self.startUploadURL(itemID: itemID, status: .pending))
                    return
                }
                guard let url = self.startURLBuilder(localPort) else {
                    let detail = "import start unavailable: invalid url"
                    importQueueLog.error("\(detail, privacy: .public)")
                    self.lastError = detail
                    await self.releaseInFlightSlot(itemID: itemID)
                    self.refreshCounts()
                    return
                }

                bodyURL = try self.buildStartRequestBody(
                    itemID: itemID,
                    saveResult: saveResult
                )
                step = .start
                taskSaveResult = saveResult
                request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            } else {
                let handle: String
                do {
                    handle = try await self.ensureRegistered()
                } catch {
                    let detail = String(describing: error)
                    importQueueLog.error("import save pending \(itemID, privacy: .public): registration unavailable \(detail, privacy: .public)")
                    if self.droppedItemIDs.contains(itemID) {
                        self.droppedItemIDs.remove(itemID)
                        importQueueLog.info("import drop consumed during registration window (throw) \(itemID, privacy: .public)")
                        await self.releaseInFlightSlot(itemID: itemID)
                        self.refreshCounts()
                        return
                    }
                    self.lastError = detail
                    await self.releaseInFlightSlot(itemID: itemID)
                    self.refreshCounts()
                    return
                }

                if self.droppedItemIDs.contains(itemID) {
                    self.droppedItemIDs.remove(itemID)
                    importQueueLog.info("import drop consumed during registration window (success) \(itemID, privacy: .public)")
                    await self.releaseInFlightSlot(itemID: itemID)
                    self.refreshCounts()
                    return
                }

                guard let url = self.saveURLBuilder(localPort) else {
                    let detail = "import save unavailable: invalid url"
                    importQueueLog.error("\(detail, privacy: .public)")
                    self.lastError = detail
                    await self.releaseInFlightSlot(itemID: itemID)
                    self.refreshCounts()
                    return
                }

                bodyURL = try self.buildSaveRequestBody(
                    itemID: itemID,
                    descriptor: descriptor,
                    observerHandle: handle
                )
                step = .save
                taskSaveResult = nil
                request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("multipart/form-data; boundary=\(self.boundary(for: itemID))", forHTTPHeaderField: "Content-Type")
            }

            let createResumeStart = DispatchTime.now().uptimeNanoseconds
            guard !self.droppedItemIDs.contains(itemID) else {
                self.droppedItemIDs.remove(itemID)
                try? self.fileManager.removeItem(at: bodyURL)
                await self.releaseInFlightSlot(itemID: itemID)
                self.refreshCounts()
                return
            }
            let task = self.session.uploadTask(with: request, fromFile: bodyURL)
            task.taskDescription = itemID
            self.taskInfoByTaskID[task.taskIdentifier] = TaskInfo(
                itemID: itemID,
                itemDirectoryURL: itemDirectoryURL,
                bodyURL: bodyURL,
                step: step,
                descriptor: descriptor,
                ledgerStub: ledgerStub,
                saveResult: taskSaveResult
            )
            self.activeTaskIDByItemID[itemID] = task.taskIdentifier
            task.resume()
            self.uploadTaskByItemID[itemID] = task
            DrainSignpost.event(
                .taskCreateResume,
                source: .share,
                fields: DrainFields(
                    status: "resumed",
                    durationMs: DrainSignpost.durationMs(since: createResumeStart),
                    step: step.drainLabel
                )
            )
        } catch {
            await self.handleUploadFailure(itemID: itemID, reason: String(describing: error))
            try? self.fileManager.removeItem(at: self.saveUploadURL(itemID: itemID, status: .pending))
            try? self.fileManager.removeItem(at: self.startUploadURL(itemID: itemID, status: .pending))
        }
    }

    func handleCompletion(for task: URLSessionTask, responseData: Data, error: (any Error)?) async {
        let start = DispatchTime.now().uptimeNanoseconds
        let resolvedItemID = task.taskDescription ?? self.taskInfoByTaskID[task.taskIdentifier]?.itemID
        if let resolvedItemID, self.droppedItemIDs.remove(resolvedItemID) != nil {
            self.taskInfoByTaskID.removeValue(forKey: task.taskIdentifier)
            if self.activeTaskIDByItemID[resolvedItemID] == task.taskIdentifier {
                self.activeTaskIDByItemID.removeValue(forKey: resolvedItemID)
            }
            self.uploadTaskByItemID.removeValue(forKey: resolvedItemID)
            try? self.fileManager.removeItem(at: self.saveUploadURL(itemID: resolvedItemID, status: .pending))
            try? self.fileManager.removeItem(at: self.startUploadURL(itemID: resolvedItemID, status: .pending))
            importQueueLog.info("import dropped-item completion ignored \(resolvedItemID, privacy: .public)")
            await self.releaseInFlightSlot(itemID: resolvedItemID)
            return
        }
        guard let info = self.taskInfoByTaskID.removeValue(forKey: task.taskIdentifier) else { return }
        let step = info.step.drainLabel
        if self.activeTaskIDByItemID[info.itemID] == task.taskIdentifier {
            self.activeTaskIDByItemID.removeValue(forKey: info.itemID)
        }
        if self.uploadTaskByItemID[info.itemID]?.taskIdentifier == task.taskIdentifier {
            self.uploadTaskByItemID.removeValue(forKey: info.itemID)
        }

        if let error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled && info.step == .save {
                // Defensive parity: this only fires if loopback teardown surfaces -999.
                // Re-enqueue correctness assumes a SAVE that reached the server before reconnect
                // re-uploads to 2xx via client_item_id. This branch owns a delayed,
                // un-counted re-drive. START cancels are intentionally not given this
                // benign path; they recover through normal retry, where a re-issued
                // START already imported by the server maps HTTP 400
                // invalid_operation_for_state to terminal success in the non-2xx tail.
                importQueueLog.info("import save cancelled by reconnect; awaiting resume \(info.itemID, privacy: .public)")
                let requeueDelay = self.retryDelays.first ?? 0
                self.retryTasksByItemID[info.itemID]?.cancel()
                self.retryTasksByItemID[info.itemID] = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.sleep(requeueDelay)
                    guard !Task.isCancelled else { return }
                    self.retryTasksByItemID.removeValue(forKey: info.itemID)
                    await self.scheduleUpload(itemID: info.itemID)
                }
                await self.releaseInFlightSlot(itemID: info.itemID)
                self.refreshCounts()
                return
            }
            await self.handleUploadFailure(itemID: info.itemID, reason: String(describing: error))
            try? self.fileManager.removeItem(at: info.bodyURL)
            DrainSignpost.event(
                .uploadCompletion,
                source: .share,
                fields: DrainFields(
                    status: "transportFailure",
                    error: .transport,
                    durationMs: DrainSignpost.durationMs(since: start),
                    step: step
                )
            )
            return
        }

        let statusCode = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if 200..<300 ~= statusCode {
            self.throughputMeter.record(bytes: ThroughputMeter.byteCount(of: info.bodyURL))
            switch info.step {
            case .save:
                await self.handleSaveSuccess(info: info, responseData: responseData)
            case .start:
                await self.handleStartSuccess(info: info, responseData: responseData)
            }
            DrainSignpost.event(
                .uploadCompletion,
                source: .share,
                fields: DrainFields(
                    status: "success",
                    error: .none,
                    durationMs: DrainSignpost.durationMs(since: start),
                    step: step
                )
            )
            return
        }

        let body = String(data: responseData, encoding: .utf8) ?? ""
        if info.step == .start,
           statusCode == 400,
           let errorResponse = try? self.decoder.decode(StartErrorResponse.self, from: responseData),
           errorResponse.reasonCode == "invalid_operation_for_state",
           let saveResult = info.saveResult {
            await self.finalizeDelivery(
                info: info,
                serverPath: saveResult.path,
                serverTimestamp: saveResult.timestamp
            )
            DrainSignpost.event(
                .uploadCompletion,
                source: .share,
                fields: DrainFields(
                    status: "success",
                    error: .none,
                    durationMs: DrainSignpost.durationMs(since: start),
                    step: step
                )
            )
            return
        }
        await self.handleUploadFailure(
            itemID: info.itemID,
            reason: body.isEmpty ? "HTTP \(statusCode)" : "HTTP \(statusCode): \(body)"
        )
        try? self.fileManager.removeItem(at: info.bodyURL)
        DrainSignpost.event(
            .uploadCompletion,
            source: .share,
            fields: DrainFields(
                status: "httpFailure",
                error: .http,
                durationMs: DrainSignpost.durationMs(since: start),
                step: step,
                httpStatusClass: DrainSignpost.httpStatusClass(statusCode)
            )
        )
    }

    func handleSaveSuccess(info: TaskInfo, responseData: Data) async {
        do {
            let response = try self.decoder.decode(SaveResponse.self, from: responseData)
            guard response.clientItemID == info.itemID else {
                await self.handleUploadFailure(itemID: info.itemID, reason: "client_item_id mismatch")
                try? self.fileManager.removeItem(at: info.bodyURL)
                return
            }

            switch response.recommendedAction {
            case .start:
                guard let path = response.path, let timestamp = response.timestamp else {
                    await self.handleUploadFailure(itemID: info.itemID, reason: "missing path/timestamp")
                    try? self.fileManager.removeItem(at: info.bodyURL)
                    return
                }
                let saveResult = SaveResult(
                    path: path,
                    timestamp: timestamp,
                    recommendedAction: RecommendedAction.start.rawValue,
                    source: response.source
                )
                try self.saveSaveResult(saveResult, itemID: info.itemID, status: .pending)
                try? self.fileManager.removeItem(at: info.bodyURL)
                self.attemptCountByItemID.removeValue(forKey: info.itemID)
                await self.scheduleUpload(itemID: info.itemID)
            case .doNotStart:
                try? self.fileManager.removeItem(at: info.bodyURL)
                self.attemptCountByItemID.removeValue(forKey: info.itemID)
                await self.finalizeDelivery(
                    info: info,
                    serverPath: response.path,
                    serverTimestamp: response.timestamp
                )
            }
        } catch {
            await self.handleUploadFailure(itemID: info.itemID, reason: String(describing: error))
            try? self.fileManager.removeItem(at: info.bodyURL)
        }
    }

    func handleStartSuccess(info: TaskInfo, responseData: Data) async {
        guard let saveResult = info.saveResult else {
            await self.handleUploadFailure(itemID: info.itemID, reason: "missing save result")
            try? self.fileManager.removeItem(at: info.bodyURL)
            return
        }
        guard let response = try? self.decoder.decode(StartResponse.self, from: responseData),
              response.status == "ok",
              let taskID = response.taskID,
              !taskID.isEmpty
        else {
            await self.handleUploadFailure(itemID: info.itemID, reason: "invalid start response")
            try? self.fileManager.removeItem(at: info.bodyURL)
            return
        }
        await self.finalizeDelivery(
            info: info,
            serverPath: saveResult.path,
            serverTimestamp: saveResult.timestamp
        )
    }

    func finalizeDelivery(info: TaskInfo, serverPath: String?, serverTimestamp: String?) async {
        do {
            var ledger = try self.loadLedger()
            ledger[info.itemID] = LedgerEntry(
                itemID: info.itemID,
                basis: info.ledgerStub.basis,
                contentType: info.ledgerStub.contentType,
                targetJournal: info.ledgerStub.targetJournal,
                serverPath: serverPath,
                serverTimestamp: serverTimestamp,
                deliveredAt: self.now(),
                filename: info.ledgerStub.filename,
                originApp: info.ledgerStub.originApp,
                itemTime: info.ledgerStub.itemTime
            )
            try self.saveLedger(ledger)
            try? self.fileManager.removeItem(at: info.itemDirectoryURL)
            self.attemptCountByItemID.removeValue(forKey: info.itemID)
            self.retryTasksByItemID[info.itemID]?.cancel()
            self.retryTasksByItemID.removeValue(forKey: info.itemID)
            self.lastDeliveredAt = ledger[info.itemID]?.deliveredAt
            self.lastError = nil
            importQueueLog.info("import item delivered \(info.itemID, privacy: .public)")
        } catch {
            let detail = String(describing: error)
            self.lastError = detail
            importQueueLog.error("import ledger write failed \(info.itemID, privacy: .public): \(detail, privacy: .public)")
            try? self.fileManager.removeItem(at: info.bodyURL)
        }
        await self.releaseInFlightSlot(itemID: info.itemID)
        self.refreshCounts()
    }

    func handleUploadFailure(itemID: String, reason: String) async {
        let nextAttempt = self.attemptCountByItemID[itemID, default: 0] + 1
        self.attemptCountByItemID[itemID] = nextAttempt
        self.lastError = reason

        if nextAttempt >= self.maxAttempts {
            do {
                try self.movePendingItemToFailed(itemID: itemID, reason: reason)
            } catch {
                self.lastError = String(describing: error)
            }
            self.retryTasksByItemID[itemID]?.cancel()
            self.retryTasksByItemID.removeValue(forKey: itemID)
            self.attemptCountByItemID.removeValue(forKey: itemID)
            self.refreshCounts()
            await self.releaseInFlightSlot(itemID: itemID)
            return
        }

        let delayIndex = min(nextAttempt - 1, max(self.retryDelays.count - 1, 0))
        let delay = self.retryDelays.isEmpty ? 0 : self.retryDelays[delayIndex]
        importQueueLog.error("import item upload failed \(itemID, privacy: .public): \(reason, privacy: .private)")
        self.retryTasksByItemID[itemID]?.cancel()
        self.retryTasksByItemID[itemID] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sleep(delay)
            guard !Task.isCancelled else { return }
            self.retryTasksByItemID.removeValue(forKey: itemID)
            await self.scheduleUpload(itemID: itemID)
        }
        self.refreshCounts()
        await self.releaseInFlightSlot(itemID: itemID)
    }

    func movePendingItemToFailed(itemID: String, reason: String) throws {
        let pendingURL = self.pendingItemDirectoryURL(itemID: itemID)
        let failedURL = self.failedItemDirectoryURL(itemID: itemID)
        try self.fileManager.createDirectory(at: self.failedDirectoryURL(), withIntermediateDirectories: true)
        if self.fileManager.fileExists(atPath: failedURL.path) {
            try self.fileManager.removeItem(at: failedURL)
        }
        if self.fileManager.fileExists(atPath: pendingURL.path) {
            try? self.fileManager.removeItem(at: self.saveUploadURL(itemID: itemID, status: .pending))
            try? self.fileManager.removeItem(at: self.startUploadURL(itemID: itemID, status: .pending))
            try self.fileManager.moveItem(at: pendingURL, to: failedURL)
        }
        importQueueLog.error("import item moved to failed \(itemID, privacy: .public): \(reason, privacy: .private)")
        self.lastError = reason
    }

    func buildSaveRequestBody(
        itemID: String,
        descriptor: RequestDescriptor,
        observerHandle: String
    ) throws -> URL {
        let interval = DrainSignpost.begin(
            .multipartBodyBuild,
            source: .share,
            fields: DrainFields(step: "save")
        )
        do {
            let rawData = try Data(contentsOf: self.rawURL(itemID: itemID, status: .pending))
            let boundary = self.boundary(for: itemID)
            let bodyURL = self.saveUploadURL(itemID: itemID, status: .pending)

            var body = Data()
            body.append(self.multipartField(named: "imported_via", value: "mobile_share", boundary: boundary))
            body.append(self.multipartField(named: "observer_handle", value: observerHandle, boundary: boundary))
            body.append(self.multipartField(named: "client_item_id", value: itemID, boundary: boundary))

            // The importer treats "quick" as the share-extension text path; all other sources are file imports.
            if descriptor.source == "quick" {
                guard let text = String(data: rawData, encoding: .utf8) else {
                    throw ImportQueueError.textDecodeFailed(itemID: itemID)
                }
                body.append(self.multipartField(named: "text", value: text, boundary: boundary))
            } else {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(descriptor.filename)\"\r\n".data(using: .utf8)!)
                body.append("Content-Type: \(descriptor.contentType)\r\n\r\n".data(using: .utf8)!)
                body.append(rawData)
                body.append("\r\n".data(using: .utf8)!)
            }

            body.append("--\(boundary)--\r\n".data(using: .utf8)!)
            let byteCount = body.count
            try body.write(to: bodyURL, options: .atomic)
            DrainSignpost.end(
                interval,
                source: .share,
                fields: DrainFields(status: "success", error: .none, bytes: byteCount, step: "save")
            )
            return bodyURL
        } catch {
            DrainSignpost.end(
                interval,
                source: .share,
                fields: DrainFields(
                    status: "failure",
                    error: DrainErrorCategory.classify(error),
                    step: "save"
                )
            )
            throw error
        }
    }

    func buildStartRequestBody(
        itemID: String,
        saveResult: SaveResult
    ) throws -> URL {
        let interval = DrainSignpost.begin(
            .multipartBodyBuild,
            source: .share,
            fields: DrainFields(step: "start")
        )
        do {
            let bodyURL = self.startUploadURL(itemID: itemID, status: .pending)
            let body = StartRequest(
                path: saveResult.path,
                timestamp: saveResult.timestamp
            )
            let bodyData = try self.encoder.encode(body)
            let byteCount = bodyData.count
            try bodyData.write(to: bodyURL, options: .atomic)
            DrainSignpost.end(
                interval,
                source: .share,
                fields: DrainFields(status: "success", error: .none, bytes: byteCount, step: "start")
            )
            return bodyURL
        } catch {
            DrainSignpost.end(
                interval,
                source: .share,
                fields: DrainFields(
                    status: "failure",
                    error: DrainErrorCategory.classify(error),
                    step: "start"
                )
            )
            throw error
        }
    }

    func multipartField(named name: String, value: String, boundary: String) -> Data {
        Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
    }

    func localOnThisPhoneItem(
        itemID: String,
        status: ItemStatus,
        location: OnThisPhoneLocation,
        isActivelyUploading: Bool
    ) -> OnThisPhoneItem {
        let object = self.readNoteObject(itemID: itemID, status: status)
        let rawURL = self.rawURL(itemID: itemID, status: status)
        let rawFileURL = self.fileManager.fileExists(atPath: rawURL.path) ? rawURL : nil
        let canRetry = location == .failed

        return OnThisPhoneItem(
            id: itemID,
            sourceKind: .share,
            sendState: onThisPhoneSendState(location: location, canRetry: canRetry, isActivelyUploading: isActivelyUploading),
            contentType: object?["content_type"] as? String,
            filename: object?["filename"] as? String,
            bytes: (object?["bytes"] as? NSNumber)?.int64Value,
            originApp: object?["origin_app"] as? String,
            basis: object?["basis"] as? String,
            itemTime: Self.parseItemTime(object?["item_time"] as? String),
            targetJournal: object?["target_journal"] as? String,
            stream: nil,
            day: nil,
            segment: nil,
            deliveredAt: nil,
            rawFileURL: rawFileURL,
            retryAvailable: canRetry
        )
    }

    func deliveredOnThisPhoneItem(itemID: String, entry: LedgerEntry) -> OnThisPhoneItem {
        OnThisPhoneItem(
            id: itemID,
            sourceKind: .share,
            sendState: .inYourJournal,
            contentType: entry.contentType,
            filename: entry.filename,
            bytes: nil,
            originApp: entry.originApp,
            basis: entry.basis,
            itemTime: Self.parseItemTime(entry.itemTime),
            targetJournal: entry.targetJournal,
            stream: nil,
            day: Self.dayString(fromServerTimestamp: entry.serverTimestamp),
            segment: nil,
            deliveredAt: entry.deliveredAt,
            rawFileURL: nil
        )
    }

    func readNoteObject(itemID: String, status: ItemStatus) -> [String: Any]? {
        guard let data = try? Data(contentsOf: self.noteURL(itemID: itemID, status: status)) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func boundary(for itemID: String) -> String {
        "Boundary-\(itemID)"
    }

    func resolvePlacement(for fileURL: URL) throws -> Placement {
        let attributes = try self.fileManager.attributesOfItem(atPath: fileURL.path)
        if let modified = attributes[.modificationDate] as? Date {
            return Placement(basis: "modified", itemTime: modified)
        }
        if let created = attributes[.creationDate] as? Date {
            return Placement(basis: "created", itemTime: created)
        }
        return Placement(basis: "sent", itemTime: self.now())
    }

    func rawByteCount(fileURL: URL) throws -> Int64 {
        let attributes = try self.fileManager.attributesOfItem(atPath: fileURL.path)
        if let size = attributes[.size] as? NSNumber {
            return size.int64Value
        }
        return Int64((try Data(contentsOf: fileURL)).count)
    }

    nonisolated static func rawFileInfo(for contentType: String) -> RawFileInfo {
        switch contentType {
        case "public.mpeg-4-audio", "com.apple.m4a-audio", "public.m4a-audio", "audio/m4a", "audio/mp4":
            return RawFileInfo(filename: "audio.m4a", mimeType: "audio/mp4")
        case "com.adobe.pdf", "application/pdf":
            return RawFileInfo(filename: "document.pdf", mimeType: "application/pdf")
        case "public.jpeg", "public.jpg", "image/jpeg":
            return RawFileInfo(filename: "image.jpg", mimeType: "image/jpeg")
        case "public.png", "image/png":
            return RawFileInfo(filename: "image.png", mimeType: "image/png")
        case "public.heic", "public.heif", "image/heic", "image/heif":
            return RawFileInfo(filename: "image.heic", mimeType: "image/heic")
        case "com.compuserve.gif", "image/gif":
            return RawFileInfo(filename: "image.gif", mimeType: "image/gif")
        case "org.webmproject.webp", "public.webp", "image/webp":
            return RawFileInfo(filename: "image.webp", mimeType: "image/webp")
        case "public.tiff", "image/tiff":
            return RawFileInfo(filename: "image.tiff", mimeType: "image/tiff")
        case "public.plain-text", "public.utf8-plain-text", "text/plain":
            return RawFileInfo(filename: "text.txt", mimeType: "text/plain")
        default:
            if let type = UTType(contentType) ?? UTType(mimeType: contentType),
               type.conforms(to: .audio) {
                let ext = type.preferredFilenameExtension ?? "audio"
                let mime = type.preferredMIMEType ?? "audio/\(ext)"
                return RawFileInfo(filename: "audio.\(ext)", mimeType: mime)
            }
            return RawFileInfo(filename: "item.bin", mimeType: "application/octet-stream")
        }
    }

    nonisolated static func orderedNoteData(_ note: FrozenNote) throws -> Data {
        let json = "{"
            + "\"schema\":\"solstone.source.item/1\","
            + "\"source\":\(try Self.jsonString(note.source)),"
            + "\"origin_app\":\(try Self.optionalJSONString(note.originApp)),"
            + "\"content_type\":\(try Self.jsonString(note.contentType)),"
            + "\"filename\":\(try Self.optionalJSONString(note.filename)),"
            + "\"bytes\":\(note.bytes),"
            + "\"basis\":\(try Self.jsonString(note.basis)),"
            + "\"item_time\":\(try Self.jsonString(note.itemTime)),"
            + "\"target_journal\":\(try Self.jsonString(note.targetJournal)),"
            + "\"kind\":\"raw\","
            + "\"item_id\":\(try Self.jsonString(note.itemID))"
            + "}"
        return Data(json.utf8)
    }

    nonisolated static func jsonString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value])
        let encoded = String(decoding: data, as: UTF8.self)
        return String(encoded.dropFirst().dropLast())
    }

    nonisolated static func optionalJSONString(_ value: String?) throws -> String {
        guard let value else { return "null" }
        return try Self.jsonString(value)
    }

    nonisolated static func iso8601String(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    nonisolated static func parseItemTime(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: string)
    }

    nonisolated static func parseServerTimestamp(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    nonisolated static func dayString(fromServerTimestamp timestamp: String?) -> String? {
        guard let date = Self.parseServerTimestamp(timestamp) else { return nil }
        return Self.dayString(for: date)
    }

    nonisolated static func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    nonisolated static func timeString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "HHmmss"
        return formatter.string(from: date)
    }

    func ensureRootDirectories() throws {
        try self.fileManager.createDirectory(at: self.pendingDirectoryURL(), withIntermediateDirectories: true)
        try self.fileManager.createDirectory(at: self.failedDirectoryURL(), withIntermediateDirectories: true)
    }

    func pendingDirectoryURL() -> URL {
        self.cacheRootURL.appendingPathComponent("pending", isDirectory: true)
    }

    func failedDirectoryURL() -> URL {
        self.cacheRootURL.appendingPathComponent("failed", isDirectory: true)
    }

    func ledgerURL() -> URL {
        self.cacheRootURL.appendingPathComponent("ledger.json", isDirectory: false)
    }

    func itemDirectoryURL(itemID: String, status: ItemStatus) -> URL {
        switch status {
        case .pending:
            self.pendingItemDirectoryURL(itemID: itemID)
        case .failed:
            self.failedItemDirectoryURL(itemID: itemID)
        }
    }

    func pendingItemDirectoryURL(itemID: String) -> URL {
        self.pendingDirectoryURL().appendingPathComponent(itemID, isDirectory: true)
    }

    func failedItemDirectoryURL(itemID: String) -> URL {
        self.failedDirectoryURL().appendingPathComponent(itemID, isDirectory: true)
    }

    func rawURL(itemID: String, status: ItemStatus) -> URL {
        self.itemDirectoryURL(itemID: itemID, status: status).appendingPathComponent("raw.bin", isDirectory: false)
    }

    func noteURL(itemID: String, status: ItemStatus) -> URL {
        self.itemDirectoryURL(itemID: itemID, status: status).appendingPathComponent("item.json", isDirectory: false)
    }

    func descriptorURL(itemID: String, status: ItemStatus) -> URL {
        self.itemDirectoryURL(itemID: itemID, status: status).appendingPathComponent("request.json", isDirectory: false)
    }

    func saveResultURL(itemID: String, status: ItemStatus) -> URL {
        self.itemDirectoryURL(itemID: itemID, status: status).appendingPathComponent("save.json", isDirectory: false)
    }

    func saveUploadURL(itemID: String, status: ItemStatus) -> URL {
        self.itemDirectoryURL(itemID: itemID, status: status).appendingPathComponent("save.upload", isDirectory: false)
    }

    func startUploadURL(itemID: String, status: ItemStatus) -> URL {
        self.itemDirectoryURL(itemID: itemID, status: status).appendingPathComponent("start.upload", isDirectory: false)
    }

    func requiredFilesExist(itemID: String, status: ItemStatus) -> Bool {
        self.fileManager.fileExists(atPath: self.rawURL(itemID: itemID, status: status).path)
            && self.fileManager.fileExists(atPath: self.noteURL(itemID: itemID, status: status).path)
            && self.fileManager.fileExists(atPath: self.descriptorURL(itemID: itemID, status: status).path)
    }

    func loadDescriptor(itemID: String, status: ItemStatus) throws -> RequestDescriptor {
        try self.decoder.decode(RequestDescriptor.self, from: Data(contentsOf: self.descriptorURL(itemID: itemID, status: status)))
    }

    func loadSaveResultIfPresent(itemID: String, status: ItemStatus) throws -> SaveResult? {
        let url = self.saveResultURL(itemID: itemID, status: status)
        guard self.fileManager.fileExists(atPath: url.path) else { return nil }
        return try self.decoder.decode(SaveResult.self, from: Data(contentsOf: url))
    }

    func saveSaveResult(_ saveResult: SaveResult, itemID: String, status: ItemStatus) throws {
        let data = try self.encoder.encode(saveResult)
        try data.write(to: self.saveResultURL(itemID: itemID, status: status), options: .atomic)
    }

    func loadLedgerStub(itemID: String, status: ItemStatus) throws -> LedgerStub {
        let data = try Data(contentsOf: self.noteURL(itemID: itemID, status: status))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let basis = object["basis"] as? String,
              let contentType = object["content_type"] as? String,
              let targetJournal = object["target_journal"] as? String
        else {
            throw ImportQueueError.noteDecodeFailed(itemID: itemID)
        }
        return LedgerStub(
            basis: basis,
            contentType: contentType,
            targetJournal: targetJournal,
            filename: object["filename"] as? String,
            originApp: object["origin_app"] as? String,
            itemTime: object["item_time"] as? String
        )
    }

    func loadLedger() throws -> [String: LedgerEntry] {
        let url = self.ledgerURL()
        guard self.fileManager.fileExists(atPath: url.path) else { return [:] }
        return try self.decoder.decode([String: LedgerEntry].self, from: Data(contentsOf: url))
    }

    func saveLedger(_ ledger: [String: LedgerEntry]) throws {
        let data = try self.encoder.encode(ledger)
        try data.write(to: self.ledgerURL(), options: .atomic)
    }

    func refreshCounts() {
        let start = DispatchTime.now().uptimeNanoseconds
        self.pendingCount = self.countItemDirectories(at: self.pendingDirectoryURL())
        self.failedCount = self.countItemDirectories(at: self.failedDirectoryURL())
        DrainSignpost.event(
            .countRefresh,
            source: .share,
            fields: DrainFields(
                status: "success",
                pending: self.pendingCount,
                failed: self.failedCount,
                durationMs: DrainSignpost.durationMs(since: start)
            )
        )
    }

    func countItemDirectories(at url: URL) -> Int {
        guard let entries = try? self.fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        return entries.filter { self.isDirectory($0) }.count
    }

    func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

enum ImportQueueError: Error, Equatable, Sendable {
    case registrationUnavailable
    case writeFailed(path: String)
    case missingRequiredArtifact(itemID: String)
    case noteDecodeFailed(itemID: String)
    case textDecodeFailed(itemID: String)
}
