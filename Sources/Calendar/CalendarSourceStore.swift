// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

nonisolated private let calendarStoreLog = Logger(subsystem: "app.solstone.swift", category: "calendar")

/// How far back the owner chose to bring their calendar in.
nonisolated enum CalendarSpanChoice: String, Codable, CaseIterable, Equatable, Sendable {
    case last30Days
    case last6Months
    case lastYear
    case everything
    case fromToday

    /// Where the span starts for a setup at `now`. "All of it" starts at 1900-01-01.
    func start(now: Date, timeZone: TimeZone) -> Date {
        let today = CalendarWire.startOfDay(now, in: timeZone)
        switch self {
        case .last30Days:
            return CalendarWire.adding(days: -30, to: today, in: timeZone)
        case .last6Months:
            return CalendarWire.adding(months: -6, to: today, in: timeZone)
        case .lastYear:
            return CalendarWire.adding(years: -1, to: today, in: timeZone)
        case .everything:
            return CalendarWire.gregorian(in: timeZone).date(from: DateComponents(year: 1900, month: 1, day: 1)) ?? today
        case .fromToday:
            return today
        }
    }
}

/// A calendar the source knows about. `key` is the source's own name for it and never
/// changes; `identifier` is what iOS calls it now, which an account resync can change.
nonisolated struct CalendarFollowRecord: Codable, Equatable, Sendable {
    let key: String
    var identifier: String
    var accountName: String
    var title: String
    var isBirthdays: Bool
    var followed: Bool
    /// Whether iOS listed it at the last look.
    var present: Bool
}

/// What the source last sent for one identity. Entries are never dropped.
nonisolated struct CalendarSentEntry: Codable, Equatable, Sendable {
    var event: String
    var occurrence: String?
    /// Fingerprint of the fields last sent; `nil` if nothing was ever sent.
    var fingerprint: String?
    /// The same without `start` and `end`, to tell a move from another change.
    var placementFree: String?
    /// The last `changed_at` sent, in whole seconds since the epoch.
    var changedAt: Int64?
    var start: String?
    var end: String?
    /// The last start, as an instant, to tell whether a read covers it.
    var startAt: Int64?
    var title: String?
    var calendar: String?
    /// Keys of the calendars that held it at the last look.
    var holders: [String]
    /// The key of the calendar whose copy was last sent.
    var winner: String?
    var removed: Bool
    /// When a read first found it missing; cleared whenever it is seen again.
    var firstMissingAt: Int64?
    /// A version that failed the contract and was not sent, so it is not tried again.
    var skipped: String?

    enum CodingKeys: String, CodingKey {
        case event = "e"
        case occurrence = "o"
        case fingerprint = "f"
        case placementFree = "p"
        case changedAt = "c"
        case start = "s"
        case end = "n"
        case startAt = "a"
        case title = "t"
        case calendar = "k"
        case holders = "h"
        case winner = "w"
        case removed = "r"
        case firstMissingAt = "m"
        case skipped = "x"
    }

    init(identity: CalendarIdentity) {
        self.event = identity.event
        self.occurrence = identity.occurrence
        self.fingerprint = nil
        self.placementFree = nil
        self.changedAt = nil
        self.start = nil
        self.end = nil
        self.startAt = nil
        self.title = nil
        self.calendar = nil
        self.holders = []
        self.winner = nil
        self.removed = false
        self.firstMissingAt = nil
        self.skipped = nil
    }

    var identity: CalendarIdentity {
        CalendarIdentity(event: self.event, occurrence: self.occurrence)
    }

    var wasSent: Bool {
        self.changedAt != nil
    }
}

nonisolated enum CalendarImportKind: Codable, Equatable, Sendable {
    /// The span the owner chose at setup, across the calendars followed then.
    case setup
    /// A calendar switched on after setup, over the setup span.
    case calendar(key: String)
}

/// A counted import. Its notes are frozen in the source's own store when counted, and go to
/// the journal a few files at a time once confirmed.
nonisolated struct CalendarImportRecord: Codable, Equatable, Sendable {
    let id: String
    let kind: CalendarImportKind
    var confirmed: Bool
    let count: Int
    let fileCount: Int
    /// The next frozen file to send.
    var cursor: Int
    /// When the import's read was made, in whole seconds.
    let frozenAt: Int64
    /// How many of its notes have gone into the transfer queue so far.
    var queuedNotes: Int? = nil

    /// Confirmed notes still in the source's own store, not yet in the transfer queue.
    var notesNotYetQueued: Int {
        self.confirmed ? max(0, self.count - (self.queuedNotes ?? 0)) : 0
    }

    /// Confirmed files still in the source's own store, not yet in the transfer queue.
    var filesNotYetQueued: Int {
        self.confirmed ? max(0, self.fileCount - self.cursor) : 0
    }

    var isFinished: Bool {
        self.confirmed && self.cursor >= self.fileCount
    }
}

nonisolated enum CalendarRecentKind: String, Codable, Equatable, Sendable {
    case added
    /// Only the date or time differed.
    case moved
    case changed
    case removed
}

