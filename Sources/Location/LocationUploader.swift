// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Network
import Observation
import os

private let locationUploadLog = Logger(subsystem: "app.solstone.swift", category: "location-upload")

final class LocationUploaderSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate {
    private struct WeakOwner: Sendable {
        weak var value: LocationUploader?
    }

    private let ownerBox = OSAllocatedUnfairLock<WeakOwner>(initialState: WeakOwner())

    func setOwner(_ owner: LocationUploader?) {
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
final class LocationUploader: LocationUploading {
    nonisolated static let backgroundSessionIdentifier = "app.solstone.swift.location-upload"

    private(set) var pendingCount = 0
    private(set) var failedCount = 0
    var lastUploadAt: Date?
    var lastError: String?
    private let throughputMeter = ThroughputMeter()

    var inFlightCount: Int {
        self.uploadTaskByFileID.count + self.retryTasksByFileID.count
    }

    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let cacheRootURL: URL
    @ObservationIgnored private let sessionDelegate: LocationUploaderSessionDelegate
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let deleteSession: URLSession
    @ObservationIgnored private let ensureRegistered: @Sendable @MainActor () async throws -> String
    @ObservationIgnored private let isJournalConfigured: @Sendable @MainActor () -> Bool
    @ObservationIgnored private let localPortProvider: @Sendable @MainActor () -> Int?
    @ObservationIgnored private let urlBuilder: @Sendable (Int) -> URL?
    @ObservationIgnored private let retryDelays: [UInt64]
    @ObservationIgnored private let maxAttempts: Int
    @ObservationIgnored private let sleep: @Sendable (UInt64) async -> Void
    @ObservationIgnored private let encoder: JSONEncoder
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var backgroundCompletionHandler: (@MainActor @Sendable () -> Void)?
    @ObservationIgnored private var responseDataByTaskID: [Int: Data] = [:]
    @ObservationIgnored private var taskInfoByTaskID: [Int: TaskInfo] = [:]
    @ObservationIgnored private var activeTaskIDByFileID: [String: Int] = [:]
    @ObservationIgnored private var uploadTaskByFileID: [String: URLSessionUploadTask] = [:]
    @ObservationIgnored private var attemptCountByFileID: [String: Int] = [:]
    @ObservationIgnored private var retryTasksByFileID: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var isDeleting = false
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private let pathMonitorQueue = DispatchQueue(label: "app.solstone.swift.location-uploader")

    var recentBytesPerSecond: Double {
        self.throughputMeter.recentBytesPerSecond
    }

    init(
        cacheRootURL: URL? = nil,
        fileManager: FileManager = .default,
        sessionConfiguration: URLSessionConfiguration? = nil,
        deleteSessionConfiguration: URLSessionConfiguration? = nil,
        ensureRegistered: @escaping @Sendable @MainActor () async throws -> String = {
            throw LocationUploaderError.registrationUnavailable
        },
        isJournalConfigured: @escaping @Sendable @MainActor () -> Bool = { true },
        localPortProvider: @escaping @Sendable @MainActor () -> Int? = { nil },
        urlBuilder: @escaping @Sendable (Int) -> URL? = { localPort in
            ObserverServerURL.ingestURL(localPort: localPort)
        },
        retryDelays: [UInt64] = [2, 4, 8, 16],
        maxAttempts: Int = 5,
        sleep: @escaping @Sendable (UInt64) async -> Void = { delay in
            try? await Task.sleep(for: .seconds(delay))
        },
        startPathMonitor: Bool = true,
        timeZone: TimeZone = .current,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) {
        self.fileManager = fileManager
        self.cacheRootURL = cacheRootURL
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Location", isDirectory: true)
        self.ensureRegistered = ensureRegistered
        self.isJournalConfigured = isJournalConfigured
        self.localPortProvider = localPortProvider
        self.urlBuilder = urlBuilder
        self.retryDelays = retryDelays
        self.maxAttempts = maxAttempts
        self.sleep = sleep
        var configuredCalendar = calendar
        configuredCalendar.timeZone = timeZone
        self.calendar = configuredCalendar

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]

        self.sessionDelegate = LocationUploaderSessionDelegate()
        let configuration = sessionConfiguration ?? {
            let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
            config.waitsForConnectivity = true
            return config
        }()
        self.session = URLSession(configuration: configuration, delegate: self.sessionDelegate, delegateQueue: nil)
        self.deleteSession = URLSession(configuration: deleteSessionConfiguration ?? .ephemeral)
        self.sessionDelegate.setOwner(self)

        try? self.ensureRootDirectories()
        self.refreshCounts()

        if startPathMonitor {
            self.startPathMonitor()
        }
    }

    nonisolated func enqueue(_ batch: LocationSegmentBatch) async {
        await self.enqueueOnMain(batch)
    }

    private func enqueueOnMain(_ batch: LocationSegmentBatch) async {
        guard !self.isDeleting else {
            locationUploadLog.debug("location enqueue skipped during source delete")
            return
        }
        if batch.fixes.isEmpty && batch.visits.isEmpty {
            locationUploadLog.debug("skipping net-new gap-only location heartbeat (no fixes, no visits)")
            return
        }

        do {
            let frozen = try self.frozenSegment(for: batch)
            try self.ensureRootDirectories()
            let pendingURL = self.pendingFileURL(fileID: frozen.fileID)
            if self.fileManager.fileExists(atPath: pendingURL.path) {
                try self.fileManager.removeItem(at: pendingURL)
            }
            try frozen.data.write(to: pendingURL, options: .atomic)
            locationUploadLog.info("location: segment enqueued \(frozen.fileID, privacy: .public)")
            self.refreshCounts()
            await self.scheduleUpload(fileID: frozen.fileID)
        } catch {
            let detail = String(describing: error)
            locationUploadLog.error("failed to enqueue location segment: \(detail, privacy: .public)")
            self.lastError = detail
            self.refreshCounts()
        }
    }

    func resumeFromDisk() async {
        guard !self.isDeleting else {
            locationUploadLog.debug("location resume skipped during source delete")
            return
        }

        do {
            try self.ensureRootDirectories()
            let entries = try self.fileManager.contentsOfDirectory(
                at: self.pendingDirectoryURL(),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            let frozenEntries = entries.filter { $0.pathExtension == "jsonl" }
            for entry in frozenEntries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let fileID = entry.deletingPathExtension().lastPathComponent
                do {
                    _ = try self.parseFrozenFileName(entry.lastPathComponent)
                    await self.scheduleUpload(fileID: fileID)
                } catch {
                    try self.movePendingFileToFailed(
                        fileID: fileID,
                        fileURL: entry,
                        reason: "pending location segment filename invalid"
                    )
                }
            }
        } catch {
            let detail = String(describing: error)
            locationUploadLog.error("location resume failed: \(detail, privacy: .public)")
            self.lastError = detail
        }

        self.refreshCounts()
    }

    func onThisPhoneSnapshot() -> OnThisPhoneSourceResult {
        let interval = DrainSignpost.begin(.sourceSnapshotScan, source: .location)
        do {
            var items: [OnThisPhoneItem] = []
            items.append(contentsOf: try self.onThisPhoneItems(
                directory: self.pendingDirectoryURL(),
                location: .pending
            ))
            items.append(contentsOf: try self.onThisPhoneItems(
                directory: self.failedDirectoryURL(),
                location: .failed
            ))
            let sortedItems = OnThisPhoneItemSort.newestFirst(items)
            DrainSignpost.end(
                interval,
                source: .location,
                fields: DrainFields(status: "loaded", error: .none, items: sortedItems.count)
            )
            return .loaded(items: sortedItems)
        } catch {
            locationUploadLog.error("location on-this-phone snapshot failed: \(String(describing: error), privacy: .public)")
            DrainSignpost.end(
                interval,
                source: .location,
                fields: DrainFields(status: "failed", error: .filesystem, items: 0)
            )
            return .failed
        }
    }

    func retryFailed() async {
        guard !self.isDeleting else {
            locationUploadLog.debug("location retry skipped during source delete")
            return
        }

        do {
            try self.ensureRootDirectories()
            let entries = try self.fileManager.contentsOfDirectory(
                at: self.failedDirectoryURL(),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for entry in entries where entry.pathExtension == "jsonl" {
                let target = self.pendingDirectoryURL().appendingPathComponent(entry.lastPathComponent, isDirectory: false)
                if self.fileManager.fileExists(atPath: target.path) {
                    try self.fileManager.removeItem(at: target)
                }
                try self.fileManager.moveItem(at: entry, to: target)
                let fileID = target.deletingPathExtension().lastPathComponent
                self.attemptCountByFileID.removeValue(forKey: fileID)
                self.retryTasksByFileID[fileID]?.cancel()
                self.retryTasksByFileID.removeValue(forKey: fileID)
            }
        } catch {
            let detail = String(describing: error)
            locationUploadLog.error("location retry failed move failed: \(detail, privacy: .public)")
            self.lastError = detail
        }

        self.refreshCounts()
        await self.resumeFromDisk()
    }

    func handleBackgroundURLSessionEvents(completionHandler: @escaping @MainActor @Sendable () -> Void) {
        self.backgroundCompletionHandler = completionHandler
    }

    func attemptCountForTesting(fileID: String) -> Int {
        self.attemptCountByFileID[fileID, default: 0]
    }

    func dropItem(fileID: String) {
        self.uploadTaskByFileID[fileID]?.cancel()
        self.uploadTaskByFileID.removeValue(forKey: fileID)
        self.retryTasksByFileID[fileID]?.cancel()
        self.retryTasksByFileID.removeValue(forKey: fileID)
        self.attemptCountByFileID.removeValue(forKey: fileID)
        if let taskID = self.activeTaskIDByFileID.removeValue(forKey: fileID) {
            self.taskInfoByTaskID.removeValue(forKey: taskID)
            self.responseDataByTaskID.removeValue(forKey: taskID)
        }

        try? self.fileManager.removeItem(at: self.pendingFileURL(fileID: fileID))
        try? self.fileManager.removeItem(at: self.pendingDirectoryURL().appendingPathComponent("\(fileID).upload", isDirectory: false))
        try? self.fileManager.removeItem(at: self.failedDirectoryURL().appendingPathComponent("\(fileID).jsonl", isDirectory: false))

        self.refreshCounts()
        locationUploadLog.info("location item dropped \(fileID, privacy: .public)")
    }

    func handlePathStatus(_ status: NWPath.Status) {
        guard status == .satisfied else { return }
        guard !self.isDeleting else {
            locationUploadLog.debug("location reachability drain skipped during source delete")
            return
        }
        Task { @MainActor [weak self] in
            await self?.resumeFromDisk()
        }
    }

    func deleteLocationSource() async -> DeleteShareSourceResult {
        self.isDeleting = true
        self.cancelLocationWorkForDelete()

        let handle: String
        do {
            handle = try await self.ensureRegistered()
        } catch {
            let detail = String(describing: error)
            locationUploadLog.error("location source delete unavailable: registration failed \(detail, privacy: .public)")
            return await self.resetDeleteAndResume(result: .unreachable(reason: detail))
        }

        guard let localPort = self.localPortProvider() else {
            let detail = "location source delete unavailable: missing local port"
            locationUploadLog.error("\(detail, privacy: .public)")
            return await self.resetDeleteAndResume(result: .unreachable(reason: detail))
        }

        guard let url = ObserverServerURL.deleteSourceURL(localPort: localPort, source: "location") else {
            let detail = "location source delete unavailable: invalid url"
            locationUploadLog.error("\(detail, privacy: .public)")
            return await self.resetDeleteAndResume(result: .unreachable(reason: detail))
        }

        var request = ObserverAuthorizedRequest.make(url: url, handle: handle, method: "DELETE")
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.deleteSession.data(for: request)
        } catch {
            let detail = String(describing: error)
            locationUploadLog.error("location source delete failed: \(detail, privacy: .public)")
            return await self.resetDeleteAndResume(result: .unreachable(reason: detail))
        }

        guard let http = response as? HTTPURLResponse else {
            let detail = "location source delete failed: invalid response"
            locationUploadLog.error("\(detail, privacy: .public)")
            return await self.resetDeleteAndResume(result: .unreachable(reason: detail))
        }

        guard 200..<300 ~= http.statusCode else {
            let detail = "HTTP \(http.statusCode)"
            locationUploadLog.error("location source delete failed: \(detail, privacy: .public)")
            return await self.resetDeleteAndResume(result: .unreachable(reason: detail))
        }

        guard !data.isEmpty,
              let receipt = try? JSONDecoder().decode(DeleteSourceReceipt.self, from: data)
        else {
            locationUploadLog.error("location source delete not confirmed: missing receipt")
            return await self.resetDeleteAndResume(result: .notConfirmed)
        }

        let localNotRemoved = self.clearLocationLocalState()
        locationUploadLog.info("location source delete confirmed")
        return .confirmed(receipt: receipt, localNotRemoved: localNotRemoved)
    }

    func finishDelete() {
        self.isDeleting = false
        locationUploadLog.info("location source delete finished")
    }

    func finishBackgroundEvents() {
        guard let completionHandler = self.backgroundCompletionHandler else { return }
        self.backgroundCompletionHandler = nil
        completionHandler()
    }
}

private extension LocationUploader {
    struct FrozenSegment {
        let fileID: String
        let data: Data
    }

