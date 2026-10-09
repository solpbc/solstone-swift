// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

/// Items the phone stored under a segment name written in the 12-hour form are rewritten, once,
/// into the 24-hour name of the same date and time, and then reach the journal. Everything the
/// rewrite is not certain about is left exactly as it was, and counted.
nonisolated final class TransferSegmentRepairTests: XCTestCase {
    var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferSegmentRepairTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        TransferURLProtocol.reset()
    }

    override func tearDown() {
        TransferURLProtocol.reset()
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    // MARK: - through the engine

    func testRepairedKeyReachesTheWireThroughTheEngine() async throws {
        let root = self.tempDirectory.appendingPathComponent("wire", isDirectory: true)
        let spool = TransferSpool(rootURL: root)
        let itemID = Self.uuid(1)
        let stored = try Self.seedAttention(
            spool: spool,
            manifest: Self.manifest(itemID: itemID, segment: Self.twelveHourSegment)
        )
        let staleCache = try XCTUnwrap(Self.builtBody(of: stored, spool: spool))
        _ = try spool.writeBodyCache(staleCache, for: stored)
        XCTAssertEqual(Self.envelopeSegment(in: staleCache), Self.twelveHourSegment, "the cache is the body the old key was sent in")

        TransferURLProtocol.handler = Self.faithfulJournal()
        let engine = self.makeEngine(spool: TransferSpool(rootURL: root))
        self.pauseAtTeardown(engine)
        try await engine.start()
        await engine.noteNewConnectionEstablished()
        await engine.endpointAvailabilityChanged()
        try await self.waitFor("one dispatch") { TransferURLProtocol.bodies.count >= 1 }

        let sent = try XCTUnwrap(TransferURLProtocol.bodies.first)
        XCTAssertEqual(Self.envelopeSegment(in: sent), "085000_13")
        XCTAssertNotEqual(sent, staleCache, "the old cache must not be sent")
        try await self.waitFor("delivered") { (await engine.snapshot()).counters.deliveredCount == 1 }
        XCTAssertEqual(TransferURLProtocol.bodies.count, 1, "one send, no refusal")
        try Self.assertTheOriginalNameIsNotOnTheWire(sent)
    }

    func testAQueuedItemWithAStaleCacheIsSentUnderTheNewKey() async throws {
        let root = self.tempDirectory.appendingPathComponent("queued-wire", isDirectory: true)
        let spool = TransferSpool(rootURL: root)
        let itemID = Self.uuid(2)
        let stored = try Self.seedQueued(spool: spool, manifest: Self.manifest(itemID: itemID, segment: Self.twelveHourSegment))
        let staleCache = try XCTUnwrap(Self.builtBody(of: stored, spool: spool))
        _ = try spool.writeBodyCache(staleCache, for: stored)

        TransferURLProtocol.handler = Self.faithfulJournal()
        let engine = self.makeEngine(spool: TransferSpool(rootURL: root))
        self.pauseAtTeardown(engine)
        try await engine.start()
        try await self.waitFor("delivered") { (await engine.snapshot()).counters.deliveredCount == 1 }

        XCTAssertEqual(TransferURLProtocol.bodies.count, 1, "no refused send first")
        let sent = try XCTUnwrap(TransferURLProtocol.bodies.first)
        XCTAssertEqual(Self.envelopeSegment(in: sent), "085000_13")
        XCTAssertNotEqual(sent, staleCache)
        try Self.assertTheOriginalNameIsNotOnTheWire(sent)
    }

    // MARK: - the name grammar

    func testTwelveHourNamesMapToTheKeysTheFormatterGives() throws {
        let narrow = "\u{202F}"
        let table: [(stored: String, pinned: String)] = [
            ("101509\(narrow)PM_13", "221509_13"), ("101509\(narrow)pm_13", "221509_13"),
            ("104509\(narrow)AM_13", "104509_13"), ("104509\(narrow)am_13", "104509_13"),
            ("120500\(narrow)AM_13", "000500_13"), ("120500\(narrow)am_13", "000500_13"),
            ("123500\(narrow)PM_13", "123500_13"), ("123500\(narrow)pm_13", "123500_13"),
            ("85000\(narrow)AM_13", "085000_13"), ("85000\(narrow)am_13", "085000_13"),
            ("92000\(narrow)PM_13", "212000_13"), ("92000\(narrow)pm_13", "212000_13"),
            ("120000\(narrow)AM_1", "000000_1"),
            ("120000\(narrow)PM_300", "120000_300"),
            ("115959\(narrow)PM_86400", "235959_86400"),
            ("10000\(narrow)AM_13", "010000_13"),
        ]
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: -25_200))
        for (stored, pinned) in table {
            let ingest = Self.ingest(segment: stored, pinnedClock: String(pinned.prefix(6)), offset: -25_200)
            // The pinned formatter gives this key for this instant and zone.
            let duration = try XCTUnwrap(Double(pinned.split(separator: "_")[1]))
            XCTAssertEqual(ChunkSidecar.segmentString(for: ingest.startedAt, durationSeconds: duration, timeZone: zone), pinned, stored)
            guard case .repairable(let repair) = TransferSegmentRepair.verdict(for: ingest) else {
                XCTFail("not repairable: \(stored.unicodeScalars.map(\.value))")
                continue
            }
            XCTAssertEqual(repair.segment, pinned, "\(stored.unicodeScalars.map(\.value))")
            XCTAssertTrue(stored.contains(repair.dayPeriod.rawValue), "the marker is the one that was stored")
        }
    }

    func testNamesThatAreNotExactlyTheTwelveHourFormAreNotMatched() {
        let narrow = "\u{202F}"
        let notTwelveHour = [
            "13:37:24_13", "٠١٣٧٢٤_13", "133724\(narrow)PM_13", "0137240_13", "85000AM_13", "85000 AM_13",
            "85000\u{00A0}AM_13", "85000\(narrow)a.m._13", "", "85000\(narrow)AM", "133724",
            "85000\(narrow)Am_13", "85000\(narrow)aM_13", "85000\(narrow)AM_", "85000\(narrow)AM_13x",
            "85000\(narrow)AM_13\n", "85000\(narrow)AM_١٣", " 85000\(narrow)AM_13", "85000\(narrow)\(narrow)AM_13",
            "005000\(narrow)AM_13", "136000\(narrow)AM_13", "86000\(narrow)AM_13", "85060\(narrow)AM_13",
            "8500\(narrow)AM_13", "850000\(narrow)AM_13", "８５０００\(narrow)AM_13", "85000\(narrow)AM_13\u{0301}",
            "133724_13\n", "133724_", "_13", "13372_13", "1337245_13",
        ]
        for segment in notTwelveHour {
            let ingest = Self.ingest(segment: segment, pinnedClock: "085000", offset: -25_200)
            XCTAssertEqual(
                TransferSegmentRepair.verdict(for: ingest),
                .noTwelveHourMatch,
                "\(segment.unicodeScalars.map(\.value))"
            )
        }
        for segment in ["133724_13", "000000_1", "235959_86400"] {
            let ingest = Self.ingest(segment: segment, pinnedClock: "085000", offset: -25_200)
            XCTAssertEqual(TransferSegmentRepair.verdict(for: ingest), .wireForm, segment)
        }
        // A name in the exact 12-hour form whose day is not eight ASCII digits.
        for day in ["", "2026010", "202601050", "2026-01-05", "20260105\n", "２０２６０１０５", "٢٠٢٦٠١٠٥"] {
            var ingest = Self.ingest(segment: Self.twelveHourSegment, pinnedClock: "085000", offset: -25_200)
            ingest.day = day
            XCTAssertEqual(TransferSegmentRepair.verdict(for: ingest), .noTwelveHourMatch, "\(day.unicodeScalars.map(\.value))")
        }
    }

    // MARK: - the sanity check

    func testEveryFractionOfASecondIsRepairedAfterThePersistRoundTrip() throws {
        for fraction in [0.0, 0.4, 0.5, 0.999] {
            let startedAt = Self.startedAt.addingTimeInterval(fraction)
            let manifest = Self.manifest(itemID: Self.uuid(10), segment: Self.twelveHourSegment, startedAt: startedAt)
            let data = try TransferSpool.encoder().encode(manifest)
            let decoded = try TransferSpool.decoder().decode(TransferManifest.self, from: data)
            for ingest in [try XCTUnwrap(manifest.observerIngest), try XCTUnwrap(decoded.observerIngest)] {
                guard case .repairable(let repair) = TransferSegmentRepair.verdict(for: ingest) else {
                    XCTFail("fraction \(fraction) not repaired")
                    continue
                }
                XCTAssertEqual(repair.segment, "085000_13", "fraction \(fraction)")
            }
        }
    }

    func testTheProcessTimeZoneDoesNotDecideTheCheck() throws {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        NSTimeZone.default = try XCTUnwrap(TimeZone(secondsFromGMT: 50_400))
        XCTAssertEqual(NSTimeZone.default.secondsFromGMT(), 50_400)
        // Captured at -10:00; the process is at +14:00.
        let ingest = Self.ingest(segment: Self.twelveHourSegment, pinnedClock: "085000", offset: -36_000)
        XCTAssertEqual(TransferSegmentRepair.verdict(for: ingest), .repairable(.init(segment: "085000_13", dayPeriod: .upperAM)))
    }

    func testOffsetBoundaries() {
        let accepted = [0, 1, -1, 899, 900, 901, -899, -901, 19_800, 20_700, 45_900, -34_200, -43_200, 50_400, 3_601, 3_599]
        for offset in accepted {
            XCTAssertTrue(TransferSegmentRepair.isPlausibleOffset(offset), "\(offset)")
        }
        let rejected = [-43_201, 50_401, -43_500, 54_000, -46_800, 420, 2, -2, 898, 902, -25_620, 3_602, 3_598, 86_400, -86_400]
        for offset in rejected {
            XCTAssertFalse(TransferSegmentRepair.isPlausibleOffset(offset), "\(offset)")
        }
        // Through the verdict, at the edges: 12:00:00 AM is 00:00:00.
        let expectations: [(offset: Int, repairable: Bool)] = [
            (-43_200, true), (50_400, true), (-43_201, false), (50_401, false), (-25_620, false), (0, true),
        ]
        for (offset, repairable) in expectations {
            let ingest = Self.ingest(segment: "120000\u{202F}AM_13", pinnedClock: "000000", offset: offset)
            let verdict = TransferSegmentRepair.verdict(for: ingest)
            if repairable {
                XCTAssertEqual(verdict, .repairable(.init(segment: "000000_13", dayPeriod: .upperAM)), "\(offset)")
            } else {
                XCTAssertEqual(verdict, .sanityCheckFailed, "\(offset)")
            }
        }
    }

    func testTheCalendarIsRealAndTheDayArithmeticAgreesWithTheSystemCalendar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        for (year, month, day) in [(1970, 1, 1), (2026, 1, 5), (2000, 2, 29), (2024, 2, 29), (2100, 3, 1), (1900, 3, 1), (2026, 12, 31), (1969, 12, 31)] {
            let date = try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day)))
            XCTAssertEqual(
                TransferSegmentRepair.daysFromCivil(year: year, month: month, day: day) * 86_400,
                Int(date.timeIntervalSince1970),
                "\(year)-\(month)-\(day)"
            )
        }
        // A day that matches eight digits but is not a date is not repaired, and is counted as failing
        // the check, not as a name that is not in the 12-hour form.
        for day in ["20260230", "20260100", "20261301", "20250229", "20260431", "00000000"] {
            var ingest = Self.ingest(segment: Self.twelveHourSegment, pinnedClock: "085000", offset: -25_200)
            ingest.day = day
            XCTAssertEqual(TransferSegmentRepair.verdict(for: ingest), .sanityCheckFailed, day)
        }
        var leapDay = Self.ingest(segment: Self.twelveHourSegment, pinnedClock: "085000", offset: -25_200, day: "20240229")
        XCTAssertEqual(TransferSegmentRepair.verdict(for: leapDay), .repairable(.init(segment: "085000_13", dayPeriod: .upperAM)))
        leapDay.startedAt = Date(timeIntervalSince1970: .infinity)
        XCTAssertEqual(TransferSegmentRepair.verdict(for: leapDay), .sanityCheckFailed)
        leapDay.startedAt = Date(timeIntervalSince1970: 1e15)
        XCTAssertEqual(TransferSegmentRepair.verdict(for: leapDay), .sanityCheckFailed)
    }

    // MARK: - left alone

    func testLeftAloneItemsAreByteIdenticalAndCountedByWhyTheyWereLeft() async throws {
        let narrow = "\u{202F}"
        let root = self.tempDirectory.appendingPathComponent("left-alone", isDirectory: true)
        let spool = TransferSpool(rootURL: root)
        let notTwelveHour: [(segment: String, day: String)] = [
            ("13:37:24_13", Self.day), ("٠١٣٧٢٤_13", Self.day), ("133724\(narrow)PM_13", Self.day), ("0137240_13", Self.day),
            ("85000AM_13", Self.day), ("85000 AM_13", Self.day), ("85000\u{00A0}AM_13", Self.day),
            ("85000\(narrow)a.m._13", Self.day), ("", Self.day), ("85000\(narrow)AM", Self.day),
            (Self.twelveHourSegment, "2026010"),
        ]
        var seeded: [TransferStoredItem] = []
        for (index, entry) in notTwelveHour.enumerated() {
            let item = try Self.seedAttention(
                spool: spool,
                manifest: Self.manifest(itemID: Self.uuid(100 + index), segment: entry.segment, day: entry.day)
            )
            _ = try spool.writeBodyCache(Data("cache-\(index)".utf8), for: item)
            seeded.append(item)
        }
        let control = try Self.seedAttention(
            spool: spool,
            manifest: Self.manifest(itemID: Self.uuid(150), segment: "133724_13")
        )
        _ = try spool.writeBodyCache(Data("cache-control".utf8), for: control)
        let before = try Self.byteMap(of: spool.attentionDirectoryURL)

        _ = try spool.initialize(now: Self.launch)

        XCTAssertEqual(try Self.byteMap(of: spool.attentionDirectoryURL), before, "every manifest and cache is byte-identical")
        XCTAssertNil(try? Data(contentsOf: root.appendingPathComponent(TransferSpool.segmentRepairTallyFilename)), "nothing was repaired, so nothing was counted")

        let engine = self.makeEngine(spool: TransferSpool(rootURL: root))
        self.pauseAtTeardown(engine)
        try await engine.initialize()
        let export = await Self.exportRows(engine: engine, now: Self.launch)
        XCTAssertEqual(
            export.detail.unrepairedSegmentNames,
            UnrepairedSegmentNameCounts(noTwelveHourMatch: notTwelveHour.count, sanityCheckFailed: 0),
            "the count equals the number left alone with a name the wire refuses; the wire-form control is not counted"
        )
        XCTAssertEqual(try Self.byteMap(of: spool.attentionDirectoryURL), before, "building the export reads, never writes")
        let expectedLines = SegmentRepairExport(tally: .empty, unrepaired: export.detail.unrepairedSegmentNames).lines(now: Self.launch)
        XCTAssertFalse(expectedLines.isEmpty)
        for line in expectedLines {
            XCTAssertTrue(export.lines.contains(line), line)
        }
    }

    func testAFailedSanityCheckLeavesTheItemAndIsCountedSeparately() async throws {
        let root = self.tempDirectory.appendingPathComponent("sanity-failed", isDirectory: true)
        let spool = TransferSpool(rootURL: root)
        // Seven minutes from the nearest quarter hour: the clock and the start instant disagree.
        let skewed = Self.startedAt.addingTimeInterval(420)
        let skewedItem = try Self.seedAttention(
            spool: spool,
            manifest: Self.manifest(itemID: Self.uuid(200), segment: Self.twelveHourSegment, startedAt: skewed)
        )
        _ = try spool.writeBodyCache(Data("cache-skewed".utf8), for: skewedItem)
        let good = try Self.seedAttention(
            spool: spool,
            manifest: Self.manifest(itemID: Self.uuid(201), segment: Self.twelveHourSegment)
        )
        let before = try Self.byteMap(of: spool.attentionDirectoryURL.appendingPathComponent(skewedItem.manifest.itemID.uuidString))

        let snapshot = try spool.initialize(now: Self.launch)

        XCTAssertEqual(
            try Self.byteMap(of: spool.attentionDirectoryURL.appendingPathComponent(skewedItem.manifest.itemID.uuidString)),
            before
        )
        XCTAssertEqual(snapshot.attention.first { $0.manifest.itemID == good.manifest.itemID }?.manifest.observerIngest?.segment, "085000_13")
        let engine = self.makeEngine(spool: TransferSpool(rootURL: root))
        self.pauseAtTeardown(engine)
        try await engine.initialize()
        let export = await Self.exportRows(engine: engine, now: Self.launch)
        XCTAssertEqual(export.detail.unrepairedSegmentNames, UnrepairedSegmentNameCounts(noTwelveHourMatch: 0, sanityCheckFailed: 1))
        XCTAssertEqual(export.detail.segmentRepairTally.repaired, 1)
    }

    // MARK: - isolation of failures

    func testAFailedWriteAfterTheDeleteLeavesTheItemAsItWasAndTheNextLaunchRepairsIt() async throws {
        let root = self.tempDirectory.appendingPathComponent("write-fails", isDirectory: true)
        let plain = TransferSpool(rootURL: root)
        let ids = [Self.uuid(301), Self.uuid(302), Self.uuid(303)]
        for (index, id) in ids.enumerated() {
            let item = try Self.seedAttention(plain, Self.fixtures[index], id)
            _ = try plain.writeBodyCache(Data("cache-\(index)".utf8), for: item)
        }
        let victim = ids[1]
        let victimDirectory = plain.attentionDirectoryURL.appendingPathComponent(victim.uuidString, isDirectory: true)
        let manifestBefore = try Data(contentsOf: victimDirectory.appendingPathComponent(TransferSpool.manifestFilename))
        XCTAssertTrue(plain.bodyCacheExists(for: TransferStoredItem(manifest: Self.manifest(itemID: victim, segment: ""), directoryURL: victimDirectory)))

        let faults = RepairFaultFileSystem()
        faults.failManifestReplace(for: [victim])
        let faulted = TransferSpool(rootURL: root, fileSystem: faults)
        let snapshot = try faulted.initialize(now: Self.launch)

        XCTAssertEqual(try Data(contentsOf: victimDirectory.appendingPathComponent(TransferSpool.manifestFilename)), manifestBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: victimDirectory.appendingPathComponent(TransferSpool.bodyUploadFilename).path), "its cache was already deleted")
        XCTAssertEqual(Self.segments(in: snapshot.attention)[victim], Self.fixtures[1].stored, "the snapshot keeps the old name")
        XCTAssertEqual(Self.segments(in: snapshot.attention)[ids[0]], Self.fixtures[0].repaired)
        XCTAssertEqual(Self.segments(in: snapshot.attention)[ids[2]], Self.fixtures[2].repaired)
        XCTAssertEqual(plain.segmentRepairTally().repaired, 2)
        XCTAssertEqual(plain.segmentRepairTally().failures, 1)

        faults.failManifestReplace(for: [])
        let second = try faulted.initialize(now: Self.launch.addingTimeInterval(60))
        XCTAssertEqual(Self.segments(in: second.attention)[victim], Self.fixtures[1].repaired)
        XCTAssertEqual(plain.segmentRepairTally().repaired, 3)
        XCTAssertEqual(plain.segmentRepairTally().failures, 1)

        TransferURLProtocol.handler = Self.faithfulJournal()
        let engine = self.makeEngine(spool: TransferSpool(rootURL: root))
        self.pauseAtTeardown(engine)
        try await engine.start()
        await engine.noteNewConnectionEstablished()
        await engine.endpointAvailabilityChanged()
        try await self.waitFor("all three sent") { TransferURLProtocol.bodies.count >= 3 }
        XCTAssertEqual(Self.sentSegments()[victim], Self.fixtures[1].repaired)
    }

    func testAFailedDeleteLeavesTheManifestAndTheCacheAsTheyWereAndTheOthersAreRepaired() async throws {
        let root = self.tempDirectory.appendingPathComponent("delete-fails", isDirectory: true)
        let plain = TransferSpool(rootURL: root)
        let ids = [Self.uuid(311), Self.uuid(312), Self.uuid(313)]
        for (index, id) in ids.enumerated() {
            let item = try Self.seedAttention(plain, Self.fixtures[index], id)
            _ = try plain.writeBodyCache(Data("cache-\(index)".utf8), for: item)
        }
        let victim = ids[0]
        let victimDirectory = plain.attentionDirectoryURL.appendingPathComponent(victim.uuidString, isDirectory: true)
        let before = try Self.byteMap(of: victimDirectory)

        let faults = RepairFaultFileSystem()
        faults.failBodyDelete(for: [victim])
        let faulted = TransferSpool(rootURL: root, fileSystem: faults)
        let snapshot = try faulted.initialize(now: Self.launch)

        XCTAssertEqual(try Self.byteMap(of: victimDirectory), before, "manifest and cache are byte-identical")
        XCTAssertEqual(Self.segments(in: snapshot.attention)[victim], Self.fixtures[0].stored)
        XCTAssertEqual(Self.segments(in: snapshot.attention)[ids[1]], Self.fixtures[1].repaired)
        XCTAssertEqual(Self.segments(in: snapshot.attention)[ids[2]], Self.fixtures[2].repaired)
        XCTAssertEqual(plain.segmentRepairTally().repaired, 2)
        XCTAssertEqual(plain.segmentRepairTally().failures, 1)

        faults.failBodyDelete(for: [])
        let second = try faulted.initialize(now: Self.launch.addingTimeInterval(60))
        XCTAssertEqual(Self.segments(in: second.attention)[victim], Self.fixtures[0].repaired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: victimDirectory.appendingPathComponent(TransferSpool.bodyUploadFilename).path))
    }

    func testATallyThatCannotBeWrittenNeverStopsARepair() throws {
        let root = self.tempDirectory.appendingPathComponent("tally-unwritable", isDirectory: true)
        let plain = TransferSpool(rootURL: root)
        try Self.seedAttention(plain, Self.fixtures[0], Self.uuid(321))
        let faults = RepairFaultFileSystem()
        faults.failTallyWrite(true)

        let snapshot = try TransferSpool(rootURL: root, fileSystem: faults).initialize(now: Self.launch)

        XCTAssertEqual(Self.segments(in: snapshot.attention)[Self.uuid(321)], Self.fixtures[0].repaired)
        XCTAssertEqual(plain.segmentRepairTally(), .empty)
    }

    // MARK: - attention stays attention

    func testARepairedAttentionItemStaysInAttentionWithItsRecordUntouched() async throws {
        let root = self.tempDirectory.appendingPathComponent("attention-invariants", isDirectory: true)
        let spool = TransferSpool(rootURL: root)
        let itemID = Self.uuid(401)
        let movedAt = Date(timeIntervalSince1970: 1_767_700_123)
        let refusedUnder = TransferRefusalConditions(
            appBuild: "build-a",
            pairingIdentity: "pairing-a",
            journalVersion: "2.0.37",
            endpointPath: "/app/devices/ingest",
            source: "alpha",
            day: Self.day,
            segment: Self.twelveHourSegment,
            ingestProtocolVersion: 3
        )
        var manifest = Self.manifest(itemID: itemID, segment: Self.twelveHourSegment)
        manifest.retryCount = 2
        manifest.lastRetriedAt = Date(timeIntervalSince1970: 1_767_690_000)
        manifest.appVersion = "2.0.6"
        let stored = try Self.seedAttention(spool: spool, manifest: manifest, refusedUnder: refusedUnder, movedAt: movedAt)
        _ = try spool.writeBodyCache(Data("cache".utf8), for: stored)
        let attentionBefore = try XCTUnwrap(stored.manifest.attention)
        XCTAssertEqual(attentionBefore.refusedUnder, refusedUnder)

        let snapshot = try spool.initialize(now: Self.launch)

        let repaired = try XCTUnwrap(snapshot.attention.first { $0.manifest.itemID == itemID })
        XCTAssertFalse(snapshot.queued.contains { $0.manifest.itemID == itemID })
        XCTAssertEqual(repaired.directoryURL, spool.attentionDirectoryURL.appendingPathComponent(itemID.uuidString, isDirectory: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.queuedDirectoryURL.appendingPathComponent(itemID.uuidString).path))
        XCTAssertEqual(repaired.manifest.diskState, .attention)
        XCTAssertEqual(repaired.manifest.attention, attentionBefore)
        XCTAssertEqual(repaired.manifest.attention?.movedAt, movedAt)
        XCTAssertEqual(repaired.manifest.attention?.refusedUnder, refusedUnder)
        XCTAssertEqual(repaired.manifest.observerIngest?.segment, "085000_13")
        XCTAssertEqual(repaired.manifest.observerIngest?.segmentRepairedFrom, Self.twelveHourSegment)
        // Nothing else in the manifest moved.
        var expected = stored.manifest
        expected.observerIngest?.segment = "085000_13"
        expected.observerIngest?.segmentRepairedFrom = Self.twelveHourSegment
        XCTAssertEqual(repaired.manifest, expected)
        XCTAssertEqual(try spool.readManifest(in: repaired.directoryURL), expected, "and the disk agrees")
        XCTAssertFalse(spool.bodyCacheExists(for: repaired))

        // The engine's snapshot shows the new key.
        let engine = self.makeEngine(spool: TransferSpool(rootURL: root))
        self.pauseAtTeardown(engine)
        try await engine.initialize()
        let engineView = await engine.itemSnapshot(itemID: itemID)
        XCTAssertEqual(engineView?.manifest.observerIngest?.segment, "085000_13")
        XCTAssertEqual(engineView?.state, .attention)

        // Moved back to queued, the key stays.
        let queued = try spool.moveAttentionItemToQueued(repaired, now: Self.launch)
        XCTAssertEqual(queued.manifest.observerIngest?.segment, "085000_13")
        let onDisk = try spool.readManifest(in: queued.directoryURL)
        XCTAssertEqual(onDisk.observerIngest?.segment, "085000_13")
        XCTAssertEqual(onDisk.observerIngest?.segmentRepairedFrom, Self.twelveHourSegment)
        XCTAssertEqual(onDisk.diskState, .queued)
    }

    // MARK: - staged items

    func testAStagedItemRecoveredAtLaunchIsQueuedRepaired() throws {
        let root = self.tempDirectory.appendingPathComponent("staged-recovery", isDirectory: true)
        let spool = TransferSpool(rootURL: root)
        let itemID = Self.uuid(501)
        let staged = try spool.stage(
            manifest: Self.manifest(itemID: itemID, segment: Self.twelveHourSegment),
            payloads: Self.audioPayloads
        )
        XCTAssertEqual(staged.item.manifest.observerIngest?.segment, Self.twelveHourSegment, "staging keeps what the producer gave it")

        let snapshot = try spool.initialize(now: Self.launch)

        let item = try XCTUnwrap(snapshot.queued.first { $0.manifest.itemID == itemID })
        XCTAssertEqual(item.manifest.observerIngest?.segment, "085000_13")
        XCTAssertEqual(item.manifest.observerIngest?.segmentRepairedFrom, Self.twelveHourSegment)
        XCTAssertEqual(try spool.readManifest(in: item.directoryURL).observerIngest?.segment, "085000_13")
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.stagingDirectoryURL.appendingPathComponent(itemID.uuidString).path))
        XCTAssertEqual(spool.segmentRepairTally().repaired, 1)
    }

    func testAnItemCommittedAtRuntimeIsCommittedRepairedAndNeverRefused() async throws {
        let root = self.tempDirectory.appendingPathComponent("staged-runtime", isDirectory: true)
        TransferURLProtocol.handler = Self.faithfulJournal()
        let engine = self.makeEngine(spool: TransferSpool(rootURL: root))
        self.pauseAtTeardown(engine)
        try await engine.start()
        let itemID = try await engine.enqueue(
            manifest: Self.manifest(itemID: Self.uuid(502), segment: Self.twelveHourSegment),
            payloads: Self.audioPayloads
        )
        try await self.waitFor("delivered") { (await engine.snapshot()).counters.deliveredCount == 1 }

        XCTAssertEqual(TransferURLProtocol.requests.count, 1, "zero refused sends")
        XCTAssertEqual(Self.sentSegments()[itemID], "085000_13")
        let counters = await engine.snapshot().counters
        XCTAssertEqual(counters.attentionCount, 0)
        XCTAssertEqual(TransferSpool(rootURL: root).segmentRepairTally().repaired, 1)
    }

    func testACommitWhoseDeleteFailsCommitsTheItemUnrepairedAndTheNextLaunchRepairsIt() throws {
        let root = self.tempDirectory.appendingPathComponent("staged-delete-fails", isDirectory: true)
        let plain = TransferSpool(rootURL: root)
        let itemID = Self.uuid(503)
        let staged = try plain.stage(
            manifest: Self.manifest(itemID: itemID, segment: Self.twelveHourSegment),
            payloads: Self.audioPayloads
        )
        _ = try plain.writeBodyCache(Data("cache".utf8), for: staged.item)
        let faults = RepairFaultFileSystem()
        faults.failBodyDelete(for: [itemID])

        let committed = try TransferSpool(rootURL: root, fileSystem: faults).commitStagedItem(itemID: itemID, now: Self.launch)

        XCTAssertEqual(committed.manifest.observerIngest?.segment, Self.twelveHourSegment, "committed as it was")
        XCTAssertNil(committed.manifest.observerIngest?.segmentRepairedFrom)
        XCTAssertEqual(plain.segmentRepairTally().failures, 1)
        XCTAssertEqual(plain.segmentRepairTally().repaired, 0)

        faults.failBodyDelete(for: [])
        let snapshot = try TransferSpool(rootURL: root, fileSystem: faults).initialize(now: Self.launch.addingTimeInterval(60))
        XCTAssertEqual(Self.segments(in: snapshot.queued)[itemID], "085000_13")
        XCTAssertFalse(plain.bodyCacheExists(for: committed))
    }

    // MARK: - conflicted identities

    func testAConflictedIdentityIsNeitherRepairedNorReadForTheExport() async throws {
        let root = self.tempDirectory.appendingPathComponent("conflicted", isDirectory: true)
        let spool = TransferSpool(rootURL: root)
        let conflicted = Self.uuid(601)
        let queued = try Self.seedQueued(spool: spool, manifest: Self.manifest(itemID: conflicted, segment: Self.twelveHourSegment))
        _ = try spool.writeBodyCache(Data("queued-cache".utf8), for: queued)
        let attentionURL = spool.attentionDirectoryURL.appendingPathComponent(conflicted.uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: queued.directoryURL, to: attentionURL)
        try Data("attention-cache".utf8).write(to: attentionURL.appendingPathComponent(TransferSpool.bodyUploadFilename))
        // A neighbour that is not conflicted is repaired, so the pass did run.
        let neighbour = Self.uuid(602)
        try Self.seedAttention(spool: spool, manifest: Self.manifest(itemID: neighbour, segment: Self.twelveHourSegment))
        let queuedBefore = try Self.byteMap(of: queued.directoryURL)
        let attentionBefore = try Self.byteMap(of: attentionURL)

        let snapshot = try spool.initialize(now: Self.launch)
        XCTAssertEqual(snapshot.conflictedItemIDs, [conflicted])
        let engine = self.makeEngine(spool: TransferSpool(rootURL: root))
        self.pauseAtTeardown(engine)
        try await engine.initialize()
        let export = await Self.exportRows(engine: engine, now: Self.launch)

        XCTAssertEqual(try Self.byteMap(of: queued.directoryURL), queuedBefore)
        XCTAssertEqual(try Self.byteMap(of: attentionURL), attentionBefore)
        XCTAssertEqual(export.detail.segmentRepairTally.repaired, 1, "only the neighbour")
        XCTAssertEqual(export.detail.unrepairedSegmentNames, UnrepairedSegmentNameCounts(), "the conflicted pair is not counted")
        XCTAssertEqual(Self.segments(in: snapshot.attention)[neighbour], "085000_13")
        XCTAssertEqual(try Self.byteMap(of: queued.directoryURL), queuedBefore, "still, after the export")
        XCTAssertEqual(try Self.byteMap(of: attentionURL), attentionBefore)
    }

    // MARK: - ownership

    func testResidueCarryingTheOriginalKeyIsStillOwnedByTheRepairedItem() throws {
        for state in [TransferDiskState.queued, .attention] {
            let root = self.tempDirectory.appendingPathComponent("ownership-\(state.rawValue)", isDirectory: true)
            let spool = TransferSpool(rootURL: root)
            let itemID = Self.uuid(state == .queued ? 701 : 702)
            let original = Self.manifest(itemID: itemID, segment: Self.twelveHourSegment)
            if state == .queued {
                try Self.seedQueued(spool: spool, manifest: original)
            } else {
                try Self.seedAttention(spool: spool, manifest: original)
            }
            _ = try spool.initialize(now: Self.launch)
            let owned: TransferOwnershipVerdict = state == .queued ? .ownedInQueued : .ownedInAttention
            let directory = (state == .queued ? spool.queuedDirectoryURL : spool.attentionDirectoryURL)
                .appendingPathComponent(itemID.uuidString, isDirectory: true)
            XCTAssertEqual(try spool.readManifest(in: directory).observerIngest?.segment, "085000_13")
            let payloadSource = self.tempDirectory.appendingPathComponent("residue-\(state.rawValue).m4a")
            try Self.audioPayloads["audio"]!.write(to: payloadSource)

            XCTAssertEqual(
                try spool.verifyOwnership(expectedManifest: original, expectedPayloadSourceURLs: ["audio": payloadSource]),
                owned,
                state.rawValue
            )

            var differentSegment = original
            differentSegment.observerIngest?.segment = "090000_13"
            XCTAssertEqual(
                try spool.verifyOwnership(expectedManifest: differentSegment, expectedPayloadSourceURLs: [:]),
                .conflict(.manifestMismatch)
            )
            var repairedKey = original
            repairedKey.observerIngest?.segment = "085000_13"
            XCTAssertEqual(
                try spool.verifyOwnership(expectedManifest: repairedKey, expectedPayloadSourceURLs: [:]),
                .conflict(.manifestMismatch),
                "only the name the item was stored under proves it"
            )
            var differentDay = original
            differentDay.observerIngest?.day = "20260106"
            XCTAssertEqual(
                try spool.verifyOwnership(expectedManifest: differentDay, expectedPayloadSourceURLs: [:]),
                .conflict(.manifestMismatch)
            )

            let otherBytes = self.tempDirectory.appendingPathComponent("residue-other-\(state.rawValue).m4a")
            try Data("other bytes".utf8).write(to: otherBytes)
            XCTAssertEqual(
                try spool.verifyOwnership(expectedManifest: original, expectedPayloadSourceURLs: ["audio": otherBytes]),
                .conflict(.payloadMismatch)
            )
        }
    }

    // MARK: - the stored shape

    func testAManifestWithoutTheFieldReEncodesByteForByte() throws {
        let manifest = Self.manifest(itemID: Self.uuid(801), segment: "085000_13")
        let data = try TransferSpool.encoder().encode(manifest)
        XCTAssertFalse(Self.text(data).contains("segmentRepairedFrom"), "an item that was not rewritten stores nothing new")
        let decoded = try TransferSpool.decoder().decode(TransferManifest.self, from: data)
        XCTAssertNil(decoded.observerIngest?.segmentRepairedFrom)
        XCTAssertEqual(try TransferSpool.encoder().encode(decoded), data)
        XCTAssertEqual(try TransferSpool.encoder().encode(manifest), data)

        // A manifest as a build that had no such field stored it, byte for byte.
        let storedByAnOlderBuild = Data(
            #"{"createdAt":"2026-01-05T15:50:00Z","diskState":"queued","endpoint":{"destinationKind":"observer_ingest","path":"\/app\/devices\/ingest"},"itemID":"00000000-0000-0000-0000-000000000801","meta":{"kind":"test"},"observerIngest":{"chunkIndex":0,"day":"20260105","durationS":13,"ingestProtocolVersion":3,"modeRawValue":"meeting","platform":"ios","segment":"085000_13","segmentID":"00000000-0000-0000-0000-000000000801","sessionID":"00000000-0000-0000-0000-000000000801","sources":["audio"],"startedAt":"2026-01-05T15:50:00Z"},"payloadParts":[{"contentType":"audio\/mp4","filename":"audio.m4a","kind":"audio","partID":"audio","relativePath":"audio.m4a","requiredForDispatch":true}],"priority":{"basePriority":"normal","sourceKey":"alpha","userInitiated":false},"retryCount":0,"schemaVersion":"solstone.transfer.item\/1","source":"alpha"}"#.utf8
        )
        let older = try TransferSpool.decoder().decode(TransferManifest.self, from: storedByAnOlderBuild)
        XCTAssertNil(older.observerIngest?.segmentRepairedFrom)
        XCTAssertEqual(older, manifest)
        XCTAssertEqual(try TransferSpool.encoder().encode(older), storedByAnOlderBuild)

        var repaired = manifest
        repaired.observerIngest?.segmentRepairedFrom = Self.twelveHourSegment
        let repairedData = try TransferSpool.encoder().encode(repaired)
        XCTAssertEqual(try TransferSpool.decoder().decode(TransferManifest.self, from: repairedData), repaired)
        XCTAssertEqual(try TransferSpool.encoder().encode(TransferSpool.decoder().decode(TransferManifest.self, from: repairedData)), repairedData)
    }

    func testTheOriginalNameNeverReachesAnyBuiltBody() throws {
        let root = self.tempDirectory.appendingPathComponent("wire-absence", isDirectory: true)
        let spool = TransferSpool(rootURL: root)
        try Self.seedAttention(spool: spool, manifest: Self.manifest(itemID: Self.uuid(802), segment: Self.twelveHourSegment))
        let snapshot = try spool.initialize(now: Self.launch)
        let item = try XCTUnwrap(snapshot.attention.first)
        XCTAssertEqual(item.manifest.observerIngest?.segmentRepairedFrom, Self.twelveHourSegment)

        let body = try XCTUnwrap(Self.builtBody(of: item, spool: spool))

        XCTAssertEqual(Self.envelopeSegment(in: body), "085000_13")
        try Self.assertTheOriginalNameIsNotOnTheWire(body)
    }

    // MARK: - the tally

    func testTheTallyCountsEachFormAndKeepsTheFirstAndLastRepairTimeAndNamesNothing() throws {
        let root = self.tempDirectory.appendingPathComponent("tally", isDirectory: true)
        let spool = TransferSpool(rootURL: root)
        let first = Self.launch
        let later = Self.launch.addingTimeInterval(3_600)
        for (index, fixture) in Self.fixtures.enumerated() {
            try Self.seedAttention(spool, fixture, Self.uuid(900 + index))
        }
        _ = try spool.initialize(now: first)
        try Self.seedAttention(spool, Self.fixtures[1], Self.uuid(910))
        _ = try spool.initialize(now: later)

        let tally = spool.segmentRepairTally()
        XCTAssertEqual(tally.repaired, 5)
        XCTAssertEqual(tally.failures, 0)
        XCTAssertEqual(tally.firstRepairedAt, first)
        XCTAssertEqual(tally.lastRepairedAt, later)
        var expectedByMarker: [String: Int] = [:]
        for fixture in Self.fixtures + [Self.fixtures[1]] {
            let marker = try XCTUnwrap(TransferSegmentRepair.DayPeriod.allCases.first { fixture.stored.contains($0.rawValue) })
            expectedByMarker[marker.rawValue, default: 0] += 1
        }
        XCTAssertEqual(tally.repairedByForm, expectedByMarker)

        let file = try Self.text(Data(contentsOf: root.appendingPathComponent(TransferSpool.segmentRepairTallyFilename)))
        for needle in [Self.day, "85000", "101509", "120500", "123500", "085000", "221509", "202F", "00000000-0000"] {
            XCTAssertFalse(file.contains(needle), needle)
        }
    }

    func testASecondLaunchChangesNothingAndMovesNoCount() throws {
        let root = self.tempDirectory.appendingPathComponent("idempotent", isDirectory: true)
        let spool = TransferSpool(rootURL: root)
        for (index, fixture) in Self.fixtures.enumerated() {
            let item = try Self.seedAttention(spool, fixture, Self.uuid(1_000 + index))
            _ = try spool.writeBodyCache(Data("cache-\(index)".utf8), for: item)
        }
        _ = try spool.initialize(now: Self.launch)
        let treeAfterFirst = try Self.byteMap(of: root)
        let tallyAfterFirst = spool.segmentRepairTally()
        XCTAssertEqual(tallyAfterFirst.repaired, Self.fixtures.count)

        let second = try spool.initialize(now: Self.launch.addingTimeInterval(86_400))

        XCTAssertEqual(try Self.byteMap(of: root), treeAfterFirst)
        XCTAssertEqual(spool.segmentRepairTally(), tallyAfterFirst)
        XCTAssertEqual(second.attention.count, Self.fixtures.count)
    }

    // MARK: - with refusal pacing

    func testARefusalPacedUnderTheSameBuildIsOfferedOnceUnderTheNewKey() async throws {
        let root = self.tempDirectory.appendingPathComponent("pacing", isDirectory: true)
        let spool = TransferSpool(rootURL: root)
        let repairable = Self.uuid(1_101)
        let unrepairable = Self.uuid(1_102)
        for (itemID, segment) in [(repairable, Self.twelveHourSegment), (unrepairable, "85000 AM_13")] {
            let manifest = Self.manifest(itemID: itemID, segment: segment)
            try Self.seedAttention(
                spool: spool,
                manifest: manifest,
                refusedUnder: TransferRefusalConditions(
                    appBuild: "build-a",
                    endpointPath: "/app/devices/ingest",
                    source: "alpha",
                    day: Self.day,
                    segment: segment,
                    ingestProtocolVersion: 3
                ),
                movedAt: Self.launch.addingTimeInterval(-60)
            )
        }
        TransferURLProtocol.handler = Self.faithfulJournal()
        let engine = self.makeEngine(spool: TransferSpool(rootURL: root), appBuild: "build-a")
        self.pauseAtTeardown(engine)
        try await engine.start()
        let pacedBefore = await engine.itemSnapshot(itemID: unrepairable)?.refusalPaced
        XCTAssertEqual(pacedBefore, true, "the name nobody can read is paced as it always was")

        await engine.noteNewConnectionEstablished()
        await engine.endpointAvailabilityChanged()
        try await self.waitFor("delivered") { (await engine.snapshot()).counters.deliveredCount == 1 }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(TransferURLProtocol.bodies.count, 1, "exactly one send")
        XCTAssertEqual(Self.sentSegments()[repairable], "085000_13")
        XCTAssertNil(Self.sentSegments()[unrepairable])
        let unrepairableView = await engine.itemSnapshot(itemID: unrepairable)
        XCTAssertEqual(unrepairableView?.state, .attention)
        XCTAssertEqual(unrepairableView?.refusalPaced, true)
    }

    // MARK: - survives delivery

    @MainActor
    func testTheTallySurvivesDeliveryAndTheExportNamesNothing() async throws {
        let root = self.tempDirectory.appendingPathComponent("survives", isDirectory: true)
        let spool = TransferSpool(rootURL: root)
        let ids = [Self.uuid(1_201), Self.uuid(1_202), Self.uuid(1_203)]
        for (index, id) in ids.enumerated() {
            try Self.seedAttention(spool, Self.fixtures[index], id)
        }
        TransferURLProtocol.handler = Self.faithfulJournal()
        let first = self.makeEngine(spool: TransferSpool(rootURL: root))
        self.pauseAtTeardown(first)
        try await first.start()
        await first.noteNewConnectionEstablished()
        await first.endpointAvailabilityChanged()
        try await self.waitFor("all delivered") {
            let counters = await first.snapshot().counters
            return counters.deliveredCount == 3 && counters.attentionCount == 0 && counters.queuedCount == 0
        }
        await first.pause()
        XCTAssertEqual(Set(Self.sentSegments().keys), Set(ids))

        let fresh = self.makeEngine(spool: TransferSpool(rootURL: root))
        self.pauseAtTeardown(fresh)
        try await fresh.initialize()
        let export = await Self.exportRows(engine: fresh, now: Self.launch.addingTimeInterval(600))

        XCTAssertEqual(export.detail.segmentRepairTally.repaired, 3)
        XCTAssertEqual(export.detail.unrepairedSegmentNames, UnrepairedSegmentNameCounts())
        let repairLines = SegmentRepairExport(tally: export.detail.segmentRepairTally, unrepaired: UnrepairedSegmentNameCounts())
            .lines(now: Self.launch.addingTimeInterval(600))
        XCTAssertFalse(repairLines.isEmpty)
        for line in repairLines {
            XCTAssertTrue(export.lines.contains(line), line)
        }
        // The lines name no item, day or segment, and the export's own redaction leaves them whole.
        let forbidden = ids.map(\.uuidString) + [Self.day] + Self.fixtures.flatMap { [$0.stored, $0.repaired, String($0.repaired.prefix(6))] }
            + Self.fixtures.map { String($0.stored.split(separator: "\u{202F}")[0]) } + ["\u{202F}"]
        for line in repairLines {
            for needle in forbidden {
                XCTAssertFalse(line.contains(needle), "\(needle) in a repair line")
            }
        }
        let url = try XCTUnwrap(DiagnosticLog().exportFileURL(tunnel: TunnelManager(), syncState: export.lines))
        let text = try String(contentsOf: url, encoding: .utf8)
        for line in repairLines {
            XCTAssertTrue(text.contains(line), "redaction left \(line)")
        }
        XCTAssertFalse(repairLines.joined().contains("redacted"))
    }

    // MARK: - what the export lists

    func testAListedRepairedItemShowsItsOriginalBesideItsCurrentSegmentEscaped() throws {
        var manifest = Self.manifest(itemID: Self.uuid(1_301), segment: "085000_13")
        manifest.attention = TransferAttentionInfo(
            reason: TransferAttentionReason.httpClientErrorCode,
            shortDetail: "reason_code=segment_invalid",
            movedAt: Self.launch,
            journalReasonCode: "segment_invalid"
        )
        let plain = try XCTUnwrap(RefusedItemExportRecord(manifest: manifest))
        let plainFields = RefusedItemsExport.itemFields(plain, now: Self.launch).joined(separator: ", ")
        XCTAssertEqual(plainFields.components(separatedBy: "«").count - 1, 2, "day and segment only")

        manifest.observerIngest?.segmentRepairedFrom = Self.twelveHourSegment
        let repaired = try XCTUnwrap(RefusedItemExportRecord(manifest: manifest))
        let fields = RefusedItemsExport.itemFields(repaired, now: Self.launch)
        let line = fields.joined(separator: ", ")
        XCTAssertEqual(line.components(separatedBy: "«").count - 1, 3, "day, segment and the name it was stored under")
        let current = try XCTUnwrap(line.range(of: "«085000_13»"))
        let original = try XCTUnwrap(line.range(of: #"«85000\u{202F}AM_13»"#))
        XCTAssertLessThan(current.lowerBound, original.lowerBound)
        XCTAssertFalse(line.unicodeScalars.contains { $0.value == 0x202F }, "printable ASCII only")
        let segmentIndex = try XCTUnwrap(fields.firstIndex { $0.contains("«085000_13»") })
        XCTAssertTrue(fields[segmentIndex + 1].contains(#"«85000\u{202F}AM_13»"#), "right after the segment field")
    }
}

// MARK: - the producer's copy of an item the spool repaired

/// A producer that still holds the item under the name it was stored under retires its copy, as
/// it does for any item the spool owns, and keeps it when the spool's item is not the same one.
@MainActor
final class TransferSegmentRepairResidueTests: XCTestCase {
    private var tempDirectory: URL!
    private var clock: MockObserverClock!

    override func setUp() async throws {
        try await super.setUp()
        TransferURLProtocol.reset()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferSegmentRepairResidueTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        self.clock = MockObserverClock(now: TransferSegmentRepairTests.startedAt)
    }

    override func tearDown() async throws {
        TransferURLProtocol.reset()
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        self.clock = nil
        try await super.tearDown()
    }

    func testResidueCarryingTheOriginalKeyRetiresWithNoError() async throws {
        let outcome = try await self.resume(spoolPayload: Data("audio-bytes".utf8), residueSegment: TransferSegmentRepairTests.twelveHourSegment)

        XCTAssertFalse(outcome.residueRemains, "verified as owned and retired")
        XCTAssertNil(outcome.lastError)
        XCTAssertEqual(outcome.spoolSegment, "085000_13")
    }

    func testResidueWithTheSameKeyButOtherBytesIsKept() async throws {
        let outcome = try await self.resume(spoolPayload: Data("other bytes".utf8), residueSegment: TransferSegmentRepairTests.twelveHourSegment)

        XCTAssertTrue(outcome.residueRemains, "a payload mismatch never retires the producer's copy")
        XCTAssertNotNil(outcome.lastError)
        XCTAssertEqual(outcome.spoolSegment, "085000_13")
    }

    func testResidueUnderAnotherSegmentIsKept() async throws {
        let outcome = try await self.resume(spoolPayload: Data("audio-bytes".utf8), residueSegment: "90000\u{202F}AM_13")

        XCTAssertTrue(outcome.residueRemains)
        XCTAssertNotNil(outcome.lastError)
    }

    private struct Outcome {
        var residueRemains: Bool
        var lastError: String?
        var spoolSegment: String?
    }

    /// The spool holds the item as an older build stored it under the 12-hour name and a launch
    /// repairs it; then the producer's pass runs over its own copy.
    private func resume(spoolPayload: Data, residueSegment: String) async throws -> Outcome {
        let root = self.tempDirectory.appendingPathComponent("Transfers", isDirectory: true)
        let store = MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true))
        let segmentID = UUID()
        let residue = try self.writeSegment(store: store, segmentID: segmentID, segment: residueSegment)

        var spoolSide = try store.readManifest(in: residue)
        spoolSide.segment = TransferSegmentRepairTests.twelveHourSegment
        let spoolManifest = ObserverAudioTransferEnqueuer.makeMobileSegmentManifest(
            itemID: segmentID,
            manifest: spoolSide,
            now: self.clock.now(),
            sources: [.audio],
            payloadParts: [ObserverAudioTransferEnqueuer.audioPart()]
        )
        let spool = TransferSpool(rootURL: root)
        try TransferSegmentRepairTests.seedQueued(spool: spool, manifest: spoolManifest, payloads: ["audio": spoolPayload])

        let transfer = makeTransferCutoverHarness(rootURL: root, sessionConfiguration: makeTransferTestURLSessionConfiguration())
        let uploader = MobileSegmentUploader(
            transferEngine: transfer.engine,
            store: store,
            clock: self.clock,
            cooperator: MaintenanceCooperator()
        )
        try await transfer.engine.initialize()
        await uploader.resumeFromDisk()

        let snapshots = await transfer.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        return Outcome(
            residueRemains: store.fileExists(residue),
            lastError: uploader.lastError,
            spoolSegment: snapshots.first { $0.manifest.itemID == segmentID }?.manifest.observerIngest?.segment
        )
    }

    private func writeSegment(store: MobileSegmentStore, segmentID: UUID, segment: String) throws -> URL {
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(13)
        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.audio],
            activeSourceSetVersion: 1
        )
        manifest.day = TransferSegmentRepairTests.day
        manifest.segment = segment
        manifest.endedAt = endedAt
        manifest.durationS = 13
        manifest.upload = .pending
        let activeDirectory = try store.createActive(manifest: manifest)
        let artifactURL = store.artifactURL(in: activeDirectory, source: .audio)
        try Data("audio-bytes".utf8).write(to: artifactURL, options: .atomic)
        manifest = try store.readManifest(in: activeDirectory)
        try store.writeOutcome(
            MobileSegmentSourceResolution(
                state: .finalizedArtifact,
                artifactFilename: artifactURL.lastPathComponent,
                bytes: store.fileSize(at: artifactURL),
                startedAt: startedAt,
                endedAt: endedAt,
                durationS: 13,
                mode: .meeting
            ),
            source: .audio,
            manifest: &manifest,
            in: activeDirectory,
            now: endedAt
        )
        return try store.move(segmentID: segmentID, from: .active, to: .pending)
    }
}