nonisolated struct CalendarRecentNote: Codable, Equatable, Sendable {
    let kind: CalendarRecentKind
    let title: String?
    let changedAt: Int64
}

/// The source's settings and progress. Small, and written on every check.
nonisolated struct CalendarSourceDocument: Codable, Equatable, Sendable {
    static let schema = "solstone.calendar.source/1"
    static let recentLimit = 8

    var schema: String = Self.schema
    var span: CalendarSpanChoice?
    var spanStart: Int64?
    var setupAt: Int64?
    var everOn = false
    var paused = false
    var calendars: [CalendarFollowRecord] = []
    var lastCompletedCheck: Int64?
    /// The latest moment noticed so far. A clock that moves backward never breaks the order
    /// of one identity's notes.
    var lastNoticed: Int64?
    var imports: [CalendarImportRecord] = []
    var recent: [CalendarRecentNote] = []

    mutating func noteRecent(_ notes: [CalendarRecentNote]) {
        guard !notes.isEmpty else { return }
        self.recent = Array((notes.reversed() + self.recent).prefix(Self.recentLimit))
    }
}

/// One line of a frozen import, with the record entry it leaves behind once sent.
nonisolated struct CalendarFrozenLine: Codable, Equatable, Sendable {
    let line: CalendarFiledLine
    let change: CalendarNoteChange
    let entry: CalendarSentEntry
    /// The record's last `changed_at` for this identity when the import was frozen. If the
    /// record has moved on since, the line is older than what was sent and is dropped.
    let baseline: Int64?
    let recent: CalendarRecentNote
}

nonisolated struct CalendarFrozenFile: Codable, Equatable, Sendable {
    let lines: [CalendarFrozenLine]
}

nonisolated struct CalendarFrozenImport: Codable, Equatable, Sendable {
    let files: [CalendarFrozenFile]
    /// Identities the read saw and that need no note: the calendars now known to hold them.
    let sightings: [String: [String]]
    /// Versions that failed the contract, recorded as skipped when the import is confirmed.
    let skips: [String: CalendarSentEntry]
}

/// A file waiting to be queued, with what its transfer item is built from.
nonisolated struct CalendarPendingFile: Codable, Equatable, Sendable {
    let file: CalendarNoteFile
    let timeZoneIdentifier: String
}

/// One step of the source: the files it queues, the record entries it writes, and the
/// settings it leaves. Written before any of them, and replayed after a kill, so a step
/// leaves either nothing or all of it.
nonisolated struct CalendarPendingStep: Codable, Equatable, Sendable {
    let files: [CalendarPendingFile]
    let upserts: [String: CalendarSentEntry]
    let document: CalendarSourceDocument
}

nonisolated enum CalendarStoreError: Error {
    case notLoaded
}

nonisolated enum CalendarStepPoint: Equatable, Sendable {
    case afterStepWritten
    case afterRecordWritten
    case afterFileQueued(Int)
}

