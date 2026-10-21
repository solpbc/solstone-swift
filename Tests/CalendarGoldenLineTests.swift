// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

/// The five golden lines of the calendar note contract, each produced byte for byte from a fake
/// event, under three device settings: the default, a 12-hour clock and a Buddhist calendar.
nonisolated final class CalendarGoldenLineTests: XCTestCase {
    static let golden1 = #"{"all_day":false,"attendees":[{"email":"alex@example.com","name":"Alex Rivera","status":"accepted","you":false},{"email":"owner@example.com","name":null,"status":"tentative","you":true}],"calendar":"Work","change":"added","changed_at":"2026-10-19T09:42:00-06:00","end":"2026-10-27T11:00:00-06:00","event":"6CF25C80-68D2-44D9-B52C-6CAD5BEC8C10","location":"room 4","notes":"bring the mocks","occurrence":null,"organizer":{"email":"alex@example.com","name":"Alex Rivera"},"repeats":null,"start":"2026-10-27T10:00:00-06:00","time_zone":"America/Denver","title":"design review","url":null,"v":1}"#
    static let golden2 = #"{"all_day":false,"attendees":[],"calendar":"Work","change":"changed","changed_at":"2026-10-20T16:30:00-06:00","end":"2026-10-21T09:45:00-06:00","event":"CCBF5C02-6D92-477A-AB25-1A2ED19E1D67","location":null,"notes":null,"occurrence":"2026-10-21T15:00:00Z","organizer":null,"repeats":"every weekday","start":"2026-10-21T09:30:00-06:00","time_zone":"America/Denver","title":"standup","url":null,"v":1}"#
    static let golden3 = #"{"all_day":true,"attendees":[],"calendar":"US Holidays","change":"added","changed_at":"2026-10-20T16:31:00-06:00","end":"2026-11-01","event":"48fa6175-2399-3bac-960a-fff947563ba7","location":null,"notes":null,"occurrence":null,"organizer":null,"repeats":null,"start":"2026-10-31","time_zone":null,"title":"Halloween","url":null,"v":1}"#
    static let golden4 = #"{"all_day":true,"attendees":[],"calendar":"Birthdays","change":"added","changed_at":"2026-10-20T16:31:00-06:00","end":"2027-01-21","event":"701BCFB9-A70C-42C2-873F-34990264C973","location":null,"notes":null,"occurrence":"2027-01-20","organizer":null,"repeats":"every year","start":"2027-01-20","time_zone":null,"title":"Kate Bell's Birthday","url":null,"v":1}"#
    static let golden5 = #"{"all_day":null,"attendees":[],"calendar":"Work","change":"removed","changed_at":"2026-10-22T08:05:12-06:00","end":null,"event":"6CF25C80-68D2-44D9-B52C-6CAD5BEC8C10","location":null,"notes":null,"occurrence":null,"organizer":null,"repeats":null,"start":null,"time_zone":null,"title":"design review","url":null,"v":1}"#

    struct DeviceSettings {
        let name: String
        let calendar: Calendar
    }

    static var settings: [DeviceSettings] {
        var standard = Calendar(identifier: .gregorian)
        standard.locale = Locale(identifier: "en_GB")
        var twelveHour = Calendar(identifier: .gregorian)
        twelveHour.locale = Locale(identifier: "en_US")
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.locale = Locale(identifier: "th_TH")
        return [
            DeviceSettings(name: "default", calendar: standard),
            DeviceSettings(name: "12-hour", calendar: twelveHour),
            DeviceSettings(name: "buddhist", calendar: buddhist),
        ]
    }

    /// The device settings really differ from the wire's fixed Gregorian, 24-hour form.
    func testTheDeviceSettingsUnderTestDiffer() {
        let settings = Self.settings
        XCTAssertEqual(
            settings[2].calendar.component(.year, from: CalendarFixtures.instant("2026-10-27T10:00:00-06:00")),
            2569
        )
        XCTAssertTrue(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: settings[1].calendar.locale)?.contains("a") == true)
        XCTAssertFalse(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: settings[0].calendar.locale)?.contains("a") == true)
    }

    @MainActor
    func testGoldenLine1AOneOffTimedMeetingAdded() async throws {
        for device in Self.settings {
            let harness = Self.harness(device, now: "2026-10-20T16:31:00-06:00")
            harness.provider.events.append(Self.designReview(device))
            await harness.setUpAndConfirm()
            XCTAssertEqual(harness.delivery.rawLines(event: "6CF25C80-68D2-44D9-B52C-6CAD5BEC8C10"), [Self.golden1], device.name)
        }
    }

    @MainActor
    func testGoldenLine2AMovedOccurrenceOfAWeekdaySeries() async throws {
        for device in Self.settings {
            let harness = Self.harness(device, now: "2026-10-20T16:00:00-06:00")
            var standup = FakeCalendarEvent(
                calendarID: "cal-work",
                uid: "CCBF5C02-6D92-477A-AB25-1A2ED19E1D67",
                title: "standup",
                timing: .zoned(zone: "America/Denver", minutes: 15),
                start: Self.components(CalendarFixtures.at(2026, 10, 12, 9, 0), zone: CalendarFixtures.denver, device),
                lastModified: CalendarFixtures.instant("2026-10-01T08:00:00-06:00"),
                created: CalendarFixtures.instant("2026-10-01T08:00:00-06:00")
            )
            standup.rule = CalendarRepeatRule(frequency: .weekly, daysOfWeek: [2, 3, 4, 5, 6])
            harness.provider.events.append(standup)
            await harness.setUpAndConfirm()
            XCTAssertEqual(harness.delivery.lines(event: "CCBF5C02-6D92-477A-AB25-1A2ED19E1D67").first?["changed_at"] as? String, "2026-10-01T08:00:00-06:00")

            // Tuesday's standup, the eighth occurrence, moves 30 minutes later.
            harness.provider.events[0].moved[7] = FakeCalendarEvent.Override(
                start: Self.components(CalendarFixtures.at(2026, 10, 21, 9, 30), zone: CalendarFixtures.denver, device),
                lastModified: CalendarFixtures.instant("2026-10-20T16:30:00-06:00")
            )
            harness.now = CalendarFixtures.instant("2026-10-20T16:35:00-06:00")
            await harness.check()

            let lines = harness.delivery.rawLines(event: "CCBF5C02-6D92-477A-AB25-1A2ED19E1D67")
                .filter { $0.contains(#""occurrence":"2026-10-21T15:00:00Z""#) }
            XCTAssertEqual(lines.count, 2, device.name)
            XCTAssertEqual(lines.last, Self.golden2, device.name)
        }
    }

    @MainActor
    func testGoldenLine3AOneDayAllDayEventFromASubscribedCalendar() async throws {
        for device in Self.settings {
            let harness = Self.harness(device, now: "2026-10-20T16:31:00-06:00")
            harness.provider.addCalendar("cal-holidays", title: "US Holidays", account: "Subscribed Calendars")
            harness.provider.events.append(Self.halloween(device))
            await harness.setUpAndConfirm()
            XCTAssertEqual(harness.delivery.rawLines(event: "48fa6175-2399-3bac-960a-fff947563ba7"), [Self.golden3], device.name)
        }
    }

    @MainActor
    func testGoldenLine4AnOccurrenceOfAYearlyAllDaySeries() async throws {
        for device in Self.settings {
            let harness = Self.harness(device, now: "2026-10-20T16:31:00-06:00")
            harness.provider.addCalendar("cal-birthdays", title: "Birthdays", account: "Other", birthdays: true)
            harness.provider.events.append(Self.kateBell(device))
            await harness.setUpAndConfirm()
            XCTAssertEqual(harness.delivery.rawLines(event: "701BCFB9-A70C-42C2-873F-34990264C973"), [Self.golden4], device.name)
        }
    }

    @MainActor
    func testGoldenLine5TheMeetingDeleted() async throws {
        for device in Self.settings {
            let harness = Self.harness(device, now: "2026-10-20T16:31:00-06:00")
            harness.provider.events.append(Self.designReview(device))
            await harness.setUpAndConfirm()
            harness.provider.events.removeAll()
            harness.now = CalendarFixtures.instant("2026-10-22T07:55:00-06:00")
            await harness.check()
            XCTAssertEqual(harness.delivery.rawLines(event: "6CF25C80-68D2-44D9-B52C-6CAD5BEC8C10"), [Self.golden1], "one miss sends nothing")
            harness.now = CalendarFixtures.instant("2026-10-22T08:05:12.700-06:00")
            await harness.check()
            XCTAssertEqual(harness.delivery.rawLines(event: "6CF25C80-68D2-44D9-B52C-6CAD5BEC8C10"), [Self.golden1, Self.golden5], device.name)
        }
    }

    // MARK: fixtures

    @MainActor
    static func harness(_ device: DeviceSettings, now: String) -> CalendarHarness {
        let harness = CalendarHarness(now: CalendarFixtures.instant(now))
        harness.provider.deviceCalendar = device.calendar
        harness.provider.addCalendar("cal-work", title: "Work")
        return harness
    }

    /// Gregorian wall-clock fields as the device's own calendar writes them.
    static func components(_ gregorian: DateComponents, zone: TimeZone, _ device: DeviceSettings) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let date = calendar.date(from: gregorian)!
        var deviceCalendar = device.calendar
        deviceCalendar.timeZone = zone
        return deviceCalendar.dateComponents([.era, .year, .month, .day, .hour, .minute, .second], from: date)
    }

    static func designReview(_ device: DeviceSettings) -> FakeCalendarEvent {
        var event = FakeCalendarEvent(
            calendarID: "cal-work",
            uid: "6CF25C80-68D2-44D9-B52C-6CAD5BEC8C10",
            title: "design review",
            timing: .zoned(zone: "America/Denver", minutes: 60),
            start: Self.components(CalendarFixtures.at(2026, 10, 27, 10, 0), zone: CalendarFixtures.denver, device),
            lastModified: CalendarFixtures.instant("2026-10-19T09:42:00.400-06:00"),
            created: CalendarFixtures.instant("2026-10-12T11:00:00-06:00")
        )
        event.location = "room 4"
        event.notes = "bring the mocks"
        event.organizer = CalendarFixtures.participant("Alex Rivera", "alex@example.com", .accepted)
        event.attendees = [
            CalendarFixtures.participant(nil, "owner@example.com", .tentative, you: true),
            CalendarFixtures.participant("Alex Rivera", "alex@example.com", .accepted),
        ]
        return event
    }

    static func halloween(_ device: DeviceSettings) -> FakeCalendarEvent {
        FakeCalendarEvent(
            calendarID: "cal-holidays",
            uid: "48fa6175-2399-3bac-960a-fff947563ba7",
            title: "Halloween",
            timing: .allDay(days: 1),
            start: Self.components(CalendarFixtures.at(2026, 10, 31), zone: CalendarFixtures.denver, device),
            lastModified: CalendarFixtures.instant("1976-04-01T00:00:00Z"),
            created: nil
        )
    }

    static func kateBell(_ device: DeviceSettings) -> FakeCalendarEvent {
        var event = FakeCalendarEvent(
            calendarID: "cal-birthdays",
            uid: "701BCFB9-A70C-42C2-873F-34990264C973",
            title: "Kate Bell's Birthday",
            timing: .allDay(days: 1),
            start: Self.components(CalendarFixtures.at(1604, 1, 20), zone: CalendarFixtures.denver, device)
        )
        event.rule = CalendarRepeatRule(frequency: .yearly)
        return event
    }
}
