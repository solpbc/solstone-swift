// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

/// A calendar event as the fake keeps it: wall-clock fields, so a device time-zone change
/// moves floating and all-day events the way iOS does.
nonisolated struct FakeCalendarEvent: Sendable {
    enum Timing: Sendable {
        /// A timed event set in `zone`.
        case zoned(zone: String, minutes: Int)
        /// A timed event with no zone: wall-clock time wherever the device is.
        case floating(minutes: Int)
        /// An all-day event covering `days` days.
        case allDay(days: Int)
    }

    struct Override: Sendable {
        var start: DateComponents?
        var minutes: Int?
        var title: String?
        var lastModified: Date?
    }

    var calendarID: String
    var uid: String
    var hasExternalID = true
    var itemID: String
    var title: String?
    var location: String?
    var notes: String?
    var url: URL?
    var timing: Timing
    /// Wall-clock start: in the event's zone when zoned, on the device otherwise.
    var start: DateComponents
    var lastModified: Date?
    var created: Date?
    var organizer: CalendarParticipantRecord?
    var attendees: [CalendarParticipantRecord] = []
    var rule: CalendarRepeatRule?
    /// How many occurrences a series has; `nil` repeats until reads stop.
    var occurrenceCount: Int?
    /// Moved occurrences, by index: iOS gives each its own `/RID=` id.
    var moved: [Int: Override] = [:]
    var deletedOccurrences: Set<Int> = []
    /// Starts with no end date.
    var hasEnd = true

    init(
        calendarID: String,
        uid: String,
        itemID: String? = nil,
        title: String?,
        timing: Timing,
        start: DateComponents,
        lastModified: Date? = nil,
        created: Date? = nil
    ) {
        self.calendarID = calendarID
        self.uid = uid
        self.itemID = itemID ?? "item-\(uid)"
        self.title = title
        self.timing = timing
        self.start = start
        self.lastModified = lastModified
        self.created = created
    }
}

