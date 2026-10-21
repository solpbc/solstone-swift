// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@preconcurrency import EventKit
import Foundation
import os

nonisolated private let calendarProviderLog = Logger(subsystem: "app.solstone.swift", category: "calendar")

/// What iOS lets this app do with the owner's calendars.
nonisolated enum CalendarAccess: String, Codable, Equatable, Sendable {
    case notDetermined
    case denied
    case writeOnly
    case restricted
    case full

    var canRead: Bool {
        self == .full
    }
}

/// One calendar as iOS lists it.
nonisolated struct CalendarInfo: Equatable, Sendable {
    let identifier: String
    let title: String
    /// The account the calendar belongs to, as iOS names it.
    let accountName: String
    let isBirthdays: Bool
}

nonisolated enum CalendarParticipantStatus: Equatable, Sendable {
    case accepted
    case declined
    case tentative
    case pending
    case inProcess
    case other

    var wireValue: String {
        switch self {
        case .accepted: "accepted"
        case .declined: "declined"
        case .tentative: "tentative"
        case .pending, .inProcess: "pending"
        case .other: "unknown"
        }
    }
}

nonisolated struct CalendarParticipantRecord: Equatable, Sendable {
    let name: String?
    let url: URL?
    let status: CalendarParticipantStatus
    let isCurrentUser: Bool
}

/// The part of a repeat rule the notes describe.
nonisolated struct CalendarRepeatRule: Equatable, Sendable {
    enum Frequency: Equatable, Sendable {
        case daily
        case weekly
        case monthly
        case yearly
    }

    let frequency: Frequency
    let interval: Int
    /// Days of the week the rule names, 1 for Sunday through 7 for Saturday.
    let daysOfWeek: [Int]

    init(frequency: Frequency, interval: Int = 1, daysOfWeek: [Int] = []) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.daysOfWeek = daysOfWeek
    }

    /// A plain description for display. It is never parsed.
    var plainDescription: String {
        switch self.frequency {
        case .daily:
            return self.interval == 1 ? "every day" : "every \(self.interval) days"
        case .weekly:
            if self.interval == 1, Set(self.daysOfWeek) == [2, 3, 4, 5, 6] {
                return "every weekday"
            }
            return self.interval == 1 ? "every week" : "every \(self.interval) weeks"
        case .monthly:
            return self.interval == 1 ? "every month" : "every \(self.interval) months"
        case .yearly:
            return self.interval == 1 ? "every year" : "every \(self.interval) years"
        }
    }
}

/// One event or occurrence as a calendar read returns it.
nonisolated struct CalendarEventRecord: Equatable, Sendable {
    var calendarID: String
    /// The phone's own id for the item.
    var itemID: String
    /// The calendar's own id for the event. A moved occurrence's carries `/RID=…`.
    var externalID: String?
    var title: String?
    var location: String?
    var notes: String?
    var url: URL?
    var start: Date?
    var end: Date?
    var isAllDay: Bool
    /// The zone the event is set in; `nil` for all-day and floating events.
    var timeZoneIdentifier: String?
    /// For an occurrence of a repeating event, its original start.
    var occurrenceDate: Date?
    /// The repeat rules the item carries itself. A moved occurrence carries none.
    var repeatRules: [CalendarRepeatRule]
    var isDetached: Bool
    var lastModified: Date?
    var created: Date?
    var organizer: CalendarParticipantRecord?
    var attendees: [CalendarParticipantRecord]
}

/// Calendar access as iOS grants it, and notice of changes. Asked from the main actor.
nonisolated protocol CalendarAccessProviding: AnyObject, Sendable {
    func access() -> CalendarAccess
    /// Asks iOS for full access. Never asks for write-only access.
    func requestFullAccess() async -> CalendarAccess
    /// Starts reporting iOS's calendar changes to `handler`, on the main actor. Called only
    /// once the source is set up.
    func observeChanges(_ handler: @escaping @MainActor @Sendable () -> Void)
}

/// The calendars, as the engine reads them. Called only from the calendar worker, one call at
/// a time, never on the main actor. The live one is EventKit; tests use a fake that reproduces
/// what iOS does.
nonisolated protocol CalendarEventReading: Sendable {
    func calendars() -> [CalendarInfo]
    /// One read of the events overlapping `from..<to` in the given calendars. iOS silently
    /// cuts a single read at its first four years, so callers page.
    func events(from: Date, to: Date, calendarIDs: [String]) -> [CalendarEventRecord]
    /// The repeat rule of a series, for an occurrence that carries none of its own.
    func seriesRule(seriesID: String) -> CalendarRepeatRule?
}

nonisolated enum EventKitAuthorization {
    static func access() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .fullAccess:
            return .full
        case .writeOnly:
            return .writeOnly
        @unknown default:
            return .denied
        }
    }
}

