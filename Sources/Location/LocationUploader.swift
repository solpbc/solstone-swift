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

    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let cacheRootURL: URL
    @ObservationIgnored private let sessionDelegate: LocationUploaderSessionDelegate
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let ensureRegistered: @Sendable @MainActor () async throws -> String
    @ObservationIgnored private let localPortProvider: @Sendable @MainActor () -> Int?
    @ObservationIgnored private let urlBuilder: @Sendable (Int, String) -> URL?
    @ObservationIgnored private let retryDelays: [UInt64]
    @ObservationIgnored private let maxAttempts: Int
    @ObservationIgnored private let sleep: @Sendable (UInt64) async -> Void
    @ObservationIgnored private let encoder: JSONEncoder
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var backgroundCompletionHandler: (@MainActor @Sendable () -> Void)?
    @ObservationIgnored private var responseDataByTaskID: [Int: Data] = [:]
    @ObservationIgnored private var taskInfoByTaskID: [Int: TaskInfo] = [:]
    @ObservationIgnored private var activeTaskIDByFileID: [String: Int] = [:]
    @ObservationIgnored private var attemptCountByFileID: [String: Int] = [:]
    @ObservationIgnored private var retryTasksByFileID: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private let pathMonitorQueue = DispatchQueue(label: "app.solstone.swift.location-uploader")

    init(
        cacheRootURL: URL? = nil,
        fileManager: FileManager = .default,
        sessionConfiguration: URLSessionConfiguration? = nil,
        ensureRegistered: @escaping @Sendable @MainActor () async throws -> String = {
            throw LocationUploaderError.registrationUnavailable
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
        timeZone: TimeZone = .current,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) {
        self.fileManager = fileManager
        self.cacheRootURL = cacheRootURL
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Location", isDirectory: true)
        self.ensureRegistered = ensureRegistered
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

    func retryFailed() async {
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
        guard self.activeTaskIDByFileID[fileID] == nil else { return }

        let segmentURL = self.pendingFileURL(fileID: fileID)
        guard self.fileManager.fileExists(atPath: segmentURL.path) else { return }

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

        let key: String
        do {
            key = try await self.ensureRegistered()
        } catch {
            await self.handleUploadFailure(
                fileID: fileID,
                segmentURL: segmentURL,
                reason: String(describing: error)
            )
            return
        }

        guard let localPort = self.localPortProvider() else {
            await self.handleUploadFailure(
                fileID: fileID,
                segmentURL: segmentURL,
                reason: "location upload unavailable: missing local port"
            )
            return
        }

        guard let url = self.urlBuilder(localPort, key) else {
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
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(self.boundary(for: fileID))", forHTTPHeaderField: "Content-Type")

            let task = self.session.uploadTask(with: request, fromFile: requestBodyURL)
            self.taskInfoByTaskID[task.taskIdentifier] = TaskInfo(
                fileID: fileID,
                segmentURL: segmentURL,
                requestBodyURL: requestBodyURL
            )
            self.activeTaskIDByFileID[fileID] = task.taskIdentifier
            task.resume()
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
        guard let info = self.taskInfoByTaskID.removeValue(forKey: task.taskIdentifier) else { return }
        self.activeTaskIDByFileID.removeValue(forKey: info.fileID)
        let responseData = self.responseDataByTaskID.removeValue(forKey: task.taskIdentifier) ?? Data()

        if let error {
            await self.handleUploadFailure(
                fileID: info.fileID,
                segmentURL: info.segmentURL,
                reason: String(describing: error)
            )
            try? self.fileManager.removeItem(at: info.requestBodyURL)
            return
        }

        let statusCode = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if 200..<300 ~= statusCode {
            let ingestResponse = try? JSONDecoder().decode(IngestResponse.self, from: responseData)
            if ingestResponse?.status == "duplicate" {
                locationUploadLog.info("location segment already delivered \(info.fileID, privacy: .public)")
            }
            try? self.fileManager.removeItem(at: info.segmentURL)
            try? self.fileManager.removeItem(at: info.requestBodyURL)
            self.attemptCountByFileID.removeValue(forKey: info.fileID)
            self.retryTasksByFileID[info.fileID]?.cancel()
            self.retryTasksByFileID.removeValue(forKey: info.fileID)
            self.lastUploadAt = Date()
            self.lastError = nil
            locationUploadLog.info("location segment uploaded \(info.fileID, privacy: .public)")
            self.refreshCounts()
            return
        }

        let body = String(data: responseData, encoding: .utf8) ?? ""
        await self.handleUploadFailure(
            fileID: info.fileID,
            segmentURL: info.segmentURL,
            reason: body.isEmpty ? "HTTP \(statusCode)" : "HTTP \(statusCode): \(body)"
        )
        try? self.fileManager.removeItem(at: info.requestBodyURL)
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
        let boundary = self.boundary(for: fileID)
        let requestBodyURL = self.pendingDirectoryURL()
            .appendingPathComponent("\(fileID).upload", isDirectory: false)

        var body = Data()
        body.append(self.multipartField(named: "segment", value: parsed.segment, boundary: boundary))
        body.append(self.multipartField(named: "day", value: parsed.day, boundary: boundary))
        body.append(self.multipartField(named: "platform", value: "ios", boundary: boundary))
        body.append(self.multipartField(named: "meta", value: Self.metaJSONString(), boundary: boundary))

        let segmentData = try Data(contentsOf: segmentURL)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"files[]\"; filename=\"location.jsonl\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/jsonl\r\n\r\n".data(using: .utf8)!)
        body.append(segmentData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        try body.write(to: requestBodyURL, options: .atomic)
        return requestBodyURL
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

    static func metaJSONString() -> String {
        let data = try? JSONSerialization.data(withJSONObject: ["stream": "location"], options: [.sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? #"{"stream":"location"}"#
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
        self.pendingCount = self.countFiles(in: self.pendingDirectoryURL())
        self.failedCount = self.countFiles(in: self.failedDirectoryURL())
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