/// EventKit as measured on iOS 26: a read longer than four years returns its first four years
/// only; an all-day event ends at the last instant of its last day; a moved occurrence carries a
/// `/RID=` id, its original occurrence date and no repeat rules of its own; a subscribed
/// calendar reports last-changed 1976-04-01 and no creation time; Birthdays expands back to 1604.
///
/// The engine reads it from its worker, off the main actor, while tests change it from the main
/// actor, so its state is behind a lock. It records whether each read ran on the main thread.
nonisolated final class FakeCalendarProvider: CalendarAccessProviding, CalendarEventReading, @unchecked Sendable {
    private struct State {
        var accessValue: CalendarAccess = .full
        var requestedAccess: CalendarAccess = .full
        var calendarList: [CalendarInfo] = []
        var events: [FakeCalendarEvent] = []
        var deviceTimeZone: TimeZone
        var deviceCalendar = Calendar(identifier: .gregorian)
        var eventReads: [(from: Date, to: Date)] = []
        var calendarListReads = 0
        var accessRequests = 0
        var mainThreadReads = 0
        var workerReads = 0
        var seriesLookups = 0
        var mainThreadSeriesLookups = 0
        var onChange: (@MainActor @Sendable () -> Void)?
        var readGate: (@Sendable () -> Void)?
    }

    private let lock = NSLock()
    private var state: State

    init(deviceTimeZone: TimeZone) {
        self.state = State(deviceTimeZone: deviceTimeZone)
    }

    private func locked<T>(_ body: (inout State) -> T) -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        return body(&self.state)
    }

    var accessValue: CalendarAccess {
        get { self.locked { $0.accessValue } }
        set { self.locked { $0.accessValue = newValue } }
    }

    var requestedAccess: CalendarAccess {
        get { self.locked { $0.requestedAccess } }
        set { self.locked { $0.requestedAccess = newValue } }
    }

    var calendarList: [CalendarInfo] {
        get { self.locked { $0.calendarList } }
        set { self.locked { $0.calendarList = newValue } }
    }

    var events: [FakeCalendarEvent] {
        get { self.locked { $0.events } }
        set { self.locked { $0.events = newValue } }
    }

    var deviceTimeZone: TimeZone {
        get { self.locked { $0.deviceTimeZone } }
        set { self.locked { $0.deviceTimeZone = newValue } }
    }

    /// The calendar the device is set to. Events are entered in it; the notes never use it.
    var deviceCalendar: Calendar {
        get { self.locked { $0.deviceCalendar } }
        set { self.locked { $0.deviceCalendar = newValue } }
    }

    var eventReads: [(from: Date, to: Date)] { self.locked { $0.eventReads } }
    var calendarListReads: Int { self.locked { $0.calendarListReads } }
    var accessRequests: Int { self.locked { $0.accessRequests } }
    var mainThreadReads: Int { self.locked { $0.mainThreadReads } }
    var workerReads: Int { self.locked { $0.workerReads } }
    var seriesLookups: Int { self.locked { $0.seriesLookups } }
    var mainThreadSeriesLookups: Int { self.locked { $0.mainThreadSeriesLookups } }
    /// Runs at the start of each event read, on the reading thread. For tests that act while a
    /// read is under way.
    var readGate: (@Sendable () -> Void)? {
        get { self.locked { $0.readGate } }
        set { self.locked { $0.readGate = newValue } }
    }

    /// The handler the engine registered for iOS's change notices, once set up.
    var onChange: (@MainActor @Sendable () -> Void)? { self.locked { $0.onChange } }

    var readCount: Int {
        self.locked { $0.eventReads.count + $0.calendarListReads }
    }

    func access() -> CalendarAccess {
        self.accessValue
    }

    func requestFullAccess() async -> CalendarAccess {
        self.locked { state in
            state.accessRequests += 1
            if state.accessValue == .notDetermined {
                state.accessValue = state.requestedAccess
            }
            return state.accessValue
        }
    }

    func observeChanges(_ handler: @escaping @MainActor @Sendable () -> Void) {
        self.locked { $0.onChange = handler }
    }

    private func noteRead() {
        let onMain = Thread.isMainThread
        self.locked { state in
            if onMain { state.mainThreadReads += 1 } else { state.workerReads += 1 }
        }
    }

    func calendars() -> [CalendarInfo] {
        self.noteRead()
        return self.locked { state in
            state.calendarListReads += 1
            return state.accessValue.canRead ? state.calendarList : []
        }
    }

    func events(from: Date, to: Date, calendarIDs: [String]) -> [CalendarEventRecord] {
        self.noteRead()
        self.readGate?()
        let (canRead, events) = self.locked { state -> (Bool, [FakeCalendarEvent]) in
            state.eventReads.append((from, to))
            return (state.accessValue.canRead, state.events)
        }
        guard canRead else { return [] }
        let utc = CalendarWire.gregorianUTC
        let cappedEnd = min(to, utc.date(byAdding: .year, value: 4, to: from)!)
        let wanted = Set(calendarIDs)
        var records: [CalendarEventRecord] = []
        for event in events where wanted.contains(event.calendarID) {
            records.append(contentsOf: self.occurrences(of: event, from: from, to: cappedEnd))
        }
        return records
    }

    func seriesRule(seriesID: String) -> CalendarRepeatRule? {
        let onMain = Thread.isMainThread
        return self.locked { state in
            state.seriesLookups += 1
            if onMain { state.mainThreadSeriesLookups += 1 }
            return state.events.first { $0.uid == seriesID }?.rule
        }
    }

    func addCalendar(_ identifier: String, title: String, account: String = "iCloud", birthdays: Bool = false) {
        self.locked { $0.calendarList.append(CalendarInfo(identifier: identifier, title: title, accountName: account, isBirthdays: birthdays)) }
    }

    // MARK: expansion

    private func zone(of event: FakeCalendarEvent) -> TimeZone {
        if case .zoned(let zone, _) = event.timing {
            return TimeZone(identifier: zone)!
        }
        return self.deviceTimeZone
    }

    private func calendar(in zone: TimeZone) -> Calendar {
        var calendar = self.deviceCalendar
        calendar.timeZone = zone
        return calendar
    }

    private func occurrences(of event: FakeCalendarEvent, from: Date, to: Date) -> [CalendarEventRecord] {
        let zone = self.zone(of: event)
        let calendar = self.calendar(in: zone)
        guard let first = calendar.date(from: event.start) else { return [] }
        guard let rule = event.rule else {
            return self.record(event, index: 0, original: first, override: nil, from: from, to: to).map { [$0] } ?? []
        }
        var results: [CalendarEventRecord] = []
        var original = first
        var index = 0
        while original < to {
            if let count = event.occurrenceCount, index >= count { break }
            if !event.deletedOccurrences.contains(index),
               let record = self.record(event, index: index, original: original, override: event.moved[index], from: from, to: to)
            {
                results.append(record)
            }
            index += 1
            original = self.next(after: original, rule: rule, calendar: calendar)
        }
        return results
    }

    private func next(after date: Date, rule: CalendarRepeatRule, calendar: Calendar) -> Date {
        switch rule.frequency {
        case .daily:
            return calendar.date(byAdding: .day, value: rule.interval, to: date)!
        case .weekly:
            if !rule.daysOfWeek.isEmpty {
                var next = calendar.date(byAdding: .day, value: 1, to: date)!
                while !rule.daysOfWeek.contains(calendar.component(.weekday, from: next)) {
                    next = calendar.date(byAdding: .day, value: 1, to: next)!
                }
                return next
            }
            return calendar.date(byAdding: .day, value: 7 * rule.interval, to: date)!
        case .monthly:
            return calendar.date(byAdding: .month, value: rule.interval, to: date)!
        case .yearly:
            return calendar.date(byAdding: .year, value: rule.interval, to: date)!
        }
    }

    private func record(
        _ event: FakeCalendarEvent,
        index: Int,
        original: Date,
        override: FakeCalendarEvent.Override?,
        from: Date,
        to: Date
    ) -> CalendarEventRecord? {
        let zone = self.zone(of: event)
        let calendar = self.calendar(in: zone)
        var start = original
        if let overrideStart = override?.start {
            start = calendar.date(from: overrideStart)!
        }
        let end: Date
        var isAllDay = false
        var zoneIdentifier: String?
        switch event.timing {
        case .zoned(let identifier, let minutes):
            end = start.addingTimeInterval(TimeInterval((override?.minutes ?? minutes) * 60))
            zoneIdentifier = identifier
        case .floating(let minutes):
            end = start.addingTimeInterval(TimeInterval((override?.minutes ?? minutes) * 60))
        case .allDay(let days):
            isAllDay = true
            // iOS gives an all-day event's end as the last instant of its last day.
            end = calendar.date(byAdding: .day, value: days, to: start)!.addingTimeInterval(-1)
        }
        guard start < to, end >= from else { return nil }
        let repeating = event.rule != nil
        let externalID: String?
        if !event.hasExternalID {
            externalID = nil
        } else if repeating, override != nil {
            // A moved occurrence's external id is the series id plus the seconds since 2001 of
            // its original start.
            externalID = "\(event.uid)/RID=\(Int(original.timeIntervalSinceReferenceDate))"
        } else {
            externalID = event.uid
        }
        return CalendarEventRecord(
            calendarID: event.calendarID,
            itemID: override != nil ? "\(event.itemID)-\(index)" : event.itemID,
            externalID: externalID,
            title: override?.title ?? event.title,
            location: event.location,
            notes: event.notes,
            url: event.url,
            start: start,
            end: event.hasEnd ? end : nil,
            isAllDay: isAllDay,
            timeZoneIdentifier: zoneIdentifier,
            occurrenceDate: repeating ? original : start,
            repeatRules: repeating && override == nil ? [event.rule!] : [],
            isDetached: repeating && override != nil,
            lastModified: override?.lastModified ?? event.lastModified,
            created: event.created,
            organizer: event.organizer,
            attendees: event.attendees
        )
    }
}