    struct ParsedFileName {
        let day: String
        let segment: String
    }

    struct TaskInfo {
        let fileID: String
        let segmentURL: URL
        let requestBodyURL: URL
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

    struct HeaderLine: Encodable {
        let batch: LocationSegmentBatch

        enum CodingKeys: String, CodingKey {
            case schema
            case kind
            case source
            case platform
            case tier
            case accuracy
            case fixCount = "fix_count"
            case gap
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("solstone.location.segment/1", forKey: .schema)
            try container.encode("location", forKey: .kind)
            try container.encode("location", forKey: .source)
            try container.encode("ios", forKey: .platform)
            try container.encode(self.batch.tier.rawValue, forKey: .tier)
            try container.encode(self.batch.accuracy.rawValue, forKey: .accuracy)
            try container.encode(self.batch.fixes.count, forKey: .fixCount)
            try container.encode(self.batch.gap, forKey: .gap)
        }
    }

    struct SnapshotHeaderLine: Decodable {
        let fixCount: Int

        enum CodingKeys: String, CodingKey {
            case fixCount = "fix_count"
        }
    }

    struct FixLine: Encodable {
        let fix: LocationFix

        enum CodingKeys: String, CodingKey {
            case schema
            case t
            case lat
            case lon
            case hAcc = "h_acc"
            case alt
            case vAcc = "v_acc"
            case speed
            case course
            case stationary
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("solstone.location.fix/1", forKey: .schema)
            try container.encode(self.fix.t, forKey: .t)
            try container.encode(self.fix.lat, forKey: .lat)
            try container.encode(self.fix.lon, forKey: .lon)
            try container.encode(self.fix.hAcc, forKey: .hAcc)
            if let alt = self.fix.alt {
                try container.encode(alt, forKey: .alt)
            } else {
                try container.encodeNil(forKey: .alt)
            }
            if let vAcc = self.fix.vAcc {
                try container.encode(vAcc, forKey: .vAcc)
            } else {
                try container.encodeNil(forKey: .vAcc)
            }
            if let speed = self.fix.speed {
                try container.encode(speed, forKey: .speed)
            } else {
                try container.encodeNil(forKey: .speed)
            }
            if let course = self.fix.course {
                try container.encode(course, forKey: .course)
            } else {
                try container.encodeNil(forKey: .course)
            }
            try container.encode(self.fix.stationary, forKey: .stationary)
        }
    }