// MARK: - helpers

/// A file system that fails what it is told to fail, by item, and does everything else for real.
nonisolated final class RepairFaultFileSystem: TransferFileSystem, @unchecked Sendable {
    private struct Faults {
        var bodyDelete: Set<UUID> = []
        var manifestReplace: Set<UUID> = []
        var tallyWrite = false
    }

    private let base = FoundationTransferFileSystem()
    private let faults = OSAllocatedUnfairLock(initialState: Faults())

    func failBodyDelete(for itemIDs: Set<UUID>) { self.faults.withLock { $0.bodyDelete = itemIDs } }
    func failManifestReplace(for itemIDs: Set<UUID>) { self.faults.withLock { $0.manifestReplace = itemIDs } }
    func failTallyWrite(_ fails: Bool) { self.faults.withLock { $0.tallyWrite = fails } }

    private func itemID(containing url: URL) -> UUID? {
        UUID(uuidString: url.deletingLastPathComponent().lastPathComponent)
    }

    func fileExists(atPath path: String) -> Bool { self.base.fileExists(atPath: path) }
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try self.base.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories)
    }
    func contentsOfDirectory(at url: URL) throws -> [URL] { try self.base.contentsOfDirectory(at: url) }
    func removeItem(at url: URL) throws {
        if url.lastPathComponent == TransferSpool.bodyUploadFilename,
           let itemID = self.itemID(containing: url),
           self.faults.withLock({ $0.bodyDelete.contains(itemID) }) {
            throw CocoaError(.fileWriteNoPermission)
        }
        try self.base.removeItem(at: url)
    }
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws { try self.base.moveItem(at: sourceURL, to: destinationURL) }
    func replaceItem(at originalURL: URL, withItemAt newURL: URL) throws {
        if originalURL.lastPathComponent == TransferSpool.manifestFilename,
           let itemID = self.itemID(containing: originalURL),
           self.faults.withLock({ $0.manifestReplace.contains(itemID) }) {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try self.base.replaceItem(at: originalURL, withItemAt: newURL)
    }
    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        if url.lastPathComponent == TransferSpool.segmentRepairTallyFilename, self.faults.withLock({ $0.tallyWrite }) {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try self.base.write(data, to: url, options: options)
    }
    func data(contentsOf url: URL) throws -> Data { try self.base.data(contentsOf: url) }
    func byteCount(at url: URL) throws -> Int { try self.base.byteCount(at: url) }
    func readChunks(at url: URL, chunkSize: Int, _ consume: (Data) throws -> Void) throws {
        try self.base.readChunks(at: url, chunkSize: chunkSize, consume)
    }
    func writeStream(to url: URL, _ body: (any TransferByteSink) throws -> Void) throws -> Int {
        try self.base.writeStream(to: url, body)
    }
}

