// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

nonisolated private let journalEventLog = Logger(subsystem: "app.solstone.swift", category: "journal-events")

/// One serial queue per journal-event directory. A write that marks or prunes re-enters the same queue.
nonisolated private final class JournalEventWriteGate: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.solstone.swift.journal-events")
    private let key = DispatchSpecificKey<UInt8>()

    init() {
        self.queue.setSpecific(key: self.key, value: 1)
    }

    func sync<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: self.key) != nil {
            return try body()
        }
        return try self.queue.sync(execute: body)
    }
}

nonisolated private final class JournalEventWriteRegistry: @unchecked Sendable {
    static let shared = JournalEventWriteRegistry()
    private let registry = DispatchQueue(label: "app.solstone.swift.journal-events.registry")
    private var gates: [String: JournalEventWriteGate] = [:]

    func sync<T>(root: URL, _ body: () throws -> T) rethrows -> T {
        try self.gate(for: root).sync(body)
    }

    private func gate(for root: URL) -> JournalEventWriteGate {
        let path = root.standardizedFileURL.path
        return self.registry.sync {
            if let existing = self.gates[path] {
                return existing
            }
            let created = JournalEventWriteGate()
            self.gates[path] = created
            return created
        }
    }
}

nonisolated enum JournalEventKind: String, Codable, Sendable, Equatable {
    case loss
    case diagnostic
    case legacy
}

nonisolated enum JournalEventSource: String, Codable, Sendable, Equatable {
    case audio
    case screencast
    case screenAudio = "screen-audio"
}

nonisolated struct JournalEventDetail: Codable, Sendable, Equatable {
    var interruptionDuration: TimeInterval?
    var configurationRestartSuccesses: Int?
    var configurationRestartFailures: Int?

    enum CodingKeys: String, CodingKey {
        case interruptionDuration = "interruption_duration"
        case configurationRestartSuccesses = "configuration_restart_successes"
        case configurationRestartFailures = "configuration_restart_failures"
    }

    func merging(_ incoming: JournalEventDetail?) -> JournalEventDetail {
        guard let incoming else { return self }
        var detail = self
        if let seconds = incoming.interruptionDuration {
            detail.interruptionDuration = (detail.interruptionDuration ?? 0) + seconds
        }
        if let count = incoming.configurationRestartSuccesses {
            detail.configurationRestartSuccesses = (detail.configurationRestartSuccesses ?? 0) + count
        }
        if let count = incoming.configurationRestartFailures {
            detail.configurationRestartFailures = (detail.configurationRestartFailures ?? 0) + count
        }
        return detail
    }
}

nonisolated struct JournalEventRecord: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var kind: JournalEventKind
    var source: JournalEventSource
    var reason: String
    var segmentID: String?
    var foundAt: Date
    var lastAt: Date
    var captureAt: Date?
    /// The source record's own time. Import dates `foundAt` for retention and keeps this for the export.
    var recordedAt: Date? = nil
    var count: Int
    var detail: JournalEventDetail?

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case source
        case reason
        case segmentID = "segment_id"
        case foundAt = "found_at"
        case lastAt = "last_at"
        case captureAt = "capture_at"
        case recordedAt = "recorded_at"
        case count
        case detail
    }
}

nonisolated enum JournalEventsRead: Sendable, Equatable {
    case events([JournalEventRecord])
    case unreadable
}

nonisolated enum JournalImportMarker: Sendable, Equatable {
    case notRun
    case complete(imported: Int, skipped: Int)
    case failed(reason: String)
}

nonisolated struct JournalImportRun: Sendable, Equatable {
    var imported: Int
    var skipped: Int
}