    struct VisitLine: Encodable {
        let visit: LocationVisit

        enum CodingKeys: String, CodingKey {
            case schema
            case arrival
            case departure
            case lat
            case lon
            case hAcc = "h_acc"
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("solstone.location.visit/1", forKey: .schema)
            try container.encode(self.visit.arrival, forKey: .arrival)
            if let departure = self.visit.departure {
                try container.encode(departure, forKey: .departure)
            } else {
                try container.encodeNil(forKey: .departure)
            }
            try container.encode(self.visit.lat, forKey: .lat)
            try container.encode(self.visit.lon, forKey: .lon)
            try container.encode(self.visit.hAcc, forKey: .hAcc)
        }
    }

    func onThisPhoneItems(directory: URL, location: OnThisPhoneLocation) throws -> [OnThisPhoneItem] {
        guard self.fileManager.fileExists(atPath: directory.path) else {
            return []
        }
        let entries = try self.fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var items: [OnThisPhoneItem] = []
        for entry in entries where entry.pathExtension == "jsonl" {
            let fileID = entry.deletingPathExtension().lastPathComponent
            do {
                let parsed = try self.parseFrozenFileName(entry.lastPathComponent)
                let segmentStart = try self.segmentStartDate(parsed: parsed)
                let header = try self.loadSnapshotHeader(from: entry)
                // Zero-fix snapshots (gap-only and already-on-disk visit-only) stay off the
                // on-this-phone feed/counts, but may still upload.
                if header.fixCount == 0 { continue }
                let isActivelyUploading = location == .pending && self.activeTaskIDByFileID[fileID] != nil
                items.append(OnThisPhoneItem(
                    id: "location:\(fileID)",
                    sourceKind: .location,
                    sendState: onThisPhoneSendState(location: location, isActivelyUploading: isActivelyUploading),
                    contentType: "application/jsonl",
                    filename: entry.lastPathComponent,
                    bytes: self.byteCountIfAvailable(at: entry),
                    originApp: nil,
                    basis: nil,
                    itemTime: segmentStart,
                    targetJournal: nil,
                    stream: nil,
                    day: parsed.day,
                    segment: parsed.segment,
                    deliveredAt: nil,
                    rawFileURL: entry,
                    locationFixCount: header.fixCount
                ))
            } catch {
                locationUploadLog.debug("location on-this-phone item skipped: metadata unavailable")
            }
        }
        return items
    }