extension TransferSegmentRepairTests {
    static let twelveHourSegment = "85000\u{202F}AM_13"
    /// A name the repair leaves alone, for committing an item that is then stored under another.
    static let untouchedSegment = "000000_13"
    static let day = "20260105"
    /// 2026-01-05 15:50:00 UTC is 08:50:00 at -07:00.
    static let startedAt = Date(timeIntervalSince1970: 1_767_628_200)
    static let launch = Date(timeIntervalSince1970: 1_767_710_000)
    static let audioPayloads: [String: Data] = ["audio": Data("audio".utf8)]
    static let segmentInvalidBody = Data(
        #"{"error":"Ingest request refused","reason_code":"segment_invalid","detail":"segment must be HHMMSS_LEN"}"#.utf8
    )

    /// A name as an older build stored it, and the name of the same date and time that the wire takes.
    struct Fixture {
        let stored: String
        let repaired: String
    }

    static let fixtures: [Fixture] = [
        Fixture(stored: "85000\u{202F}AM_13", repaired: "085000_13"),
        Fixture(stored: "101509\u{202F}PM_13", repaired: "221509_13"),
        Fixture(stored: "120500\u{202F}am_13", repaired: "000500_13"),
        Fixture(stored: "123500\u{202F}pm_13", repaired: "123500_13"),
    ]