/// Stands in for the transfer queue: keeps every file queued, once, in order.
@MainActor
final class FakeCalendarDelivery: CalendarNoteDelivering {
    private(set) var stagingClears = 0
    private(set) var files: [CalendarPendingFile] = []
    /// Files queued and not yet settled.
    private(set) var waiting = 0
    /// When true, each file is in the journal as soon as it is queued.
    var settlesAtOnce = true
    private(set) var mostWaiting = 0

    func deliver(_ file: CalendarPendingFile) async throws {
        guard !self.files.contains(where: { $0.file.name == file.file.name }) else { return }
        self.files.append(file)
        if !self.settlesAtOnce {
            self.waiting += 1
            self.mostWaiting = max(self.mostWaiting, self.waiting)
        }
    }

    func queuedFileCount() async -> Int {
        self.waiting
    }

    func clearStaging() {
        self.stagingClears += 1
    }

    func settle(_ count: Int = .max) {
        self.waiting = max(0, self.waiting - count)
    }

    var lines: [String] {
        self.files.flatMap { pending in
            String(decoding: pending.file.bytes, as: UTF8.self).split(separator: "\n").map(String.init)
        }
    }

    func lines(event: String) -> [[String: Any]] {
        self.lines.compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["event"] as? String == event
            else {
                return nil
            }
            return object
        }
    }

    func rawLines(event: String) -> [String] {
        self.lines.filter { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["event"] as? String == event
        }
    }
}