    func loadSnapshotHeader(from url: URL) throws -> SnapshotHeaderLine {
        let data = try Data(contentsOf: url)
        let lineData: Data
        if let newline = data.firstIndex(of: 0x0A) {
            lineData = Data(data[..<newline])
        } else {
            lineData = data
        }
        return try JSONDecoder().decode(SnapshotHeaderLine.self, from: lineData)
    }

    func segmentStartDate(parsed: ParsedFileName) throws -> Date {
        let parts = parsed.segment.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw LocationUploaderError.invalidFrozenFilename("\(parsed.day)-\(parsed.segment).jsonl")
        }
        let time = String(parts[0])
        let coveredSeconds = String(parts[1])
        guard parsed.day.count == 8,
              time.count == 6,
              !coveredSeconds.isEmpty,
              let year = Int(parsed.day.prefix(4)),
              let month = Int(parsed.day.dropFirst(4).prefix(2)),
              let day = Int(parsed.day.suffix(2)),
              let hour = Int(time.prefix(2)),
              let minute = Int(time.dropFirst(2).prefix(2)),
              let second = Int(time.suffix(2)),
              coveredSeconds.allSatisfy(\.isNumber),
              (1...12).contains(month),
              (1...31).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second)
        else {
            throw LocationUploaderError.invalidFrozenFilename("\(parsed.day)-\(parsed.segment).jsonl")
        }

