// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

nonisolated private let calendarEngineLog = Logger(subsystem: "app.solstone.swift", category: "calendar")

nonisolated enum CalendarSetupStep: Equatable, Sendable {
    case notSetUp
    /// Reading the chosen span. No number is known yet.
    case counting
    /// Counted and frozen; nothing is sent until the owner confirms.
    case readyToConfirm(count: Int)
    /// Confirmed; the frozen notes are on their way into the transfer queue.
    case importing
    case on
}

/// A calendar switched on after setup brings its setup span in through its own count.
nonisolated enum CalendarImportStep: Equatable, Sendable {
    case counting
    case readyToConfirm(count: Int)
    case importing
}

nonisolated struct CalendarSourceCalendar: Equatable, Sendable, Identifiable {
    /// iOS's identifier for the calendar.
    let id: String
    let title: String
    let accountName: String
    let followed: Bool
    let importStep: CalendarImportStep?
}

/// What the source's screens show.
nonisolated struct CalendarSourceState: Equatable, Sendable {
    var setupStep: CalendarSetupStep
    var access: CalendarAccess
    var everOn: Bool
    var paused: Bool
    var lastCompletedCheck: Date?
    var followedCount: Int
    var calendarCount: Int
    /// Newest first.
    var recent: [CalendarRecentNote]
    var notesWaiting: Int
    var notesNeedingAttention: Int
    /// The paired journal was read and does not take calendar notes yet.
    var waitingForJournalUpdate: Bool
}

/// The calendar source. It reads the owner's calendars, keeps a record of what it sent, builds
/// calendar notes and files, and hands them to the transfer queue.
///
/// Nothing is read or sent until the owner sets the source up. iOS never wakes an app when a
/// calendar changes, so the source checks whenever the app runs: at launch, on coming to the
/// foreground, when iOS reports a change while the app runs, and when iOS grants background
/// refresh time. It records when it last completed a check.
///
/// A routine check reads from a back edge to one year ahead. The back edge is the earlier of 30
/// days ago and one day before the last completed check, and never earlier than the span's
/// start. Edits to events that ended before the back edge are not followed.
@MainActor
@Observable
final class CalendarSourceEngine {
    struct Settings {
        /// How many of the source's files may sit in the transfer queue before an import adds more.
        var importWindow = 3
        /// The longest single read. iOS cuts a read at its first four years; three keeps clear.
        /// `nil` reads a range in one go.
        var pageYears: Int? = 3
        /// How long an identity must stay missing before it is removed.
        var removalConfirmationSeconds: Int64 = 600
        var lookBackDays = 30
    }

    struct Dependencies {
        var now: @MainActor () -> Date = { Date() }
        var timeZone: @MainActor () -> TimeZone = { TimeZone.autoupdatingCurrent }
        /// Notes waiting and needing attention, and whether the journal needs an update first.
        var delivery: @MainActor () -> (waiting: Int, attention: Int, waitingForJournalUpdate: Bool) = { (0, 0, false) }
        /// Called after files are queued.
        var deliveryChanged: @MainActor () -> Void = {}
    }

    private(set) var access: CalendarAccess
    private(set) var document: CalendarSourceDocument
    private(set) var isCountingSetup = false
    private(set) var countingCalendarKeys: Set<String> = []

    @ObservationIgnored private let provider: any CalendarProviding
    @ObservationIgnored let store: CalendarSourceStore
    @ObservationIgnored private let delivery: any CalendarNoteDelivering
    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var operationCount = 0
    @ObservationIgnored private var checkQueued = false
    @ObservationIgnored private var pumpQueued = false
    @ObservationIgnored private var started = false
    /// Whether `document` has been taken from a loaded store.
    @ObservationIgnored private var storeSynced: Bool

    init(
        provider: any CalendarProviding,
        store: CalendarSourceStore,
        delivery: any CalendarNoteDelivering,
        settings: Settings = Settings(),
        dependencies: Dependencies = Dependencies()
    ) {
        self.provider = provider
        self.store = store
        self.delivery = delivery
        self.settings = settings
        self.dependencies = dependencies
        self.access = provider.access()
        self.document = store.document
        self.storeSynced = store.isLoaded
        provider.onChange = { [weak self] in
            self?.storeChanged()
        }
    }

