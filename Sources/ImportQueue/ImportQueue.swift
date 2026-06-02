// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Network
import Observation
import os

private let importQueueLog = Logger(subsystem: "app.solstone.swift", category: "import-queue")

final class ImportQueueSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate {
    private struct WeakOwner: Sendable {
        weak var value: ImportQueue?
    }

    private let ownerBox = OSAllocatedUnfairLock<WeakOwner>(initialState: WeakOwner())

    func setOwner(_ owner: ImportQueue?) {
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
final class ImportQueue {
    nonisolated static let backgroundSessionIdentifier = "app.solstone.swift.share-upload"

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

    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let cacheRootURL: URL
    @ObservationIgnored private let sessionDelegate: ImportQueueSessionDelegate
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let ensureRegistered: @Sendable @MainActor () async throws -> String
    @ObservationIgnored private let localPortProvider: @Sendable @MainActor () -> Int?
    @ObservationIgnored private let urlBuilder: @Sendable (Int, String) -> URL?
    @ObservationIgnored private let retryDelays: [UInt64]
    @ObservationIgnored private let maxAttempts: Int
    @ObservationIgnored private let sleep: @Sendable (UInt64) async -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private let decoder = JSONDecoder()
    @ObservationIgnored private var backgroundCompletionHandler: (@MainActor @Sendable () -> Void)?
    @ObservationIgnored private var responseDataByTaskID: [Int: Data] = [:]
    @ObservationIgnored private var taskInfoByTaskID: [Int: TaskInfo] = [:]
    @ObservationIgnored private var activeTaskIDByItemID: [String: Int] = [:]
    @ObservationIgnored private var attemptCountByItemID: [String: Int] = [:]
    @ObservationIgnored private var retryTasksByItemID: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private let pathMonitorQueue = DispatchQueue(label: "app.solstone.swift.import-queue")

    init(
        cacheRootURL: URL? = nil,
        fileManager: FileManager = .default,
        sessionConfiguration: URLSessionConfiguration? = nil,
        ensureRegistered: @escaping @Sendable @MainActor () async throws -> String = {
            throw ImportQueueError.registrationUnavailable
        },
        localPortProvider: @escaping @Sendable @MainActor () -> Int? = { nil },
        urlBuilder: @escaping @Sendable (Int, String) -> URL? = { localPort, key in
            ObserverServerURL.ingestURL(localPort: localPort, key: key)
        },
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
        self.localPortProvider = localPortProvider
        self.urlBuilder = urlBuilder
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
        stream: String,
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
                day: Self.dayString(for: placement.itemTime),
                segment: "\(Self.timeString(for: placement.itemTime))_0",
                stream: stream,
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

                try? self.fileManager.removeItem(at: self.bodyURL(itemID: itemID, status: .pending))
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

    struct TaskInfo {
        let itemID: String
        let itemDirectoryURL: URL
        let bodyURL: URL
        let descriptor: RequestDescriptor
        let ledgerStub: LedgerStub
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
        let day: String
        let segment: String
        let stream: String
        let filename: String
        let contentType: String

        enum CodingKeys: String, CodingKey {
            case day
            case segment
            case stream
            case filename
            case contentType = "content_type"
        }
    }

    struct LedgerStub {
        let stream: String
        let basis: String
        let contentType: String
        let targetJournal: String
    }

    struct LedgerEntry: Codable, Equatable, Sendable {
        let itemID: String
        let stream: String
        let basis: String
        let contentType: String
        let targetJournal: String
        let serverDay: String
        let serverSegment: String?
        let deliveredAt: Date

        enum CodingKeys: String, CodingKey {
            case itemID = "item_id"
            case stream
            case basis
            case contentType = "content_type"
            case targetJournal = "target_journal"
            case serverDay = "server_day"
            case serverSegment = "server_segment"
            case deliveredAt = "delivered_at"
        }
    }

    struct IngestResponse: Decodable {
        let status: String?
        let segment: String?
        let existingSegment: String?

        enum CodingKeys: String, CodingKey {
            case status
            case segment
            case existingSegment = "existing_segment"
        }
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

    func scheduleUpload(itemID: String) async {
        guard self.activeTaskIDByItemID[itemID] == nil else { return }
        guard self.requiredFilesExist(itemID: itemID, status: .pending) else { return }

        let key: String
        do {
            key = try await self.ensureRegistered()
        } catch {
            let detail = String(describing: error)
            importQueueLog.error("import upload pending \(itemID, privacy: .public): registration unavailable \(detail, privacy: .public)")
            self.lastError = detail
            self.refreshCounts()
            return
        }

        guard let localPort = self.localPortProvider() else {
            let detail = "import upload unavailable: missing local port"
            importQueueLog.error("\(detail, privacy: .public)")
            self.lastError = detail
            self.refreshCounts()
            return
        }

        guard let url = self.urlBuilder(localPort, key) else {
            let detail = "import upload unavailable: invalid url"
            importQueueLog.error("\(detail, privacy: .public)")
            self.lastError = detail
            self.refreshCounts()
            return
        }

        do {
            let descriptor = try self.loadDescriptor(itemID: itemID, status: .pending)
            let ledgerStub = try self.loadLedgerStub(itemID: itemID, status: .pending, descriptor: descriptor)
            let bodyURL = try self.buildMultipartRequestBody(itemID: itemID)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(self.boundary(for: itemID))", forHTTPHeaderField: "Content-Type")

            let task = self.session.uploadTask(with: request, fromFile: bodyURL)
            self.taskInfoByTaskID[task.taskIdentifier] = TaskInfo(
                itemID: itemID,
                itemDirectoryURL: self.pendingItemDirectoryURL(itemID: itemID),
                bodyURL: bodyURL,
                descriptor: descriptor,
                ledgerStub: ledgerStub
            )
            self.activeTaskIDByItemID[itemID] = task.taskIdentifier
            task.resume()
        } catch {
            await self.handleUploadFailure(itemID: itemID, reason: String(describing: error))
            try? self.fileManager.removeItem(at: self.bodyURL(itemID: itemID, status: .pending))
        }
    }

    func appendResponseData(_ data: Data, for taskIdentifier: Int) {
        self.responseDataByTaskID[taskIdentifier, default: Data()].append(data)
    }

    func handleCompletion(for task: URLSessionTask, error: (any Error)?) async {
        guard let info = self.taskInfoByTaskID.removeValue(forKey: task.taskIdentifier) else { return }
        self.activeTaskIDByItemID.removeValue(forKey: info.itemID)
        let responseData = self.responseDataByTaskID.removeValue(forKey: task.taskIdentifier) ?? Data()

        if let error {
            await self.handleUploadFailure(itemID: info.itemID, reason: String(describing: error))
            try? self.fileManager.removeItem(at: info.bodyURL)
            return
        }

        let statusCode = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if 200..<300 ~= statusCode {
            await self.handleDeliverySuccess(info: info, responseData: responseData)
            return
        }

        let body = String(data: responseData, encoding: .utf8) ?? ""
        await self.handleUploadFailure(
            itemID: info.itemID,
            reason: body.isEmpty ? "HTTP \(statusCode)" : "HTTP \(statusCode): \(body)"
        )
        try? self.fileManager.removeItem(at: info.bodyURL)
    }

    func handleDeliverySuccess(info: TaskInfo, responseData: Data) async {
        let response = try? self.decoder.decode(IngestResponse.self, from: responseData)
        let serverSegment: String?
        if response?.status == "duplicate" {
            serverSegment = response?.existingSegment
        } else {
            serverSegment = response?.segment
        }

        do {
            var ledger = try self.loadLedger()
            ledger[info.itemID] = LedgerEntry(
                itemID: info.itemID,
                stream: info.ledgerStub.stream,
                basis: info.ledgerStub.basis,
                contentType: info.ledgerStub.contentType,
                targetJournal: info.ledgerStub.targetJournal,
                serverDay: info.descriptor.day,
                serverSegment: serverSegment,
                deliveredAt: self.now()
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
            return
        }

        let delayIndex = min(nextAttempt - 1, max(self.retryDelays.count - 1, 0))
        let delay = self.retryDelays.isEmpty ? 0 : self.retryDelays[delayIndex]
        importQueueLog.error("import item upload failed \(itemID, privacy: .public): \(reason, privacy: .public)")
        self.retryTasksByItemID[itemID]?.cancel()
        self.retryTasksByItemID[itemID] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sleep(delay)
            guard !Task.isCancelled else { return }
            await self.scheduleUpload(itemID: itemID)
        }
        self.refreshCounts()
    }

    func movePendingItemToFailed(itemID: String, reason: String) throws {
        let pendingURL = self.pendingItemDirectoryURL(itemID: itemID)
        let failedURL = self.failedItemDirectoryURL(itemID: itemID)
        try self.fileManager.createDirectory(at: self.failedDirectoryURL(), withIntermediateDirectories: true)
        if self.fileManager.fileExists(atPath: failedURL.path) {
            try self.fileManager.removeItem(at: failedURL)
        }
        if self.fileManager.fileExists(atPath: pendingURL.path) {
            try? self.fileManager.removeItem(at: self.bodyURL(itemID: itemID, status: .pending))
            try self.fileManager.moveItem(at: pendingURL, to: failedURL)
        }
        importQueueLog.error("import item moved to failed \(itemID, privacy: .public): \(reason, privacy: .public)")
        self.lastError = reason
    }

    func buildMultipartRequestBody(itemID: String) throws -> URL {
        let descriptor = try self.loadDescriptor(itemID: itemID, status: .pending)
        let noteData = try Data(contentsOf: self.noteURL(itemID: itemID, status: .pending))
        let rawData = try Data(contentsOf: self.rawURL(itemID: itemID, status: .pending))
        let boundary = self.boundary(for: itemID)
        let bodyURL = self.bodyURL(itemID: itemID, status: .pending)

        var body = Data()
        body.append(self.multipartField(named: "day", value: descriptor.day, boundary: boundary))
        body.append(self.multipartField(named: "segment", value: descriptor.segment, boundary: boundary))
        body.append(self.multipartField(named: "platform", value: "ios", boundary: boundary))
        body.append(self.multipartField(named: "meta", value: Self.metaJSONString(stream: descriptor.stream), boundary: boundary))

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"files[]\"; filename=\"\(descriptor.filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(descriptor.contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(rawData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"files[]\"; filename=\"item.json\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json\r\n\r\n".data(using: .utf8)!)
        body.append(noteData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        try body.write(to: bodyURL, options: .atomic)
        return bodyURL
    }

    func multipartField(named name: String, value: String, boundary: String) -> Data {
        Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
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
            RawFileInfo(filename: "audio.m4a", mimeType: "audio/mp4")
        case "com.adobe.pdf", "application/pdf":
            RawFileInfo(filename: "document.pdf", mimeType: "application/pdf")
        case "public.jpeg", "public.jpg", "image/jpeg":
            RawFileInfo(filename: "image.jpg", mimeType: "image/jpeg")
        case "public.png", "image/png":
            RawFileInfo(filename: "image.png", mimeType: "image/png")
        case "public.heic", "public.heif", "image/heic", "image/heif":
            RawFileInfo(filename: "image.heic", mimeType: "image/heic")
        case "com.compuserve.gif", "image/gif":
            RawFileInfo(filename: "image.gif", mimeType: "image/gif")
        case "org.webmproject.webp", "public.webp", "image/webp":
            RawFileInfo(filename: "image.webp", mimeType: "image/webp")
        case "public.tiff", "image/tiff":
            RawFileInfo(filename: "image.tiff", mimeType: "image/tiff")
        default:
            RawFileInfo(filename: "item.bin", mimeType: "application/octet-stream")
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

    nonisolated static func metaJSONString(stream: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: ["stream": stream], options: [.sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? #"{"stream":""}"#
    }

    nonisolated static func iso8601String(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
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

    func bodyURL(itemID: String, status: ItemStatus) -> URL {
        self.itemDirectoryURL(itemID: itemID, status: status).appendingPathComponent("body.upload", isDirectory: false)
    }

    func requiredFilesExist(itemID: String, status: ItemStatus) -> Bool {
        self.fileManager.fileExists(atPath: self.rawURL(itemID: itemID, status: status).path)
            && self.fileManager.fileExists(atPath: self.noteURL(itemID: itemID, status: status).path)
            && self.fileManager.fileExists(atPath: self.descriptorURL(itemID: itemID, status: status).path)
    }

    func loadDescriptor(itemID: String, status: ItemStatus) throws -> RequestDescriptor {
        try self.decoder.decode(RequestDescriptor.self, from: Data(contentsOf: self.descriptorURL(itemID: itemID, status: status)))
    }

    func loadLedgerStub(itemID: String, status: ItemStatus, descriptor: RequestDescriptor) throws -> LedgerStub {
        let data = try Data(contentsOf: self.noteURL(itemID: itemID, status: status))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let basis = object["basis"] as? String,
              let contentType = object["content_type"] as? String,
              let targetJournal = object["target_journal"] as? String
        else {
            throw ImportQueueError.noteDecodeFailed(itemID: itemID)
        }
        return LedgerStub(
            stream: descriptor.stream,
            basis: basis,
            contentType: contentType,
            targetJournal: targetJournal
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
        self.pendingCount = self.countItemDirectories(at: self.pendingDirectoryURL())
        self.failedCount = self.countItemDirectories(at: self.failedDirectoryURL())
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
}