        var components = DateComponents()
        components.calendar = self.calendar
        components.timeZone = self.calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let date = self.calendar.date(from: components) else {
            throw LocationUploaderError.invalidFrozenFilename("\(parsed.day)-\(parsed.segment).jsonl")
        }
        return date
    }

    func byteCountIfAvailable(at url: URL) -> Int64? {
        guard let size = try? self.fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
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

    func resetDeleteAndResume(result: DeleteShareSourceResult) async -> DeleteShareSourceResult {
        self.isDeleting = false
        await self.resumeFromDisk()
        return result
    }

    func cancelLocationWorkForDelete() {
        for task in self.uploadTaskByFileID.values {
            task.cancel()
        }
        for task in self.retryTasksByFileID.values {
            task.cancel()
        }

        self.uploadTaskByFileID.removeAll()
        self.activeTaskIDByFileID.removeAll()
        self.taskInfoByTaskID.removeAll()
        self.responseDataByTaskID.removeAll()
        self.retryTasksByFileID.removeAll()
        self.attemptCountByFileID.removeAll()
    }

    func clearLocationLocalState() -> [DeleteSourceReceipt.Issue] {
        var issues: [DeleteSourceReceipt.Issue] = []
        issues.append(contentsOf: self.clearFiles(at: self.pendingDirectoryURL(), surface: "pending"))
        issues.append(contentsOf: self.clearFiles(at: self.failedDirectoryURL(), surface: "failed"))
        self.refreshCounts()
        return issues
    }

    func clearFiles(at url: URL, surface: String) -> [DeleteSourceReceipt.Issue] {
        let entries: [URL]
        do {
            entries = try self.fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return [Self.deleteIssue(what: surface, error: error)]
        }

        var issues: [DeleteSourceReceipt.Issue] = []
        for entry in entries {
            do {
                try self.fileManager.removeItem(at: entry)
            } catch {
                issues.append(Self.deleteIssue(what: "\(surface)/\(entry.lastPathComponent)", error: error))
            }
        }
        return issues
    }

    static func deleteIssue(what: String, error: any Error) -> DeleteSourceReceipt.Issue {
        DeleteSourceReceipt.Issue(what: what, plainReason: String(describing: error))
    }

    func frozenSegment(for batch: LocationSegmentBatch) throws -> FrozenSegment {
        let day = self.dayString(for: batch.segmentStart)
        let segment = "\(self.timeString(for: batch.segmentStart))_\(Int(Double(batch.coveredSeconds).rounded()))"
        let fileID = "\(day)-\(segment)"
        var lines = [Data]()
        lines.append(try self.encoder.encode(HeaderLine(batch: batch)))
        for fix in batch.fixes {
            lines.append(try self.encoder.encode(FixLine(fix: fix)))
        }
        for visit in batch.visits {
            lines.append(try self.encoder.encode(VisitLine(visit: visit)))
        }

        var data = Data()
        for line in lines {
            data.append(line)
            data.append(0x0A)
        }
        return FrozenSegment(fileID: fileID, data: data)
    }

    func scheduleUpload(fileID: String) async {
        guard !self.isDeleting else {
            locationUploadLog.debug("location upload schedule skipped during source delete")
            return
        }
        guard self.activeTaskIDByFileID[fileID] == nil else { return }

        let segmentURL = self.pendingFileURL(fileID: fileID)
        guard self.fileManager.fileExists(atPath: segmentURL.path) else { return }

        guard self.isJournalConfigured() else {
            locationUploadLog.debug("location upload held: journal unavailable")
            self.lastError = nil
            self.refreshCounts()
            return
        }

        guard let localPort = self.localPortProvider() else {
            locationUploadLog.debug("location upload held: local port unavailable")
            self.lastError = nil
            self.refreshCounts()
            return
        }

        let parsed: ParsedFileName
        do {
            parsed = try self.parseFrozenFileName(segmentURL.lastPathComponent)
        } catch {
            do {
                try self.movePendingFileToFailed(
                    fileID: fileID,
                    fileURL: segmentURL,
                    reason: "pending location segment filename invalid"
                )
            } catch {
                self.lastError = String(describing: error)
            }
            self.refreshCounts()
            return
        }

        let handle: String
        do {
            handle = try await self.ensureRegistered()
        } catch {
            await self.handleUploadFailure(
                fileID: fileID,
                segmentURL: segmentURL,
                reason: String(describing: error)
            )
            return
        }

        guard let url = self.urlBuilder(localPort) else {
            await self.handleUploadFailure(
                fileID: fileID,
                segmentURL: segmentURL,
                reason: "location upload unavailable: invalid url"
            )
            return
        }

        do {
            let requestBodyURL = try self.buildMultipartRequestBody(
                segmentURL: segmentURL,
                fileID: fileID,
                parsed: parsed
            )
            let createResumeStart = DispatchTime.now().uptimeNanoseconds
            var request = ObserverAuthorizedRequest.make(url: url, handle: handle, method: "POST")
            request.setValue("multipart/form-data; boundary=\(self.boundary(for: fileID))", forHTTPHeaderField: "Content-Type")

            let task = self.session.uploadTask(with: request, fromFile: requestBodyURL)
            self.taskInfoByTaskID[task.taskIdentifier] = TaskInfo(
                fileID: fileID,
                segmentURL: segmentURL,
                requestBodyURL: requestBodyURL
            )
            self.activeTaskIDByFileID[fileID] = task.taskIdentifier
            self.uploadTaskByFileID[fileID] = task
            task.resume()
            DrainSignpost.event(
                .taskCreateResume,
                source: .location,
                fields: DrainFields(
                    status: "resumed",
                    durationMs: DrainSignpost.durationMs(since: createResumeStart)
                )
            )
        } catch {
            await self.handleUploadFailure(
                fileID: fileID,
                segmentURL: segmentURL,
                reason: String(describing: error)
            )
        }
    }

    func appendResponseData(_ data: Data, for taskIdentifier: Int) {
        self.responseDataByTaskID[taskIdentifier, default: Data()].append(data)
    }

    func handleCompletion(for task: URLSessionTask, error: (any Error)?) async {
        let start = DispatchTime.now().uptimeNanoseconds
        guard let info = self.taskInfoByTaskID.removeValue(forKey: task.taskIdentifier) else { return }
        self.activeTaskIDByFileID.removeValue(forKey: info.fileID)
        self.uploadTaskByFileID.removeValue(forKey: info.fileID)
        let responseData = self.responseDataByTaskID.removeValue(forKey: task.taskIdentifier) ?? Data()

        if self.isDeleting {
            locationUploadLog.debug("location upload completion dropped during source delete")
            DrainSignpost.event(
                .uploadCompletion,
                source: .location,
                fields: DrainFields(
                    status: "dropped",
                    error: .none,
                    durationMs: DrainSignpost.durationMs(since: start)
                )
            )
            return
        }

        if let error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                // Defensive parity: this only fires if loopback teardown surfaces -999.
                // Re-enqueue correctness assumes a segment that reached the server before
                // reconnect re-uploads to 2xx (status==duplicate is success). This branch
                // owns a delayed, un-counted re-drive; revisit if ingest ever returns 4xx
                // for duplicates.
                locationUploadLog.info("location upload cancelled by reconnect; awaiting resume \(info.fileID, privacy: .public)")
                let requeueDelay = self.retryDelays.first ?? 0
                self.retryTasksByFileID[info.fileID]?.cancel()
                self.retryTasksByFileID[info.fileID] = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.sleep(requeueDelay)
                    guard !Task.isCancelled else { return }
                    guard !self.isDeleting else { return }
                    await self.scheduleUpload(fileID: info.fileID)
                }
                self.refreshCounts()
                return
            }
            await self.handleUploadFailure(
                fileID: info.fileID,
                segmentURL: info.segmentURL,
                reason: String(describing: error)
            )
            try? self.fileManager.removeItem(at: info.requestBodyURL)
            DrainSignpost.event(
                .uploadCompletion,
                source: .location,
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
            let ingestResponse = try? JSONDecoder().decode(IngestResponse.self, from: responseData)
            if ingestResponse?.status == "duplicate" {
                locationUploadLog.info("location segment already delivered \(info.fileID, privacy: .public)")
            }
            let uploadedBytes = ThroughputMeter.byteCount(of: info.requestBodyURL)
            self.throughputMeter.record(
                bytes: uploadedBytes > 0 ? uploadedBytes : ThroughputMeter.byteCount(of: info.segmentURL)
            )
            try? self.fileManager.removeItem(at: info.segmentURL)
            try? self.fileManager.removeItem(at: info.requestBodyURL)
            self.attemptCountByFileID.removeValue(forKey: info.fileID)
            self.retryTasksByFileID[info.fileID]?.cancel()
            self.retryTasksByFileID.removeValue(forKey: info.fileID)
            self.lastUploadAt = Date()
            self.lastError = nil
            locationUploadLog.info("location segment uploaded \(info.fileID, privacy: .public)")
            self.refreshCounts()
            DrainSignpost.event(
                .uploadCompletion,
                source: .location,
                fields: DrainFields(
                    status: "success",
                    error: .none,
                    durationMs: DrainSignpost.durationMs(since: start)
                )
            )
            return
        }