/// Synchronous journal-event directory. Foundation and os only. Callers on the main actor
/// and the broadcast extension's queue both use it. Writes for one directory run one at a time,
/// including a write that marks or prunes before it returns. A seen-mark write never opens an event file.
nonisolated struct JournalEventStore: Sendable {
    static let directoryName = "JournalEvents"
    static let lossCap = 500
    static let diagnosticCap = 1000
    static let retentionDays = 30
    static let noticeWindowDays = 6
    static let unreadableLine = "journal events could not be read"

    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// The process file manager. Not stored: `FileManager` is not `Sendable`.
    private var fileManager: FileManager { .default }

    private func withWrite<T>(_ body: () throws -> T) rethrows -> T {
        try JournalEventWriteRegistry.shared.sync(root: self.rootURL, body)
    }

    static func directory(inAppGroupRoot root: URL) -> URL {
        root.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    static func directory(besideMobileSegmentRoot mobileSegmentRoot: URL) -> URL {
        mobileSegmentRoot
            .deletingLastPathComponent()
            .appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    static func lossID(segmentID: UUID, source: JournalEventSource) -> String {
        "\(segmentID.uuidString)-\(source.rawValue)"
    }

    static func diagnosticID(segmentID: UUID?, source: JournalEventSource, reason: String, writerFault: Bool) -> String {
        let segment = segmentID?.uuidString ?? "none"
        var id = "\(segment)-\(source.rawValue)-\(reason)"
        if writerFault { id += "-fault" }
        return id
    }

    static func legacyID(segmentID: UUID, reason: String, recordedAt: Date) -> String {
        "legacy|\(segmentID.uuidString)|\(reason)|\(Self.makeInternetDate().string(from: recordedAt))"
    }

    // MARK: - Writes

    func recordLoss(
        segmentID: UUID,
        source: JournalEventSource,
        reason: String,
        captureAt: Date?,
        now: Date,
        calendar: Calendar = .current
    ) throws {
        try self.withWrite {
            try self.recordLossWhileLocked(
                segmentID: segmentID,
                source: source,
                reason: reason,
                captureAt: captureAt,
                now: now,
                calendar: calendar
            )
        }
    }

    private func recordLossWhileLocked(
        segmentID: UUID,
        source: JournalEventSource,
        reason: String,
        captureAt: Date?,
        now: Date,
        calendar: Calendar
    ) throws {
        let id = Self.lossID(segmentID: segmentID, source: source)
        let url = self.eventURL(kind: .loss, id: id)
        if self.fileManager.fileExists(atPath: url.path) {
            if !self.isGateOpen {
                try self.markSeen(id: id)
            }
            self.prune(now: now, calendar: calendar)
            return
        }
        let record = JournalEventRecord(
            id: id,
            kind: .loss,
            source: source,
            reason: reason,
            segmentID: segmentID.uuidString,
            foundAt: now,
            lastAt: now,
            captureAt: captureAt,
            count: 1,
            detail: nil
        )
        try self.writeRecord(record, to: url)
        if !self.isGateOpen {
            try self.markSeen(id: id)
        }
        self.prune(now: now, calendar: calendar)
    }

    func recordDiagnostic(
        segmentID: UUID?,
        source: JournalEventSource,
        reason: String,
        captureAt: Date?,
        now: Date,
        writerFault: Bool = false,
        detail: JournalEventDetail? = nil,
        calendar: Calendar = .current
    ) throws {
        try self.withWrite {
            try self.recordDiagnosticWhileLocked(
                segmentID: segmentID,
                source: source,
                reason: reason,
                captureAt: captureAt,
                now: now,
                writerFault: writerFault,
                detail: detail,
                calendar: calendar
            )
        }
    }

    private func recordDiagnosticWhileLocked(
        segmentID: UUID?,
        source: JournalEventSource,
        reason: String,
        captureAt: Date?,
        now: Date,
        writerFault: Bool,
        detail: JournalEventDetail?,
        calendar: Calendar
    ) throws {
        let id = Self.diagnosticID(segmentID: segmentID, source: source, reason: reason, writerFault: writerFault)
        let url = self.eventURL(kind: .diagnostic, id: id)
        if self.fileManager.fileExists(atPath: url.path) {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                journalEventLog.error("journal event unreadable name=\(url.lastPathComponent, privacy: .public)")
                return
            }
            if let existing = try? Self.makeDecoder().decode(JournalEventRecord.self, from: data),
               existing.id == id {
                var updated = existing
                updated.lastAt = now
                updated.count += 1
                updated.detail = (existing.detail ?? JournalEventDetail()).merging(detail)
                try self.writeRecord(updated, to: url)
                self.prune(now: now, calendar: calendar)
                return
            }
            self.moveAside(url)
            guard !self.fileManager.fileExists(atPath: url.path) else { return }
        }
        let record = JournalEventRecord(
            id: id,
            kind: .diagnostic,
            source: source,
            reason: reason,
            segmentID: segmentID?.uuidString,
            foundAt: now,
            lastAt: now,
            captureAt: captureAt,
            count: 1,
            detail: detail
        )
        try self.writeRecord(record, to: url)
        self.prune(now: now, calendar: calendar)
    }

    /// Writes a new legacy row dated at `now` for retention. The record's own time is `recordedAt`.
    /// Returns false when that identity is already stored. An existing row is marked seen and not counted again.
    @discardableResult
    func recordLegacy(
        segmentID: UUID,
        reason: String,
        recordedAt: Date,
        now: Date
    ) throws -> Bool {
        try self.withWrite {
            try self.recordLegacyWhileLocked(
                segmentID: segmentID,
                reason: reason,
                recordedAt: recordedAt,
                now: now
            )
        }
    }

    private func recordLegacyWhileLocked(
        segmentID: UUID,
        reason: String,
        recordedAt: Date,
        now: Date
    ) throws -> Bool {
        let id = Self.legacyID(segmentID: segmentID, reason: reason, recordedAt: recordedAt)
        let url = self.eventURL(kind: .diagnostic, id: id)
        if self.fileManager.fileExists(atPath: url.path) {
            if !self.isSeen(id: id) {
                try self.markSeen(id: id)
            }
            return false
        }
        let record = JournalEventRecord(
            id: id,
            kind: .legacy,
            source: .audio,
            reason: reason,
            segmentID: segmentID.uuidString,
            foundAt: now,
            lastAt: now,
            captureAt: nil,
            recordedAt: recordedAt,
            count: 1,
            detail: nil
        )
        try self.writeRecord(record, to: url)
        try self.markSeen(id: id)
        return true
    }

    func markSeen(id: String) throws {
        try self.withWrite {
            try self.markSeenWhileLocked(id: id)
        }
    }

    private func markSeenWhileLocked(id: String) throws {
        let url = self.seenURL(id)
        if self.fileManager.fileExists(atPath: url.path) { return }
        let body = try Self.makeEncoder().encode(SeenMark(id: id))
        try self.atomicWrite(body, to: url)
    }

    func markAllEventsSeen() throws {
        try self.withWrite {
            try self.markAllEventsSeenWhileLocked()
        }
    }

    private func markAllEventsSeenWhileLocked() throws {
        switch self.readEvents() {
        case .unreadable:
            throw CocoaError(.fileReadUnknown)
        case .events(let events):
            for event in events {
                try self.markSeen(id: event.id)
            }
        }
    }

    func isSeen(id: String) -> Bool {
        self.fileManager.fileExists(atPath: self.seenURL(id).path)
    }

    @discardableResult
    func openGate(now: Date) throws -> Bool {
        try self.withWrite {
            try self.openGateWhileLocked(now: now)
        }
    }

    private func openGateWhileLocked(now: Date) throws -> Bool {
        let url = self.rootURL.appendingPathComponent("gate.json", isDirectory: false)
        if self.fileManager.fileExists(atPath: url.path) { return false }
        let body = try Self.makeEncoder().encode(GateMark(openedAt: now))
        try self.atomicWrite(body, to: url)
        return true
    }

    var isGateOpen: Bool {
        self.fileManager.fileExists(atPath: self.gateURL.path)
    }

    func seedIdentityIfAbsent(_ identity: String) throws {
        try self.withWrite {
            try self.seedIdentityIfAbsentWhileLocked(identity)
        }
    }

    private func seedIdentityIfAbsentWhileLocked(_ identity: String) throws {
        let url = self.identityURL
        if self.fileManager.fileExists(atPath: url.path) { return }
        try self.writeIdentity(identity)
    }

    func readIdentity() -> String? {
        let url = self.identityURL
        guard self.fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let mark = try? Self.makeDecoder().decode(IdentityMark.self, from: data) else {
            journalEventLog.error("journal identity unreadable")
            return nil
        }
        return mark.identity
    }

    func writeIdentity(_ identity: String) throws {
        try self.withWrite {
            try self.writeIdentityWhileLocked(identity)
        }
    }

    private func writeIdentityWhileLocked(_ identity: String) throws {
        let body = try Self.makeEncoder().encode(IdentityMark(identity: identity))
        try self.atomicWrite(body, to: self.identityURL)
    }

    func readImportMarker() -> JournalImportMarker {
        let url = self.importURL
        guard self.fileManager.fileExists(atPath: url.path) else { return .notRun }
        guard let data = try? Data(contentsOf: url),
              let mark = try? Self.makeDecoder().decode(ImportMark.self, from: data) else {
            return .failed(reason: "unreadable")
        }
        switch mark.status {
        case "complete":
            return .complete(imported: mark.imported ?? 0, skipped: mark.skipped ?? 0)
        case "failed":
            return .failed(reason: mark.reason ?? "")
        default:
            return .failed(reason: mark.reason ?? mark.status)
        }
    }

    func writeImportComplete(imported: Int, skipped: Int) throws {
        try self.withWrite {
            try self.writeImportCompleteWhileLocked(imported: imported, skipped: skipped)
        }
    }

    private func writeImportCompleteWhileLocked(imported: Int, skipped: Int) throws {
        let body = try Self.makeEncoder().encode(ImportMark(status: "complete", imported: imported, skipped: skipped, reason: nil))
        try self.atomicWrite(body, to: self.importURL)
    }

    func writeImportFailed(reason: String) throws {
        try self.withWrite {
            try self.writeImportFailedWhileLocked(reason: reason)
        }
    }

    private func writeImportFailedWhileLocked(reason: String) throws {
        let body = try Self.makeEncoder().encode(ImportMark(status: "failed", imported: nil, skipped: nil, reason: reason))
        try self.atomicWrite(body, to: self.importURL)
    }

    /// Reads legacy interruption evidence. Does not delete source files. Returns nil when cancelled
    /// before the marker should be written. A file that does not decode increments `skipped` and stays.
    /// Rows are dated at `now`. Prune runs once, after a pass that was not cancelled.
    func importLegacy(
        from mobileSegmentRoots: [URL],
        now: Date = Date(),
        calendar: Calendar = .current,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> JournalImportRun? {
        try self.withWrite {
            try self.importLegacyWhileLocked(
                from: mobileSegmentRoots,
                now: now,
                calendar: calendar,
                isCancelled: isCancelled
            )
        }
    }

    private func importLegacyWhileLocked(
        from mobileSegmentRoots: [URL],
        now: Date,
        calendar: Calendar,
        isCancelled: @Sendable () -> Bool
    ) throws -> JournalImportRun? {
        if isCancelled() { return nil }
        var imported = 0
        var skipped = 0
        for root in mobileSegmentRoots {
            if isCancelled() { return nil }
            try self.importInterruptions(
                in: root, now: now, imported: &imported, skipped: &skipped, isCancelled: isCancelled
            )
            if isCancelled() { return nil }
            try self.importEmptyTombstones(
                in: root, now: now, imported: &imported, skipped: &skipped, isCancelled: isCancelled
            )
            if isCancelled() { return nil }
            try self.importManifests(
                in: root, now: now, imported: &imported, skipped: &skipped, isCancelled: isCancelled
            )
        }
        if isCancelled() { return nil }
        self.pruneWhileLocked(now: now, calendar: calendar)
        self.pruneOrphanSeenMarks()
        return JournalImportRun(imported: imported, skipped: skipped)
    }

    // MARK: - Reads

    func readEvents() -> JournalEventsRead {
        var records: [JournalEventRecord] = []
        for kind in [JournalEventKind.loss, JournalEventKind.diagnostic] {
            switch self.readDirectory(self.directoryURL(kind == .loss ? "losses" : "diagnostics"), into: &records) {
            case .unreadable:
                return .unreadable
            case .ok:
                break
            }
        }
        return .events(records)
    }

    func unseenLosses(now: Date, calendar: Calendar = .current) -> JournalEventsRead {
        guard self.isGateOpen else { return .events([]) }
        guard case .events(let events) = self.readEvents() else { return .unreadable }
        guard let windowStart = Self.windowStart(now: now, calendar: calendar) else { return .events([]) }
        let losses = events.filter { event in
            event.kind == .loss
                && !self.isSeen(id: event.id)
                && calendar.startOfDay(for: event.foundAt) >= windowStart
        }
        return .events(losses.sorted { $0.foundAt == $1.foundAt ? $0.id < $1.id : $0.foundAt < $1.foundAt })
    }

    func diagnosticSection(now: Date, calendar: Calendar = .current) -> String {
        self.prune(now: now, calendar: calendar)
        switch self.readEvents() {
        case .unreadable:
            return Self.unreadableLine
        case .events(let events):
            let cutoff = calendar.date(byAdding: .day, value: -Self.retentionDays, to: now) ?? now
            let recent = events
                .filter { $0.lastAt >= cutoff }
                .sorted { $0.lastAt == $1.lastAt ? $0.id > $1.id : $0.lastAt > $1.lastAt }
            let formatter = Self.localTimestamp(calendar: calendar)
            var lines = recent.map { record in
                self.diagnosticLine(record, formatter: formatter)
            }
            lines.append(self.importLine())
            return lines.joined(separator: "\n")
        }
    }

    func prune(now: Date, calendar: Calendar = .current) {
        self.withWrite {
            self.pruneWhileLocked(now: now, calendar: calendar)
        }
    }

    /// Retention, then seen marks whose event file is confirmed absent. A resume or reconcile calls this once.
    func pruneForPass(now: Date, calendar: Calendar = .current) {
        self.withWrite {
            self.pruneWhileLocked(now: now, calendar: calendar)
            self.pruneOrphanSeenMarks()
        }
    }

    private func pruneWhileLocked(now: Date, calendar: Calendar) {
        guard case .events(let events) = self.readEvents() else { return }
        let ageCutoff = calendar.date(byAdding: .day, value: -Self.retentionDays, to: now) ?? now
        var losses = events.filter { $0.kind == .loss }
        var diagnostics = events.filter { $0.kind == .diagnostic || $0.kind == .legacy }
        losses.removeAll { self.removeIfExpired($0, ageCutoff: ageCutoff, now: now, calendar: calendar) }
        diagnostics.removeAll { self.removeIfExpired($0, ageCutoff: ageCutoff, now: now, calendar: calendar) }
        self.removeOverflow(losses, cap: Self.lossCap, now: now, calendar: calendar)
        self.removeOverflow(diagnostics, cap: Self.diagnosticCap, now: now, calendar: calendar)
    }

    // MARK: - Import walk

    private func importInterruptions(
        in root: URL,
        now: Date,
        imported: inout Int,
        skipped: inout Int,
        isCancelled: @Sendable () -> Bool
    ) throws {
        let directory = root
            .appendingPathComponent("interruptions", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let interruptionSkips = try self.importJSONFiles(in: directory, isCancelled: isCancelled) { data in
            try self.importTombstoneData(
                data, now: now, imported: &imported, skipped: &skipped, requireUndecodable: false
            )
        }
        skipped += interruptionSkips
    }

    private func importEmptyTombstones(
        in root: URL,
        now: Date,
        imported: inout Int,
        skipped: inout Int,
        isCancelled: @Sendable () -> Bool
    ) throws {
        let directory = root
            .appendingPathComponent("tombstones", isDirectory: true)
            .appendingPathComponent("empty", isDirectory: true)
        let tombstoneSkips = try self.importJSONFiles(in: directory, isCancelled: isCancelled) { data in
            try self.importTombstoneData(
                data, now: now, imported: &imported, skipped: &skipped, requireUndecodable: true
            )
        }
        skipped += tombstoneSkips
    }

    private func importManifests(
        in root: URL,
        now: Date,
        imported: inout Int,
        skipped: inout Int,
        isCancelled: @Sendable () -> Bool
    ) throws {
        for lifecycle in ["active", "pending", "failed"] {
            if isCancelled() { return }
            let directory = root.appendingPathComponent(lifecycle, isDirectory: true)
            let children = self.childURLs(directory)
            switch children {
            case .missing:
                continue
            case .unreadable:
                throw CocoaError(.fileReadUnknown)
            case .urls(let urls):
                for segment in urls {
                    if isCancelled() { return }
                    let manifest = segment.appendingPathComponent("manifest.json", isDirectory: false)
                    guard self.fileManager.fileExists(atPath: manifest.path) else { continue }
                    guard let data = try? Data(contentsOf: manifest) else {
                        self.noteSkipped(manifest.lastPathComponent)
                        skipped += 1
                        continue
                    }
                    do {
                        try self.importManifestData(
                            data, name: manifest.lastPathComponent, now: now, imported: &imported, skipped: &skipped
                        )
                    } catch is JournalLegacyDecodeError {
                        self.noteSkipped(manifest.lastPathComponent)
                        skipped += 1
                    }
                }
            }
        }
    }

    /// Skips this walk counts itself. The consume closure owns the caller's counters, so this
    /// function does not take them: one call cannot both borrow them and close over them.
    private func importJSONFiles(
        in directory: URL,
        isCancelled: @Sendable () -> Bool,
        consume: (Data) throws -> Void
    ) throws -> Int {
        var skippedHere = 0
        switch self.childURLs(directory) {
        case .missing:
            return 0
        case .unreadable:
            throw CocoaError(.fileReadUnknown)
        case .urls(let urls):
            for url in urls where url.pathExtension == "json" {
                if isCancelled() { return skippedHere }
                guard let data = try? Data(contentsOf: url) else {
                    self.noteSkipped(url.lastPathComponent)
                    skippedHere += 1
                    continue
                }
                do {
                    try consume(data)
                } catch is JournalLegacyDecodeError {
                    self.noteSkipped(url.lastPathComponent)
                    skippedHere += 1
                }
            }
        }
        return skippedHere
    }

    private func importTombstoneData(
        _ data: Data,
        now: Date,
        imported: inout Int,
        skipped: inout Int,
        requireUndecodable: Bool
    ) throws {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let segmentString = object["segment_id"] as? String,
              let segmentID = UUID(uuidString: segmentString),
              let reason = object["reason"] as? String,
              let recordedString = object["recorded_at"] as? String,
              let recordedAt = Self.makeInternetDate().date(from: recordedString) else {
            throw JournalLegacyDecodeError.undecodable
        }
        if requireUndecodable && reason != "audio_undecodable_container" { return }
        if try self.recordLegacy(segmentID: segmentID, reason: reason, recordedAt: recordedAt, now: now) {
            imported += 1
        }
    }

    private func importManifestData(
        _ data: Data,
        name: String,
        now: Date,
        imported: inout Int,
        skipped: inout Int
    ) throws {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let segmentString = object["segment_id"] as? String,
              let segmentID = UUID(uuidString: segmentString),
              let audio = object["audio"] as? [String: Any] else {
            throw JournalLegacyDecodeError.undecodable
        }
        guard let reason = audio["reason"] as? String, reason == "audio_undecodable_container" else { return }
        let recordedString = (audio["last_attempt_at"] as? String) ?? (object["updated_at"] as? String)
        guard let recordedString, let recordedAt = Self.makeInternetDate().date(from: recordedString) else {
            throw JournalLegacyDecodeError.undecodable
        }
        if try self.recordLegacy(segmentID: segmentID, reason: reason, recordedAt: recordedAt, now: now) {
            imported += 1
        }
    }

    private func noteSkipped(_ name: String) {
        journalEventLog.error("journal legacy import skipped name=\(name, privacy: .public)")
    }

    // MARK: - Retention

    private func removeIfExpired(
        _ event: JournalEventRecord,
        ageCutoff: Date,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        let agedAt = event.kind == .loss ? event.foundAt : event.lastAt
        guard agedAt < ageCutoff else { return false }
        if self.isProtectedUnseenLoss(event, now: now, calendar: calendar) { return false }
        self.deleteEvent(event)
        return true
    }

    private func removeOverflow(_ events: [JournalEventRecord], cap: Int, now: Date, calendar: Calendar) {
        guard events.count > cap else { return }
        let oldest = events.sorted { lhs, rhs in
            let left = lhs.kind == .loss ? lhs.foundAt : lhs.lastAt
            let right = rhs.kind == .loss ? rhs.foundAt : rhs.lastAt
            return left == right ? lhs.id < rhs.id : left < right
        }
        var removed = 0
        let overflow = events.count - cap
        for event in oldest {
            if removed >= overflow { break }
            if self.isProtectedUnseenLoss(event, now: now, calendar: calendar) { continue }
            self.deleteEvent(event)
            removed += 1
        }
    }

    private func isProtectedUnseenLoss(_ event: JournalEventRecord, now: Date, calendar: Calendar) -> Bool {
        guard event.kind == .loss, !self.isSeen(id: event.id) else { return false }
        guard let windowStart = Self.windowStart(now: now, calendar: calendar) else { return false }
        return calendar.startOfDay(for: event.foundAt) >= windowStart
    }

    private func deleteEvent(_ event: JournalEventRecord) {
        let url = self.eventURL(kind: event.kind == .loss ? .loss : .diagnostic, id: event.id)
        try? self.fileManager.removeItem(at: url)
        try? self.fileManager.removeItem(at: self.seenURL(event.id))
    }

    /// Drops a seen mark only when its event file is confirmed absent. An unreadable event file,
    /// or a losses or diagnostics directory that is missing or cannot be listed, keeps the mark.
    private func pruneOrphanSeenMarks() {
        let listed = self.confirmedEventFileNames()
        guard let listed else { return }
        switch self.childURLs(self.directoryURL("seen")) {
        case .missing, .unreadable:
            return
        case .urls(let urls):
            for url in urls where url.pathExtension == "json" && !listed.contains(url.lastPathComponent) {
                try? self.fileManager.removeItem(at: url)
            }
        }
    }

    /// Filenames present in the event directories. Nil when a losses directory is missing or
    /// either directory cannot be listed: absence is not confirmed, so seen marks stay.
    private func confirmedEventFileNames() -> Set<String>? {
        let losses = self.childURLs(self.directoryURL("losses"))
        let diagnostics = self.childURLs(self.directoryURL("diagnostics"))
        if case .unreadable = losses { return nil }
        if case .unreadable = diagnostics { return nil }
        if case .missing = losses { return nil }
        let lossNames: [String]
        switch losses {
        case .urls(let urls):
            lossNames = urls.map(\.lastPathComponent)
        case .missing, .unreadable:
            return nil
        }
        let diagnosticNames: [String]
        switch diagnostics {
        case .urls(let urls):
            diagnosticNames = urls.map(\.lastPathComponent)
        case .missing:
            diagnosticNames = []
        case .unreadable:
            return nil
        }
        return Set(lossNames + diagnosticNames)
    }

    // MARK: - Files

    private func writeRecord(_ record: JournalEventRecord, to url: URL) throws {
        try self.atomicWrite(try Self.makeEncoder().encode(record), to: url)
    }

    private func readRecord(at url: URL) throws -> JournalEventRecord {
        try Self.makeDecoder().decode(JournalEventRecord.self, from: Data(contentsOf: url))
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try self.fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp", isDirectory: false)
        do {
            try data.write(to: temp, options: [])
            if self.fileManager.fileExists(atPath: url.path) {
                _ = try self.fileManager.replaceItemAt(url, withItemAt: temp)
            } else {
                try self.fileManager.moveItem(at: temp, to: url)
            }
        } catch {
            try? self.fileManager.removeItem(at: temp)
            throw error
        }
    }

    private enum DirectoryRead {
        case ok
        case unreadable
    }

    private func readDirectory(_ url: URL, into records: inout [JournalEventRecord]) -> DirectoryRead {
        switch self.childURLs(url) {
        case .missing:
            return .ok
        case .unreadable:
            journalEventLog.error("journal events directory unreadable")
            return .unreadable
        case .urls(let urls):
            for file in urls where file.pathExtension == "json" {
                let data: Data
                do {
                    data = try Data(contentsOf: file)
                } catch {
                    journalEventLog.error("journal event unreadable name=\(file.lastPathComponent, privacy: .public)")
                    continue
                }
                do {
                    records.append(try Self.makeDecoder().decode(JournalEventRecord.self, from: data))
                } catch {
                    self.moveAside(file)
                }
            }
            return .ok
        }
    }

    private enum ChildList {
        case missing
        case unreadable
        case urls([URL])
    }

    private func childURLs(_ url: URL) -> ChildList {
        var isDirectory: ObjCBool = false
        guard self.fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .missing }
        guard isDirectory.boolValue else { return .unreadable }
        do {
            return .urls(try self.fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ))
        } catch {
            return .unreadable
        }
    }

    private func moveAside(_ url: URL) {
        let aside = self.rootURL.appendingPathComponent("aside", isDirectory: true)
        do {
            try self.fileManager.createDirectory(at: aside, withIntermediateDirectories: true)
            let destination = aside.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)", isDirectory: false)
            try self.fileManager.moveItem(at: url, to: destination)
            journalEventLog.error("journal event undecodable moved aside name=\(url.lastPathComponent, privacy: .public)")
        } catch {
            journalEventLog.error("journal event aside failed name=\(url.lastPathComponent, privacy: .public)")
        }
    }

    private func eventURL(kind: JournalEventKind, id: String) -> URL {
        let folder = kind == .loss ? "losses" : "diagnostics"
        return self.directoryURL(folder).appendingPathComponent("\(Self.fileName(for: id)).json", isDirectory: false)
    }

    private func seenURL(_ id: String) -> URL {
        self.directoryURL("seen").appendingPathComponent("\(Self.fileName(for: id)).json", isDirectory: false)
    }

    private func directoryURL(_ name: String) -> URL {
        self.rootURL.appendingPathComponent(name, isDirectory: true)
    }

    private var gateURL: URL { self.rootURL.appendingPathComponent("gate.json", isDirectory: false) }
    private var importURL: URL { self.rootURL.appendingPathComponent("import.json", isDirectory: false) }
    private var identityURL: URL { self.rootURL.appendingPathComponent("journal-identity.json", isDirectory: false) }

    static func fileName(for id: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_")
        if id.unicodeScalars.allSatisfy({ allowed.contains($0) }) { return id }
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }

    static func windowStart(now: Date, calendar: Calendar) -> Date? {
        calendar.date(byAdding: .day, value: -Self.noticeWindowDays, to: calendar.startOfDay(for: now))
    }

    private func diagnosticLine(_ record: JournalEventRecord, formatter: DateFormatter) -> String {
        var parts = [
            formatter.string(from: record.lastAt),
            record.kind.rawValue,
            record.source.rawValue,
            record.reason,
        ]
        if let segmentID = record.segmentID, !segmentID.isEmpty {
            parts.append(String(segmentID.prefix(8)))
        }
        if let captureAt = record.captureAt {
            parts.append(formatter.string(from: captureAt))
        }
        if let recordedAt = record.recordedAt {
            parts.append("recorded=\(formatter.string(from: recordedAt))")
        }
        if record.count > 1 {
            parts.append("count=\(record.count)")
            parts.append("first=\(formatter.string(from: record.foundAt))")
            parts.append("last=\(formatter.string(from: record.lastAt))")
        }
        if let duration = record.detail?.interruptionDuration {
            parts.append("interruption_duration=\(duration)")
        }
        if let successes = record.detail?.configurationRestartSuccesses {
            parts.append("configuration_restart_successes=\(successes)")
        }
        if let failures = record.detail?.configurationRestartFailures {
            parts.append("configuration_restart_failures=\(failures)")
        }
        parts.append(self.isSeen(id: record.id) ? "seen" : "unseen")
        return parts.joined(separator: " ")
    }

    private func importLine() -> String {
        switch self.readImportMarker() {
        case .notRun:
            return "Import: not run"
        case .complete(let imported, let skipped):
            return "Import: complete, \(imported) imported, \(skipped) skipped"
        case .failed(let reason):
            return "Import: failed, \(reason)"
        }
    }

    private static func localTimestamp(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func makeInternetDate() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
}

private nonisolated enum JournalLegacyDecodeError: Error {
    case undecodable
}

private nonisolated struct SeenMark: Codable {
    var id: String
}

private nonisolated struct GateMark: Codable {
    var openedAt: Date
    enum CodingKeys: String, CodingKey { case openedAt = "opened_at" }
}

private nonisolated struct IdentityMark: Codable {
    var identity: String
}

private nonisolated struct ImportMark: Codable {
    var status: String
    var imported: Int?
    var skipped: Int?
    var reason: String?
}

/// Deletes one existing part after recording the loss or diagnostic. A loss throw leaves the file.
nonisolated enum JournalPartRemoval {
    static func removeExisting(
        at url: URL,
        source: JournalEventSource,
        reason: String,
        segmentID: UUID,
        captureAt: Date?,
        now: Date,
        eventsRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        switch JournalBoxedFile.existence(at: url, rule: .screen, acceptedFrames: 0, fileManager: fileManager) {
        case .absent, .unreadableSize:
            return
        case .present(let existed):
            let store = JournalEventStore(rootURL: eventsRoot)
            if existed {
                try store.recordLoss(
                    segmentID: segmentID,
                    source: source,
                    reason: reason,
                    captureAt: captureAt,
                    now: now
                )
            } else {
                do {
                    try store.recordDiagnostic(
                        segmentID: segmentID,
                        source: source,
                        reason: reason,
                        captureAt: captureAt,
                        now: now
                    )
                } catch {
                    journalEventLog.error("journal diagnostic record failed reason=\(reason, privacy: .public)")
                }
            }
            try fileManager.removeItem(at: url)
        }
    }
}

/// A capture part the uploader must not throw away. The canonical names and every numbered
/// sibling (`screen.mp4.part.1`, `screen-audio.m4a.part.<id>`) match. A later pass records
/// each one, then deletes it. Until that record is written, the file stays.
nonisolated enum JournalKeptPart {
    static let reason = "screencast_part_kept"

    static func isKeptPartFileName(_ name: String) -> Bool {
        let screen = MobileSegmentScreencastPaths.screenPartFilename
        let audio = MobileSegmentScreencastPaths.screenAudioPartFilename
        return name == screen || name.hasPrefix(screen + ".")
            || name == audio || name.hasPrefix(audio + ".")
    }

    static func source(forFileName name: String) -> JournalEventSource {
        let audio = MobileSegmentScreencastPaths.screenAudioPartFilename
        if name == audio || name.hasPrefix(audio + ".") {
            return .screenAudio
        }
        return .screencast
    }

    /// Files in `directory` the uploader has to classify. Nil when the directory cannot be listed,
    /// which is not a signal that it is safe to delete.
    static func urls(in directory: URL, fileManager: FileManager = .default) -> [URL]? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else { return nil }
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: directory.path)
        } catch {
            return nil
        }
        return names.compactMap { name in
            guard self.isKeptPartFileName(name) else { return nil }
            let url = directory.appendingPathComponent(name, isDirectory: false)
            var childIsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &childIsDirectory),
                  !childIsDirectory.boolValue else {
                return nil
            }
            return url
        }
    }

    static func holdsUnrecordedPart(in directory: URL, fileManager: FileManager = .default) -> Bool {
        guard let urls = self.urls(in: directory, fileManager: fileManager) else { return true }
        return !urls.isEmpty
    }

    /// Records each kept part under the usual rule, then deletes it. A part whose size cannot be
    /// read, or whose loss cannot be written, stays. Returns false while any such part remains.
    @discardableResult
    static func classify(
        in directory: URL,
        segmentID: UUID,
        captureAt: Date?,
        now: Date,
        eventsRoot: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let urls = self.urls(in: directory, fileManager: fileManager) else { return false }
        for url in urls {
            do {
                try JournalPartRemoval.removeExisting(
                    at: url,
                    source: self.source(forFileName: url.lastPathComponent),
                    reason: Self.reason,
                    segmentID: segmentID,
                    captureAt: captureAt,
                    now: now,
                    eventsRoot: eventsRoot,
                    fileManager: fileManager
                )
            } catch {
                journalEventLog.error("journal kept part stayed name=\(url.lastPathComponent, privacy: .public)")
            }
        }
        return !self.holdsUnrecordedPart(in: directory, fileManager: fileManager)
    }
}