    static func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    /// The instant at which a wall clock reading `day` + `clock` (24-hour, `HHmmss`) is `offset`
    /// seconds from GMT. Worked out with the system calendar, independently of the code under test.
    static func instant(day: String, clock: String, offset: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let wall = calendar.date(from: DateComponents(
            year: Int(day.prefix(4)),
            month: Int(day.dropFirst(4).prefix(2)),
            day: Int(day.suffix(2)),
            hour: Int(clock.prefix(2)),
            minute: Int(clock.dropFirst(2).prefix(2)),
            second: Int(clock.suffix(2))
        ))!
        return wall.addingTimeInterval(-Double(offset))
    }

    static func ingest(
        segment: String,
        pinnedClock: String,
        offset: Int,
        day: String = TransferSegmentRepairTests.day
    ) -> TransferObserverIngestMetadata {
        TransferObserverIngestMetadata(
            segment: segment,
            day: day,
            startedAt: Self.instant(day: day, clock: pinnedClock, offset: offset),
            durationS: 13,
            sources: ["audio"],
            ingestProtocolVersion: 3
        )
    }

    static func manifest(
        itemID: UUID,
        source: String = "alpha",
        segment: String,
        day: String = TransferSegmentRepairTests.day,
        startedAt: Date = TransferSegmentRepairTests.startedAt
    ) -> TransferManifest {
        TransferManifest(
            itemID: itemID,
            source: source,
            createdAt: startedAt,
            priority: TransferPriorityInputs(basePriority: .normal, sourceKey: source),
            payloadParts: [
                TransferPayloadPartDescriptor(
                    partID: "audio",
                    kind: .audio,
                    relativePath: "audio.m4a",
                    filename: "audio.m4a",
                    contentType: "audio/mp4"
                ),
            ],
            endpoint: TransferEndpointDescriptor(destinationKind: .observerIngest, path: "/app/devices/ingest"),
            observerIngest: TransferObserverIngestMetadata(
                segment: segment,
                day: day,
                startedAt: startedAt,
                durationS: 13,
                sources: ["audio"],
                chunkIndex: 0,
                sessionID: itemID,
                modeRawValue: "meeting",
                segmentID: itemID,
                ingestProtocolVersion: 3
            ),
            meta: .object(["kind": .string("test")])
        )
    }

