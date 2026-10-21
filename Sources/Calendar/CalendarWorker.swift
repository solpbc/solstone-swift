// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

nonisolated private let calendarWorkerLog = Logger(subsystem: "app.solstone.swift", category: "calendar")

/// What a routine check found: the settings it leaves, the record entries it writes and the
/// files it queues.
nonisolated struct CalendarCheckOutcome: Sendable {
    let document: CalendarSourceDocument
    let upserts: [String: CalendarSentEntry]
    let files: [CalendarPendingFile]
    let noteCount: Int
}

/// One step of a confirmed import.
nonisolated struct CalendarImportBatch: Sendable {
    let files: [CalendarPendingFile]
    let upserts: [String: CalendarSentEntry]
    let recent: [CalendarRecentNote]
    let cursor: Int
    let finished: Bool
}

/// Does the calendar source's heavy work away from the main actor: every read, building every
/// note and file, counting and freezing imports, and reading and writing the frozen sets. It
/// owns its reader, and with it its own event store. The engine on the main actor keeps only
/// what the screens show and the step it commits.
actor CalendarWorker {
    nonisolated struct Settings: Sendable {
        var pageYears: Int?
        var removalConfirmationSeconds: Int64
        var lookBackDays: Int
    }

    private let reader: any CalendarEventReading
    private let importsURL: URL
    private let settings: Settings
    private var frozenCache: [String: CalendarFrozenImport] = [:]

    init(reader: any CalendarEventReading, importsURL: URL, settings: Settings) {
        self.reader = reader
        self.importsURL = importsURL
        self.settings = settings
    }

    // MARK: setup

    /// Reads the span across the followed calendars, freezes what the import will send and
    /// returns the settings with the counted import in them. Nothing is sent.
    func countSetup(
        document input: CalendarSourceDocument,
        span: CalendarSpanChoice,
        calendarIDs: Set<String>?,
        now: Date,
        timeZone: TimeZone
    ) throws -> CalendarSourceDocument {
        let noticed = CalendarWire.wholeSeconds(now)
        var document = input
        document.imports.removeAll { $0.kind == .setup }
        let spanStart = span.start(now: now, timeZone: timeZone)
        document.span = span
        document.spanStart = CalendarWire.wholeSeconds(spanStart)
        document.setupAt = noticed
        let earlier = Dictionary(document.calendars.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        document.calendars = self.reader.calendars().map { info in
            CalendarFollowRecord(
                key: earlier[info.identifier]?.key ?? UUID().uuidString,
                identifier: info.identifier,
                accountName: info.accountName,
                title: info.title,
                isBirthdays: info.isBirthdays,
                followed: calendarIDs.map { $0.contains(info.identifier) } ?? earlier[info.identifier]?.followed ?? true,
                present: true
            )
        }
        let events = self.read(
            document.calendars.filter(\.followed),
            from: spanStart,
            to: Self.readEnd(now: now, timeZone: timeZone),
            birthdayFloor: Self.birthdayFloor(document, timeZone: timeZone)
        )
        let sightings = self.gather(events, calendars: document.calendars, timeZone: timeZone)
        var lines: [CalendarFrozenLine] = []
        var skips: [String: CalendarSentEntry] = [:]
        for key in sightings.keys.sorted(by: CalendarWire.precedes) {
            let sighting = sightings[key]!
            guard let content = self.content(of: sighting.winner, identity: sighting.identity, timeZone: timeZone) else {
                continue
            }
            let changedAt = CalendarSourceEngine.changedAt(
                lastModified: sighting.winner.event.lastModified,
                created: sighting.winner.event.created,
                previous: nil,
                now: now,
                lastNoticed: document.lastNoticed
            )
            let line = CalendarNoteLine(change: .added, changedAt: CalendarWireInstant(seconds: changedAt, timeZone: timeZone), content: content)
            var entry = CalendarSentEntry(identity: sighting.identity)
            entry.holders = sighting.holderKeys
            if let problem = CalendarNoteValidator.problem(with: line) {
                calendarWorkerLog.error("calendar note skipped: \(String(describing: problem), privacy: .public)")
                entry.skipped = content.fingerprint
                skips[key] = entry
                continue
            }
            Self.recordSent(&entry, line: line, winner: sighting.winner)
            lines.append(Self.frozenLine(line, entry: entry, baseline: nil, kind: .added))
        }
        let frozen = Self.freeze(lines, sightings: [:], skips: skips)
        let id = UUID().uuidString
        try self.writeFrozen(frozen, id: id)
        document.imports.append(CalendarImportRecord(
            id: id,
            kind: .setup,
            confirmed: false,
            count: lines.count,
            fileCount: frozen.files.count,
            cursor: 0,
            frozenAt: noticed,
            selection: document.calendars.filter { $0.followed && $0.present }.map(\.identifier).sorted()
        ))
        calendarWorkerLog.notice("calendar setup counted notes=\(lines.count, privacy: .public)")
        return document
    }

    /// The versions the setup count found failing the contract, recorded once it is confirmed.
    func skips(importID: String) -> [String: CalendarSentEntry] {
        self.frozen(id: importID)?.skips ?? [:]
    }

    // MARK: a calendar switched on after setup

    /// Counts a calendar switched on after setup over the setup span. Identities the record
    /// lacks go out as `added`, identities whose fingerprint changed as `changed`, and the rest
    /// send nothing. `nil` when there is nothing to count.
    func countCalendar(
        document input: CalendarSourceDocument,
        key: String,
        record: [String: CalendarSentEntry],
        now: Date,
        timeZone: TimeZone
    ) throws -> CalendarSourceDocument? {
        guard let spanStartSeconds = input.spanStart,
              let calendar = input.calendars.first(where: { $0.key == key && $0.present && $0.followed })
        else {
            return nil
        }
        let noticed = CalendarWire.wholeSeconds(now)
        var document = input
        let events = self.read(
            [calendar],
            from: Date(timeIntervalSince1970: TimeInterval(spanStartSeconds)),
            to: Self.readEnd(now: now, timeZone: timeZone),
            birthdayFloor: Self.birthdayFloor(document, timeZone: timeZone)
        )
        let sightings = self.gather(events, calendars: document.calendars, timeZone: timeZone)
        let liveKeys = Set(document.calendars.filter(\.present).map(\.key))
        let importing = Self.importingKeys(document)
        var lines: [CalendarFrozenLine] = []
        var seenOnly: [String: [String]] = [:]
        var skips: [String: CalendarSentEntry] = [:]
        for identityKey in sightings.keys.sorted(by: CalendarWire.precedes) {
            let sighting = sightings[identityKey]!
            let old = record[identityKey]
            // Another followed calendar's copy wins; this calendar only holds it too.
            if let old, old.wasSent, !old.removed, let winnerKey = old.winner, winnerKey != key,
               let winner = document.calendars.first(where: { $0.key == winnerKey }),
               winner.present, winner.followed, !importing.contains(winnerKey),
               CalendarSourceEngine.calendarPrecedes(winner, calendar)
            {
                seenOnly[identityKey] = [key]
                continue
            }
            guard let content = self.content(of: sighting.winner, identity: sighting.identity, timeZone: timeZone) else {
                continue
            }
            let fingerprint = content.fingerprint
            let change: CalendarNoteChange?
            if old?.skipped == fingerprint {
                change = nil
            } else if let old, old.wasSent, !old.removed {
                change = old.fingerprint == fingerprint ? nil : .changed
            } else {
                change = .added
            }
            guard let change else {
                seenOnly[identityKey] = [key]
                continue
            }
            let changedAt = CalendarSourceEngine.changedAt(
                lastModified: sighting.winner.event.lastModified,
                created: sighting.winner.event.created,
                previous: old?.changedAt,
                now: now,
                lastNoticed: document.lastNoticed
            )
            let line = CalendarNoteLine(change: change, changedAt: CalendarWireInstant(seconds: changedAt, timeZone: timeZone), content: content)
            var entry = old ?? CalendarSentEntry(identity: sighting.identity)
            entry.holders = Self.holders(old?.holders ?? [], adding: [key], liveKeys: liveKeys)
            if let problem = CalendarNoteValidator.problem(with: line) {
                calendarWorkerLog.error("calendar note skipped: \(String(describing: problem), privacy: .public)")
                entry.skipped = fingerprint
                skips[identityKey] = entry
                continue
            }
            let kind: CalendarRecentKind = change == .added ? .added : Self.changeKind(old: old, content: content)
            Self.recordSent(&entry, line: line, winner: sighting.winner)
            lines.append(Self.frozenLine(line, entry: entry, baseline: old?.changedAt, kind: kind))
        }
        let frozen = Self.freeze(lines, sightings: seenOnly, skips: skips)
        let id = UUID().uuidString
        try self.writeFrozen(frozen, id: id)
        document.imports.removeAll { $0.kind == .calendar(key: key) && !$0.confirmed }
        document.imports.append(CalendarImportRecord(
            id: id,
            kind: .calendar(key: key),
            confirmed: false,
            count: lines.count,
            fileCount: frozen.files.count,
            cursor: 0,
            frozenAt: noticed
        ))
        return document
    }

    /// What confirming a calendar's import writes to the record: its skipped versions, and the
    /// calendar as a holder of every identity it holds, whether or not a note for it has gone
    /// yet, so a deletion from another calendar is not taken for a removal. A sighting clears a
    /// first miss, as a routine sighting does.
    func confirmUpserts(
        importID: String,
        calendarKey: String,
        record: [String: CalendarSentEntry],
        liveKeys: Set<String>
    ) -> [String: CalendarSentEntry] {
        let frozen = self.frozen(id: importID)
        var upserts = frozen?.skips ?? [:]
        var sightings = frozen?.sightings ?? [:]
        for file in frozen?.files ?? [] {
            for line in file.lines {
                sightings[line.line.identity.key, default: []].append(calendarKey)
            }
        }
        for (identityKey, keys) in sightings {
            guard let current = upserts[identityKey] ?? record[identityKey] else { continue }
            var entry = current
            entry.holders = Self.holders(entry.holders, adding: keys, liveKeys: liveKeys)
            entry.firstMissingAt = nil
            if entry != current {
                upserts[identityKey] = entry
            }
        }
        return upserts
    }

    // MARK: imports

    /// The next files of a confirmed import, at most `room` of them. `nil` when its frozen set
    /// is gone.
    func importBatch(
        _ importRecord: CalendarImportRecord,
        record: [String: CalendarSentEntry],
        followedKeys: Set<String>,
        room: Int,
        timeZone: TimeZone
    ) -> CalendarImportBatch? {
        guard let frozen = self.frozen(id: importRecord.id) else { return nil }
        var cursor = importRecord.cursor
        var files: [CalendarPendingFile] = []
        var upserts: [String: CalendarSentEntry] = [:]
        var recent: [CalendarRecentNote] = []
        while files.count < room, cursor < frozen.files.count {
            var kept: [CalendarFiledLine] = []
            for frozenLine in frozen.files[cursor].lines {
                let key = frozenLine.line.identity.key
                let current = upserts[key] ?? record[key]
                // The record moved on since the freeze: a newer version was already sent.
                guard current?.changedAt == frozenLine.baseline else { continue }
                // Its calendars were switched off since the count.
                guard frozenLine.entry.holders.contains(where: followedKeys.contains) else { continue }
                var entry = frozenLine.entry
                if let current {
                    entry.holders = Array(Set(current.holders).union(entry.holders)).sorted()
                }
                upserts[key] = entry
                kept.append(frozenLine.line)
                recent.append(frozenLine.recent)
            }
            cursor += 1
            if !kept.isEmpty {
                files.append(CalendarPendingFile(file: CalendarNoteFiles.file(kept), timeZoneIdentifier: timeZone.identifier))
            }
        }
        return CalendarImportBatch(
            files: files,
            upserts: upserts,
            recent: recent,
            cursor: cursor,
            finished: cursor >= frozen.files.count
        )
    }

    // MARK: routine checks

    /// One routine check, from the back edge to one year ahead. Edits to events that ended
    /// before the back edge are not followed.
    func routineCheck(
        document input: CalendarSourceDocument,
        record: [String: CalendarSentEntry],
        now: Date,
        timeZone: TimeZone
    ) -> CalendarCheckOutcome? {
        guard let spanStartSeconds = input.spanStart else { return nil }
        let noticed = CalendarWire.wholeSeconds(now)
        var document = input
        self.reconcileCalendars(&document)
        let importing = Self.importingKeys(document)
        let readSet = document.calendars.filter { $0.followed && $0.present && !importing.contains($0.key) }
        let readKeys = Set(readSet.map(\.key))
        let liveKeys = Set(document.calendars.filter(\.present).map(\.key))

        let spanStart = Date(timeIntervalSince1970: TimeInterval(spanStartSeconds))
        var backEdge = CalendarWire.adding(days: -self.settings.lookBackDays, to: now, in: timeZone)
        if let last = document.lastCompletedCheck {
            backEdge = min(backEdge, Date(timeIntervalSince1970: TimeInterval(last - 86_400)))
        }
        backEdge = max(backEdge, spanStart)
        let end = Self.readEnd(now: now, timeZone: timeZone)
        let events = self.read(readSet, from: backEdge, to: end, birthdayFloor: Self.birthdayFloor(document, timeZone: timeZone))
        let sightings = self.gather(events, calendars: document.calendars, timeZone: timeZone)

        var upserts: [String: CalendarSentEntry] = [:]
        var filed: [CalendarFiledLine] = []
        var recent: [CalendarRecentNote] = []
        for identityKey in sightings.keys.sorted(by: CalendarWire.precedes) {
            let sighting = sightings[identityKey]!
            let old = record[identityKey]
            guard let content = self.content(of: sighting.winner, identity: sighting.identity, timeZone: timeZone) else {
                continue
            }
            let fingerprint = content.fingerprint
            var entry = old ?? CalendarSentEntry(identity: sighting.identity)
            entry.holders = Self.holders(old?.holders ?? [], seen: sighting.holderKeys, readKeys: readKeys, liveKeys: liveKeys)
            entry.firstMissingAt = nil
            // The last winner was read: a new calendar name is a rename or a real move between
            // followed calendars. Not read (switched off, coming in, unreadable): the name alone
            // is never a change.
            let lastWinnerRead = old?.winner.map(readKeys.contains) ?? false
            let renamed = lastWinnerRead && old?.calendar != content.calendar
            let change: CalendarNoteChange?
            if old?.skipped == fingerprint, !renamed {
                change = nil
            } else if let old, old.wasSent, !old.removed {
                change = old.fingerprint == fingerprint && !renamed ? nil : .changed
            } else {
                change = .added
            }
            guard let change else {
                // A last winner that was not read hands over to this read's winner, so an edit
                // is never held back waiting on a calendar that is off or still coming in. The
                // calendar name last sent stands.
                if let old, old.wasSent, let winner = old.winner, !readKeys.contains(winner) {
                    entry.winner = sighting.winner.calendar.key
                }
                if entry != old {
                    upserts[identityKey] = entry
                }
                continue
            }
            let changedAt = CalendarSourceEngine.changedAt(
                lastModified: sighting.winner.event.lastModified,
                created: sighting.winner.event.created,
                previous: old?.changedAt,
                now: now,
                lastNoticed: document.lastNoticed
            )
            let line = CalendarNoteLine(change: change, changedAt: CalendarWireInstant(seconds: changedAt, timeZone: timeZone), content: content)
            if let problem = CalendarNoteValidator.problem(with: line) {
                calendarWorkerLog.error("calendar note skipped: \(String(describing: problem), privacy: .public)")
                entry.skipped = fingerprint
                upserts[identityKey] = entry
                continue
            }
            let kind: CalendarRecentKind = change == .added ? .added : Self.changeKind(old: old, content: content)
            Self.recordSent(&entry, line: line, winner: sighting.winner)
            upserts[identityKey] = entry
            if let json = line.json, let window = line.changedAt.window {
                filed.append(CalendarFiledLine(identity: sighting.identity, json: json, window: window))
                recent.append(CalendarRecentNote(kind: kind, title: content.title, changedAt: changedAt))
            }
        }

        // An identity is removed only when a read covering its last start misses it, every
        // calendar that last held it is followed and readable, and an earlier check at least
        // `removalConfirmationSeconds` before missed it too.
        let readFrom = CalendarWire.wholeSeconds(backEdge)
        let readTo = CalendarWire.wholeSeconds(end)
        for (identityKey, old) in record where sightings[identityKey] == nil && old.wasSent && !old.removed {
            guard let startAt = old.startAt, startAt >= readFrom, startAt < readTo,
                  !old.holders.isEmpty, old.holders.allSatisfy(readKeys.contains)
            else {
                continue
            }
            guard let firstMissing = old.firstMissingAt else {
                var entry = old
                entry.firstMissingAt = noticed
                upserts[identityKey] = entry
                continue
            }
            guard noticed - firstMissing >= self.settings.removalConfirmationSeconds else { continue }
            let changedAt = CalendarSourceEngine.changedAt(lastModified: nil, created: nil, previous: old.changedAt, now: now, lastNoticed: document.lastNoticed)
            let line = CalendarNoteLine(
                change: .removed,
                changedAt: CalendarWireInstant(seconds: changedAt, timeZone: timeZone),
                content: .removed(identity: old.identity, title: old.title, calendar: old.calendar)
            )
            guard CalendarNoteValidator.problem(with: line) == nil, let json = line.json, let window = line.changedAt.window else {
                continue
            }
            var entry = old
            entry.removed = true
            entry.changedAt = changedAt
            entry.firstMissingAt = nil
            upserts[identityKey] = entry
            filed.append(CalendarFiledLine(identity: old.identity, json: json, window: window))
            recent.append(CalendarRecentNote(kind: .removed, title: old.title, changedAt: changedAt))
        }

        document.lastCompletedCheck = noticed
        document.lastNoticed = max(document.lastNoticed ?? noticed, noticed)
        document.noteRecent(recent)
        let files = CalendarNoteFiles.files(from: filed).map {
            CalendarPendingFile(file: $0, timeZoneIdentifier: timeZone.identifier)
        }
        return CalendarCheckOutcome(document: document, upserts: upserts, files: files, noteCount: filed.count)
    }

    // MARK: frozen sets

    func removeFrozen(id: String) {
        self.frozenCache.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: self.frozenURL(id: id))
    }

    /// Frozen sets no import points to any more.
    func removeFrozen(except referenced: Set<String>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: self.importsURL.path) else { return }
        for name in names where name.hasSuffix(".json") {
            let id = String(name.dropLast(5))
            if !referenced.contains(id) {
                self.removeFrozen(id: id)
            }
        }
    }

    private func frozen(id: String) -> CalendarFrozenImport? {
        if let cached = self.frozenCache[id] { return cached }
        let url = self.frozenURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let frozen = try JSONDecoder().decode(CalendarFrozenImport.self, from: Data(contentsOf: url))
            self.frozenCache[id] = frozen
            return frozen
        } catch {
            calendarWorkerLog.error("calendar import set unreadable: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
    }

    private func writeFrozen(_ frozen: CalendarFrozenImport, id: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(frozen)
        try FileManager.default.createDirectory(at: self.importsURL, withIntermediateDirectories: true)
        try data.write(to: self.frozenURL(id: id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        self.frozenCache[id] = frozen
    }

    private func frozenURL(id: String) -> URL {
        self.importsURL.appendingPathComponent("\(id).json")
    }

    // MARK: reading

    /// The end of every read: one year ahead of today.
    nonisolated static func readEnd(now: Date, timeZone: TimeZone) -> Date {
        CalendarWire.adding(years: 1, to: CalendarWire.startOfDay(now, in: timeZone), in: timeZone)
    }

    /// Birthdays start at the later of the span's start and the start of the setup year. iOS
    /// expands a contact's birthday back to 1604, and those past copies add nothing.
    nonisolated static func birthdayFloor(_ document: CalendarSourceDocument, timeZone: TimeZone) -> Date {
        let spanStart = Date(timeIntervalSince1970: TimeInterval(document.spanStart ?? 0))
        let setupYear = CalendarWire.startOfYear(
            Date(timeIntervalSince1970: TimeInterval(document.setupAt ?? 0)),
            in: timeZone
        )
        return max(spanStart, setupYear)
    }

    /// Reads events that start in `from..<to`, in consecutive pages of at most `pageYears`. An
    /// event straddling a page edge is kept only in the page it starts in.
    func read(
        _ calendars: [CalendarFollowRecord],
        from: Date,
        to: Date,
        birthdayFloor: Date
    ) -> [CalendarEventRecord] {
        guard !calendars.isEmpty, from < to else { return [] }
        let identifiers = calendars.map(\.identifier)
        let birthdays = Set(calendars.filter(\.isBirthdays).map(\.identifier))
        var events: [CalendarEventRecord] = []
        var pageStart = from
        while pageStart < to {
            let pageEnd = self.settings.pageYears.map {
                min(to, CalendarWire.adding(years: $0, to: pageStart, in: CalendarWire.utc))
            } ?? to
            for event in self.reader.events(from: pageStart, to: pageEnd, calendarIDs: identifiers) {
                guard let start = event.start else {
                    calendarWorkerLog.notice("calendar event without a start skipped")
                    continue
                }
                guard start >= pageStart, start < pageEnd else { continue }
                if birthdays.contains(event.calendarID), start < birthdayFloor { continue }
                events.append(event)
            }
            pageStart = pageEnd
        }
        return events
    }

    private struct Copy {
        let calendar: CalendarFollowRecord
        let event: CalendarEventRecord
    }

    private struct Sighting {
        let identity: CalendarIdentity
        var copies: [Copy]

        /// The copy from the calendar first in order of (name, identifier).
        var winner: Copy {
            self.copies.min { CalendarSourceEngine.calendarPrecedes($0.calendar, $1.calendar) }!
        }

        var holderKeys: [String] {
            Array(Set(self.copies.map(\.calendar.key))).sorted()
        }
    }

    private func gather(_ events: [CalendarEventRecord], calendars: [CalendarFollowRecord], timeZone: TimeZone) -> [String: Sighting] {
        let byIdentifier = Dictionary(
            calendars.filter(\.present).map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var sightings: [String: Sighting] = [:]
        for event in events {
            guard let calendar = byIdentifier[event.calendarID],
                  let identity = CalendarNoteBuilder.identity(of: event, deviceTimeZone: timeZone)
            else {
                continue
            }
            sightings[identity.key, default: Sighting(identity: identity, copies: [])].copies.append(Copy(calendar: calendar, event: event))
        }
        return sightings
    }

    private func content(of copy: Copy, identity: CalendarIdentity, timeZone: TimeZone) -> CalendarNoteContent? {
        var seriesRule: CalendarRepeatRule?
        if CalendarNoteBuilder.repeats(copy.event), copy.event.repeatRules.isEmpty {
            seriesRule = self.reader.seriesRule(seriesID: identity.event)
        }
        guard let content = CalendarNoteBuilder.content(
            of: copy.event,
            identity: identity,
            calendarName: copy.calendar.title,
            deviceTimeZone: timeZone,
            seriesRule: seriesRule
        ) else {
            calendarWorkerLog.notice("calendar event without a start skipped")
            return nil
        }
        return content
    }

    /// Recognises calendars by identifier and, when an account resync changes identifiers, by
    /// account and name, so a resync never stops following a calendar or resends its events.
    /// When account and name match more than one calendar, the calendar counts as new, and if
    /// any of the matching calendars was off, it comes back off. A calendar first seen after
    /// setup is followed, with no backfill.
    private func reconcileCalendars(_ document: inout CalendarSourceDocument) {
        let live = self.reader.calendars()
        for index in document.calendars.indices {
            document.calendars[index].present = false
        }
        var unmatched: [CalendarInfo] = []
        for info in live {
            if let index = document.calendars.firstIndex(where: { $0.identifier == info.identifier }) {
                document.calendars[index].present = true
                document.calendars[index].title = info.title
                document.calendars[index].accountName = info.accountName
                document.calendars[index].isBirthdays = info.isBirthdays
            } else {
                unmatched.append(info)
            }
        }
        for info in unmatched {
            let sameName = unmatched.filter { $0.accountName == info.accountName && $0.title == info.title }
            let candidates = document.calendars.indices.filter { index in
                let known = document.calendars[index]
                return !known.present && known.accountName == info.accountName && known.title == info.title
            }
            if candidates.count == 1, sameName.count == 1 {
                let index = candidates[0]
                document.calendars[index].identifier = info.identifier
                document.calendars[index].present = true
                document.calendars[index].isBirthdays = info.isBirthdays
                continue
            }
            let anyOff = candidates.contains { !document.calendars[$0].followed }
            document.calendars.append(CalendarFollowRecord(
                key: UUID().uuidString,
                identifier: info.identifier,
                accountName: info.accountName,
                title: info.title,
                isBirthdays: info.isBirthdays,
                followed: !anyOff,
                present: true
            ))
        }
    }

    // MARK: building

    private static func frozenLine(_ line: CalendarNoteLine, entry: CalendarSentEntry, baseline: Int64?, kind: CalendarRecentKind) -> CalendarFrozenLine {
        CalendarFrozenLine(
            line: CalendarFiledLine(identity: line.content.identity, json: line.json ?? "", window: line.changedAt.window!),
            change: line.change,
            entry: entry,
            baseline: baseline,
            recent: CalendarRecentNote(kind: kind, title: line.content.title, changedAt: line.changedAt.seconds)
        )
    }

    private static func freeze(
        _ lines: [CalendarFrozenLine],
        sightings: [String: [String]],
        skips: [String: CalendarSentEntry]
    ) -> CalendarFrozenImport {
        let byKey = Dictionary(lines.map { ($0.line.identity.key, $0) }, uniquingKeysWith: { first, _ in first })
        let files = CalendarNoteFiles.files(from: lines.map(\.line)).map { file in
            CalendarFrozenFile(lines: file.identityKeys.compactMap { byKey[$0] })
        }
        return CalendarFrozenImport(files: files, sightings: sightings, skips: skips)
    }

    private static func recordSent(_ entry: inout CalendarSentEntry, line: CalendarNoteLine, winner: Copy) {
        entry.fingerprint = line.content.fingerprint
        entry.placementFree = line.content.placementFreeFingerprint
        entry.changedAt = line.changedAt.seconds
        entry.start = line.content.start
        entry.end = line.content.end
        entry.startAt = winner.event.start.map(CalendarWire.wholeSeconds)
        entry.title = line.content.title
        entry.calendar = line.content.calendar
        entry.winner = winner.calendar.key
        entry.removed = false
        entry.firstMissingAt = nil
        entry.skipped = nil
    }

    /// Moved when only `start` and `end` changed; changed otherwise.
    private static func changeKind(old: CalendarSentEntry?, content: CalendarNoteContent) -> CalendarRecentKind {
        guard let old, let placementFree = old.placementFree else { return .changed }
        return placementFree == content.placementFreeFingerprint ? .moved : .changed
    }

    /// Calendars that were read are replaced by what the read saw; calendars not read keep
    /// their place; calendars no longer on the device go once the identity is seen elsewhere.
    private static func holders(_ old: [String], seen: [String], readKeys: Set<String>, liveKeys: Set<String>) -> [String] {
        let kept = old.filter { liveKeys.contains($0) && !readKeys.contains($0) }
        return Array(Set(kept).union(seen)).sorted()
    }

    private static func holders(_ old: [String], adding keys: [String], liveKeys: Set<String>) -> [String] {
        Array(Set(old.filter(liveKeys.contains)).union(keys)).sorted()
    }

    nonisolated static func importingKeys(_ document: CalendarSourceDocument) -> Set<String> {
        Set(document.imports.compactMap { record in
            if case .calendar(let key) = record.kind { return key }
            return nil
        })
    }
}
