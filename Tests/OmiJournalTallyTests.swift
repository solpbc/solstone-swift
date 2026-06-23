// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class OmiJournalTallyTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmiJournalTallyTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    @MainActor
    func testPersistReloadRoundTrip() {
        let fileURL = self.fileURL()
        let tally = OmiJournalTally(fileURL: fileURL)

        tally.record(day: "20260623", durationS: 60, identity: "session:0")
        tally.record(day: "20260623", durationS: 120, identity: "session:1")

        let reloaded = OmiJournalTally(fileURL: fileURL)
        let day = reloaded.tally(for: "20260623")
        XCTAssertEqual(day?.segmentCount, 2)
        XCTAssertEqual(day?.totalSeconds, 180)
        XCTAssertEqual(day?.seenIdentities, ["session:0", "session:1"])
    }

    @MainActor
    func testRecordIsIdempotentForSameIdentityOnSameDay() {
        let tally = OmiJournalTally(fileURL: self.fileURL())

        tally.record(day: "20260623", durationS: 60, identity: "session:0")
        tally.record(day: "20260623", durationS: 60, identity: "session:0")

        let day = tally.tally(for: "20260623")
        XCTAssertEqual(day?.segmentCount, 1)
        XCTAssertEqual(day?.totalSeconds, 60)
        XCTAssertEqual(day?.seenIdentities, ["session:0"])
    }

    @MainActor
    func testSameIdentityOnDifferentDaysIsIndependent() {
        let tally = OmiJournalTally(fileURL: self.fileURL())

        tally.record(day: "20260622", durationS: 60, identity: "session:0")
        tally.record(day: "20260623", durationS: 120, identity: "session:0")

        XCTAssertEqual(tally.tally(for: "20260622")?.segmentCount, 1)
        XCTAssertEqual(tally.tally(for: "20260622")?.totalSeconds, 60)
        XCTAssertEqual(tally.tally(for: "20260623")?.segmentCount, 1)
        XCTAssertEqual(tally.tally(for: "20260623")?.totalSeconds, 120)
    }

    @MainActor
    func testMissingAndCorruptFilesFailOpenToEmpty() throws {
        let missing = OmiJournalTally(fileURL: self.fileURL("missing.json"))
        XCTAssertTrue(missing.payload.isEmpty)

        let corruptURL = self.fileURL("corrupt.json")
        try Data("{".utf8).write(to: corruptURL, options: .atomic)
        let corrupt = OmiJournalTally(fileURL: corruptURL)
        XCTAssertTrue(corrupt.payload.isEmpty)
    }

    @MainActor
    func testPrunesToSevenMostRecentKeysOnLoadAndRecord() throws {
        let fileURL = self.fileURL()
        try self.writePayload(
            Dictionary(uniqueKeysWithValues: (1...9).map { index in
                let day = String(format: "202606%02d", index)
                return (day, OmiJournalDayTally(segmentCount: 1, totalSeconds: 60, seenIdentities: [day]))
            }),
            to: fileURL
        )

        let tally = OmiJournalTally(fileURL: fileURL)
        XCTAssertEqual(tally.payload.keys.sorted(), [
            "20260603",
            "20260604",
            "20260605",
            "20260606",
            "20260607",
            "20260608",
            "20260609",
        ])

        tally.record(day: "20260610", durationS: 60, identity: "today")
        XCTAssertEqual(tally.payload.keys.sorted(), [
            "20260604",
            "20260605",
            "20260606",
            "20260607",
            "20260608",
            "20260609",
            "20260610",
        ])
        XCTAssertEqual(tally.tally(for: "20260610")?.seenIdentities, ["today"])

        let reloaded = OmiJournalTally(fileURL: fileURL)
        XCTAssertEqual(reloaded.payload.keys.sorted(), tally.payload.keys.sorted())
    }

    private func fileURL(_ name: String = "omi-journal-tally.json") -> URL {
        self.tempDirectory.appendingPathComponent(name, isDirectory: false)
    }

    private func writePayload(_ payload: OmiJournalTallyPayload, to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(payload).write(to: fileURL, options: .atomic)
    }
}