/// Picks a URL a capture writer can create. A loss that cannot be recorded, or a part whose
/// size cannot be read, leaves the old part in place and returns a fresh sibling name.
nonisolated enum JournalPartClaim {
    static func urlForNewCapture(
        canonical url: URL,
        source: JournalEventSource,
        reason: String,
        segmentID: UUID,
        captureAt: Date?,
        now: Date,
        eventsRoot: URL,
        fileManager: FileManager = .default
    ) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }
        do {
            try JournalPartRemoval.removeExisting(
                at: url,
                source: source,
                reason: reason,
                segmentID: segmentID,
                captureAt: captureAt,
                now: now,
                eventsRoot: eventsRoot,
                fileManager: fileManager
            )
        } catch {
            journalEventLog.error("journal part claim kept the previous file reason=\(reason, privacy: .public)")
        }
        guard fileManager.fileExists(atPath: url.path) else { return url }
        return self.freshURL(beside: url, fileManager: fileManager)
    }

    private static func freshURL(beside url: URL, fileManager: FileManager) -> URL {
        let directory = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        for index in 1...64 {
            let candidate = directory.appendingPathComponent("\(name).\(index)", isDirectory: false)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directory.appendingPathComponent("\(name).\(UUID().uuidString)", isDirectory: false)
    }
}