    /// The manifest an older build stored for a fixture: its name, and a start instant that
    /// agrees with the 24-hour clock at -07:00.
    static func manifest(for fixture: Fixture, itemID: UUID) -> TransferManifest {
        Self.manifest(
            itemID: itemID,
            segment: fixture.stored,
            startedAt: Self.instant(day: Self.day, clock: String(fixture.repaired.prefix(6)), offset: -25_200)
        )
    }

    /// An item the journal refused, as an older build left it: in attention, with the refusal's
    /// reason code. The manifest is stored under its own segment, whatever that is.
    @discardableResult
    static func seedAttention(
        spool: TransferSpool,
        manifest: TransferManifest,
        refusedUnder: TransferRefusalConditions? = nil,
        movedAt: Date = Date(timeIntervalSince1970: 1_767_700_000)
    ) throws -> TransferStoredItem {
        let moved = try spool.moveQueuedItemToAttention(
            try Self.seedQueued(spool: spool, manifest: manifest),
            reason: TransferAttentionReason.httpClientErrorCode,
            detail: "reason_code=segment_invalid",
            journalReasonCode: "segment_invalid",
            refusedUnder: refusedUnder,
            now: movedAt
        )
        return try Self.storeSegment(of: manifest, onto: moved, spool: spool)
    }

