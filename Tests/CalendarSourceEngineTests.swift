// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

/// The calendar engine over a fake calendar that behaves as iOS does, a temporary store and a
/// fake transfer queue.
nonisolated final class CalendarSourceEngineTests: XCTestCase {
    static let start = "2026-10-20T16:31:00-06:00"

    @MainActor
    static func harness(now: String = CalendarSourceEngineTests.start) -> CalendarHarness {
        let harness = CalendarHarness(now: CalendarFixtures.instant(now))
        harness.provider.addCalendar("cal-work", title: "Work")
        return harness
    }

    static func meeting(
        _ uid: String,
        calendar: String = "cal-work",
        title: String,
        _ start: DateComponents,
        minutes: Int = 60,
        zone: String = "America/Denver",
        lastModified: String? = nil,
        created: String? = nil
    ) -> FakeCalendarEvent {
        FakeCalendarEvent(
            calendarID: calendar,
            uid: uid,
            title: title,
            timing: .zoned(zone: zone, minutes: minutes),
            start: start,
            lastModified: lastModified.map(CalendarFixtures.instant),
            created: created.map(CalendarFixtures.instant)
        )
    }

    @MainActor
    static func removedCount(_ harness: CalendarHarness) -> Int {
        harness.delivery.lines.filter { $0.contains(#""change":"removed""#) }.count
    }

    // MARK: identity

    @MainActor
    func testAnUndetachedAndAMovedOccurrenceOfOneSeriesGiveTheSamePair() {
        let provider = FakeCalendarProvider(deviceTimeZone: CalendarFixtures.denver)
        provider.addCalendar("cal-work", title: "Work")
        var series = Self.meeting("SERIES-1", title: "sync", CalendarFixtures.at(2026, 10, 19, 9, 0))
        series.rule = CalendarRepeatRule(frequency: .daily)
        provider.events = [series]
        let range = (CalendarFixtures.instant("2026-10-21T00:00:00-06:00"), CalendarFixtures.instant("2026-10-22T00:00:00-06:00"))
        let before = try! XCTUnwrap(provider.events(from: range.0, to: range.1, calendarIDs: ["cal-work"]).first)
        provider.events[0].moved[2] = FakeCalendarEvent.Override(start: CalendarFixtures.at(2026, 10, 21, 13, 0))
        let after = try! XCTUnwrap(provider.events(from: range.0, to: range.1, calendarIDs: ["cal-work"]).first)

        XCTAssertNil(before.externalID?.range(of: "/RID="))
        XCTAssertTrue(after.externalID?.hasPrefix("SERIES-1/RID=") == true)
        XCTAssertTrue(after.repeatRules.isEmpty)
        XCTAssertTrue(after.isDetached)
        XCTAssertNotEqual(before.start, after.start)
        let lhs = CalendarNoteBuilder.identity(of: before, deviceTimeZone: CalendarFixtures.denver)
        let rhs = CalendarNoteBuilder.identity(of: after, deviceTimeZone: CalendarFixtures.denver)
        XCTAssertEqual(lhs, rhs)
        XCTAssertEqual(lhs, CalendarIdentity(event: "SERIES-1", occurrence: "2026-10-21T15:00:00Z"))
    }

    @MainActor
    func testAnAllDayRepeatingOccurrenceKeepsItsIdentityAcrossATimeZoneChange() async {
        let harness = Self.harness()
        harness.provider.addCalendar("cal-birthdays", title: "Birthdays", birthdays: true)
        var birthday = FakeCalendarEvent(
            calendarID: "cal-birthdays",
            uid: "BIRTHDAY-1",
            title: "Sam's Birthday",
            timing: .allDay(days: 1),
            start: CalendarFixtures.at(1990, 3, 4)
        )
        birthday.rule = CalendarRepeatRule(frequency: .yearly)
        harness.provider.events = [birthday]
        await harness.setUpAndConfirm()
        XCTAssertEqual(harness.delivery.lines(event: "BIRTHDAY-1").compactMap { $0["occurrence"] as? String }, ["2027-03-04"])

        harness.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        harness.advance(minutes: 30)
        await harness.check()
        XCTAssertEqual(harness.delivery.lines(event: "BIRTHDAY-1").count, 1, "the same occurrence in a new zone is not new")

        let tokyo = harness.provider.events(
            from: CalendarFixtures.instant("2027-03-01T00:00:00Z"),
            to: CalendarFixtures.instant("2027-03-10T00:00:00Z"),
            calendarIDs: ["cal-birthdays"]
        )
        XCTAssertEqual(CalendarNoteBuilder.identity(of: tokyo[0], deviceTimeZone: harness.timeZone)?.occurrence, "2027-03-04")
    }

    @MainActor
    func testOneIdentityInTwoCalendarsGivesOneNoteAndAReversedReadSendsNothing() async {
        let harness = Self.harness()
        harness.provider.addCalendar("cal-family", title: "Family")
        harness.provider.events = [
            Self.meeting("SHARED-1", calendar: "cal-work", title: "dinner", CalendarFixtures.at(2026, 10, 25, 18, 0), lastModified: "2026-10-18T12:00:00-06:00"),
            Self.meeting("SHARED-1", calendar: "cal-family", title: "dinner", CalendarFixtures.at(2026, 10, 25, 18, 0), lastModified: "2026-10-18T12:00:00-06:00"),
        ]
        await harness.setUpAndConfirm()
        let lines = harness.delivery.lines(event: "SHARED-1")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?["calendar"] as? String, "Family", "the calendar first by name wins")

        harness.provider.events.reverse()
        harness.provider.calendarList.reverse()
        harness.advance(minutes: 15)
        await harness.check()
        XCTAssertEqual(harness.delivery.lines(event: "SHARED-1").count, 1)
    }

    @MainActor
    func testAResyncThatGivesEveryCalendarANewIdentifierSendsNothingAndKeepsFollowing() async {
        let harness = Self.harness()
        harness.provider.addCalendar("cal-family", title: "Family")
        harness.provider.events = [
            Self.meeting("WORK-1", title: "review", CalendarFixtures.at(2026, 10, 26, 9, 0), lastModified: "2026-10-18T12:00:00-06:00"),
            Self.meeting("HOME-1", calendar: "cal-family", title: "school run", CalendarFixtures.at(2026, 10, 26, 8, 0), lastModified: "2026-10-17T12:00:00-06:00"),
        ]
        await harness.setUpAndConfirm()
        let sent = harness.delivery.lines.count
        XCTAssertEqual(sent, 2)

        Self.resync(harness, ["cal-work": "cal-work-2", "cal-family": "cal-family-2"])
        harness.advance(minutes: 20)
        await harness.check()
        XCTAssertEqual(harness.delivery.lines.count, sent, "a resync resends nothing")
        XCTAssertEqual(Set(harness.engine.calendars.filter(\.followed).map(\.id)), ["cal-work-2", "cal-family-2"])

        harness.provider.events[1].title = "school pick-up"
        harness.provider.events[1].lastModified = harness.now
        harness.advance(minutes: 1)
        await harness.check()
        XCTAssertEqual(harness.delivery.lines(event: "HOME-1").last?["title"] as? String, "school pick-up")
        XCTAssertEqual(harness.delivery.lines(event: "HOME-1").last?["change"] as? String, "changed")
    }

    // MARK: changes

    @MainActor
    func testAddedChangedMovedAndRemovedEachProduceExactlyOneCorrectNote() async {
        let harness = Self.harness()
        harness.provider.events = [
            Self.meeting("A", title: "planning", CalendarFixtures.at(2026, 10, 28, 14, 0), lastModified: "2026-10-15T10:00:00-06:00"),
        ]
        await harness.setUpAndConfirm()
        XCTAssertEqual(harness.delivery.lines.count, 1)

        harness.advance(minutes: 5)
        harness.provider.events.append(Self.meeting("B", title: "lunch", CalendarFixtures.at(2026, 10, 29, 12, 0), created: "2026-10-20T16:34:10-06:00"))
        await harness.check()
        XCTAssertEqual(harness.delivery.lines.count, 2)
        XCTAssertEqual(harness.delivery.lines(event: "B").map { $0["change"] as? String }, ["added"])
        XCTAssertEqual(harness.delivery.lines(event: "B").first?["changed_at"] as? String, "2026-10-20T16:34:10-06:00")

        harness.advance(minutes: 5)
        harness.provider.events[0].title = "planning, moved room"
        harness.provider.events[0].lastModified = CalendarFixtures.instant("2026-10-20T16:40:00-06:00")
        await harness.check()
        XCTAssertEqual(harness.delivery.lines.count, 3)
        let changed = harness.delivery.lines(event: "A").last!
        XCTAssertEqual(changed["change"] as? String, "changed")
        XCTAssertEqual(changed["title"] as? String, "planning, moved room")
        XCTAssertEqual(harness.engine.state.recent.first?.kind, .changed)

        harness.advance(minutes: 5)
        harness.provider.events[0].start = CalendarFixtures.at(2026, 10, 30, 14, 0)
        harness.provider.events[0].lastModified = CalendarFixtures.instant("2026-10-20T16:45:00-06:00")
        await harness.check()
        XCTAssertEqual(harness.delivery.lines.count, 4)
        let moved = harness.delivery.lines(event: "A").last!
        XCTAssertEqual(moved["change"] as? String, "changed")
        XCTAssertEqual(moved["start"] as? String, "2026-10-30T14:00:00-06:00")
        XCTAssertEqual(moved["end"] as? String, "2026-10-30T15:00:00-06:00")
        XCTAssertEqual(harness.engine.state.recent.first?.kind, .moved)

        harness.provider.events.removeFirst()
        harness.advance(minutes: 5)
        await harness.check()
        harness.advance(minutes: 10)
        await harness.check()
        XCTAssertEqual(harness.delivery.lines.count, 5)
        let removed = harness.delivery.lines(event: "A").last!
        XCTAssertEqual(removed["change"] as? String, "removed")
        XCTAssertEqual(removed["title"] as? String, "planning, moved room")
        XCTAssertEqual(removed["calendar"] as? String, "Work")
        XCTAssertTrue(removed["start"] is NSNull)
        XCTAssertEqual(harness.engine.state.recent.first?.kind, .removed)
        XCTAssertEqual(harness.engine.state.recent.first?.title, "planning, moved room")
    }

    @MainActor
    func testUnchangedEventsSendNothingIncludingSubscribedOnesAndAfterATimeZoneChange() async {
        let harness = Self.harness()
        harness.provider.addCalendar("cal-holidays", title: "US Holidays", account: "Subscribed Calendars")
        var floating = FakeCalendarEvent(calendarID: "cal-work", uid: "FLOAT-1", title: "gym", timing: .floating(minutes: 45), start: CalendarFixtures.at(2026, 10, 24, 7, 0), lastModified: CalendarFixtures.instant("2026-10-10T07:00:00-06:00"))
        floating.location = "the gym"
        harness.provider.events = [
            Self.meeting("ZONED-1", title: "1:1", CalendarFixtures.at(2026, 10, 23, 15, 0), zone: "Europe/Madrid", lastModified: "2026-10-11T07:00:00-06:00"),
            floating,
            FakeCalendarEvent(calendarID: "cal-work", uid: "OFFSITE-1", title: "offsite", timing: .allDay(days: 2), start: CalendarFixtures.at(2026, 11, 5), lastModified: CalendarFixtures.instant("2026-10-12T07:00:00-06:00")),
            FakeCalendarEvent(calendarID: "cal-holidays", uid: "veterans-day", title: "Veterans Day", timing: .allDay(days: 1), start: CalendarFixtures.at(2026, 11, 11), lastModified: CalendarFixtures.instant("1976-04-01T00:00:00Z")),
        ]
        await harness.setUpAndConfirm()
        let sent = harness.delivery.lines
        XCTAssertEqual(sent.count, 4)
        XCTAssertEqual(harness.delivery.lines(event: "FLOAT-1").first?["start"] as? String, "2026-10-24T07:00:00")
        XCTAssertEqual(harness.delivery.lines(event: "OFFSITE-1").first?["end"] as? String, "2026-11-07")

        harness.advance(minutes: 30)
        await harness.check()
        XCTAssertEqual(harness.delivery.lines, sent, "an unchanged event and an unchanged subscribed event send nothing")

        harness.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        harness.advance(minutes: 30)
        await harness.check()
        XCTAssertEqual(harness.delivery.lines, sent, "a time-zone change sends nothing")
    }

    @MainActor
    func testMissingPresentAndMissingAgainWithinTenMinutesSendsNothing() async {
        let harness = Self.harness()
        let event = Self.meeting("FLICKER-1", title: "standup", CalendarFixtures.at(2026, 10, 27, 9, 0), lastModified: "2026-10-15T10:00:00-06:00")
        harness.provider.events = [event]
        await harness.setUpAndConfirm()

        harness.provider.events = []
        harness.advance(minutes: 1)
        await harness.check()
        XCTAssertNotNil(harness.store.record.values.first?.firstMissingAt)

        harness.provider.events = [event]
        harness.advance(minutes: 5)
        await harness.check()
        XCTAssertNil(harness.store.record.values.first?.firstMissingAt, "seen again clears the first miss")

        harness.provider.events = []
        harness.advance(minutes: 7)
        await harness.check()
        XCTAssertEqual(Self.removedCount(harness), 0)

        harness.advance(minutes: 10)
        await harness.check()
        XCTAssertEqual(Self.removedCount(harness), 1, "the twin: ten minutes after its own first miss it goes")
    }

    @MainActor
    func testTwoMissesTenMinutesApartOnAFreshEngineSendOneRemoved() async {
        let harness = Self.harness()
        harness.provider.events = [Self.meeting("GONE-1", title: "vendor call", CalendarFixtures.at(2026, 10, 26, 11, 0), lastModified: "2026-10-15T10:00:00-06:00")]
        await harness.setUpAndConfirm()
        harness.provider.events = []
        harness.advance(minutes: 2)
        await harness.check()
        XCTAssertEqual(Self.removedCount(harness), 0)

        await harness.relaunch()
        harness.advance(minutes: 10)
        await harness.check()
        let removed = harness.delivery.lines(event: "GONE-1").filter { $0["change"] as? String == "removed" }
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed.first?["title"] as? String, "vendor call")
        XCTAssertEqual(removed.first?["calendar"] as? String, "Work")
    }

    @MainActor
    func testACalendarSwitchedOffBeforeAResyncStaysOffAndAFollowedDeletionIsStillRemoved() async {
        let harness = Self.harness()
        harness.provider.addCalendar("cal-family", title: "Family")
        harness.provider.events = [
            Self.meeting("W-1", title: "retro", CalendarFixtures.at(2026, 10, 27, 15, 0), lastModified: "2026-10-15T10:00:00-06:00"),
            Self.meeting("F-1", calendar: "cal-family", title: "recital", CalendarFixtures.at(2026, 10, 28, 18, 0), lastModified: "2026-10-15T11:00:00-06:00"),
        ]
        await harness.setUpAndConfirm()
        await harness.engine.setCalendar("cal-family", followed: false)
        let sent = harness.delivery.lines.count

        Self.resync(harness, ["cal-work": "cal-work-9", "cal-family": "cal-family-9"])
        harness.provider.events[1].title = "recital, new time"
        harness.provider.events[1].lastModified = harness.now
        harness.advance(minutes: 3)
        await harness.check()
        XCTAssertEqual(harness.engine.calendars.first { $0.id == "cal-family-9" }?.followed, false)
        XCTAssertEqual(harness.delivery.lines.count, sent, "an off calendar sends nothing")

        harness.provider.events.removeFirst()
        harness.advance(minutes: 1)
        await harness.check()
        harness.advance(minutes: 11)
        await harness.check()
        XCTAssertEqual(harness.delivery.lines(event: "W-1").last?["change"] as? String, "removed")
        XCTAssertEqual(harness.delivery.lines(event: "F-1").count, 1)
    }

    @MainActor
    func testAnEventMovedTwoYearsOutIsRemovedAndAddedWhenItReturns() async {
        let harness = Self.harness()
        harness.provider.events = [Self.meeting("FAR-1", title: "conference", CalendarFixtures.at(2026, 11, 3, 9, 0), lastModified: "2026-10-15T10:00:00-06:00")]
        await harness.setUpAndConfirm()
        harness.provider.events[0].start = CalendarFixtures.at(2028, 11, 3, 9, 0)
        harness.provider.events[0].lastModified = harness.now
        harness.advance(minutes: 1)
        await harness.check()
        harness.advance(minutes: 10)
        await harness.check()
        XCTAssertEqual(harness.delivery.lines(event: "FAR-1").map { $0["change"] as? String }, ["added", "removed"])

        harness.provider.events[0].start = CalendarFixtures.at(2027, 2, 3, 9, 0)
        harness.provider.events[0].lastModified = harness.now.addingTimeInterval(30)
        harness.advance(minutes: 1)
        await harness.check()
        XCTAssertEqual(harness.delivery.lines(event: "FAR-1").map { $0["change"] as? String }, ["added", "removed", "added"])
        XCTAssertEqual(harness.delivery.lines(event: "FAR-1").last?["start"] as? String, "2027-02-03T09:00:00-07:00")
    }

    // MARK: no removals without a readable, followed calendar

    @MainActor
    func testNoRemovalsForAnOffCalendarAVanishedCalendarWriteOnlyOrRevokedAccessOrPause() async {
        for scenario in ["off", "vanished", "write-only", "revoked", "paused"] {
            let harness = Self.harness()
            harness.provider.events = [
                Self.meeting("R-1", title: "one", CalendarFixtures.at(2026, 10, 26, 9, 0), lastModified: "2026-10-15T10:00:00-06:00"),
                Self.meeting("R-2", title: "two", CalendarFixtures.at(2026, 10, 27, 9, 0), lastModified: "2026-10-15T10:00:00-06:00"),
            ]
            await harness.setUpAndConfirm()
            let readsBefore = harness.provider.eventReads.count
            switch scenario {
            case "off":
                await harness.engine.setCalendar("cal-work", followed: false)
            case "vanished":
                harness.provider.calendarList = []
            case "write-only":
                harness.provider.accessValue = .writeOnly
            case "revoked":
                harness.provider.accessValue = .denied
            default:
                harness.engine.pause()
            }
            harness.provider.events = []
            for _ in 0..<4 {
                harness.advance(minutes: 11)
                await harness.check()
            }
            XCTAssertEqual(Self.removedCount(harness), 0, scenario)
            if ["write-only", "revoked", "paused"].contains(scenario) {
                XCTAssertEqual(harness.provider.eventReads.count, readsBefore, "\(scenario) reads nothing")
            }
        }
    }

    // MARK: changed_at

    @MainActor
    func testChangedAtUsesLastChangedThenCreationThenTheMomentNoticed() async {
        let harness = Self.harness()
        harness.provider.events = [
            Self.meeting("C-1", title: "edited", CalendarFixtures.at(2026, 10, 26, 9, 0), lastModified: "2026-10-14T10:11:12-06:00", created: "2026-10-01T09:00:00-06:00"),
            Self.meeting("C-2", title: "booked", CalendarFixtures.at(2026, 10, 26, 10, 0), created: "2026-10-02T08:07:06-06:00"),
            Self.meeting("C-3", title: "unknown", CalendarFixtures.at(2026, 10, 26, 11, 0)),
        ]
        await harness.setUpAndConfirm()
        XCTAssertEqual(harness.delivery.lines(event: "C-1").first?["changed_at"] as? String, "2026-10-14T10:11:12-06:00")
        XCTAssertEqual(harness.delivery.lines(event: "C-2").first?["changed_at"] as? String, "2026-10-02T08:07:06-06:00")
        XCTAssertEqual(harness.delivery.lines(event: "C-3").first?["changed_at"] as? String, "2026-10-20T16:31:00-06:00")
    }

    @MainActor
    func testThePlaceholderDateA1976DateAndAFutureDateAreNotBelieved() async {
        let harness = Self.harness()
        harness.provider.events = [
            Self.meeting("U-1", title: "placeholder", CalendarFixtures.at(2026, 10, 26, 9, 0), lastModified: "2001-01-01T00:00:00Z", created: "2026-10-03T03:03:03-06:00"),
            Self.meeting("U-2", title: "subscribed", CalendarFixtures.at(2026, 10, 26, 10, 0), lastModified: "1976-04-01T00:00:00Z", created: "2026-10-04T04:04:04-06:00"),
            Self.meeting("U-3", title: "future", CalendarFixtures.at(2026, 10, 26, 11, 0), lastModified: "2026-10-21T09:00:00-06:00", created: "2026-10-05T05:05:05-06:00"),
            Self.meeting("U-4", title: "nothing believable", CalendarFixtures.at(2026, 10, 26, 12, 0), lastModified: "1999-12-31T23:59:59Z", created: "2030-01-01T00:00:00Z"),
        ]
        await harness.setUpAndConfirm()
        XCTAssertEqual(harness.delivery.lines(event: "U-1").first?["changed_at"] as? String, "2026-10-03T03:03:03-06:00")
        XCTAssertEqual(harness.delivery.lines(event: "U-2").first?["changed_at"] as? String, "2026-10-04T04:04:04-06:00")
        XCTAssertEqual(harness.delivery.lines(event: "U-3").first?["changed_at"] as? String, "2026-10-05T05:05:05-06:00")
        XCTAssertEqual(harness.delivery.lines(event: "U-4").first?["changed_at"] as? String, "2026-10-20T16:31:00-06:00")
        XCTAssertNil(CalendarSourceEngine.believable(CalendarFixtures.instant("2001-01-01T00:00:00Z"), now: Date()))
        XCTAssertEqual(CalendarSourceEngine.believable(CalendarFixtures.instant("2001-01-01T00:00:01Z"), now: Date()), 978_307_201)
    }

    @MainActor
    func testASeriesEditStampsItsNewOccurrencesWithTheEditTime() async {
        let harness = Self.harness()
        var series = Self.meeting("WEEKLY-1", title: "review", CalendarFixtures.at(2026, 10, 22, 13, 0), lastModified: "2026-10-01T09:00:00-06:00")
        series.rule = CalendarRepeatRule(frequency: .weekly)
        series.occurrenceCount = 2
        harness.provider.events = [series]
        await harness.setUpAndConfirm()
        XCTAssertEqual(harness.delivery.lines(event: "WEEKLY-1").count, 2)

        harness.advance(minutes: 20)
        harness.provider.events[0].occurrenceCount = 4
        harness.provider.events[0].lastModified = CalendarFixtures.instant("2026-10-20T16:45:30-06:00")
        await harness.check()
        let added = harness.delivery.lines(event: "WEEKLY-1").dropFirst(2)
        XCTAssertEqual(added.count, 2)
        XCTAssertEqual(Set(added.compactMap { $0["changed_at"] as? String }), ["2026-10-20T16:45:30-06:00"])
        XCTAssertEqual(Set(added.compactMap { $0["occurrence"] as? String }), ["2026-11-05T20:00:00Z", "2026-11-12T20:00:00Z"])
    }

    @MainActor
    func testChangedAtIsStrictlyIncreasingPerIdentityInWholeSeconds() async {
        let harness = Self.harness()
        harness.provider.events = [Self.meeting("S-1", title: "first", CalendarFixtures.at(2026, 10, 26, 9, 0), lastModified: "2026-10-20T16:30:00.200-06:00", created: "2026-10-20T16:30:00.200-06:00")]
        await harness.setUpAndConfirm()

        // Changed again within the same second it was created.
        harness.provider.events[0].title = "second"
        harness.provider.events[0].lastModified = CalendarFixtures.instant("2026-10-20T16:30:00.800-06:00")
        harness.advance(minutes: 1)
        await harness.check()

        // The clock moves an hour backward, and an edit is stamped by it.
        harness.now = CalendarFixtures.instant("2026-10-20T15:40:00-06:00")
        harness.provider.events[0].title = "third"
        harness.provider.events[0].lastModified = CalendarFixtures.instant("2026-10-20T15:39:00-06:00")
        await harness.check()
        harness.provider.events = []
        harness.advance(minutes: 1)
        await harness.check()
        harness.advance(minutes: 11)
        await harness.check()

        let stamps = harness.delivery.lines(event: "S-1").compactMap { $0["changed_at"] as? String }
        XCTAssertEqual(stamps.count, 4)
        XCTAssertEqual(stamps[0], "2026-10-20T16:30:00-06:00")
        XCTAssertEqual(stamps[1], "2026-10-20T16:32:00-06:00")
        let seconds = stamps.map { CalendarWire.wholeSeconds(CalendarFixtures.instant($0)) }
        XCTAssertEqual(seconds, seconds.sorted())
        XCTAssertEqual(Set(seconds).count, seconds.count, "strictly increasing")
    }

    // MARK: spans

    @MainActor
    func testAFiveYearRangeReturnsEveryEventOnlyWhenReadInPages() async {
        let from = CalendarFixtures.instant("2021-10-20T00:00:00Z")
        let to = CalendarFixtures.instant("2026-10-20T00:00:00Z")
        let calendar = CalendarFollowRecord(key: "k", identifier: "cal-work", accountName: "iCloud", title: "Work", isBirthdays: false, followed: true, present: true)
        var daily = FakeCalendarEvent(calendarID: "cal-work", uid: "DAILY", title: "walk", timing: .zoned(zone: "UTC", minutes: 30), start: CalendarFixtures.at(2020, 10, 20, 12, 0))
        daily.rule = CalendarRepeatRule(frequency: .daily)

        var counts: [Int] = []
        for pageYears in [3, nil] as [Int?] {
            let harness = Self.harness()
            harness.provider.events = [daily]
            harness.settings.pageYears = pageYears
            await harness.relaunch()
            let events = await harness.engine.worker.read([calendar], from: from, to: to, birthdayFloor: from)
            counts.append(events.count)
        }
        XCTAssertEqual(counts[0], 1826, "five years, paged")
        XCTAssertEqual(counts[1], 1461, "one read is cut at its first four years")
    }

    @MainActor
    func testAllOfItBringsA1901EventAndACurrentYearEvent() async {
        let harness = Self.harness()
        harness.provider.events = [
            Self.meeting("OLD-1", title: "founding", CalendarFixtures.at(1901, 5, 1, 12, 0), zone: "UTC"),
            Self.meeting("NEW-1", title: "this year", CalendarFixtures.at(2026, 3, 1, 12, 0), lastModified: "2026-02-01T10:00:00-07:00"),
            Self.meeting("PRE-1", title: "too early", CalendarFixtures.at(1899, 12, 31, 12, 0), zone: "UTC"),
        ]
        await harness.setUpAndConfirm(.everything)
        XCTAssertEqual(harness.delivery.lines(event: "OLD-1").first?["start"] as? String, "1901-05-01T12:00:00+00:00")
        XCTAssertEqual(harness.delivery.lines(event: "NEW-1").first?["start"] as? String, "2026-03-01T12:00:00-07:00")
        XCTAssertTrue(harness.delivery.lines(event: "PRE-1").isEmpty)
    }

    @MainActor
    func testNothingFromBeforeTodayNeverSendsAnEventThatStartsBeforeTheSetupDay() async {
        let harness = Self.harness()
        harness.provider.events = [
            Self.meeting("YESTERDAY-1", title: "yesterday", CalendarFixtures.at(2026, 10, 19, 15, 0), lastModified: "2026-10-01T10:00:00-06:00"),
            Self.meeting("TODAY-1", title: "this morning", CalendarFixtures.at(2026, 10, 20, 8, 0), lastModified: "2026-10-01T10:00:00-06:00"),
        ]
        await harness.setUpAndConfirm(.fromToday)
        XCTAssertTrue(harness.delivery.lines(event: "YESTERDAY-1").isEmpty)
        XCTAssertEqual(harness.delivery.lines(event: "TODAY-1").count, 1)

        harness.provider.events[0].title = "yesterday, edited"
        harness.provider.events[0].lastModified = harness.now
        for days in [1.0, 20, 45] {
            harness.advance(days: days)
            await harness.check()
        }
        XCTAssertTrue(harness.delivery.lines(event: "YESTERDAY-1").isEmpty)
    }

    @MainActor
    func testAPhoneUnusedFor45DaysCatchesAnEventCreatedAndHeld40DaysAgo() async {
        let harness = Self.harness()
        await harness.setUpAndConfirm()
        harness.advance(days: 45)
        harness.provider.events = [
            Self.meeting("LATE-1", title: "while away", CalendarFixtures.at(2026, 10, 25, 10, 0), created: "2026-10-25T09:00:00-06:00"),
        ]
        harness.provider.events[0].lastModified = CalendarFixtures.instant("2026-10-25T09:00:00-06:00")
        await harness.check()
        XCTAssertEqual(harness.delivery.lines(event: "LATE-1").first?["changed_at"] as? String, "2026-10-25T09:00:00-06:00")
    }

    @MainActor
    func testBirthdaysStartAtTheSetupYearAndNeverBeforeTheSetupDayFromToday() async {
        for span in [CalendarSpanChoice.everything, .fromToday] {
            let harness = Self.harness()
            harness.provider.addCalendar("cal-birthdays", title: "Birthdays", birthdays: true)
            var birthday = FakeCalendarEvent(calendarID: "cal-birthdays", uid: "BDAY-1", title: "Lee's Birthday", timing: .allDay(days: 1), start: CalendarFixtures.at(1604, 2, 1))
            birthday.rule = CalendarRepeatRule(frequency: .yearly)
            var late = FakeCalendarEvent(calendarID: "cal-birthdays", uid: "BDAY-2", title: "Ari's Birthday", timing: .allDay(days: 1), start: CalendarFixtures.at(1604, 12, 1))
            late.rule = CalendarRepeatRule(frequency: .yearly)
            harness.provider.events = [birthday, late]
            await harness.setUpAndConfirm(span)
            let occurrences = harness.delivery.lines.compactMap { line -> String? in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["occurrence"] as? String
            }.sorted()
            if span == .everything {
                XCTAssertEqual(occurrences, ["2026-02-01", "2026-12-01", "2027-02-01"])
            } else {
                XCTAssertEqual(occurrences, ["2026-12-01", "2027-02-01"])
            }
        }
    }

    @MainActor
    func testACalendarFirstSeenAfterSetupBringsTheRoutineRangeAsAddedAndNothingOlder() async {
        let harness = Self.harness()
        await harness.setUpAndConfirm(.everything)
        harness.advance(minutes: 10)
        harness.provider.addCalendar("cal-club", title: "Club", account: "Exchange")
        harness.provider.events = [
            Self.meeting("CLUB-OLD", calendar: "cal-club", title: "last spring", CalendarFixtures.at(2026, 4, 1, 18, 0), lastModified: "2026-03-01T10:00:00-07:00"),
            Self.meeting("CLUB-RECENT", calendar: "cal-club", title: "last week", CalendarFixtures.at(2026, 10, 13, 18, 0), lastModified: "2026-10-01T10:00:00-06:00"),
            Self.meeting("CLUB-NEXT", calendar: "cal-club", title: "next month", CalendarFixtures.at(2026, 11, 17, 18, 0), lastModified: "2026-10-01T10:00:00-06:00"),
        ]
        await harness.check()
        XCTAssertEqual(harness.engine.calendars.first { $0.id == "cal-club" }?.followed, true)
        XCTAssertTrue(harness.delivery.lines(event: "CLUB-OLD").isEmpty)
        XCTAssertEqual(harness.delivery.lines(event: "CLUB-RECENT").map { $0["change"] as? String }, ["added"])
        XCTAssertEqual(harness.delivery.lines(event: "CLUB-NEXT").map { $0["change"] as? String }, ["added"])
    }

    @MainActor
    func testACalendarSwitchedOnAfterSetupBringsItsSetupSpanThroughACount() async {
        let harness = Self.harness()
        harness.provider.addCalendar("cal-family", title: "Family")
        harness.provider.events = [
            Self.meeting("FAM-OLD", calendar: "cal-family", title: "trip", CalendarFixtures.at(2026, 6, 1, 9, 0), lastModified: "2026-05-01T10:00:00-06:00"),
            Self.meeting("FAM-NEW", calendar: "cal-family", title: "party", CalendarFixtures.at(2026, 11, 7, 19, 0), lastModified: "2026-10-01T10:00:00-06:00"),
            Self.meeting("FAM-ANCIENT", calendar: "cal-family", title: "before the span", CalendarFixtures.at(2025, 1, 1, 9, 0), lastModified: "2024-12-01T10:00:00-07:00"),
        ]
        await harness.setUpAndConfirm(.lastYear, calendarIDs: ["cal-work"])
        XCTAssertTrue(harness.delivery.lines.isEmpty)

        harness.advance(days: 3)
        await harness.engine.setCalendar("cal-family", followed: true)
        XCTAssertEqual(harness.engine.calendars.first { $0.id == "cal-family" }?.importStep, .readyToConfirm(count: 2))
        await harness.check()
        XCTAssertTrue(harness.delivery.lines.isEmpty, "nothing comes in before the owner confirms")

        await harness.engine.confirmCalendar("cal-family")
        await harness.engine.waitUntilIdle()
        XCTAssertEqual(Set(harness.delivery.lines.compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["event"] as? String
        }), ["FAM-OLD", "FAM-NEW"])
        XCTAssertNil(harness.engine.calendars.first { $0.id == "cal-family" }?.importStep)
    }

    // MARK: import

    @MainActor
    func testTheCountEqualsTheLinesSentOnAFixtureWithAStraddlerAPageEdgeAndASharedIdentity() async {
        let harness = Self.harness()
        harness.provider.addCalendar("cal-family", title: "Family")
        harness.provider.events = [
            // Starts before the span and ends inside it: an event belongs where it starts.
            Self.meeting("STRADDLE-START", title: "overnight", CalendarFixtures.at(1900, 1, 1, 5, 0), minutes: 180, zone: "UTC"),
            // The span starts at 1900-01-01T00:00 in Denver, 07:00Z, and pages every three
            // years from there, so one page edge is 2026-01-01T07:00Z. This one spans it.
            Self.meeting("PAGE-EDGE", title: "late night", CalendarFixtures.at(2026, 1, 1, 6, 30), minutes: 120, zone: "UTC", lastModified: "2026-10-01T10:00:00-06:00"),
            // Starts inside the span and ends past one year ahead.
            Self.meeting("STRADDLE-END", title: "long build", CalendarFixtures.at(2027, 10, 19, 22, 0), minutes: 600, lastModified: "2026-10-02T10:00:00-06:00"),
            Self.meeting("SHARED", calendar: "cal-work", title: "all hands", CalendarFixtures.at(2026, 10, 30, 9, 0), lastModified: "2026-10-03T10:00:00-06:00"),
            Self.meeting("SHARED", calendar: "cal-family", title: "all hands", CalendarFixtures.at(2026, 10, 30, 9, 0), lastModified: "2026-10-03T10:00:00-06:00"),
            Self.meeting("PLAIN", title: "dentist", CalendarFixtures.at(2025, 3, 1, 9, 0), lastModified: "2025-02-01T10:00:00-07:00"),
        ]
        await harness.engine.setUp(span: .everything)
        XCTAssertEqual(harness.engine.setupStep, .readyToConfirm(count: 4))
        await harness.engine.confirm()
        await harness.engine.launch()
        await harness.engine.waitUntilIdle()
        XCTAssertEqual(harness.delivery.lines.count, 4)
        let events = harness.delivery.lines.compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["event"] as? String
        }
        XCTAssertEqual(events.sorted(), ["PAGE-EDGE", "PLAIN", "SHARED", "STRADDLE-END"])

        harness.advance(minutes: 10)
        await harness.check()
        XCTAssertEqual(harness.delivery.lines.count, 4, "the first routine check sends nothing again")
    }

    @MainActor
    func testAKillMidImportThenARelaunchFinishesTheFrozenSetWithNoIdentityTwice() async throws {
        let harness = Self.harness()
        harness.delivery.settlesAtOnce = false
        harness.provider.events = (0..<40).map { index in
            Self.meeting("BULK-\(index)", title: "item \(index)", CalendarFixtures.at(2026, 10, 21 + index % 5, 9, 0), lastModified: "2026-10-\(String(format: "%02d", 1 + index % 19))T10:00:00-06:00")
        }
        await harness.engine.setUp(span: .last30Days)
        guard case .readyToConfirm(let count) = harness.engine.setupStep else { return XCTFail("not counted") }
        XCTAssertEqual(count, 40)
        await harness.engine.confirm()
        XCTAssertEqual(harness.delivery.files.count, CalendarSourceEngine.Settings().importWindow)
        XCTAssertEqual(harness.engine.setupStep, .importing)

        harness.stopAt(.afterFileQueued(0))
        harness.delivery.settle()
        harness.engine.deliveryProgressed()
        await harness.engine.waitUntilIdle()

        while harness.engine.setupStep != .on {
            harness.delivery.settle()
            await harness.relaunch()
        }
        let identities = harness.delivery.files.flatMap(\.file.identityKeys)
        XCTAssertEqual(identities.count, 40)
        XCTAssertEqual(Set(identities).count, 40)
    }

    @MainActor
    func testAKillBetweenQueueingAndRecordingSendsNothingTwiceAndLosesNothing() async throws {
        let points: [CalendarStepPoint] = [.afterStepWritten, .afterRecordWritten, .afterFileQueued(0)]
        for point in points {
            for routine in [false, true] {
                let harness = Self.harness()
                harness.provider.events = (0..<6).map { index in
                    Self.meeting("K-\(index)", title: "item \(index)", CalendarFixtures.at(2026, 10, 22 + index, 9, 0), lastModified: "2026-10-1\(index)T10:00:00-06:00")
                }
                if routine {
                    await harness.setUpAndConfirm()
                    for index in 0..<6 {
                        harness.provider.events[index].title = "edited \(index)"
                        harness.provider.events[index].lastModified = CalendarFixtures.instant("2026-10-20T16:4\(index):00-06:00")
                    }
                    harness.advance(minutes: 15)
                    harness.stopAt(point)
                    await harness.check()
                } else {
                    await harness.engine.setUp(span: .last30Days)
                    harness.stopAt(point)
                    await harness.engine.confirm()
                    await harness.engine.waitUntilIdle()
                }
                await harness.relaunch()
                harness.advance(minutes: 1)
                await harness.check()

                let label = "\(point) routine=\(routine)"
                let expectedPerIdentity = routine ? 2 : 1
                var seen: [String: Set<String>] = [:]
                for pending in harness.delivery.files {
                    for key in pending.file.identityKeys {
                        seen[key, default: []].insert(pending.file.name)
                    }
                }
                XCTAssertEqual(seen.count, 6, label)
                XCTAssertTrue(seen.values.allSatisfy { $0.count == expectedPerIdentity }, label)
                XCTAssertEqual(harness.delivery.lines.count, 6 * expectedPerIdentity, label)
            }
        }
    }

    @MainActor
    func testAKillBetweenCountAndConfirmThenARelaunchSendsExactlyTheCountedSet() async {
        let harness = Self.harness()
        harness.provider.events = (0..<5).map { index in
            Self.meeting("CC-\(index)", title: "item \(index)", CalendarFixtures.at(2026, 10, 22 + index, 9, 0), lastModified: "2026-10-1\(index)T10:00:00-06:00")
        }
        await harness.engine.setUp(span: .last30Days)
        XCTAssertEqual(harness.engine.setupStep, .readyToConfirm(count: 5))

        await harness.relaunch()
        // Changes between the count and the confirm are not part of the counted set; the routine
        // check that follows the import picks them up.
        harness.provider.events.append(Self.meeting("CC-LATE", title: "late", CalendarFixtures.at(2026, 10, 29, 9, 0), lastModified: "2026-10-18T10:00:00-06:00"))
        harness.provider.events[0].title = "renamed"
        harness.provider.events[0].lastModified = CalendarFixtures.instant("2026-10-20T16:35:00-06:00")
        harness.advance(minutes: 10)
        XCTAssertEqual(harness.engine.setupStep, .readyToConfirm(count: 5))
        XCTAssertTrue(harness.delivery.lines.isEmpty)
        await harness.engine.confirm()
        await harness.engine.waitUntilIdle()

        var imported: [String] = []
        for pending in harness.delivery.files where imported.count < 5 {
            imported.append(contentsOf: String(decoding: pending.file.bytes, as: UTF8.self).split(separator: "\n").map(String.init))
        }
        XCTAssertEqual(imported.count, 5)
        XCTAssertTrue(imported.allSatisfy { $0.contains(#""change":"added""#) })
        XCTAssertFalse(imported.contains { $0.contains("CC-LATE") || $0.contains("renamed") })
        XCTAssertEqual(harness.delivery.lines(event: "CC-LATE").map { $0["change"] as? String }, ["added"])
        XCTAssertEqual(harness.delivery.lines(event: "CC-0").map { $0["title"] as? String }, ["item 0", "renamed"])
    }

    @MainActor
    func testAnImportWithNoJournalNeverPutsMoreThanTheWindowInTheQueue() async {
        let harness = Self.harness()
        harness.delivery.settlesAtOnce = false
        harness.provider.events = (0..<30).map { index in
            Self.meeting("W-\(index)", title: "item \(index)", CalendarFixtures.at(2026, 10, 21, 9, 0), lastModified: "2026-10-01T\(String(format: "%02d", index % 24)):\(String(format: "%02d", index * 7 % 60)):00-06:00")
        }
        await harness.setUpAndConfirm()
        for _ in 0..<5 {
            harness.engine.foreground()
            await harness.check()
        }
        XCTAssertEqual(harness.delivery.mostWaiting, CalendarSourceEngine.Settings().importWindow)
        XCTAssertEqual(harness.engine.setupStep, .importing)

        while harness.engine.setupStep == .importing {
            harness.delivery.settle(1)
            harness.engine.deliveryProgressed()
            await harness.engine.waitUntilIdle()
            XCTAssertLessThanOrEqual(harness.delivery.waiting, 3)
        }
        XCTAssertEqual(harness.delivery.lines.count, 30)
    }

    // MARK: checks

    @MainActor
    func testOverlappingTriggersGiveOneSetOfNotes() async {
        let harness = Self.harness()
        harness.provider.events = [Self.meeting("O-1", title: "one", CalendarFixtures.at(2026, 10, 26, 9, 0), lastModified: "2026-10-15T10:00:00-06:00")]
        await harness.setUpAndConfirm()
        harness.provider.events[0].title = "one, edited"
        harness.provider.events[0].lastModified = harness.now
        harness.advance(minutes: 1)
        harness.engine.storeChanged()
        harness.engine.foreground()
        harness.engine.storeChanged()
        async let refresh: Bool = harness.engine.backgroundRefresh()
        async let launched: Void = harness.engine.launch()
        _ = await (refresh, launched)
        await harness.engine.waitUntilIdle()
        XCTAssertEqual(harness.delivery.lines(event: "O-1").map { $0["change"] as? String }, ["added", "changed"])
    }

    @MainActor
    func testPauseThenResumeCoversEverythingSinceTheLastCheck() async {
        let harness = Self.harness()
        await harness.setUpAndConfirm()
        harness.engine.pause()
        harness.advance(days: 50)
        harness.provider.events = [
            Self.meeting("P-1", title: "during the pause", CalendarFixtures.at(2026, 11, 20, 9, 0), lastModified: "2026-11-15T10:00:00-07:00"),
            Self.meeting("P-2", title: "early in the pause", CalendarFixtures.at(2026, 10, 22, 9, 0), lastModified: "2026-10-21T10:00:00-06:00"),
        ]
        await harness.check()
        harness.engine.foreground()
        await harness.engine.waitUntilIdle()
        XCTAssertTrue(harness.delivery.lines.isEmpty, "a paused source sends nothing")
        await harness.engine.resume()
        XCTAssertEqual(Set(harness.delivery.lines.compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["event"] as? String
        }), ["P-1", "P-2"])
    }

    @MainActor
    func testACheckWithNoChangesOverAHundredThousandRecordedIdentitiesWritesNothingToTheRecord() async throws {
        let harness = Self.harness()
        harness.provider.events = [Self.meeting("LIVE-1", title: "kept", CalendarFixtures.at(2026, 10, 26, 9, 0), lastModified: "2026-10-15T10:00:00-06:00")]
        await harness.setUpAndConfirm()
        var record = harness.store.record
        let holders = record.values.first!.holders
        for index in 0..<100_000 {
            var entry = CalendarSentEntry(identity: CalendarIdentity(event: "PAST-\(index)", occurrence: nil))
            entry.fingerprint = "f\(index)"
            entry.changedAt = 1_600_000_000 + Int64(index)
            entry.startAt = 1_600_000_000 + Int64(index)
            entry.title = "past \(index)"
            entry.calendar = "Work"
            entry.holders = holders
            record["PAST-\(index)\u{1F}\u{0}"] = entry
        }
        try harness.store.replaceRecord(record)
        await harness.relaunch()
        XCTAssertEqual(harness.store.record.count, 100_001)
        let before = try FileManager.default.attributesOfItem(atPath: harness.store.recordURL.path)[.modificationDate] as? Date
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.recordJournalURL.path))

        harness.advance(minutes: 30)
        await harness.check()
        let after = try FileManager.default.attributesOfItem(atPath: harness.store.recordURL.path)[.modificationDate] as? Date
        XCTAssertEqual(harness.store.recordWriteCount, 0)
        XCTAssertEqual(before, after)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.recordJournalURL.path))
        XCTAssertEqual(harness.engine.state.lastCompletedCheck, harness.now)
    }

    @MainActor
    func testWithTheSourceNotSetUpEveryTriggerMakesZeroReads() async {
        let harness = Self.harness()
        harness.provider.accessValue = .full
        harness.provider.events = [Self.meeting("DARK-1", title: "never", CalendarFixtures.at(2026, 10, 26, 9, 0))]
        await harness.engine.launch()
        harness.engine.foreground()
        harness.engine.storeChanged()
        harness.provider.onChange?()
        await harness.engine.backgroundRefresh()
        harness.engine.deliveryProgressed()
        await harness.engine.waitUntilIdle()
        XCTAssertEqual(harness.provider.readCount, 0)
        XCTAssertEqual(harness.provider.accessRequests, 0)
        XCTAssertTrue(harness.delivery.files.isEmpty)
        XCTAssertEqual(harness.engine.setupStep, .notSetUp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.recordURL.path))
    }

    @MainActor
    func testTheImportSendsNothingForAnIdentityARoutineCheckSentFirst() async {
        let harness = Self.harness()
        // "Board" sorts before "Work", so the copy being switched on would win and is frozen as a
        // change; the routine check's newer edit must make the import drop it.
        harness.provider.addCalendar("cal-board", title: "Board")
        let shared = { (calendar: String) in
            Self.meeting("X", calendar: calendar, title: "board meeting", CalendarFixtures.at(2026, 10, 29, 9, 0), lastModified: "2026-10-12T10:00:00-06:00")
        }
        var boardCopy = shared("cal-board")
        boardCopy.location = "boardroom"
        harness.provider.events = [shared("cal-work"), boardCopy]
        await harness.setUpAndConfirm(.last30Days, calendarIDs: ["cal-work"])
        XCTAssertEqual(harness.delivery.lines(event: "X").count, 1)

        harness.advance(minutes: 5)
        await harness.engine.setCalendar("cal-board", followed: true)
        XCTAssertEqual(harness.engine.calendars.first { $0.id == "cal-board" }?.importStep, .readyToConfirm(count: 1))
        for index in harness.provider.events.indices {
            harness.provider.events[index].title = "board meeting, moved online"
            harness.provider.events[index].lastModified = harness.now
        }
        harness.advance(minutes: 1)
        await harness.check()
        await harness.engine.confirmCalendar("cal-board")
        await harness.engine.waitUntilIdle()
        harness.advance(minutes: 1)
        await harness.check()

        let lines = harness.delivery.lines(event: "X")
        XCTAssertEqual(lines.map { $0["change"] as? String }, ["added", "changed", "changed"])
        XCTAssertEqual(lines.dropFirst().map { $0["title"] as? String }, ["board meeting, moved online", "board meeting, moved online"])
        XCTAssertEqual(lines.map { $0["calendar"] as? String }, ["Work", "Work", "Board"])
        XCTAssertFalse(lines.contains { $0["calendar"] as? String == "Board" && $0["title"] as? String == "board meeting" }, "the import sent nothing for X")
    }

    @MainActor
    func testAfterAnAmbiguousResyncACalendarSwitchedBackOnThenADeletionSendsOneRemoved() async {
        let harness = Self.harness()
        harness.provider.calendarList = []
        harness.provider.addCalendar("cal-a", title: "Shared", account: "Exchange")
        harness.provider.addCalendar("cal-b", title: "Shared", account: "Exchange")
        harness.provider.events = [
            Self.meeting("AMB-1", calendar: "cal-a", title: "ops review", CalendarFixtures.at(2026, 10, 27, 9, 0), lastModified: "2026-10-12T10:00:00-06:00"),
        ]
        await harness.setUpAndConfirm()
        await harness.engine.setCalendar("cal-b", followed: false)
        XCTAssertEqual(harness.delivery.lines(event: "AMB-1").count, 1)

        Self.resync(harness, ["cal-a": "cal-a-2", "cal-b": "cal-b-2"])
        harness.advance(minutes: 3)
        await harness.check()
        XCTAssertEqual(harness.engine.calendars.filter(\.followed).count, 0)

        await harness.engine.setCalendar("cal-a-2", followed: true)
        await harness.engine.confirmCalendar("cal-a-2")
        await harness.engine.waitUntilIdle()
        XCTAssertEqual(harness.delivery.lines(event: "AMB-1").count, 1, "an unchanged event is not sent again")

        harness.provider.events.removeAll()
        harness.advance(minutes: 2)
        await harness.check()
        harness.advance(minutes: 11)
        await harness.check()
        XCTAssertEqual(harness.delivery.lines(event: "AMB-1").map { $0["change"] as? String }, ["added", "removed"])
    }

    @MainActor
    func testACalendarSwitchedOffAndBackOnSendsNothingOrExactlyTheOneEdit() async {
        for edited in [false, true] {
            let harness = Self.harness()
            harness.provider.addCalendar("cal-family", title: "Family")
            harness.provider.events = [
                Self.meeting("FO-1", calendar: "cal-family", title: "picnic", CalendarFixtures.at(2026, 10, 25, 12, 0), lastModified: "2026-10-10T10:00:00-06:00"),
                Self.meeting("FO-2", calendar: "cal-family", title: "movie", CalendarFixtures.at(2026, 10, 26, 19, 0), lastModified: "2026-10-11T10:00:00-06:00"),
            ]
            await harness.setUpAndConfirm()
            XCTAssertEqual(harness.delivery.lines.count, 2)
            await harness.engine.setCalendar("cal-family", followed: false)
            harness.advance(days: 2)
            if edited {
                harness.provider.events[1].title = "movie night"
                harness.provider.events[1].lastModified = CalendarFixtures.instant("2026-10-21T20:20:20-06:00")
            }
            await harness.check()
            await harness.engine.setCalendar("cal-family", followed: true)
            XCTAssertEqual(harness.engine.calendars.first { $0.id == "cal-family" }?.importStep, .readyToConfirm(count: edited ? 1 : 0))
            await harness.engine.confirmCalendar("cal-family")
            await harness.engine.waitUntilIdle()
            harness.advance(minutes: 5)
            await harness.check()
            if edited {
                XCTAssertEqual(harness.delivery.lines.count, 3)
                XCTAssertEqual(harness.delivery.lines(event: "FO-2").last?["change"] as? String, "changed")
                XCTAssertEqual(harness.delivery.lines(event: "FO-2").last?["changed_at"] as? String, "2026-10-21T20:20:20-06:00")
            } else {
                XCTAssertEqual(harness.delivery.lines.count, 2)
            }
        }
    }

    @MainActor
    func testAnIdentityEditedDuringAnImportGoesOutOncePerVersionWithIncreasingChangedAt() async {
        let harness = Self.harness()
        harness.provider.addCalendar("cal-alpha", title: "Alpha")
        harness.delivery.settlesAtOnce = false
        harness.provider.events = [
            Self.meeting("Y", calendar: "cal-work", title: "launch", CalendarFixtures.at(2026, 10, 30, 9, 0), lastModified: "2026-10-12T10:00:00-06:00"),
            Self.meeting("Y", calendar: "cal-alpha", title: "launch prep", CalendarFixtures.at(2026, 10, 30, 9, 0), lastModified: "2026-10-13T10:00:00-06:00"),
        ] + (0..<8).map { index in
            Self.meeting("ALPHA-\(index)", calendar: "cal-alpha", title: "alpha \(index)", CalendarFixtures.at(2026, 10, 22, 9, 0), lastModified: "2026-10-0\(index + 1)T10:00:00-06:00")
        }
        await harness.setUpAndConfirm(.last30Days, calendarIDs: ["cal-work"])
        harness.delivery.settle()

        await harness.engine.setCalendar("cal-alpha", followed: true)
        await harness.engine.confirmCalendar("cal-alpha")
        await harness.engine.waitUntilIdle()
        for index in 0..<2 {
            harness.provider.events[index].title = "launch, rescheduled"
            harness.provider.events[index].lastModified = CalendarFixtures.instant("2026-10-20T16:40:00-06:00")
        }
        harness.advance(minutes: 10)
        await harness.check()
        while harness.engine.calendars.first(where: { $0.id == "cal-alpha" })?.importStep != nil {
            harness.delivery.settle()
            harness.engine.deliveryProgressed()
            await harness.engine.waitUntilIdle()
        }
        harness.advance(minutes: 1)
        await harness.check()

        let lines = harness.delivery.lines(event: "Y")
        var versions: Set<String> = []
        for line in lines {
            let version = "\(line["title"] as? String ?? "")|\(line["calendar"] as? String ?? "")"
            XCTAssertTrue(versions.insert(version).inserted, "one line per version: \(version)")
        }
        let stamps = lines.compactMap { $0["changed_at"] as? String }.map { CalendarWire.wholeSeconds(CalendarFixtures.instant($0)) }
        XCTAssertEqual(stamps, stamps.sorted())
        XCTAssertEqual(Set(stamps).count, stamps.count)
        XCTAssertEqual(lines.last?["title"] as? String, "launch, rescheduled")
    }

    @MainActor
    func testAResyncMatchingTwoCalendarsWithOneOffBringsBothBackOff() async {
        let harness = Self.harness()
        harness.provider.calendarList = []
        harness.provider.addCalendar("cal-a", title: "Team", account: "Exchange")
        harness.provider.addCalendar("cal-b", title: "Team", account: "Exchange")
        await harness.setUpAndConfirm()
        await harness.engine.setCalendar("cal-b", followed: false)
        Self.resync(harness, ["cal-a": "cal-a-3", "cal-b": "cal-b-3"])
        harness.advance(minutes: 1)
        await harness.check()
        let calendars = harness.engine.calendars
        XCTAssertEqual(Set(calendars.map(\.id)), ["cal-a-3", "cal-b-3"])
        XCTAssertTrue(calendars.allSatisfy { !$0.followed })
        XCTAssertEqual(harness.engine.state.followedCount, 0)
        XCTAssertEqual(harness.engine.state.calendarCount, 2)
    }

    @MainActor
    func testTheLatestNotesTellAMoveFromAChange() async {
        let harness = Self.harness()
        harness.provider.events = [
            Self.meeting("M-1", title: "coffee", CalendarFixtures.at(2026, 10, 26, 9, 0), lastModified: "2026-10-15T10:00:00-06:00"),
            Self.meeting("M-2", title: "tea", CalendarFixtures.at(2026, 10, 27, 9, 0), lastModified: "2026-10-15T10:00:00-06:00"),
        ]
        await harness.setUpAndConfirm()
        harness.provider.events[0].start = CalendarFixtures.at(2026, 10, 26, 10, 0)
        harness.provider.events[0].lastModified = CalendarFixtures.instant("2026-10-20T16:35:00-06:00")
        harness.provider.events[1].start = CalendarFixtures.at(2026, 10, 27, 10, 0)
        harness.provider.events[1].title = "tea, upstairs"
        harness.provider.events[1].lastModified = CalendarFixtures.instant("2026-10-20T16:36:00-06:00")
        harness.advance(minutes: 10)
        await harness.check()
        let recent = harness.engine.state.recent
        XCTAssertEqual(recent.first { $0.title == "coffee" }?.kind, .moved)
        XCTAssertEqual(recent.first { $0.title == "tea, upstairs" }?.kind, .changed)
    }

    @MainActor
    func testALineThatFailsValidationIsSkippedRecordedAndNotRetried() async {
        let harness = Self.harness()
        var huge = Self.meeting("HUGE-1", title: "minutes", CalendarFixtures.at(2026, 10, 26, 9, 0), lastModified: "2026-10-15T10:00:00-06:00")
        huge.notes = String(repeating: "x", count: CalendarNoteFiles.maxBytes)
        harness.provider.events = [huge, Self.meeting("OK-1", title: "fine", CalendarFixtures.at(2026, 10, 26, 10, 0), lastModified: "2026-10-15T10:00:00-06:00")]
        await harness.setUpAndConfirm()
        XCTAssertTrue(harness.delivery.lines(event: "HUGE-1").isEmpty)
        XCTAssertEqual(harness.delivery.lines(event: "OK-1").count, 1)
        let recorded = harness.store.record.values.first { $0.event == "HUGE-1" }
        XCTAssertNotNil(recorded?.skipped)
        XCTAssertFalse(recorded?.wasSent ?? true)

        let writes = harness.store.recordWriteCount
        harness.advance(minutes: 10)
        await harness.check()
        XCTAssertTrue(harness.delivery.lines(event: "HUGE-1").isEmpty)
        XCTAssertEqual(harness.store.recordWriteCount, writes, "the skipped version is not tried again")

        harness.provider.events[0].notes = "short now"
        harness.provider.events[0].lastModified = harness.now
        harness.advance(minutes: 1)
        await harness.check()
        XCTAssertEqual(harness.delivery.lines(event: "HUGE-1").map { $0["change"] as? String }, ["added"])
    }

    // MARK: review fixes

    @MainActor
    func testARefreshDeliveredBeforeLaunchRunsExactlyOneCheckOnceLaunchFinishes() async {
        let harness = Self.harness()
        await harness.setUpAndConfirm()
        harness.advance(minutes: 30)
        harness.provider.events = [Self.meeting("BG-1", title: "seen in the background", CalendarFixtures.at(2026, 10, 26, 9, 0), lastModified: "2026-10-20T16:50:00-06:00")]
        harness.rebuild()
        let engine = harness.engine
        async let refreshed: Bool = engine.backgroundRefresh()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(engine.checkCount, 0, "nothing runs before the launch finishes")
        await engine.launch()
        let ranCheck = await refreshed
        XCTAssertTrue(ranCheck)
        await engine.waitUntilIdle()
        XCTAssertEqual(engine.checkCount, 1)
        XCTAssertEqual(harness.delivery.lines(event: "BG-1").count, 1)
    }

    @MainActor
    func testARefreshGivesItsTimeBackWhenTheLaunchNeverFinishes() async {
        let harness = Self.harness()
        await harness.setUpAndConfirm()
        harness.settings.launchWait = .milliseconds(300)
        harness.rebuild()
        let started = ContinuousClock.now
        let ranCheck = await harness.engine.backgroundRefresh()
        XCTAssertFalse(ranCheck, "the refresh task completes unsuccessfully")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        XCTAssertEqual(harness.engine.checkCount, 0)
    }

    @MainActor
    func testAStepAppendedAfterATornRecordAppendIsWhollyThereOnTheNextLoad() async throws {
        let harness = Self.harness()
        harness.provider.events = (0..<3).map { index in
            Self.meeting("T-\(index)", title: "item \(index)", CalendarFixtures.at(2026, 10, 22 + index, 9, 0), lastModified: "2026-10-1\(index)T10:00:00-06:00")
        }
        await harness.setUpAndConfirm()
        for index in 0..<3 {
            harness.provider.events[index].title = "edited \(index)"
            harness.provider.events[index].lastModified = CalendarFixtures.instant("2026-10-20T16:4\(index):00-06:00")
        }
        harness.advance(minutes: 15)
        harness.stopAt(.afterStepWritten)
        await harness.check()
        // A kill mid-append leaves a fragment with no newline.
        let handle = try FileHandle(forWritingTo: harness.store.recordJournalURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"T-0\u001f\u0000":{"e":"T-0","h":[],"r":fal"#.utf8))
        try handle.close()

        await harness.relaunch()
        harness.rebuild()
        let titles = harness.store.record.values.compactMap(\.title).sorted()
        XCTAssertEqual(titles, ["edited 0", "edited 1", "edited 2"])
        let journal = try Data(contentsOf: harness.store.recordJournalURL)
        XCTAssertEqual(journal.last, 0x0A)
    }

    @MainActor
    func testReadsAndNoteBuildingRunOffTheMainThread() async {
        let harness = Self.harness()
        var series = Self.meeting("OFF-MAIN", title: "standup", CalendarFixtures.at(2026, 10, 19, 9, 0), lastModified: "2026-10-01T10:00:00-06:00")
        series.rule = CalendarRepeatRule(frequency: .daily)
        series.occurrenceCount = 5
        series.moved[2] = FakeCalendarEvent.Override(start: CalendarFixtures.at(2026, 10, 21, 10, 0))
        harness.provider.events = [series]
        await harness.setUpAndConfirm()
        harness.advance(minutes: 5)
        await harness.check()
        XCTAssertGreaterThan(harness.provider.workerReads, 0)
        XCTAssertEqual(harness.provider.mainThreadReads, 0)
        XCTAssertGreaterThan(harness.provider.seriesLookups, 0, "the moved occurrence's repeat rule was looked up while building its note")
        XCTAssertEqual(harness.provider.mainThreadSeriesLookups, 0)
        XCTAssertEqual(harness.delivery.lines(event: "OFF-MAIN").count, 5)
    }

    @MainActor
    func testABurstOfChangeNoticesIsOneCheck() async throws {
        let harness = Self.harness()
        await harness.setUpAndConfirm()
        let handler = try XCTUnwrap(harness.provider.onChange, "observing starts once set up")
        let checks = harness.engine.checkCount
        for _ in 0..<10 {
            handler()
        }
        try await Task.sleep(for: .milliseconds(300))
        await harness.engine.waitUntilIdle()
        XCTAssertEqual(harness.engine.checkCount, checks + 1)
    }

    @MainActor
    func testSwitchingTheWinningCalendarOffAndOnSendsNothingAndAnEditSendsOneChange() async {
        let harness = Self.harness()
        harness.provider.addCalendar("cal-family", title: "Family")
        harness.provider.events = [
            Self.meeting("BOTH-1", calendar: "cal-work", title: "parents' evening", CalendarFixtures.at(2026, 10, 28, 18, 0), lastModified: "2026-10-14T10:00:00-06:00"),
            Self.meeting("BOTH-1", calendar: "cal-family", title: "parents' evening", CalendarFixtures.at(2026, 10, 28, 18, 0), lastModified: "2026-10-14T10:00:00-06:00"),
        ]
        await harness.setUpAndConfirm()
        XCTAssertEqual(harness.delivery.lines(event: "BOTH-1").map { $0["calendar"] as? String }, ["Family"])

        await harness.engine.setCalendar("cal-family", followed: false)
        harness.advance(minutes: 5)
        await harness.check()
        XCTAssertEqual(harness.delivery.lines(event: "BOTH-1").count, 1, "switching the winner off sends nothing")

        await harness.engine.setCalendar("cal-family", followed: true)
        XCTAssertEqual(harness.engine.calendars.first { $0.id == "cal-family" }?.importStep, .readyToConfirm(count: 0))
        await harness.engine.confirmCalendar("cal-family")
        harness.advance(minutes: 5)
        await harness.check()
        XCTAssertEqual(harness.delivery.lines(event: "BOTH-1").count, 1, "switching it back on sends nothing")

        for index in harness.provider.events.indices {
            harness.provider.events[index].title = "parents' evening, room 12"
            harness.provider.events[index].lastModified = CalendarFixtures.instant("2026-10-20T16:45:00-06:00")
        }
        harness.advance(minutes: 5)
        await harness.check()
        let lines = harness.delivery.lines(event: "BOTH-1")
        XCTAssertEqual(lines.map { $0["change"] as? String }, ["added", "changed"])
        XCTAssertEqual(lines.last?["title"] as? String, "parents' evening, room 12")
    }

    @MainActor
    func testAnEditToASharedEventIsNotHeldWhileItsWinningCalendarComesBackIn() async {
        for checkWhileOff in [true, false] {
            let harness = Self.harness()
            harness.provider.addCalendar("cal-family", title: "Family")
            harness.provider.events = [
                Self.meeting("HELD-1", calendar: "cal-work", title: "school play", CalendarFixtures.at(2026, 10, 29, 18, 0), lastModified: "2026-10-14T10:00:00-06:00"),
                Self.meeting("HELD-1", calendar: "cal-family", title: "school play", CalendarFixtures.at(2026, 10, 29, 18, 0), lastModified: "2026-10-14T10:00:00-06:00"),
            ]
            await harness.setUpAndConfirm()
            XCTAssertEqual(harness.delivery.lines(event: "HELD-1").map { $0["calendar"] as? String }, ["Family"])

            await harness.engine.setCalendar("cal-family", followed: false)
            if checkWhileOff {
                harness.advance(minutes: 5)
                await harness.check()
                XCTAssertEqual(harness.delivery.lines(event: "HELD-1").count, 1)
            }
            // Back on, and its import left unconfirmed.
            await harness.engine.setCalendar("cal-family", followed: true)
            for index in harness.provider.events.indices {
                harness.provider.events[index].title = "school play, 6:30 start"
                harness.provider.events[index].lastModified = CalendarFixtures.instant("2026-10-20T16:45:00-06:00")
            }
            harness.advance(minutes: 20)
            await harness.check()
            let lines = harness.delivery.lines(event: "HELD-1")
            XCTAssertEqual(lines.map { $0["change"] as? String }, ["added", "changed"], "checked while off: \(checkWhileOff)")
            XCTAssertEqual(lines.last?["title"] as? String, "school play, 6:30 start")
        }
    }

    @MainActor
    func testAPauseWhileTheWorkerChecksQueuesNothingAndResumeSendsIt() async throws {
        let harness = Self.harness()
        harness.provider.events = [Self.meeting("PAUSED-1", title: "dentist", CalendarFixtures.at(2026, 10, 27, 9, 0), lastModified: "2026-10-14T10:00:00-06:00")]
        await harness.setUpAndConfirm()
        harness.provider.events = []
        harness.advance(minutes: 1)
        await harness.check()
        harness.advance(minutes: 11)
        let filesBefore = harness.delivery.files.count

        let reached = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        harness.provider.readGate = {
            reached.withLock { $0 = true }
            release.wait()
        }
        harness.engine.foreground()
        while !reached.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        harness.engine.pause()
        harness.provider.readGate = nil
        release.signal()
        await harness.engine.waitUntilIdle()
        XCTAssertEqual(harness.delivery.files.count, filesBefore, "nothing is queued after a pause")
        XCTAssertNotEqual(harness.delivery.lines(event: "PAUSED-1").last?["change"] as? String, "removed")

        await harness.engine.resume()
        XCTAssertEqual(harness.delivery.lines(event: "PAUSED-1").map { $0["change"] as? String }, ["added", "removed"])
    }

    @MainActor
    func testAFailedRecordWriteLeavesNothingForTheNextAppendToLandOn() async throws {
        let harness = Self.harness()
        harness.provider.events = (0..<3).map { index in
            Self.meeting("W-\(index)", title: "item \(index)", CalendarFixtures.at(2026, 10, 22 + index, 9, 0), lastModified: "2026-10-1\(index)T10:00:00-06:00")
        }
        await harness.setUpAndConfirm()
        for index in 0..<3 {
            harness.provider.events[index].title = "edited \(index)"
            harness.provider.events[index].lastModified = CalendarFixtures.instant("2026-10-20T16:4\(index):00-06:00")
        }
        harness.advance(minutes: 15)
        // The write gets halfway, then fails.
        harness.store.journalWrite = { handle, line in
            try handle.write(contentsOf: line.prefix(line.count / 2))
            throw CocoaError(.fileWriteOutOfSpace)
        }
        await harness.check()
        harness.store.journalWrite = nil
        XCTAssertTrue(harness.delivery.lines(event: "W-0").allSatisfy { $0["title"] as? String == "item 0" })

        harness.advance(minutes: 1)
        await harness.check()
        harness.rebuild()
        XCTAssertEqual(harness.store.record.values.compactMap(\.title).sorted(), ["edited 0", "edited 1", "edited 2"])
        XCTAssertEqual(harness.delivery.lines(event: "W-0").last?["title"] as? String, "edited 0")
    }

    @MainActor
    func testRenamingTheWinningCalendarSendsOneChangeWithTheNewName() async {
        let harness = Self.harness()
        harness.provider.events = [Self.meeting("RENAME-1", title: "sprint review", CalendarFixtures.at(2026, 10, 28, 15, 0), lastModified: "2026-10-14T10:00:00-06:00")]
        await harness.setUpAndConfirm()
        harness.provider.calendarList = [CalendarInfo(identifier: "cal-work", title: "Job", accountName: "iCloud", isBirthdays: false)]
        harness.advance(minutes: 5)
        await harness.check()
        harness.advance(minutes: 5)
        await harness.check()
        let lines = harness.delivery.lines(event: "RENAME-1")
        XCTAssertEqual(lines.map { $0["change"] as? String }, ["added", "changed"])
        XCTAssertEqual(lines.map { $0["calendar"] as? String }, ["Work", "Job"])
    }

    @MainActor
    func testMovingAnEventBetweenTwoFollowedCalendarsSendsOneChange() async {
        let harness = Self.harness()
        harness.provider.addCalendar("cal-home", title: "Home")
        harness.provider.events = [Self.meeting("MOVE-1", title: "plumber", CalendarFixtures.at(2026, 10, 28, 8, 0), lastModified: "2026-10-14T10:00:00-06:00")]
        await harness.setUpAndConfirm()
        harness.provider.events[0].calendarID = "cal-home"
        harness.advance(minutes: 5)
        await harness.check()
        harness.advance(minutes: 15)
        await harness.check()
        let lines = harness.delivery.lines(event: "MOVE-1")
        XCTAssertEqual(lines.map { $0["change"] as? String }, ["added", "changed"])
        XCTAssertEqual(lines.map { $0["calendar"] as? String }, ["Work", "Home"])
    }

    @MainActor
    func testAnImportSightingClearsAFirstMiss() async {
        let harness = Self.harness()
        harness.provider.addCalendar("cal-family", title: "Family")
        harness.provider.events = [
            Self.meeting("MISS-1", calendar: "cal-work", title: "recital", CalendarFixtures.at(2026, 10, 28, 18, 0), lastModified: "2026-10-14T10:00:00-06:00"),
            Self.meeting("MISS-1", calendar: "cal-family", title: "recital", CalendarFixtures.at(2026, 10, 28, 18, 0), lastModified: "2026-10-14T10:00:00-06:00"),
        ]
        await harness.setUpAndConfirm(.last30Days, calendarIDs: ["cal-work"])
        harness.provider.events.removeFirst()
        harness.advance(minutes: 1)
        await harness.check()
        XCTAssertNotNil(harness.store.record.values.first?.firstMissingAt)

        await harness.engine.setCalendar("cal-family", followed: true)
        await harness.engine.confirmCalendar("cal-family")
        XCTAssertNil(harness.store.record.values.first?.firstMissingAt)
        harness.advance(minutes: 11)
        await harness.check()
        XCTAssertEqual(Self.removedCount(harness), 0)
    }

    func testBelievableComparesWholeSeconds() {
        XCTAssertEqual(
            CalendarSourceEngine.believable(CalendarFixtures.instant("2026-10-20T12:00:00.700Z"), now: CalendarFixtures.instant("2026-10-20T12:00:00.300Z")),
            CalendarWire.wholeSeconds(CalendarFixtures.instant("2026-10-20T12:00:00Z"))
        )
        XCTAssertNil(CalendarSourceEngine.believable(CalendarFixtures.instant("2026-10-20T12:00:01.000Z"), now: CalendarFixtures.instant("2026-10-20T12:00:00.300Z")))
        XCTAssertNil(CalendarSourceEngine.believable(CalendarFixtures.instant("2001-01-01T00:00:00.400Z"), now: Date()))
        XCTAssertEqual(CalendarSourceEngine.believable(CalendarFixtures.instant("2001-01-01T00:00:01.400Z"), now: Date()), 978_307_201)
    }

    @MainActor
    func testLaunchClearsStagingBeforeTheStepReplays() async {
        let harness = Self.harness()
        await harness.relaunch()
        XCTAssertEqual(harness.delivery.stagingClears, 1)
    }

    // MARK: helpers

    @MainActor
    static func resync(_ harness: CalendarHarness, _ identifiers: [String: String]) {
        harness.provider.calendarList = harness.provider.calendarList.map { info in
            CalendarInfo(identifier: identifiers[info.identifier] ?? info.identifier, title: info.title, accountName: info.accountName, isBirthdays: info.isBirthdays)
        }
        for index in harness.provider.events.indices {
            harness.provider.events[index].calendarID = identifiers[harness.provider.events[index].calendarID] ?? harness.provider.events[index].calendarID
        }
    }
}