/// What to do with an existing final when a finished part replaces it.
nonisolated struct JournalFinalReplacement: Sendable {
    var segmentID: UUID
    var source: JournalEventSource
    var captureAt: Date?
    var now: Date
    var eventsRoot: URL

    static let reason = "screencast_final_replaced"

    enum Decision: Sendable {
        case replace
        case keepBoth
    }

    func decision(partURL: URL, finalURL: URL, fileManager: FileManager) -> Decision {
        switch JournalBoxedFile.existence(at: finalURL, rule: .screen, acceptedFrames: 0, fileManager: fileManager) {
        case .absent:
            return .replace
        case .unreadableSize:
            return .keepBoth
        case .present(let existed):
            if existed, !Self.sameBytes(partURL, finalURL, fileManager: fileManager) {
                let store = JournalEventStore(rootURL: self.eventsRoot)
                do {
                    try store.recordLoss(
                        segmentID: self.segmentID,
                        source: self.source,
                        reason: Self.reason,
                        captureAt: self.captureAt,
                        now: self.now
                    )
                } catch {
                    journalEventLog.error("journal loss record failed reason=\(Self.reason, privacy: .public)")
                    return .keepBoth
                }
            } else if !existed {
                do {
                    try JournalEventStore(rootURL: self.eventsRoot).recordDiagnostic(
                        segmentID: self.segmentID,
                        source: self.source,
                        reason: Self.reason,
                        captureAt: self.captureAt,
                        now: self.now
                    )
                } catch {
                    journalEventLog.error("journal diagnostic record failed reason=\(Self.reason, privacy: .public)")
                }
            }
            return .replace
        }
    }

    private static func sameBytes(_ partURL: URL, _ finalURL: URL, fileManager: FileManager) -> Bool {
        guard let leftSize = (try? fileManager.attributesOfItem(atPath: partURL.path)[.size] as? NSNumber)?.int64Value,
              let rightSize = (try? fileManager.attributesOfItem(atPath: finalURL.path)[.size] as? NSNumber)?.int64Value,
              leftSize == rightSize,
              let left = try? Data(contentsOf: partURL),
              let right = try? Data(contentsOf: finalURL) else {
            return false
        }
        return left == right
    }
}