    @discardableResult
    static func seedAttention(_ spool: TransferSpool, _ fixture: Fixture, _ itemID: UUID) throws -> TransferStoredItem {
        try Self.seedAttention(spool: spool, manifest: Self.manifest(for: fixture, itemID: itemID))
    }

    /// A queued item stored under the manifest's own segment, whatever it is. The commit rewrites
    /// a 12-hour name, as it does at runtime, so the item is committed under a name it leaves
    /// alone and the manifest is written back as an older build left it.
    @discardableResult
    static func seedQueued(
        spool: TransferSpool,
        manifest: TransferManifest,
        payloads: [String: Data] = TransferSegmentRepairTests.audioPayloads
    ) throws -> TransferStoredItem {
        var committable = manifest
        committable.observerIngest?.segment = Self.untouchedSegment
        committable.observerIngest?.segmentRepairedFrom = nil
        let queued = try spool.commitStagedItem(
            itemID: spool.stage(manifest: committable, payloads: payloads).item.manifest.itemID
        )
        return try Self.storeSegment(of: manifest, onto: queued, spool: spool)
    }

    private static func storeSegment(
        of manifest: TransferManifest,
        onto item: TransferStoredItem,
        spool: TransferSpool
    ) throws -> TransferStoredItem {
        var stored = item.manifest
        stored.observerIngest?.segment = manifest.observerIngest?.segment ?? ""
        stored.observerIngest?.segmentRepairedFrom = manifest.observerIngest?.segmentRepairedFrom
        try spool.writeManifestAtomically(stored, in: item.directoryURL)
        return TransferStoredItem(manifest: stored, directoryURL: item.directoryURL)
    }