/// The engine over a fake calendar, a temporary store and a fake queue, with a clock the test
/// moves. `relaunch()` builds a fresh engine over the same store and queue, as a kill and a
/// relaunch would.
@MainActor
final class CalendarHarness {
    let rootURL: URL
    let provider: FakeCalendarProvider
    let delivery: FakeCalendarDelivery
    var now: Date
    var settings: CalendarSourceEngine.Settings
    private(set) var store: CalendarSourceStore
    private(set) var engine: CalendarSourceEngine
    private let engineDelivery: any CalendarNoteDelivering
    private let dependencies: ((CalendarHarness) -> CalendarSourceEngine.Dependencies)?

    /// `delivery` replaces the fake queue, for runs through the real transfer engine.
    init(
        now: Date,
        timeZone: TimeZone = TimeZone(identifier: "America/Denver")!,
        settings: CalendarSourceEngine.Settings = CalendarSourceEngine.Settings(),
        delivery: (any CalendarNoteDelivering)? = nil,
        dependencies: ((CalendarHarness) -> CalendarSourceEngine.Dependencies)? = nil
    ) {
        self.rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalendarEngine-\(UUID().uuidString)", isDirectory: true)
        self.provider = FakeCalendarProvider(deviceTimeZone: timeZone)
        let fake = FakeCalendarDelivery()
        self.delivery = fake
        self.engineDelivery = delivery ?? fake
        self.dependencies = dependencies
        self.now = now
        self.settings = settings
        self.settings.changeDebounce = .milliseconds(20)
        self.settings.launchWait = .seconds(5)
        self.store = CalendarSourceStore(rootURL: self.rootURL)
        self.engine = CalendarSourceEngine(access: self.provider, reader: self.provider, store: self.store, delivery: self.engineDelivery)
        self.engine = self.makeEngine()
    }

    deinit {
        try? FileManager.default.removeItem(at: self.rootURL)
    }

    var timeZone: TimeZone {
        get { self.provider.deviceTimeZone }
        set { self.provider.deviceTimeZone = newValue }
    }

    private func makeEngine() -> CalendarSourceEngine {
        let provider = self.provider
        return CalendarSourceEngine(
            access: provider,
            reader: provider,
            store: self.store,
            delivery: self.engineDelivery,
            settings: self.settings,
            dependencies: self.dependencies?(self) ?? CalendarSourceEngine.Dependencies(
                now: { [weak self] in self?.now ?? Date() },
                timeZone: { provider.deviceTimeZone }
            )
        )
    }

    /// A kill and a relaunch: the store is read again from disk and the engine starts over.
    func relaunch() async {
        self.rebuild()
        await self.engine.launch()
        await self.engine.waitUntilIdle()
    }

    /// A new process whose launch has not run yet.
    func rebuild() {
        self.store = CalendarSourceStore(rootURL: self.rootURL)
        self.engine = self.makeEngine()
    }

    /// Sets up with `span`, confirms, and waits for the import and the first check.
    func setUpAndConfirm(_ span: CalendarSpanChoice = .last30Days, calendarIDs: Set<String>? = nil) async {
        await self.engine.setUp(span: span, calendarIDs: calendarIDs)
        await self.engine.confirm()
        await self.engine.launch()
        await self.engine.waitUntilIdle()
    }

    /// A routine check at the current clock.
    func check() async {
        self.engine.foreground()
        await self.engine.waitUntilIdle()
    }

    func advance(minutes: Double) {
        self.now = self.now.addingTimeInterval(minutes * 60)
    }

    func advance(days: Double) {
        self.now = self.now.addingTimeInterval(days * 86_400)
    }

    func stopAt(_ point: CalendarStepPoint) {
        self.store.interruption = { reached in
            if reached == point { throw CalendarSimulatedKill() }
        }
    }
}

nonisolated struct CalendarSimulatedKill: Error {}

nonisolated enum CalendarFixtures {
    static let denver = TimeZone(identifier: "America/Denver")!

    /// Wall-clock components.
    static func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> DateComponents {
        DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    /// An instant written as RFC 3339 with an offset.
    static func instant(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)!
    }

    static func participant(_ name: String?, _ email: String?, _ status: CalendarParticipantStatus, you: Bool = false) -> CalendarParticipantRecord {
        CalendarParticipantRecord(
            name: name,
            url: email.map { URL(string: "mailto:\($0)")! },
            status: status,
            isCurrentUser: you
        )
    }

    static func lineObjects(_ data: Data) -> [[String: Any]] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }
}