/// Access and change notices through EventKit. Its event store is made only when the owner
/// asks for access or the set-up source starts observing, so a source never set up never
/// touches EventKit.
nonisolated final class EventKitCalendarAccess: CalendarAccessProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var eventStore: EKEventStore?
    private var observer: (any NSObjectProtocol)?
    private var handler: (@MainActor @Sendable () -> Void)?

    init() {}

    func access() -> CalendarAccess {
        EventKitAuthorization.access()
    }

    func requestFullAccess() async -> CalendarAccess {
        do {
            _ = try await self.store().requestFullAccessToEvents()
        } catch {
            calendarProviderLog.error("calendar access request failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        return self.access()
    }

    func observeChanges(_ handler: @escaping @MainActor @Sendable () -> Void) {
        self.lock.withLock { self.handler = handler }
        let store = self.store()
        self.lock.withLock {
            guard self.observer == nil else { return }
            self.observer = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: store,
                queue: .main
            ) { [weak self] _ in
                let handler = self?.lock.withLock { self?.handler }
                MainActor.assumeIsolated {
                    handler?()
                }
            }
        }
    }

    private func store() -> EKEventStore {
        self.lock.withLock {
            if let eventStore { return eventStore }
            let store = EKEventStore()
            self.eventStore = store
            return store
        }
    }
}

/// Reads through EventKit with an event store of its own, used only by the calendar worker.
nonisolated final class EventKitCalendarReader: CalendarEventReading, @unchecked Sendable {
    private let lock = NSLock()
    private var eventStore: EKEventStore?

    init() {}

    private var store: EKEventStore {
        self.lock.withLock {
            if let eventStore { return eventStore }
            let store = EKEventStore()
            self.eventStore = store
            return store
        }
    }

    func calendars() -> [CalendarInfo] {
        guard EventKitAuthorization.access().canRead else { return [] }
        return self.store.calendars(for: .event).map { calendar in
            CalendarInfo(
                identifier: calendar.calendarIdentifier,
                title: calendar.title,
                accountName: calendar.source?.title ?? "",
                isBirthdays: calendar.type == .birthday
            )
        }
    }

    func events(from: Date, to: Date, calendarIDs: [String]) -> [CalendarEventRecord] {
        guard EventKitAuthorization.access().canRead, from < to else { return [] }
        let wanted = Set(calendarIDs)
        let store = self.store
        let calendars = store.calendars(for: .event).filter { wanted.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
        return store.events(matching: predicate).map(Self.record)
    }

    func seriesRule(seriesID: String) -> CalendarRepeatRule? {
        guard EventKitAuthorization.access().canRead else { return nil }
        for item in self.store.calendarItems(withExternalIdentifier: seriesID) {
            if let rule = item.recurrenceRules?.first {
                return Self.rule(rule)
            }
        }
        return nil
    }

    private static func record(_ event: EKEvent) -> CalendarEventRecord {
        CalendarEventRecord(
            calendarID: event.calendar?.calendarIdentifier ?? "",
            itemID: event.calendarItemIdentifier,
            externalID: event.calendarItemExternalIdentifier,
            title: event.title,
            location: event.location,
            notes: event.notes,
            url: event.url,
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            timeZoneIdentifier: event.isAllDay ? nil : event.timeZone?.identifier,
            occurrenceDate: event.occurrenceDate,
            repeatRules: (event.recurrenceRules ?? []).map(Self.rule),
            isDetached: event.isDetached,
            lastModified: event.lastModifiedDate,
            created: event.creationDate,
            organizer: event.organizer.map(Self.participant),
            attendees: (event.attendees ?? []).map(Self.participant)
        )
    }

    private static func participant(_ participant: EKParticipant) -> CalendarParticipantRecord {
        let status: CalendarParticipantStatus
        switch participant.participantStatus {
        case .accepted:
            status = .accepted
        case .declined:
            status = .declined
        case .tentative:
            status = .tentative
        case .pending:
            status = .pending
        case .inProcess:
            status = .inProcess
        default:
            status = .other
        }
        return CalendarParticipantRecord(
            name: participant.name,
            url: participant.url,
            status: status,
            isCurrentUser: participant.isCurrentUser
        )
    }

    private static func rule(_ rule: EKRecurrenceRule) -> CalendarRepeatRule {
        let frequency: CalendarRepeatRule.Frequency
        switch rule.frequency {
        case .daily:
            frequency = .daily
        case .weekly:
            frequency = .weekly
        case .monthly:
            frequency = .monthly
        case .yearly:
            frequency = .yearly
        @unknown default:
            frequency = .daily
        }
        return CalendarRepeatRule(
            frequency: frequency,
            interval: rule.interval,
            daysOfWeek: (rule.daysOfTheWeek ?? []).map { $0.dayOfTheWeek.rawValue }
        )
    }
}
