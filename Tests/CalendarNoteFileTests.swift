// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

/// Calendar note files: deterministic bytes, windows, offsets, splitting, and the contract check.
nonisolated final class CalendarNoteFileTests: XCTestCase {
    static func line(
        _ event: String,
        occurrence: String? = nil,
        changedAt: String,
        zone: TimeZone = CalendarFixtures.denver,
        title: String = "t",
        notes: String? = nil
    ) -> CalendarFiledLine {
        let instant = CalendarWireInstant(CalendarFixtures.instant(changedAt), timeZone: zone)
        let content = CalendarNoteContent(
            identity: CalendarIdentity(event: event, occurrence: occurrence),
            calendar: "Work",
            account: "iCloud",
            title: title,
            location: nil,
            notes: notes,
            url: nil,
            start: "2026-10-27T10:00:00-06:00",
            end: "2026-10-27T11:00:00-06:00",
            allDay: false,
            timeZone: "America/Denver",
            organizer: nil,
            attendees: [],
            repeats: nil
        )
        let note = CalendarNoteLine(change: .added, changedAt: instant, content: content)
        return CalendarFiledLine(identity: content.identity, json: note.json!, window: instant.window!)
    }

    func testTheSameNotesInAnyOrderGiveByteIdenticalFilesAndNames() {
        let lines = [
            Self.line("B", changedAt: "2026-10-19T09:41:00-06:00"),
            Self.line("A", occurrence: "2026-10-21T15:00:00Z", changedAt: "2026-10-19T09:42:00-06:00"),
            Self.line("A", changedAt: "2026-10-19T09:43:00-06:00"),
            Self.line("C", occurrence: "2026-10-20", changedAt: "2026-10-19T09:44:59-06:00"),
        ]
        let forward = CalendarNoteFiles.files(from: lines)
        let backward = CalendarNoteFiles.files(from: lines.reversed())
        let shuffled = CalendarNoteFiles.files(from: [lines[2], lines[0], lines[3], lines[1]])
        XCTAssertEqual(forward.count, 1)
        XCTAssertEqual(forward, backward)
        XCTAssertEqual(forward, shuffled)
        XCTAssertEqual(forward[0].name, "calendar_\(CalendarWire.sha256Hex(forward[0].bytes)).jsonl")
        XCTAssertTrue(forward[0].name.range(of: #"^calendar_[0-9a-f]{64}\.jsonl$"#, options: .regularExpression) != nil)
        XCTAssertEqual(forward[0].bytes.last, 0x0A)
        let events = CalendarFixtures.lineObjects(forward[0].bytes).map { "\($0["event"]!)|\($0["occurrence"]!)" }
        XCTAssertEqual(events, ["A|<null>", "A|2026-10-21T15:00:00Z", "B|<null>", "C|2026-10-20"])
        XCTAssertEqual(forward[0].itemID, CalendarNoteFiles.itemID(sha256: forward[0].sha256))
        XCTAssertNotEqual(forward[0].itemID, CalendarNoteFiles.files(from: Array(lines.dropFirst()))[0].itemID)
    }

    func testTwoWindowsGiveTwoFiles() {
        let files = CalendarNoteFiles.files(from: [
            Self.line("A", changedAt: "2026-10-19T09:44:59-06:00"),
            Self.line("B", changedAt: "2026-10-19T09:45:00-06:00"),
        ])
        XCTAssertEqual(files.map(\.window.segment), ["094000_300", "094500_300"])
        XCTAssertEqual(files.map(\.window.day), ["20261019", "20261019"])
    }

    func testFiveThousandAndOneLinesOrMoreThanEightMebibytesSplitDeterministically() {
        let many = (0..<5_001).map { Self.line(String(format: "E%05d", $0), changedAt: "2026-10-19T09:41:00-06:00") }
        let split = CalendarNoteFiles.files(from: many.shuffled())
        XCTAssertEqual(split.map(\.lineCount), [5_000, 1])
        XCTAssertEqual(split, CalendarNoteFiles.files(from: many))
        XCTAssertEqual(CalendarFixtures.lineObjects(split[1].bytes).first?["event"] as? String, "E05000")
        XCTAssertEqual(Set(split.map(\.window)), [split[0].window])

        let notes = String(repeating: "n", count: 3 * 1024 * 1024)
        let big = (0..<4).map { Self.line("BIG-\($0)", changedAt: "2026-10-19T09:41:00-06:00", notes: notes) }
        let bySize = CalendarNoteFiles.files(from: big.reversed())
        XCTAssertEqual(bySize.map(\.lineCount), [2, 2])
        XCTAssertTrue(bySize.allSatisfy { $0.bytes.count <= CalendarNoteFiles.maxBytes })
        XCTAssertEqual(bySize, CalendarNoteFiles.files(from: big))
    }

    func testEachNoteLandsInTheRightWindowWithTheRightOffset() throws {
        // On a 5-minute boundary.
        let boundary = CalendarWireInstant(CalendarFixtures.instant("2026-10-19T10:05:00-06:00"), timeZone: CalendarFixtures.denver)
        XCTAssertEqual(boundary.rfc3339, "2026-10-19T10:05:00-06:00")
        XCTAssertEqual(boundary.window?.segment, "100500_300")

        // 10:04:59.6 is written 10:04:59 and filed in the window holding 10:04:59.
        let late = CalendarWireInstant(CalendarFixtures.instant("2026-10-19T10:04:59.600-06:00"), timeZone: CalendarFixtures.denver)
        XCTAssertEqual(late.rfc3339, "2026-10-19T10:04:59-06:00")
        XCTAssertEqual(late.window?.segment, "100000_300")

        // A change made in standard time, sent while the device is in daylight time, keeps the
        // offset of its own instant.
        let winter = CalendarWireInstant(CalendarFixtures.instant("2026-01-15T08:12:00-07:00"), timeZone: CalendarFixtures.denver)
        XCTAssertEqual(winter.rfc3339, "2026-01-15T08:12:00-07:00")
        XCTAssertEqual(winter.window?.segment, "081000_300")
        XCTAssertEqual(winter.window?.day, "20260115")
        XCTAssertEqual(winter.window?.offsetSeconds, -25_200)

        // Both halves of the autumn fold fall in the same named window.
        let first = CalendarWireInstant(CalendarFixtures.instant("2026-11-01T01:32:00-06:00"), timeZone: CalendarFixtures.denver)
        let second = CalendarWireInstant(CalendarFixtures.instant("2026-11-01T01:32:00-07:00"), timeZone: CalendarFixtures.denver)
        XCTAssertEqual(first.rfc3339, "2026-11-01T01:32:00-06:00")
        XCTAssertEqual(second.rfc3339, "2026-11-01T01:32:00-07:00")
        XCTAssertEqual(first.window, second.window)
        XCTAssertEqual(first.window?.segment, "013000_300")
    }

    @MainActor
    func testAStandardTimeChangeSentDuringDaylightTimeIsFiledByItsOwnOffset() async {
        let harness = CalendarHarness(now: CalendarFixtures.instant("2026-07-01T12:00:00-06:00"))
        harness.provider.addCalendar("cal-work", title: "Work")
        harness.provider.events = [CalendarSourceEngineTests.meeting("WINTER-1", title: "booked in january", CalendarFixtures.at(2026, 7, 10, 9, 0), lastModified: "2026-01-15T08:12:00-07:00")]
        await harness.setUpAndConfirm(.everything)
        let file = try! XCTUnwrap(harness.delivery.files.first)
        XCTAssertEqual(file.file.window.day, "20260115")
        XCTAssertEqual(file.file.window.segment, "081000_300")
        XCTAssertEqual(harness.delivery.lines(event: "WINTER-1").first?["changed_at"] as? String, "2026-01-15T08:12:00-07:00")
        XCTAssertEqual(CalendarTransfer.manifest(for: file).observerIngest?.utcOffsetSeconds, -25_200)
    }

    /// A zone whose offset then had seconds is written in UTC with `Z`, exact to the second. The
    /// time-zone data on this platform gives Europe/Amsterdam in 1901 an offset of whole minutes
    /// (it follows Brussels), so the rule is shown on Paris, whose 1901 offset was +00:09:21, and
    /// Amsterdam is held to whatever offset the platform reports.
    @MainActor
    func testAnAllOfItEventIn1901IsWrittenInUTCExactToTheSecondWhereItsOffsetHasSeconds() async {
        let paris = TimeZone(identifier: "Europe/Paris")!
        let amsterdam = TimeZone(identifier: "Europe/Amsterdam")!
        let localNoon1901 = CalendarFixtures.instant("1901-05-01T12:00:00Z")
        XCTAssertEqual(paris.secondsFromGMT(for: localNoon1901), 561)

        let harness = CalendarHarness(now: CalendarFixtures.instant("2026-10-20T16:31:00-06:00"))
        harness.provider.addCalendar("cal-work", title: "Work")
        harness.provider.events = [
            CalendarSourceEngineTests.meeting("PAR-1901", title: "opening", CalendarFixtures.at(1901, 5, 1, 12, 0), zone: "Europe/Paris"),
            CalendarSourceEngineTests.meeting("AMS-1901", title: "concert", CalendarFixtures.at(1901, 5, 1, 12, 0), zone: "Europe/Amsterdam"),
        ]
        await harness.setUpAndConfirm(.everything)
        let line = try! XCTUnwrap(harness.delivery.lines(event: "PAR-1901").first)
        XCTAssertEqual(line["start"] as? String, "1901-05-01T11:50:39Z")
        XCTAssertEqual(line["end"] as? String, "1901-05-01T12:50:39Z")
        XCTAssertEqual(line["time_zone"] as? String, "Europe/Paris")

        let amsterdamLine = try! XCTUnwrap(harness.delivery.lines(event: "AMS-1901").first)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = amsterdam
        let amsterdamStart = calendar.date(from: CalendarFixtures.at(1901, 5, 1, 12, 0))!
        let offset = amsterdam.secondsFromGMT(for: amsterdamStart)
        XCTAssertEqual(amsterdamLine["start"] as? String, offset % 60 == 0
            ? CalendarWireInstant(seconds: CalendarWire.wholeSeconds(amsterdamStart), offsetSeconds: offset).rfc3339
            : CalendarWire.utcZ(amsterdamStart))

        let changedAt = CalendarWireInstant(CalendarFixtures.instant("1901-05-01T11:50:39Z"), timeZone: paris)
        XCTAssertEqual(changedAt.rfc3339, "1901-05-01T11:50:39Z")
        XCTAssertEqual(changedAt.window?.segment, "115000_300")
    }

    func testALineThatFailsTheContractIsCaught() {
        let identity = CalendarIdentity(event: "E", occurrence: nil)
        let at = CalendarWireInstant(CalendarFixtures.instant("2026-10-19T09:42:00-06:00"), timeZone: CalendarFixtures.denver)
        func content(start: String?, end: String?, allDay: Bool?, event: String = "E", status: String = "accepted", notes: String? = nil) -> CalendarNoteContent {
            CalendarNoteContent(
                identity: CalendarIdentity(event: event, occurrence: nil),
                calendar: "Work", account: "iCloud", title: "t", location: nil, notes: notes, url: nil,
                start: start, end: end, allDay: allDay, timeZone: nil, organizer: nil,
                attendees: [CalendarNoteAttendee(name: nil, email: nil, status: status, you: false)], repeats: nil
            )
        }
        func problem(_ content: CalendarNoteContent, _ change: CalendarNoteChange = .added) -> CalendarNoteValidator.Problem? {
            CalendarNoteValidator.problem(with: CalendarNoteLine(change: change, changedAt: at, content: content))
        }
        XCTAssertNil(problem(content(start: "2026-10-27T10:00:00-06:00", end: "2026-10-27T11:00:00-06:00", allDay: false)))
        XCTAssertNil(problem(content(start: "2026-10-31", end: "2026-11-01", allDay: true)))
        XCTAssertNil(problem(content(start: "2026-10-27T10:00:00", end: nil, allDay: false)))
        XCTAssertEqual(problem(content(start: "2026-10-27T10:00:00-06:00", end: nil, allDay: false, event: "")), .emptyEvent)
        XCTAssertEqual(problem(content(start: nil, end: nil, allDay: false)), .start)
        XCTAssertEqual(problem(content(start: "2026-10-27", end: nil, allDay: false)), .start)
        XCTAssertEqual(problem(content(start: "2026-10-27T10:00:00-06:00", end: nil, allDay: nil)), .allDay)
        XCTAssertEqual(problem(content(start: "2026-10-27T10:00:00", end: "2026-10-27T11:00:00Z", allDay: false)), .end)
        XCTAssertEqual(problem(content(start: "2026-10-27T10:00:00-06:00", end: "2026-10-27T09:00:00-06:00", allDay: false)), .endBeforeStart)
        XCTAssertEqual(problem(content(start: "2026-10-27T10:00:00-06:00", end: nil, allDay: false, status: "maybe")), .attendeeStatus)
        XCTAssertEqual(problem(content(start: "2026-02-30", end: nil, allDay: true)), .start)
        XCTAssertEqual(problem(content(start: "2026-10-27T10:00:00-06:00", end: nil, allDay: false), .removed), .removedCarriesDetail)
        XCTAssertNil(problem(.removed(identity: identity, title: "t", calendar: "Work", account: "iCloud"), .removed))
        XCTAssertNil(problem(.removed(identity: identity, title: "t", calendar: "Work", account: nil), .removed))
        let huge = content(start: "2026-10-27T10:00:00-06:00", end: nil, allDay: false, notes: String(repeating: "x", count: CalendarNoteFiles.maxBytes))
        XCTAssertEqual(problem(huge), .tooLarge)
        let badOccurrence = CalendarNoteContent.removed(identity: CalendarIdentity(event: "E", occurrence: "soon"), title: nil, calendar: nil, account: nil)
        XCTAssertEqual(problem(badOccurrence, .removed), .occurrence)
    }

    func testStringsAreEscapedTheOneWayTheContractWritesThem() {
        let json = CalendarJSON.object([
            "b": .string("line\nbreak \"quoted\" back\\slash tab\t \u{01} café / 😀"),
            "a": .array([.int(1), .bool(false), .null]),
        ]).serialized
        XCTAssertEqual(json, #"{"a":[1,false,null],"b":"line\nbreak \"quoted\" back\\slash tab\t \u0001 café / 😀"}"#)
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertEqual(parsed?["b"] as? String, "line\nbreak \"quoted\" back\\slash tab\t \u{01} café / 😀")
    }

    func testTheTransferItemForAFileIsBuiltFromTheFileAlone() {
        let file = CalendarNoteFiles.files(from: [Self.line("A", changedAt: "2026-10-19T09:42:00-06:00")])[0]
        let pending = CalendarPendingFile(file: file, timeZoneIdentifier: "America/Denver")
        let manifest = CalendarTransfer.manifest(for: pending)
        XCTAssertEqual(manifest, CalendarTransfer.manifest(for: pending))
        XCTAssertEqual(manifest.itemID, file.itemID)
        XCTAssertEqual(manifest.source, "calendar")
        XCTAssertEqual(manifest.observerIngest?.day, "20261019")
        XCTAssertEqual(manifest.observerIngest?.segment, "094000_300")
        XCTAssertEqual(manifest.observerIngest?.startedAt, CalendarFixtures.instant("2026-10-19T09:40:00-06:00"))
        XCTAssertEqual(manifest.payloadParts.map(\.filename), [file.name])
        XCTAssertEqual(manifest.endpoint.path, "/app/devices/ingest")
        XCTAssertEqual(CalendarTransfer.noteCount(manifest), 1)
    }
}