        let body = String(data: responseData, encoding: .utf8) ?? ""
        await self.handleUploadFailure(
            fileID: info.fileID,
            segmentURL: info.segmentURL,
            reason: body.isEmpty ? "HTTP \(statusCode)" : "HTTP \(statusCode): \(body)"
        )
        try? self.fileManager.removeItem(at: info.requestBodyURL)
        DrainSignpost.event(
            .uploadCompletion,
            source: .location,
            fields: DrainFields(
                status: "httpFailure",
                error: .http,
                durationMs: DrainSignpost.durationMs(since: start),
                httpStatusClass: DrainSignpost.httpStatusClass(statusCode)
            )
        )
    }

    func handleUploadFailure(fileID: String, segmentURL: URL, reason: String) async {
        let nextAttempt = self.attemptCountByFileID[fileID, default: 0] + 1
        self.attemptCountByFileID[fileID] = nextAttempt
        self.lastError = reason

        if nextAttempt >= self.maxAttempts {
            do {
                try self.movePendingFileToFailed(
                    fileID: fileID,
                    fileURL: segmentURL,
                    reason: reason
                )
            } catch {
                self.lastError = String(describing: error)
            }
            self.retryTasksByFileID[fileID]?.cancel()
            self.retryTasksByFileID.removeValue(forKey: fileID)
            self.attemptCountByFileID.removeValue(forKey: fileID)
            self.refreshCounts()
            return
        }

        let delayIndex = min(nextAttempt - 1, max(self.retryDelays.count - 1, 0))
        let delay = self.retryDelays.isEmpty ? 0 : self.retryDelays[delayIndex]
        locationUploadLog.error("location segment upload failed \(fileID, privacy: .public): \(reason, privacy: .public)")
        self.retryTasksByFileID[fileID]?.cancel()
        self.retryTasksByFileID[fileID] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sleep(delay)
            guard !Task.isCancelled else { return }
            guard !self.isDeleting else { return }
            await self.scheduleUpload(fileID: fileID)
        }
        self.refreshCounts()
    }

    func movePendingFileToFailed(fileID: String, fileURL: URL, reason: String) throws {
        let failedDirectory = self.failedDirectoryURL()
        try self.fileManager.createDirectory(at: failedDirectory, withIntermediateDirectories: true)
        if self.fileManager.fileExists(atPath: fileURL.path) {
            let target = failedDirectory.appendingPathComponent(fileURL.lastPathComponent, isDirectory: false)
            if self.fileManager.fileExists(atPath: target.path) {
                try self.fileManager.removeItem(at: target)
            }
            try self.fileManager.moveItem(at: fileURL, to: target)
        }

        locationUploadLog.error("location segment moved to failed \(fileID, privacy: .public): \(reason, privacy: .public)")
        self.lastError = reason
    }

    func buildMultipartRequestBody(segmentURL: URL, fileID: String, parsed: ParsedFileName) throws -> URL {
        let interval = DrainSignpost.begin(.multipartBodyBuild, source: .location)
        do {
            let boundary = self.boundary(for: fileID)
            let requestBodyURL = self.pendingDirectoryURL()
                .appendingPathComponent("\(fileID).upload", isDirectory: false)

            var body = Data()
            body.append(self.multipartField(named: "segment", value: parsed.segment, boundary: boundary))
            body.append(self.multipartField(named: "day", value: parsed.day, boundary: boundary))
            body.append(self.multipartField(named: "platform", value: "ios", boundary: boundary))

            let segmentData = try Data(contentsOf: segmentURL)
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(ObserverServerURL.filesFieldName)\"; filename=\"location.jsonl\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/jsonl\r\n\r\n".data(using: .utf8)!)
            body.append(segmentData)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            let byteCount = body.count
            try body.write(to: requestBodyURL, options: .atomic)
            DrainSignpost.end(
                interval,
                source: .location,
                fields: DrainFields(status: "success", error: .none, bytes: byteCount)
            )
            return requestBodyURL
        } catch {
            DrainSignpost.end(
                interval,
                source: .location,
                fields: DrainFields(status: "failure", error: DrainErrorCategory.classify(error))
            )
            throw error
        }
    }

    func multipartField(named name: String, value: String, boundary: String) -> Data {
        Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
    }

    func boundary(for fileID: String) -> String {
        "Boundary-\(fileID)"
    }

    func parseFrozenFileName(_ filename: String) throws -> ParsedFileName {
        guard filename.hasSuffix(".jsonl") else {
            throw LocationUploaderError.invalidFrozenFilename(filename)
        }
        let stem = String(filename.dropLast(".jsonl".count))
        guard let separator = stem.firstIndex(of: "-") else {
            throw LocationUploaderError.invalidFrozenFilename(filename)
        }
        let day = String(stem[..<separator])
        let segment = String(stem[stem.index(after: separator)...])
        guard !day.isEmpty, !segment.isEmpty else {
            throw LocationUploaderError.invalidFrozenFilename(filename)
        }
        return ParsedFileName(day: day, segment: segment)
    }

    func dayString(for date: Date) -> String {
        let components = self.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    func timeString(for date: Date) -> String {
        let components = self.calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d%02d%02d", components.hour ?? 0, components.minute ?? 0, components.second ?? 0)
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

    func pendingFileURL(fileID: String) -> URL {
        self.pendingDirectoryURL().appendingPathComponent("\(fileID).jsonl", isDirectory: false)
    }

    func refreshCounts() {
        let start = DispatchTime.now().uptimeNanoseconds
        self.pendingCount = self.countFiles(in: self.pendingDirectoryURL())
        self.failedCount = self.countFiles(in: self.failedDirectoryURL())
        DrainSignpost.event(
            .countRefresh,
            source: .location,
            fields: DrainFields(
                status: "success",
                pending: self.pendingCount,
                failed: self.failedCount,
                durationMs: DrainSignpost.durationMs(since: start)
            )
        )
    }

    func countFiles(in directory: URL) -> Int {
        guard let entries = try? self.fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        return entries.filter { $0.pathExtension == "jsonl" }.count
    }
}

enum LocationUploaderError: Error {
    case registrationUnavailable
    case invalidFrozenFilename(String)
}