    // MARK: what the screens read

    var state: CalendarSourceState {
        let delivery = self.dependencies.delivery()
        let present = self.document.calendars.filter(\.present)
        return CalendarSourceState(
            setupStep: self.setupStep,
            access: self.access,
            everOn: self.document.everOn,
            paused: self.document.paused,
            lastCompletedCheck: self.document.lastCompletedCheck.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            followedCount: present.filter(\.followed).count,
            calendarCount: present.count,
            recent: self.document.recent,
            notesWaiting: delivery.waiting,
            notesNeedingAttention: delivery.attention,
            waitingForJournalUpdate: delivery.waitingForJournalUpdate
        )
    }

    var setupStep: CalendarSetupStep {
        if self.isCountingSetup { return .counting }
        if let setup = self.document.imports.first(where: { $0.kind == .setup }) {
            return setup.confirmed ? .importing : .readyToConfirm(count: setup.count)
        }
        return self.document.everOn ? .on : .notSetUp
    }

    var calendars: [CalendarSourceCalendar] {
        self.document.calendars.filter(\.present)
            .sorted { Self.calendarPrecedes($0, $1) }
            .map { calendar in
                let importStep: CalendarImportStep?
                if self.countingCalendarKeys.contains(calendar.key) {
                    importStep = .counting
                } else if let record = self.document.imports.first(where: { $0.kind == .calendar(key: calendar.key) }) {
                    importStep = record.confirmed ? .importing : .readyToConfirm(count: record.count)
                } else {
                    importStep = nil
                }
                return CalendarSourceCalendar(
                    id: calendar.identifier,
                    title: calendar.title,
                    accountName: calendar.accountName,
                    followed: calendar.followed,
                    importStep: importStep
                )
            }
    }

    /// Set up and not paused: iOS background refresh is worth asking for.
    var wantsBackgroundRefresh: Bool {
        self.document.everOn && !self.document.paused
    }

    // MARK: what the screens do

    /// Asks iOS for full calendar access. Never asks for write-only access.
    @discardableResult
    func requestFullAccess() async -> CalendarAccess {
        self.access = await self.provider.requestFullAccess()
        return self.access
    }

    func refreshAccess() {
        self.access = self.provider.access()
    }

    /// Reads `span` across the chosen calendars (every calendar when `calendarIDs` is `nil`),
    /// counts what the import will send and freezes it. Nothing is sent until `confirm()`.
    func setUp(span: CalendarSpanChoice, calendarIDs: Set<String>? = nil) async {
        await self.perform { await self.countSetup(span: span, calendarIDs: calendarIDs) }
    }

    /// Sends the frozen set the owner was shown the count of. Returns once its first files are
    /// queued.
    func confirm() async {
        await self.perform { await self.confirmSetup() }
        self.requestPump()
        await self.waitUntilIdle()
    }

    func pause() {
        guard self.ensureStore(), !self.document.paused else { return }
        var document = self.document
        document.paused = true
        self.store.saveDocument(document)
        self.document = document
    }

    /// Runs one check covering everything since the last completed check.
    func resume() async {
        guard self.ensureStore(), self.document.paused else { return }
        var document = self.document
        document.paused = false
        self.store.saveDocument(document)
        self.document = document
        self.requestCheck()
        self.requestPump()
        await self.waitUntilIdle()
    }

    /// Switches one calendar on or off. Off stops its notes and sends nothing. On, after setup,
    /// counts the calendar's setup span; `confirmCalendar` sends it.
    func setCalendar(_ identifier: String, followed: Bool) async {
        await self.perform { await self.changeCalendar(identifier, followed: followed) }
    }

    func confirmCalendar(_ identifier: String) async {
        await self.perform { await self.confirmCalendarImport(identifier) }
        self.requestPump()
        await self.waitUntilIdle()
    }

    // MARK: when the source checks

    /// At launch: finishes a step a kill interrupted, then carries on an import and checks.
    /// Returns once the interrupted step is finished, so it is queued before anything is sent.
    func launch() async {
        self.started = true
        self.access = self.provider.access()
        await self.perform { _ = await self.finishPendingStep() }
        self.requestPump()
        self.requestCheck()
    }

    func foreground() {
        guard self.started else { return }
        self.access = self.provider.access()
        self.requestPump()
        self.requestCheck()
    }

