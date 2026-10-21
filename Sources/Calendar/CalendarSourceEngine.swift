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
        /// A burst of iOS change notices is one check, this long after the last of them.
        var changeDebounce: Duration = .seconds(2)
        /// How long background refresh time waits for the app's launch to finish before giving
        /// the time back. Well inside the time iOS grants.
        var launchWait: Duration = .seconds(15)
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

    @ObservationIgnored private let accessProvider: any CalendarAccessProviding
    @ObservationIgnored let worker: CalendarWorker
    @ObservationIgnored let store: CalendarSourceStore
    @ObservationIgnored private let delivery: any CalendarNoteDelivering
    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var operationCount = 0
    @ObservationIgnored private var checkQueued = false
    @ObservationIgnored private var pumpQueued = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var launched = false
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var debounce: Task<Void, Never>?
    /// Whether `document` has been taken from a loaded store.
    @ObservationIgnored private var storeSynced: Bool
    /// Routine checks that read the calendars. For tests.
    @ObservationIgnored private(set) var checkCount = 0

    init(
        access: any CalendarAccessProviding,
        reader: any CalendarEventReading,
        store: CalendarSourceStore,
        delivery: any CalendarNoteDelivering,
        settings: Settings = Settings(),
        dependencies: Dependencies = Dependencies()
    ) {
        self.accessProvider = access
        self.worker = CalendarWorker(
            reader: reader,
            importsURL: store.rootURL.appendingPathComponent("imports", isDirectory: true),
            settings: CalendarWorker.Settings(
                pageYears: settings.pageYears,
                removalConfirmationSeconds: settings.removalConfirmationSeconds,
                lookBackDays: settings.lookBackDays
            )
        )
        self.store = store
        self.delivery = delivery
        self.settings = settings
        self.dependencies = dependencies
        self.access = access.access()
        self.document = store.document
        self.storeSynced = store.isLoaded
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
        self.access = await self.accessProvider.requestFullAccess()
        return self.access
    }

    func refreshAccess() {
        self.access = self.accessProvider.access()
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

    /// At launch: clears what a kill left half-staged, finishes a step a kill interrupted, then
    /// carries on an import and checks. Returns once the interrupted step is finished, so it is
    /// queued before anything is sent.
    func launch() async {
        self.started = true
        self.access = self.accessProvider.access()
        self.delivery.clearStaging()
        await self.perform { _ = await self.finishPendingStep() }
        self.observeChangesIfSetUp()
        self.requestPump()
        self.requestCheck()
        self.launched = true
    }

    func foreground() {
        guard self.started else { return }
        self.access = self.accessProvider.access()
        self.requestPump()
        self.requestCheck()
    }

    /// iOS reported a calendar change. A burst of reports is one check, after the burst.
    func storeChanged() {
        guard self.started else { return }
        self.debounce?.cancel()
        let delay = self.settings.changeDebounce
        self.debounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.requestCheck()
        }
    }

    /// For background refresh time. iOS may launch the app just for this, before the app has
    /// finished launching; the refresh then waits for the launch, whose own check is the one it
    /// runs, and gives the time back if the launch does not finish within `launchWait`.
    func backgroundRefresh() async {
        if !self.launched {
            let deadline = ContinuousClock.now + self.settings.launchWait
            while !self.launched, ContinuousClock.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard self.launched else {
                calendarEngineLog.notice("calendar refresh ended before the app finished launching")
                return
            }
            await self.waitUntilIdle()
            return
        }
        self.access = self.accessProvider.access()
        self.requestCheck()
        self.requestPump()
        await self.waitUntilIdle()
    }

    /// A calendar file reached the journal, or went to needs attention, so an import may add
    /// more.
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

    private func observeChangesIfSetUp() {
        guard self.document.everOn, !self.observing else { return }
        self.observing = true
        self.accessProvider.observeChanges { [weak self] in
            self?.storeChanged()
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
            calendarEngineLog.error("calendar step still unfinished: \(String(describing: type(of: error)), privacy: .public)")
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
            await self.worker.removeFrozen(except: Set(document.imports.map(\.id)))
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
        await self.worker.removeFrozen(except: Set(document.imports.map(\.id)))
        if !step.files.isEmpty {
            self.dependencies.deliveryChanged()
        }
    }

    // MARK: setup

    private func countSetup(span: CalendarSpanChoice, calendarIDs: Set<String>?) async {
        guard await self.finishPendingStep(), !self.document.everOn else { return }
        self.access = self.accessProvider.access()
        guard self.access.canRead else { return }
        self.isCountingSetup = true
        defer { self.isCountingSetup = false }
        do {
            let document = try await self.worker.countSetup(
                document: self.document,
                span: span,
                calendarIDs: calendarIDs,
                now: self.dependencies.now(),
                timeZone: self.dependencies.timeZone()
            )
            try self.store.writeDocument(document)
            self.document = document
            await self.worker.removeFrozen(except: Set(document.imports.map(\.id)))
        } catch {
            calendarEngineLog.error("calendar setup could not be counted: \(String(describing: type(of: error)), privacy: .public)")
        }
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
        let skips = await self.worker.skips(importID: record.id)
        do {
            try await self.commit(files: [], upserts: skips, document: document)
            calendarEngineLog.notice("calendar setup confirmed notes=\(record.count, privacy: .public)")
            if self.started {
                self.observeChangesIfSetUp()
            }
        } catch {
            calendarEngineLog.error("calendar setup confirm failed: \(String(describing: type(of: error)), privacy: .public)")
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
        await self.worker.removeFrozen(except: Set(document.imports.map(\.id)))
        if followed {
            await self.countCalendar(key: key)
        }
    }

    /// Counts a calendar switched on after setup over the setup span; nothing is sent until
    /// `confirmCalendar`.
    private func countCalendar(key: String) async {
        guard self.document.everOn else { return }
        self.access = self.accessProvider.access()
        guard self.access.canRead else { return }
        self.countingCalendarKeys.insert(key)
        defer { self.countingCalendarKeys.remove(key) }
        do {
            guard let document = try await self.worker.countCalendar(
                document: self.document,
                key: key,
                record: self.store.record,
                now: self.dependencies.now(),
                timeZone: self.dependencies.timeZone()
            ) else {
                return
            }
            try self.store.writeDocument(document)
            self.document = document
            await self.worker.removeFrozen(except: Set(document.imports.map(\.id)))
        } catch {
            calendarEngineLog.error("calendar count failed: \(String(describing: type(of: error)), privacy: .public)")
        }
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
        let upserts = await self.worker.confirmUpserts(
            importID: importRecord.id,
            calendarKey: calendar.key,
            record: self.store.record,
            liveKeys: Set(document.calendars.filter(\.present).map(\.key))
        )
        do {
            try await self.commit(files: [], upserts: upserts, document: document)
        } catch {
            calendarEngineLog.error("calendar import confirm failed: \(String(describing: type(of: error)), privacy: .public)")
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
            guard !self.document.paused, self.accessProvider.access().canRead else { return }
            var room = self.settings.importWindow
            if importRecord.cursor < importRecord.fileCount {
                room -= await self.delivery.queuedFileCount()
                guard room > 0 else { return }
            }
            let batch = await self.worker.importBatch(
                importRecord,
                record: self.store.record,
                followedKeys: Set(self.document.calendars.filter(\.followed).map(\.key)),
                room: room,
                timeZone: self.dependencies.timeZone()
            )
            var document = self.document
            guard let index = document.imports.firstIndex(where: { $0.id == importRecord.id }) else { return }
            guard let batch else {
                calendarEngineLog.error("calendar import set missing; import ended")
                document.imports.remove(at: index)
                try? await self.commit(files: [], upserts: [:], document: document)
                continue
            }
            if batch.finished {
                document.imports.remove(at: index)
            } else {
                document.imports[index].cursor = batch.cursor
            }
            document.noteRecent(batch.recent)
            do {
                try await self.commit(files: batch.files, upserts: batch.upserts, document: document)
            } catch {
                calendarEngineLog.error("calendar import step failed: \(String(describing: type(of: error)), privacy: .public)")
                return
            }
            if batch.finished {
                calendarEngineLog.notice("calendar import queued in full")
                await self.worker.removeFrozen(id: importRecord.id)
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
        self.access = self.accessProvider.access()
        guard self.access.canRead else { return }
        self.checkCount += 1
        guard let outcome = await self.worker.routineCheck(
            document: self.document,
            record: self.store.record,
            now: self.dependencies.now(),
            timeZone: self.dependencies.timeZone()
        ) else {
            return
        }
        do {
            try await self.commit(files: outcome.files, upserts: outcome.upserts, document: outcome.document)
            if !outcome.files.isEmpty {
                calendarEngineLog.notice("calendar check queued notes=\(outcome.noteCount, privacy: .public) files=\(outcome.files.count, privacy: .public)")
            }
        } catch {
            calendarEngineLog.error("calendar check step failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    // MARK: ordering and changed_at

    nonisolated static func calendarPrecedes(_ lhs: CalendarFollowRecord, _ rhs: CalendarFollowRecord) -> Bool {
        if lhs.title != rhs.title {
            return CalendarWire.precedes(lhs.title, rhs.title)
        }
        return CalendarWire.precedes(lhs.identifier, rhs.identifier)
    }

    /// 2000-01-01T00:00:00Z: nothing earlier is believed.
    nonisolated static let earliestBelievable: Int64 = 946_684_800
    /// 2001-01-01T00:00:00Z, a placeholder some sources report.
    nonisolated static let placeholder: Int64 = 978_307_200

    /// A time is believable when, in whole seconds, it is on or after 2000-01-01, is not
    /// 2001-01-01T00:00:00Z (a placeholder some sources report), and is not after now.
    nonisolated static func believable(_ date: Date?, now: Date) -> Int64? {
        guard let date else { return nil }
        let seconds = CalendarWire.wholeSeconds(date)
        guard seconds >= Self.earliestBelievable, seconds != Self.placeholder, seconds <= CalendarWire.wholeSeconds(now) else {
            return nil
        }
        return seconds
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