/// The source's own store: settings, the record of what was sent, frozen imports and the
/// step being written. Nothing here leaves the device except the files queued for the
/// journal.
///
/// The record is a base file plus an append-only journal of the entries each step wrote, folded
/// back into the base once the journal grows, so a long import does not rewrite the whole record
/// for every few files it queues.
@MainActor
final class CalendarSourceStore {
    let rootURL: URL
    private let fileManager: FileManager
    private(set) var document = CalendarSourceDocument()
    /// False while a file that exists cannot be read, for example before the device is first
    /// unlocked. Nothing is read from or written to the store until it loads.
    private(set) var isLoaded = false
    private var recordCache: [String: CalendarSentEntry] = [:]
    private var journalEntries = 0
    /// How many times the record was written. For tests.
    private(set) var recordWriteCount = 0
    /// Stops a step at a chosen point, as a kill would. For tests.
    var interruption: ((CalendarStepPoint) throws -> Void)?
    /// Writes a record line in place of the file handle. For tests of a failed write.
    var journalWrite: ((FileHandle, Data) throws -> Void)?

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.load()
    }

    static func defaultRootURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("Calendar", isDirectory: true)
    }

    private var documentURL: URL { self.rootURL.appendingPathComponent("source.json") }
    var recordURL: URL { self.rootURL.appendingPathComponent("record.json") }
    var recordJournalURL: URL { self.rootURL.appendingPathComponent("record-journal.jsonl") }
    private var pendingURL: URL { self.rootURL.appendingPathComponent("pending.json") }

    /// Reads the settings and the record. `false`, and nothing cached, while a file that exists
    /// cannot be read; a missing file is simply empty.
    @discardableResult
    func load() -> Bool {
        guard !self.isLoaded else { return true }
        switch Self.read(CalendarSourceDocument.self, at: self.documentURL, fileManager: self.fileManager) {
        case .unreadable:
            return false
        case .absent:
            return self.loadRecord(document: CalendarSourceDocument())
        case .found(let document):
            return self.loadRecord(document: document.schema == CalendarSourceDocument.schema ? document : CalendarSourceDocument())
        }
    }

    private func loadRecord(document: CalendarSourceDocument) -> Bool {
        var record: [String: CalendarSentEntry] = [:]
        switch Self.read([String: CalendarSentEntry].self, at: self.recordURL, fileManager: self.fileManager) {
        case .unreadable:
            return false
        case .found(let base):
            record = base
        case .absent:
            break
        }
        var entries = 0
        if self.fileManager.fileExists(atPath: self.recordJournalURL.path) {
            guard var data = try? Data(contentsOf: self.recordJournalURL) else { return false }
            // A kill mid-append leaves a line with no newline. Cut it off, so the step it
            // belonged to, replayed from the written step, starts a line of its own.
            if let last = data.last, last != 0x0A {
                let keep = (data.lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex) - data.startIndex
                guard let handle = try? FileHandle(forWritingTo: self.recordJournalURL) else { return false }
                defer { try? handle.close() }
                guard (try? handle.truncate(atOffset: UInt64(keep))) != nil else { return false }
                data = data.prefix(keep)
            }
            let decoder = JSONDecoder()
            for line in data.split(separator: 0x0A) {
                // Only a torn last append can fail to decode; its step is replayed from the
                // written step.
                guard let upserts = try? decoder.decode([String: CalendarSentEntry].self, from: Data(line)) else { continue }
                for (key, entry) in upserts {
                    record[key] = entry
                }
                entries += upserts.count
            }
        }
        self.document = document
        self.recordCache = record
        self.journalEntries = entries
        self.isLoaded = true
        return true
    }

    /// The record of every identity sent. Empty until the store loads.
    var record: [String: CalendarSentEntry] {
        self.recordCache
    }

    /// Saves the settings, logging a failure.
    func saveDocument(_ document: CalendarSourceDocument) {
        do {
            try self.writeDocument(document)
        } catch {
            calendarStoreLog.error("calendar settings write failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    func writeDocument(_ document: CalendarSourceDocument) throws {
        guard self.isLoaded else { throw CalendarStoreError.notLoaded }
        try self.encodeAndWrite(document, to: self.documentURL)
        self.document = document
    }

    /// Adds `upserts` to the record by appending them to the record's journal.
    func applyRecord(_ upserts: [String: CalendarSentEntry]) throws {
        guard !upserts.isEmpty else { return }
        guard self.isLoaded else { throw CalendarStoreError.notLoaded }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(upserts)
        line.append(0x0A)
        try self.fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        if !self.fileManager.fileExists(atPath: self.recordJournalURL.path) {
            guard self.fileManager.createFile(
                atPath: self.recordJournalURL.path,
                contents: nil,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: self.recordJournalURL)
        defer { try? handle.close() }
        let offset = try handle.seekToEnd()
        do {
            if let journalWrite = self.journalWrite {
                try journalWrite(handle, line)
            } else {
                try handle.write(contentsOf: line)
            }
        } catch {
            // Leave no part of a failed append behind for the next one to land on.
            try? handle.truncate(atOffset: offset)
            throw error
        }
        for (key, entry) in upserts {
            self.recordCache[key] = entry
        }
        self.journalEntries += upserts.count
        self.recordWriteCount += 1
        if self.journalEntries > max(2_000, self.recordCache.count) {
            try self.compactRecord()
        }
    }

    /// Folds the journal into the base file. A kill between the two leaves the journal to be
    /// applied again over the new base, which changes nothing.
    private func compactRecord() throws {
        try self.encodeAndWrite(self.recordCache, to: self.recordURL)
        try? self.fileManager.removeItem(at: self.recordJournalURL)
        self.journalEntries = 0
    }

    /// Replaces the whole record. For tests that start from a large record.
    func replaceRecord(_ record: [String: CalendarSentEntry]) throws {
        self.recordCache = record
        try self.compactRecord()
    }

    var pendingStep: CalendarPendingStep? {
        Self.read(CalendarPendingStep.self, at: self.pendingURL, fileManager: self.fileManager).value
    }

    func writePendingStep(_ step: CalendarPendingStep) throws {
        try self.encodeAndWrite(step, to: self.pendingURL)
    }

    func clearPendingStep() {
        try? self.fileManager.removeItem(at: self.pendingURL)
    }

    func interrupt(at point: CalendarStepPoint) throws {
        try self.interruption?(point)
    }

    private func encodeAndWrite<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try self.fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private enum ReadResult<T: Decodable> {
        case absent
        case found(T)
        case unreadable

        var value: T? {
            if case .found(let value) = self { return value }
            return nil
        }
    }

    private static func read<T: Decodable>(_ type: T.Type, at url: URL, fileManager: FileManager) -> ReadResult<T> {
        guard fileManager.fileExists(atPath: url.path) else { return .absent }
        do {
            return .found(try JSONDecoder().decode(type, from: Data(contentsOf: url)))
        } catch {
            calendarStoreLog.error("calendar store unreadable: \(String(describing: Swift.type(of: error)), privacy: .public)")
            return .unreadable
        }
    }
}