    func storeChanged() {
        guard self.started else { return }
        self.requestCheck()
    }

    /// For background refresh time: checks, carries on an import, and returns when done.
    func backgroundRefresh() async {
        guard self.started else { return }
        self.access = self.provider.access()
        self.requestCheck()
        self.requestPump()
        await self.waitUntilIdle()
    }

    /// A calendar file reached the journal, so an import may add more.
    func deliveryProgressed() {
        guard self.started else { return }
        self.requestPump()
    }

    /// Returns once every queued operation has run.
    func waitUntilIdle() async {
        while true {
            let count = self.operationCount
            await self.tail?.value
            if count == self.operationCount { return }
        }
    }

    // MARK: serial operations

    private func perform(_ operation: @escaping @MainActor () async -> Void) async {
        await self.enqueue(operation).value
    }

    @discardableResult
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = self.tail
        self.operationCount += 1
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        self.tail = task
        return task
    }

    /// Overlapping triggers coalesce into one waiting check.
    private func requestCheck() {
        guard !self.checkQueued else { return }
        self.checkQueued = true
        self.enqueue {
            self.checkQueued = false
            await self.runCheck()
        }
    }

    private func requestPump() {
        guard !self.pumpQueued else { return }
        self.pumpQueued = true
        self.enqueue {
            self.pumpQueued = false
            await self.pumpImports()
        }
    }

    // MARK: steps

    /// Loads the store, if it could not be read before. The source does nothing until it can.
    private func ensureStore() -> Bool {
        guard self.store.load() else {
            calendarEngineLog.notice("calendar store not readable yet")
            return false
        }
        if !self.storeSynced {
            self.document = self.store.document
            self.storeSynced = true
        }
        return true
    }

    /// Finishes a step a kill interrupted. `false` while it still cannot be finished, or while
    /// the store cannot be read.
    private func finishPendingStep() async -> Bool {
        guard self.ensureStore() else { return false }
        guard let step = self.store.pendingStep else { return true }
        do {
            try await self.apply(step)
            calendarEngineLog.notice("calendar step finished after relaunch files=\(step.files.count, privacy: .public)")
            return true
        } catch {
            calendarEngineLog.error("calendar step still unfinished: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Writes the step first, then the record, the settings and the queue. A kill at any point
    /// is finished from the written step on the next launch, so a step leaves either nothing
    /// or all of it, and no file is queued twice.
    private func commit(files: [CalendarPendingFile], upserts: [String: CalendarSentEntry], document: CalendarSourceDocument) async throws {
        var document = document
        document.paused = self.document.paused
        guard !files.isEmpty || !upserts.isEmpty else {
            try self.store.writeDocument(document)
            self.document = document
            return
        }
        let step = CalendarPendingStep(files: files, upserts: upserts, document: document)
        try self.store.writePendingStep(step)
        try self.store.interrupt(at: .afterStepWritten)
        try await self.apply(step)
    }

    private func apply(_ step: CalendarPendingStep) async throws {
        try self.store.applyRecord(step.upserts)
        try self.store.interrupt(at: .afterRecordWritten)
        var document = step.document
        document.paused = self.document.paused
        try self.store.writeDocument(document)
        self.document = document
        for (index, file) in step.files.enumerated() {
            try await self.delivery.deliver(file)
            try self.store.interrupt(at: .afterFileQueued(index))
        }
        self.store.clearPendingStep()
        self.store.removeUnreferencedFrozenImports()
        if !step.files.isEmpty {
            self.dependencies.deliveryChanged()
        }
    }

    // MARK: setup

    private func countSetup(span: CalendarSpanChoice, calendarIDs: Set<String>?) async {
        guard await self.finishPendingStep(), !self.document.everOn else { return }
        self.access = self.provider.access()
        guard self.access.canRead else { return }
        self.isCountingSetup = true
        defer { self.isCountingSetup = false }

        let now = self.dependencies.now()
        let timeZone = self.dependencies.timeZone()
        let noticed = CalendarWire.wholeSeconds(now)
        var document = self.document
        document.imports.removeAll { $0.kind == .setup }
        let spanStart = span.start(now: now, timeZone: timeZone)
        document.span = span
        document.spanStart = CalendarWire.wholeSeconds(spanStart)
        document.setupAt = noticed
        let earlier = Dictionary(document.calendars.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        document.calendars = self.provider.calendars().map { info in
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
        let followed = document.calendars.filter(\.followed)
        let events = await self.read(
            followed,
            from: spanStart,
            to: self.readEnd(now: now, timeZone: timeZone),
            birthdayFloor: self.birthdayFloor(document, timeZone: timeZone)
        )
        let sightings = self.gather(events, calendars: document.calendars)
        var lines: [CalendarFrozenLine] = []
        var skips: [String: CalendarSentEntry] = [:]
        for key in sightings.keys.sorted(by: CalendarWire.precedes) {
            let sighting = sightings[key]!
            guard let content = self.content(of: sighting.winner, identity: sighting.identity, timeZone: timeZone) else {
                continue
            }
            let changedAt = Self.changedAt(
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
                calendarEngineLog.error("calendar note skipped: \(String(describing: problem), privacy: .public)")
                entry.skipped = content.fingerprint
                skips[key] = entry
                continue
            }
            Self.recordSent(&entry, line: line, winner: sighting.winner)
            lines.append(self.frozenLine(line, entry: entry, baseline: nil, kind: .added))
        }
        let frozen = Self.freeze(lines, sightings: [:], skips: skips)
        let id = UUID().uuidString
        do {
            try self.store.writeFrozenImport(frozen, id: id)
        } catch {
            calendarEngineLog.error("calendar setup could not be frozen: \(String(describing: error), privacy: .public)")
            return
        }
        document.imports.append(CalendarImportRecord(
            id: id,
            kind: .setup,
            confirmed: false,
            count: lines.count,
            fileCount: frozen.files.count,
            cursor: 0,
            frozenAt: noticed
        ))
        self.store.saveDocument(document)
        self.document = document
        self.store.removeUnreferencedFrozenImports()
        calendarEngineLog.notice("calendar setup counted notes=\(lines.count, privacy: .public)")
    }

    private func confirmSetup() async {
        guard await self.finishPendingStep(),
              let index = self.document.imports.firstIndex(where: { $0.kind == .setup && !$0.confirmed })
        else {
            return
        }
        var document = self.document
        let record = document.imports[index]
        document.imports[index].confirmed = true
        document.everOn = true
        // The setup read counts as a completed check.
        document.lastCompletedCheck = record.frozenAt
        document.lastNoticed = max(document.lastNoticed ?? record.frozenAt, record.frozenAt)
        let skips = self.store.frozenImport(id: record.id)?.skips ?? [:]
        do {
            try await self.commit(files: [], upserts: skips, document: document)
            calendarEngineLog.notice("calendar setup confirmed notes=\(record.count, privacy: .public)")
        } catch {
            calendarEngineLog.error("calendar setup confirm failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: calendars on and off

    private func changeCalendar(_ identifier: String, followed: Bool) async {
        guard await self.finishPendingStep(),
              let index = self.document.calendars.firstIndex(where: { $0.identifier == identifier && $0.present })
        else {
            return
        }
        var document = self.document
        let key = document.calendars[index].key
        document.calendars[index].followed = followed
        if !document.everOn {
            self.store.saveDocument(document)
            self.document = document
            // A change before the setup is confirmed is counted again.
            if let span = document.span, document.imports.contains(where: { $0.kind == .setup }) {
                await self.countSetup(
                    span: span,
                    calendarIDs: Set(document.calendars.filter { $0.followed && $0.present }.map(\.identifier))
                )
            }
            return
        }
        document.imports.removeAll { $0.kind == .calendar(key: key) && !$0.confirmed }
        self.store.saveDocument(document)
        self.document = document
        self.store.removeUnreferencedFrozenImports()
        if followed {
            await self.countCalendar(key: key)
        }
    }

    /// Counts a calendar switched on after setup over the setup span. Identities the record
    /// lacks go out as `added`, identities whose fingerprint changed as `changed`, and the rest
    /// send nothing. Every sighting still updates which calendars hold an identity.
    private func countCalendar(key: String) async {
        guard self.document.everOn, let spanStartSeconds = self.document.spanStart else { return }
        self.access = self.provider.access()
        guard self.access.canRead else { return }
        guard let calendar = self.document.calendars.first(where: { $0.key == key && $0.present && $0.followed }) else { return }
        self.countingCalendarKeys.insert(key)
        defer { self.countingCalendarKeys.remove(key) }

        let now = self.dependencies.now()
        let timeZone = self.dependencies.timeZone()
        let noticed = CalendarWire.wholeSeconds(now)
        var document = self.document
        let events = await self.read(
            [calendar],
            from: Date(timeIntervalSince1970: TimeInterval(spanStartSeconds)),
            to: self.readEnd(now: now, timeZone: timeZone),
            birthdayFloor: self.birthdayFloor(document, timeZone: timeZone)
        )
        let sightings = self.gather(events, calendars: document.calendars)
        let record = self.store.record
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
               Self.calendarPrecedes(winner, calendar)
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
            let changedAt = Self.changedAt(
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
                calendarEngineLog.error("calendar note skipped: \(String(describing: problem), privacy: .public)")
                entry.skipped = fingerprint
                skips[identityKey] = entry
                continue
            }
            let kind: CalendarRecentKind = change == .added ? .added : Self.changeKind(old: old, content: content)
            Self.recordSent(&entry, line: line, winner: sighting.winner)
            lines.append(self.frozenLine(line, entry: entry, baseline: old?.changedAt, kind: kind))
        }
        let frozen = Self.freeze(lines, sightings: seenOnly, skips: skips)
        let id = UUID().uuidString
        do {
            try self.store.writeFrozenImport(frozen, id: id)
        } catch {
            calendarEngineLog.error("calendar count could not be frozen: \(String(describing: error), privacy: .public)")
            return
        }
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
        self.store.saveDocument(document)
        self.document = document
        self.store.removeUnreferencedFrozenImports()
    }

    private func confirmCalendarImport(_ identifier: String) async {
        guard await self.finishPendingStep(),
              let calendar = self.document.calendars.first(where: { $0.identifier == identifier && $0.present }),
              let index = self.document.imports.firstIndex(where: { $0.kind == .calendar(key: calendar.key) && !$0.confirmed })
        else {
            return
        }
        var document = self.document
        let importRecord = document.imports[index]
        document.imports[index].confirmed = true
        let frozen = self.store.frozenImport(id: importRecord.id)
        let record = self.store.record
        let liveKeys = Set(document.calendars.filter(\.present).map(\.key))
        var upserts = frozen?.skips ?? [:]
        // Every identity the calendar holds is held by it from now on, whether or not a note for
        // it has gone yet, so a deletion from another calendar is not taken for a removal.
        var sightings = frozen?.sightings ?? [:]
        for file in frozen?.files ?? [] {
            for line in file.lines {
                sightings[line.line.identity.key, default: []].append(calendar.key)
            }
        }
        for (identityKey, keys) in sightings {
            guard var entry = upserts[identityKey] ?? record[identityKey] else { continue }
            let holders = Self.holders(entry.holders, adding: keys, liveKeys: liveKeys)
            guard holders != entry.holders else { continue }
            entry.holders = holders
            upserts[identityKey] = entry
        }
        do {
            try await self.commit(files: [], upserts: upserts, document: document)
        } catch {
            calendarEngineLog.error("calendar import confirm failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: imports

    /// Sends confirmed imports a few files at a time: the frozen set stays in the source's own
    /// store and enters the transfer queue only while fewer than `importWindow` of the source's
    /// files are waiting there, whether or not a journal is connected. An import has finished
    /// when its last file is queued.
    private func pumpImports() async {
        guard await self.finishPendingStep() else { return }
        while let importRecord = self.document.imports.first(where: \.confirmed) {
            guard !self.document.paused, self.provider.access().canRead else { return }
            var document = self.document
            guard let index = document.imports.firstIndex(where: { $0.id == importRecord.id }) else { return }
            guard let frozen = self.store.frozenImport(id: importRecord.id) else {
                calendarEngineLog.error("calendar import set missing; import ended")
                document.imports.remove(at: index)
                try? await self.commit(files: [], upserts: [:], document: document)
                continue
            }
            var cursor = importRecord.cursor
            var files: [CalendarPendingFile] = []
            var upserts: [String: CalendarSentEntry] = [:]
            var recent: [CalendarRecentNote] = []
            if cursor < frozen.files.count {
                let room = self.settings.importWindow - (await self.delivery.queuedFileCount())
                guard room > 0 else { return }
                let record = self.store.record
                let followedKeys = Set(document.calendars.filter(\.followed).map(\.key))
                let timeZone = self.dependencies.timeZone()
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
            }
            let finished = cursor >= frozen.files.count
            if finished {
                document.imports.remove(at: index)
            } else {
                document.imports[index].cursor = cursor
            }
            document.noteRecent(recent)
            do {
                try await self.commit(files: files, upserts: upserts, document: document)
            } catch {
                calendarEngineLog.error("calendar import step failed: \(String(describing: error), privacy: .public)")
                return
            }
            if finished {
                calendarEngineLog.notice("calendar import queued in full")
                self.store.removeFrozenImport(id: importRecord.id)
                self.requestCheck()
            }
        }
    }

    // MARK: routine checks

    private var isRunning: Bool {
        self.document.everOn && !self.document.imports.contains { $0.kind == .setup }
    }

    private func runCheck() async {
        guard await self.finishPendingStep(), self.isRunning, !self.document.paused else { return }
        self.access = self.provider.access()
        guard self.access.canRead else { return }
        guard let spanStartSeconds = self.document.spanStart else { return }

        let now = self.dependencies.now()
        let timeZone = self.dependencies.timeZone()
        let noticed = CalendarWire.wholeSeconds(now)
        var document = self.document
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
        let end = self.readEnd(now: now, timeZone: timeZone)
        let events = await self.read(readSet, from: backEdge, to: end, birthdayFloor: self.birthdayFloor(document, timeZone: timeZone))
        let sightings = self.gather(events, calendars: document.calendars)
        let record = self.store.record

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
            let change: CalendarNoteChange?
            if old?.skipped == fingerprint {
                change = nil
            } else if let old, old.wasSent, !old.removed {
                if old.fingerprint == fingerprint {
                    change = nil
                } else if let winner = old.winner, importing.contains(winner), liveKeys.contains(winner) {
                    // The copy last sent belongs to a calendar still coming in; it decides once in.
                    change = nil
                } else {
                    change = .changed
                }
            } else {
                change = .added
            }
            guard let change else {
                if entry != old {
                    upserts[identityKey] = entry
                }
                continue
            }
            let changedAt = Self.changedAt(
                lastModified: sighting.winner.event.lastModified,
                created: sighting.winner.event.created,
                previous: old?.changedAt,
                now: now,
                lastNoticed: document.lastNoticed
            )
            let line = CalendarNoteLine(change: change, changedAt: CalendarWireInstant(seconds: changedAt, timeZone: timeZone), content: content)
            if let problem = CalendarNoteValidator.problem(with: line) {
                calendarEngineLog.error("calendar note skipped: \(String(describing: problem), privacy: .public)")
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
            let changedAt = Self.changedAt(lastModified: nil, created: nil, previous: old.changedAt, now: now, lastNoticed: document.lastNoticed)
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
        do {
            try await self.commit(files: files, upserts: upserts, document: document)
            if !files.isEmpty {
                calendarEngineLog.notice("calendar check queued notes=\(filed.count, privacy: .public) files=\(files.count, privacy: .public)")
            }
        } catch {
            calendarEngineLog.error("calendar check step failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: reading

    /// The end of every read: one year ahead of today.
    private func readEnd(now: Date, timeZone: TimeZone) -> Date {
        CalendarWire.adding(years: 1, to: CalendarWire.startOfDay(now, in: timeZone), in: timeZone)
    }

    /// Birthdays start at the later of the span's start and the start of the setup year. iOS
    /// expands a contact's birthday back to 1604, and those past copies add nothing.
    private func birthdayFloor(_ document: CalendarSourceDocument, timeZone: TimeZone) -> Date {
        let spanStart = Date(timeIntervalSince1970: TimeInterval(document.spanStart ?? 0))
        let setupYear = CalendarWire.startOfYear(
            Date(timeIntervalSince1970: TimeInterval(document.setupAt ?? 0)),
            in: timeZone
        )
        return max(spanStart, setupYear)
    }

    /// Reads events that start in `from..<to`, in consecutive pages of at most
    /// `pageYears`. An event straddling a page edge is kept only in the page it starts in.
    func read(
        _ calendars: [CalendarFollowRecord],
        from: Date,
        to: Date,
        birthdayFloor: Date
    ) async -> [CalendarEventRecord] {
        guard !calendars.isEmpty, from < to else { return [] }
        let identifiers = calendars.map(\.identifier)
        let birthdays = Set(calendars.filter(\.isBirthdays).map(\.identifier))
        var events: [CalendarEventRecord] = []
        var pageStart = from
        while pageStart < to {
            let pageEnd = self.settings.pageYears.map {
                min(to, CalendarWire.adding(years: $0, to: pageStart, in: CalendarWire.utc))
            } ?? to
            for event in self.provider.events(from: pageStart, to: pageEnd, calendarIDs: identifiers) {
                guard let start = event.start else {
                    calendarEngineLog.notice("calendar event without a start skipped")
                    continue
                }
                guard start >= pageStart, start < pageEnd else { continue }
                if birthdays.contains(event.calendarID), start < birthdayFloor { continue }
                events.append(event)
            }
            pageStart = pageEnd
            await Task.yield()
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

    private func gather(_ events: [CalendarEventRecord], calendars: [CalendarFollowRecord]) -> [String: Sighting] {
        let timeZone = self.dependencies.timeZone()
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
            seriesRule = self.provider.seriesRule(seriesID: identity.event)
        }
        guard let content = CalendarNoteBuilder.content(
            of: copy.event,
            identity: identity,
            calendarName: copy.calendar.title,
            deviceTimeZone: timeZone,
            seriesRule: seriesRule
        ) else {
            calendarEngineLog.notice("calendar event without a start skipped")
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
        let live = self.provider.calendars()
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
        // A calendar matched by name is known again under its new identifier; the rest of the
        // old ones stay known, absent, so their identities are never taken for deletions.
        let identifiers = Set(live.map(\.identifier))
        for index in document.calendars.indices where !identifiers.contains(document.calendars[index].identifier) {
            document.calendars[index].present = false
        }
    }

    // MARK: building

    private func frozenLine(_ line: CalendarNoteLine, entry: CalendarSentEntry, baseline: Int64?, kind: CalendarRecentKind) -> CalendarFrozenLine {
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

    private static func importingKeys(_ document: CalendarSourceDocument) -> Set<String> {
        Set(document.imports.compactMap { record in
            if case .calendar(let key) = record.kind { return key }
            return nil
        })
    }

    nonisolated static func calendarPrecedes(_ lhs: CalendarFollowRecord, _ rhs: CalendarFollowRecord) -> Bool {
        if lhs.title != rhs.title {
            return CalendarWire.precedes(lhs.title, rhs.title)
        }
        return CalendarWire.precedes(lhs.identifier, rhs.identifier)
    }

    // MARK: changed_at

    /// 2000-01-01T00:00:00Z: nothing earlier is believed.
    nonisolated static let earliestBelievable: Int64 = 946_684_800

    /// A time is believable when it is on or after 2000-01-01, is not exactly
    /// 2001-01-01T00:00:00Z (a placeholder some sources report), and is not in the future.
    nonisolated static func believable(_ date: Date?, now: Date) -> Int64? {
        guard let date, date.timeIntervalSinceReferenceDate != 0, date <= now else { return nil }
        let seconds = CalendarWire.wholeSeconds(date)
        return seconds >= Self.earliestBelievable ? seconds : nil
    }

    /// When a version entered the owner's life: the first believable of the event's last change,
    /// its creation and the moment noticed. One identity's notes always carry strictly
    /// increasing `changed_at`: a time not later than the last one sent becomes the latest of
    /// the moment noticed, one second after the last one sent, and one second after the last
    /// moment noticed.
    nonisolated static func changedAt(
        lastModified: Date?,
        created: Date?,
        previous: Int64?,
        now: Date,
        lastNoticed: Int64?
    ) -> Int64 {
        let noticed = CalendarWire.wholeSeconds(now)
        var candidate = self.believable(lastModified, now: now) ?? self.believable(created, now: now) ?? noticed
        if let previous, candidate <= previous {
            candidate = max(noticed, previous + 1, (lastNoticed ?? noticed - 1) + 1)
        }
        return candidate
    }
}