    static func segments(in items: [TransferStoredItem]) -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.manifest.itemID, $0.manifest.observerIngest?.segment ?? "") })
    }

    static func builtBody(of item: TransferStoredItem, spool: TransferSpool) throws -> Data? {
        guard case .inMemory(let data) = try DefaultTransferBodyBuilder.build(item: item, spool: spool) else { return nil }
        return data
    }

    /// Every file under `url`, hidden ones included, by relative path.
    static func byteMap(of url: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return result
        }
        for case let file as URL in enumerator where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(file.path.dropFirst(url.path.count))] = try Data(contentsOf: file)
        }
        return result
    }

    /// The `segment` of a built ingest body's envelope.
    static func envelopeSegment(in body: Data) -> String? {
        Self.envelope(in: body)?["segment"] as? String
    }

    static func envelope(in body: Data) -> [String: Any]? {
        let string = String(decoding: body, as: UTF8.self)
        guard let header = string.range(of: #"Content-Disposition: form-data; name="envelope""#),
              let separator = string[header.upperBound...].range(of: "\r\n\r\n"),
              let end = string[separator.upperBound...].range(of: "\r\n--")
        else { return nil }
        let json = Data(string[separator.upperBound..<end.lowerBound].utf8)
        return try? JSONSerialization.jsonObject(with: json) as? [String: Any]
    }

    /// Nothing of the name an item was stored under, and no field that records it, is on the wire:
    /// the envelope holds exactly the fields the journal has always been sent.
    static func assertTheOriginalNameIsNotOnTheWire(
        _ body: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertNil(body.range(of: Data("\u{202F}".utf8)), "the narrow no-break space is not on the wire", file: file, line: line)
        let text = Self.text(body)
        XCTAssertFalse(text.contains("segmentRepairedFrom"), file: file, line: line)
        XCTAssertFalse(text.contains("repaired"), file: file, line: line)
        for marker in TransferSegmentRepair.DayPeriod.allCases {
            XCTAssertFalse(text.contains("\(marker.rawValue)_13"), "the stored marker is not on the wire", file: file, line: line)
        }
        let envelope = try XCTUnwrap(Self.envelope(in: body), file: file, line: line)
        XCTAssertEqual(Set(envelope.keys), ["day", "segment", "source", "files", "meta"], file: file, line: line)
        let meta = try XCTUnwrap(envelope["meta"] as? [String: Any], file: file, line: line)
        XCTAssertTrue(
            Set(meta.keys).isSubset(of: [
                "platform", "started_at", "duration_s", "sources", "chunk_index", "session_id", "mode", "segment_id",
                "battery_level", "battery_state", "low_power_mode", "power_sampled_at", "tz", "utc_offset_seconds",
            ]),
            "\(meta.keys.sorted())",
            file: file,
            line: line
        )
    }

    static func isWireSegment(_ segment: String?) -> Bool {
        guard let segment else { return false }
        return segment.range(of: #"^[0-9]{6}_[0-9]+$"#, options: .regularExpression) != nil
    }

    /// A journal that refuses what it would refuse, and receives the rest.
    static func faithfulJournal() -> TransferURLProtocol.Handler {
        { request, body in
            if !Self.isWireSegment(Self.envelopeSegment(in: body)) {
                return (Self.response(for: request, statusCode: 400), Self.segmentInvalidBody)
            }
            return (
                Self.response(for: request, statusCode: 200),
                transferTestMatchingReceipt(body: body, contentType: request.value(forHTTPHeaderField: "Content-Type"))
            )
        }
    }

    /// The `segment` each send carried, by item.
    static func sentSegments() -> [UUID: String] {
        var result: [UUID: String] = [:]
        for (request, body) in zip(TransferURLProtocol.requests, TransferURLProtocol.bodies) {
            guard let itemID = Self.boundaryItemID(from: request) else { continue }
            result[itemID] = Self.envelopeSegment(in: body)
        }
        return result
    }

    static func boundaryItemID(from request: URLRequest) -> UUID? {
        guard let contentType = request.value(forHTTPHeaderField: "Content-Type"),
              let range = contentType.range(of: "boundary=Boundary-")
        else { return nil }
        return UUID(uuidString: String(contentType[range.upperBound...]))
    }

    static func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }

    /// The export's rows and sync-state lines for the audio source, built the way the export builds them.
    static func exportRows(
        engine: TransferEngine,
        sourceKey: String = "alpha",
        now: Date
    ) async -> (detail: SourceSyncStateDetail, lines: [String]) {
        let detail = await SourceSyncStateDetail.build(from: engine, sourceKey: sourceKey)
        let row = SourceSyncStateLine(
            name: "audio", pending: 0, inFlight: 0, attention: detail.attentionItemCount, delivered: 0,
            lastUploadAt: nil, recentErrorCount: 0, recentErrorDetail: nil, detail: detail
        )
        return (detail, syncStateSummaryLines(rows: [row], now: now))
    }

    func makeEngine(
        spool: TransferSpool,
        clock: FakeTransferClock = FakeTransferClock(wall: TransferSegmentRepairTests.launch),
        appBuild: String? = nil
    ) -> TransferEngine {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransferURLProtocol.self]
        return TransferEngine(
            spool: spool,
            transport: TransferTransport(sessionConfiguration: configuration),
            endpointResolver: TransferEndpointResolverStub(.available(TransferResolvedEndpoint(
                baseURL: URL(string: "http://127.0.0.1:7071")!
            ))),
            pacer: TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [0], maxDelay: 300)),
            clock: clock,
            appBuild: appBuild
        )
    }

    func pauseAtTeardown(_ engine: TransferEngine) {
        self.addTeardownBlock {
            await engine.pause()
        }
    }

    func waitFor(
        _ label: String,
        timeout: Duration = .seconds(10),
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(label)", file: file, line: line)
    }
}
