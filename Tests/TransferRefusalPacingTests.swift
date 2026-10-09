// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

/// A refusal the journal has already given for an item's own envelope is not sent again on every
/// new connection. The item stays on the device in attention, and the round that runs on each new
/// connection offers it again once a day, when what it was refused under changes, or on the
/// owner's own retry.
nonisolated final class TransferRefusalPacingTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferRefusalPacingTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        TransferURLProtocol.reset()
    }

    override func tearDown() {
        TransferURLProtocol.reset()
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    // MARK: - one round per refusal, not one per connection

    func testSettledRefusalsAreSentOnceAcrossSixConnections() async throws {
        let count = 160
        let root = self.tempDirectory.appendingPathComponent("per-connection", isDirectory: true)
        let ids = try self.seedStoredRefusals(spool: TransferSpool(rootURL: root), count: count)
        TransferURLProtocol.handler = Self.refusing(ids)
        let engine = self.makeEngine(spool: TransferSpool(rootURL: root), maxConcurrent: 2)
        self.pauseAtTeardown(engine)
        try await engine.start()

        var perRound: [Int] = []
        for _ in 1...6 {
            let before = Self.sends(of: ids)
            await engine.noteNewConnectionEstablished()
            await engine.endpointAvailabilityChanged()
            try await self.waitForQuiescence(engine, attentionCount: count, sentIDs: ids)
            perRound.append(Self.sends(of: ids) - before)
        }
        XCTAssertEqual(perRound, [count, 0, 0, 0, 0, 0], "sends per connection, total \(perRound.reduce(0, +))")
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.counters.attentionCount, count)
    }

    // MARK: - a re-offer is built from the item as it is now

    func testReofferAfterTheSegmentChangesOnDiskSendsARebuiltBody() async throws {
        let root = self.tempDirectory.appendingPathComponent("rebuilt-segment", isDirectory: true)
        let itemID = Self.uuid(6_001)
        TransferURLProtocol.handler = Self.refusingEverything()
        let first = self.makeEngine(spool: TransferSpool(rootURL: root))
        self.pauseAtTeardown(first)
        try await first.start()
        _ = try await first.enqueue(manifest: Self.ingestManifest(itemID: itemID), payloads: Self.audioPayloads)
        try await self.waitFor("refused into attention") {
            (await first.itemSnapshot(itemID: itemID))?.state == .attention
        }
        await first.pause()

        let spool = TransferSpool(rootURL: root)
        let attentionDirectory = spool.attentionDirectoryURL.appendingPathComponent(itemID.uuidString, isDirectory: true)
        let staleCache = try Data(contentsOf: attentionDirectory.appendingPathComponent(TransferSpool.bodyUploadFilename))
        XCTAssertEqual(TransferURLProtocol.bodies.last, staleCache, "the cache is the body the journal refused")
        var manifest = try spool.readManifest(in: attentionDirectory)
        manifest.observerIngest?.segment = Self.rewrittenSegment
        try spool.writeManifestAtomically(manifest, in: attentionDirectory)

        TransferURLProtocol.handler = Self.accepting()
        let second = self.makeEngine(spool: TransferSpool(rootURL: root))
        self.pauseAtTeardown(second)
        try await second.start()
        await second.noteNewConnectionEstablished()
        await second.endpointAvailabilityChanged()
        try await self.waitFor("re-offered") { TransferURLProtocol.bodies.count >= 2 }
        let sent = TransferURLProtocol.bodies[1]
        XCTAssertNotEqual(sent, staleCache, "a re-offer must not be sent from the refused cache")
        XCTAssertTrue(Self.text(sent).contains(Self.rewrittenSegment), "the rebuilt body carries the segment on disk")
        XCTAssertFalse(Self.text(sent).contains(Self.originalSegment))
    }

    /// The day is part of what a refusal was made under, as the segment is: a paced item whose
    /// day changes on disk is offered again, and the body is rebuilt from the day it has now.
    func testReofferAfterTheDayChangesOnDiskSendsARebuiltBody() async throws {
        let recorded = TransferRefusalConditions(
            endpointPath: "/app/devices/ingest",
            source: "alpha",
            day: Self.originalDay,
            segment: Self.originalSegment,
            ingestProtocolVersion: 3
        )
        var movedDay = recorded
        movedDay.day = Self.rewrittenDay
        XCTAssertEqual(recorded.changes(to: movedDay), [.day])
        XCTAssertEqual(recorded.changes(to: recorded), [])

        let root = self.tempDirectory.appendingPathComponent("rebuilt-day", isDirectory: true)
        let itemID = Self.uuid(6_011)
        TransferURLProtocol.handler = Self.refusingEverything()
        let first = self.makeEngine(spool: TransferSpool(rootURL: root))
        self.pauseAtTeardown(first)
        try await first.start()
        try await self.refuseOnce(first, itemID: itemID)
        await first.pause()

        // Nothing changed: a later launch leaves it where it is.
        let unchanged = self.makeEngine(spool: TransferSpool(rootURL: root))
        self.pauseAtTeardown(unchanged)
        try await unchanged.start()
        try await self.connect(unchanged, attentionCount: 1, sentIDs: [itemID])
        XCTAssertEqual(Self.sends(of: itemID), 1, "paced while nothing changed")
        await unchanged.pause()

        let spool = TransferSpool(rootURL: root)
        let attentionDirectory = spool.attentionDirectoryURL.appendingPathComponent(itemID.uuidString, isDirectory: true)
        let staleCache = try Data(contentsOf: attentionDirectory.appendingPathComponent(TransferSpool.bodyUploadFilename))
        var manifest = try spool.readManifest(in: attentionDirectory)
        manifest.observerIngest?.day = Self.rewrittenDay
        try spool.writeManifestAtomically(manifest, in: attentionDirectory)

        TransferURLProtocol.handler = Self.accepting()
        let second = self.makeEngine(spool: TransferSpool(rootURL: root))
        self.pauseAtTeardown(second)
        try await second.start()
        await second.noteNewConnectionEstablished()
        await second.endpointAvailabilityChanged()
        try await self.waitFor("re-offered") { Self.sends(of: itemID) >= 2 }
        let sent = try XCTUnwrap(TransferURLProtocol.bodies.last)
        XCTAssertNotEqual(sent, staleCache, "a re-offer must not be sent from the refused cache")
        XCTAssertTrue(Self.text(sent).contains(Self.rewrittenDay), "the rebuilt body carries the day on disk")
        XCTAssertFalse(Self.text(sent).contains(Self.originalDay))
    }
}

// MARK: - when a settled refusal is skipped and when it is offered again

extension TransferRefusalPacingTests {
    func testPacedRefusalIsNotResentAndStaysOnDiskInAttention() async throws {
        let root = self.tempDirectory.appendingPathComponent("paced-on-disk", isDirectory: true)
        let itemID = Self.uuid(2_001)
        TransferURLProtocol.handler = Self.refusingEverything()
        let engine = self.makeEngine(spool: TransferSpool(rootURL: root))
        self.pauseAtTeardown(engine)
        try await engine.start()
        try await self.refuseOnce(engine, itemID: itemID)
        let refusedUnder = try await XCTUnwrapAsync(await engine.itemSnapshot(itemID: itemID)?.manifest.attention?.refusedUnder)
        XCTAssertEqual(refusedUnder.segment, Self.originalSegment)

        let spool = TransferSpool(rootURL: root)
        let directory = spool.attentionDirectoryURL.appendingPathComponent(itemID.uuidString, isDirectory: true)
        for _ in 1...3 {
            try await self.connect(engine, attentionCount: 1, sentIDs: [itemID])
            XCTAssertEqual(Self.sends(of: itemID), 1)
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
            XCTAssertEqual(try spool.readManifest(in: directory).diskState, .attention)
            let snapshot = await engine.itemSnapshot(itemID: itemID)
            XCTAssertEqual(snapshot?.state, .attention)
            XCTAssertEqual(snapshot?.manifest.diskState, .attention)
            XCTAssertEqual(snapshot?.refusalPaced, true)
        }
    }

    func testPacedRefusalIsOfferedAgainAfterADayAndTheDayRestartsOnARefusal() async throws {
        let root = self.tempDirectory.appendingPathComponent("daily", isDirectory: true)
        let itemID = Self.uuid(3_001)
        TransferURLProtocol.handler = Self.refusingEverything()
        let clock = FakeTransferClock(wall: Self.baseDate)
        let engine = self.makeEngine(spool: TransferSpool(rootURL: root), clock: clock)
        self.pauseAtTeardown(engine)
        try await engine.start()
        try await self.refuseOnce(engine, itemID: itemID)

        clock.advanceWall(by: TransferRefusalPacing.recheckInterval - 60)
        try await self.connect(engine, attentionCount: 1, sentIDs: [itemID])
        XCTAssertEqual(Self.sends(of: itemID), 1, "not at 24 h - 60 s")

        clock.advanceWall(by: 60)
        try await self.connect(engine, attentionCount: 1, sentIDs: [itemID])
        XCTAssertEqual(Self.sends(of: itemID), 2, "offered again at 24 h and refused again")
        let refusedAgainAt = await engine.itemSnapshot(itemID: itemID)?.manifest.attention?.movedAt
        XCTAssertEqual(refusedAgainAt, clock.wallNow())
        let observed1 = await engine.itemSnapshot(itemID: itemID)?.manifest.attention?.refusedUnder
        XCTAssertNotNil(observed1)

        clock.advanceWall(by: 60)
        try await self.connect(engine, attentionCount: 1, sentIDs: [itemID])
        XCTAssertEqual(Self.sends(of: itemID), 2, "not at 24 h + 1 min: the second refusal restarted the day")

        clock.advanceWall(by: TransferRefusalPacing.recheckInterval - 60)
        try await self.connect(engine, attentionCount: 1, sentIDs: [itemID])
        XCTAssertEqual(Self.sends(of: itemID), 3, "offered again at 48 h")
    }

    func testPacedRefusalIsOfferedAgainUnderANewAppBuild() async throws {
        let root = self.tempDirectory.appendingPathComponent("new-build", isDirectory: true)
        let itemID = Self.uuid(3_002)
        TransferURLProtocol.handler = Self.refusingEverything()
        let first = self.makeEngine(spool: TransferSpool(rootURL: root), appBuild: "200")
        self.pauseAtTeardown(first)
        try await first.start()
        try await self.refuseOnce(first, itemID: itemID)
        let observed2 = await first.itemSnapshot(itemID: itemID)?.manifest.attention?.refusedUnder?.appBuild
        XCTAssertEqual(observed2, "200")
        await first.pause()

        let sameBuild = self.makeEngine(spool: TransferSpool(rootURL: root), appBuild: "200")
        self.pauseAtTeardown(sameBuild)
        try await sameBuild.start()
        try await self.connect(sameBuild, attentionCount: 1, sentIDs: [itemID])
        XCTAssertEqual(Self.sends(of: itemID), 1)
        await sameBuild.pause()

        let nextBuild = self.makeEngine(spool: TransferSpool(rootURL: root), appBuild: "201")
        self.pauseAtTeardown(nextBuild)
        try await nextBuild.start()
        try await self.connect(nextBuild, attentionCount: 1, sentIDs: [itemID])
        XCTAssertEqual(Self.sends(of: itemID), 2)
        let observed3 = await nextBuild.itemSnapshot(itemID: itemID)?.manifest.attention?.refusedUnder?.appBuild
        XCTAssertEqual(observed3, "201")
        try await self.connect(nextBuild, attentionCount: 1, sentIDs: [itemID])
        XCTAssertEqual(Self.sends(of: itemID), 2, "paced again under the new build")
    }

    /// Production order: the connection arms and its round runs first; the journal's version
    /// arrives afterwards, and the item goes on that same connection.
    func testANewJournalVersionOffersTheRefusalOnTheSameConnection() async throws {
        let root = self.tempDirectory.appendingPathComponent("journal-version", isDirectory: true)
        let itemID = Self.uuid(3_003)
        TransferURLProtocol.handler = Self.refusingEverything()
        let engine = self.makeEngine(spool: TransferSpool(rootURL: root), journalVersion: "v2.0.37")
        self.pauseAtTeardown(engine)
        try await engine.start()
        try await self.refuseOnce(engine, itemID: itemID)
        let observed4 = await engine.itemSnapshot(itemID: itemID)?.manifest.attention?.refusedUnder?.journalVersion
        XCTAssertEqual(observed4, "2.0.37")

        try await self.connect(engine, attentionCount: 1, sentIDs: [itemID])
        XCTAssertEqual(Self.sends(of: itemID), 1, "the connection's own round skips it")

        await engine.noteJournalVersion(nil)
        await engine.noteJournalVersion("2.0.37")
        try await self.waitForQuiescence(engine, attentionCount: 1, sentIDs: [itemID])
        XCTAssertEqual(Self.sends(of: itemID), 1, "an unknown or unchanged version is not a change")

        await engine.noteJournalVersion("2.0.38")
        try await self.waitFor("offered on the same connection") { Self.sends(of: itemID) == 2 }
        try await self.waitForQuiescence(engine, attentionCount: 1, sentIDs: [itemID])
        let observed5 = await engine.itemSnapshot(itemID: itemID)?.manifest.attention?.refusedUnder?.journalVersion
        XCTAssertEqual(observed5, "2.0.38")

        try await self.connect(engine, attentionCount: 1, sentIDs: [itemID])
        XCTAssertEqual(Self.sends(of: itemID), 2, "paced again under the new version")
    }

    func testAPairingChangeOffersTheRefusalAgain() async throws {
        let root = self.tempDirectory.appendingPathComponent("pairing", isDirectory: true)
        let itemID = Self.uuid(3_004)
        TransferURLProtocol.handler = Self.refusingEverything()
        let engine = self.makeEngine(spool: TransferSpool(rootURL: root))
        self.pauseAtTeardown(engine)
        try await engine.start()
        try await self.connect(engine, pairingIdentity: "pairing-a", attentionCount: 0, sentIDs: [itemID])
        try await self.refuseOnce(engine, itemID: itemID)
        let observed6 = await engine.itemSnapshot(itemID: itemID)?.manifest.attention?.refusedUnder?.pairingIdentity
        XCTAssertEqual(observed6, "pairing-a")

        try await self.connect(engine, pairingIdentity: "pairing-a", attentionCount: 1, sentIDs: [itemID])
        XCTAssertEqual(Self.sends(of: itemID), 1)

        try await self.connect(engine, pairingIdentity: "pairing-b", attentionCount: 1, sentIDs: [itemID])
        XCTAssertEqual(Self.sends(of: itemID), 2, "the pairing change re-queues every held item")
        XCTAssertEqual(TransferSpool(rootURL: root).followedPairing(), "pairing-b")
        let observed7 = await engine.itemSnapshot(itemID: itemID)?.manifest.attention?.refusedUnder?.pairingIdentity
        XCTAssertEqual(observed7, "pairing-b")
    }

    /// One item that cannot be moved must not leave the rest of a pairing change undone: the
    /// others move, a share import saved but not started is saved again, the item that could not
    /// move stays held, and the pairing is not recorded, so the next connection finishes it.
    func testAPairingChangeThatCannotMoveOneItemStillMovesTheRestAndIsRetried() async throws {
        let root = self.tempDirectory.appendingPathComponent("pairing-partial", isDirectory: true)
        let moving = Self.uuid(3_101)
        let held = Self.uuid(3_102)
        let savedImport = Self.uuid(3_103)
        let fileSystem = BodyCacheDeleteFailingFileSystem()
        TransferURLProtocol.handler = Self.refusingEverything()
        let engine = self.makeEngine(
            spool: TransferSpool(rootURL: root, fileSystem: fileSystem),
            bodyBuilder: Self.saveStartBodyBuilder
        )
        self.pauseAtTeardown(engine)
        try await engine.start()
        try await self.connect(engine, pairingIdentity: "pairing-a", attentionCount: 0, sentIDs: [])
        try await self.refuseOnce(engine, itemID: moving)
        try await self.refuseOnce(engine, itemID: held, attentionCount: 2)
        _ = try await engine.enqueue(
            manifest: Self.saveThenStartManifest(itemID: savedImport, phase: .startPending, code: "x"),
            payloads: ["file": Data("file".utf8)]
        )
        try await self.waitForQuiescence(engine, attentionCount: 3, sentIDs: [])
        let importBefore = await engine.itemSnapshot(itemID: savedImport)
        XCTAssertEqual(importBefore?.state, .attention)
        XCTAssertEqual(importBefore?.manifest.saveThenStart?.phase, .startPending)
        let heldDirectory = TransferSpool(rootURL: root).attentionDirectoryURL
            .appendingPathComponent(held.uuidString, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: heldDirectory.appendingPathComponent(TransferSpool.bodyUploadFilename).path
        ), "the held item has a cached body whose delete will fail")

        // Paused, so what the pairing change did can be read before anything is sent.
        await engine.pause()
        let sentBefore = TransferURLProtocol.requests.count
        fileSystem.failCacheDelete(for: held)
        await engine.noteNewConnectionEstablished(pairingIdentity: "pairing-b")

        let movedState = await engine.itemSnapshot(itemID: moving)?.state
        XCTAssertEqual(movedState, .queued, "the rest of the change still goes")
        let importAfter = await engine.itemSnapshot(itemID: savedImport)
        XCTAssertEqual(importAfter?.state, .queued)
        XCTAssertEqual(importAfter?.manifest.saveThenStart?.phase, .savePending, "saved again, not started from the old journal's path")
        let heldState = await engine.itemSnapshot(itemID: held)?.state
        XCTAssertEqual(heldState, .attention, "it stays held, never sent from its stale cache")
        XCTAssertEqual(TransferSpool(rootURL: root).followedPairing(), "pairing-a", "not recorded, so it is tried again")
        XCTAssertEqual(TransferURLProtocol.requests.count, sentBefore)

        fileSystem.failCacheDelete(for: nil)
        await engine.noteNewConnectionEstablished(pairingIdentity: "pairing-b")
        let heldAfter = await engine.itemSnapshot(itemID: held)?.state
        XCTAssertEqual(heldAfter, .queued, "moved on the next connection")
        let importAgain = await engine.itemSnapshot(itemID: savedImport)
        XCTAssertEqual(importAgain?.manifest.saveThenStart?.phase, .savePending)
        XCTAssertEqual(TransferSpool(rootURL: root).followedPairing(), "pairing-b")
    }

    func testTheOwnersTryNowSendsAPacedRefusalAtOnce() async throws {
        let root = self.tempDirectory.appendingPathComponent("try-now", isDirectory: true)
        let itemID = Self.uuid(3_005)
        TransferURLProtocol.handler = Self.refusingEverything()
        let engine = self.makeEngine(spool: TransferSpool(rootURL: root))
        self.pauseAtTeardown(engine)
        try await engine.start()
        try await self.refuseOnce(engine, itemID: itemID)
        let observed8 = await engine.itemSnapshot(itemID: itemID)?.refusalPaced
        XCTAssertEqual(observed8, true)

        try await engine.retryAttention(itemID: itemID)
        try await self.waitFor("sent on the owner's retry") { Self.sends(of: itemID) == 2 }
    }

    func testAClockMovedBackBehindTheRefusalOffersItAgain() async throws {
        let root = self.tempDirectory.appendingPathComponent("clock-back", isDirectory: true)
        let itemID = Self.uuid(3_006)
        TransferURLProtocol.handler = Self.refusingEverything()
        let clock = FakeTransferClock(wall: Self.baseDate)
        let engine = self.makeEngine(spool: TransferSpool(rootURL: root), clock: clock)
        self.pauseAtTeardown(engine)
        try await engine.start()
        try await self.refuseOnce(engine, itemID: itemID)

        clock.advanceWall(by: -60)
        try await self.connect(engine, attentionCount: 1, sentIDs: [itemID])
        XCTAssertEqual(Self.sends(of: itemID), 1, "60 s behind is within tolerance")

        clock.advanceWall(by: -3_540)
        try await self.connect(engine, attentionCount: 1, sentIDs: [itemID])
        XCTAssertEqual(Self.sends(of: itemID), 2, "1 h behind the refusal")
    }
}

// MARK: - relaunch, and a refusal recorded before the journal version was known

extension TransferRefusalPacingTests {
    @MainActor
    func testRelaunchWithNothingChangedDoesNotResendAPacedRefusal() async throws {
        let suite = "TransferRefusalPacingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let observed = JournalVersionMetadata(defaults: defaults) { _ in "v2.0.37" }
        observed.setIdentity("pairing-a")
        await observed.connected(localPort: 1)?.value
        XCTAssertNotNil(observed.version)

        let root = self.tempDirectory.appendingPathComponent("relaunch", isDirectory: true)
        let itemID = Self.uuid(4_001)
        TransferURLProtocol.handler = Self.refusingEverything()
        let first = self.makeEngine(
            spool: TransferSpool(rootURL: root),
            appBuild: SolstoneSwiftApp.refusalAppBuild,
            journalVersion: observed.version
        )
        self.pauseAtTeardown(first)
        try await first.start()
        try await self.connect(first, pairingIdentity: "pairing-a", attentionCount: 0, sentIDs: [itemID])
        try await self.refuseOnce(first, itemID: itemID)
        let recorded = try await XCTUnwrapAsync(await first.itemSnapshot(itemID: itemID)?.manifest.attention?.refusedUnder)
        XCTAssertNotNil(recorded.appBuild)
        XCTAssertEqual(recorded.journalVersion, "2.0.37")
        XCTAssertEqual(recorded.pairingIdentity, "pairing-a")
        await first.pause()

        // The app's launch: the stored record is loaded before the engine exists, the engine is
        // seeded from it and from the bundle, and the launch-time arm has no dialed pairing.
        let restored = JournalVersionMetadata(defaults: defaults) { _ in nil }
        restored.setIdentity("pairing-a")
        let relaunched = self.makeEngine(
            spool: TransferSpool(rootURL: root),
            appBuild: SolstoneSwiftApp.refusalAppBuild,
            journalVersion: restored.version
        )
        self.pauseAtTeardown(relaunched)
        try await relaunched.start()
        try await self.connect(relaunched, pairingIdentity: nil, attentionCount: 1, sentIDs: [itemID])
        XCTAssertEqual(Self.sends(of: itemID), 1)
        let snapshot = await relaunched.itemSnapshot(itemID: itemID)
        XCTAssertEqual(snapshot?.state, .attention)
        XCTAssertEqual(snapshot?.refusalPaced, true)
    }

    func testARefusalRecordedBeforeTheJournalVersionWasKnownIsOfferedOnceWhenItIsKnown() async throws {
        let root = self.tempDirectory.appendingPathComponent("recorded-unknown", isDirectory: true)
        let itemID = Self.uuid(18_001)
        TransferURLProtocol.handler = Self.refusingEverything()
        let engine = self.makeEngine(spool: TransferSpool(rootURL: root), journalVersion: nil)
        self.pauseAtTeardown(engine)
        try await engine.start()
        try await self.refuseOnce(engine, itemID: itemID)
        let recorded = try await XCTUnwrapAsync(await engine.itemSnapshot(itemID: itemID)?.manifest.attention?.refusedUnder)
        XCTAssertNil(recorded.journalVersion)

        try await self.connect(engine, attentionCount: 1, sentIDs: [itemID])
        XCTAssertEqual(Self.sends(of: itemID), 1, "still unknown: no change")

        await engine.noteJournalVersion("2.0.37")
        try await self.waitFor("offered once the version is known") { Self.sends(of: itemID) == 2 }
        try await self.waitForQuiescence(engine, attentionCount: 1, sentIDs: [itemID])
        let observed9 = await engine.itemSnapshot(itemID: itemID)?.manifest.attention?.refusedUnder?.journalVersion
        XCTAssertEqual(observed9, "2.0.37")

        try await self.connect(engine, attentionCount: 1, sentIDs: [itemID])
        XCTAssertEqual(Self.sends(of: itemID), 2, "then paced")
    }
}

// MARK: - which refusals are settled

extension TransferRefusalPacingTests {
    /// Every reason code in the journal's closed vocabulary at v2.0.37, as literal strings.
    static let journalReasonCodes: [String] = [
        "protocol_version_required",
        "protocol_version_malformed",
        "protocol_version_legacy",
        "protocol_version_future",
        "linked_device_required",
        "legacy_observer_field",
        "legacy_stream_field",
        "source_not_utf8",
        "source_too_long",
        "source_contains_nul",
        "source_contains_path_separator",
        "source_contains_dot",
        "source_invalid_character",
        "day_invalid",
        "segment_invalid",
        "field_missing",
        "field_duplicate",
        "envelope_invalid",
        "file_metadata_invalid",
        "file_name_mismatch",
        "file_name_invalid",
        "file_name_duplicate",
        "multipart_malformed",
        "multipart_part_too_large",
        "multipart_too_many_parts",
        "multipart_too_many_files",
        "multipart_too_many_headers",
        "multipart_filename_too_long",
        "content_conflict",
        "segment_allocation_failed",
        "journal_write_failed",
        "event_append_failed",
        "stream_advance_failed",
        "stream_marker_bump_failed",
        "location_lock_unavailable",
        "notify_failed",
        "journal_read_failed",
        "malformed_evidence_row",
        "ambiguous_segment_file_name",
        "foreign_stream_binding",
        "pairing_identity_unavailable",
        "stream_binding_incomplete",
        "segment_removed",
        "browser_record_invalid",
    ]

    static let settledLiterals: Set<String> = [
        "day_invalid",
        "segment_invalid",
        "envelope_invalid",
        "legacy_observer_field",
        "legacy_stream_field",
        "source_not_utf8",
        "source_too_long",
        "source_contains_nul",
        "source_contains_path_separator",
        "source_contains_dot",
        "source_invalid_character",
    ]

    func testOnlyTheElevenEnvelopeCodesAreSettledAcrossTheJournalsVocabulary() async throws {
        XCTAssertEqual(Self.journalReasonCodes.count, 44)
        XCTAssertEqual(Set(Self.journalReasonCodes).count, 44)
        XCTAssertTrue(Self.settledLiterals.isSubset(of: Set(Self.journalReasonCodes)))
        let codes = Self.journalReasonCodes + ["not_found", "an_unknown_reason_code"]
        var answers: [UUID: Answer] = [:]
        for (index, code) in codes.enumerated() {
            answers[Self.uuid(5_000 + index)] = Answer(statusCode: 400, body: Self.refusalBody(code: code))
        }
        let outcome = try await self.refuseThenConnect(answers: answers, root: "vocabulary")
        for (index, code) in codes.enumerated() {
            let itemID = Self.uuid(5_000 + index)
            let settled = Self.settledLiterals.contains(code)
            XCTAssertEqual(outcome.recorded[itemID], settled, "\(code): refusedUnder")
            XCTAssertEqual(outcome.sends[itemID], settled ? 1 : 2, "\(code): sent on the next connection")
        }
        XCTAssertEqual(outcome.recorded.values.filter { $0 }.count, 11)
    }

    func testTheElevenAreNotSettledUnderNotNowStatusesOrAFailedStatus() async throws {
        var answers: [UUID: Answer] = [:]
        var index = 0
        for code in Self.settledLiterals.sorted() {
            for statusCode in [408, 429, 426] {
                answers[Self.uuid(5_100 + index)] = Answer(statusCode: statusCode, body: Self.refusalBody(code: code))
                index += 1
            }
            answers[Self.uuid(5_100 + index)] = Answer(
                statusCode: 200,
                body: Data(#"{"status":"failed","reason_code":"\#(code)"}"#.utf8)
            )
            index += 1
        }
        let outcome = try await self.refuseThenConnect(answers: answers, root: "statuses")
        for itemID in answers.keys {
            XCTAssertEqual(outcome.recorded[itemID], false, "no refusedUnder")
            XCTAssertEqual(outcome.sends[itemID], 2, "sent on the next connection")
        }
        let snapshot = await outcome.engine.itemSnapshot(itemID: Self.uuid(5_100))
        XCTAssertNotNil(snapshot?.manifest.attention?.journalReasonCode, "the code is still kept for diagnosis")
    }

    /// The journal answers 400 for every code in the list. The same code under another refusal
    /// status did not come from the envelope alone, so it is not settled.
    func testTheElevenAreSettledOnlyOnA400() async throws {
        var answers: [UUID: Answer] = [:]
        var index = 0
        for code in Self.settledLiterals.sorted() {
            for statusCode in [422, 403] {
                answers[Self.uuid(5_700 + index)] = Answer(statusCode: statusCode, body: Self.refusalBody(code: code))
                index += 1
            }
        }
        answers[Self.uuid(5_799)] = Answer(statusCode: 400, body: Self.refusalBody(code: "segment_invalid"))
        let outcome = try await self.refuseThenConnect(answers: answers, root: "only-400")
        for (itemID, answer) in answers {
            let settled = answer.statusCode == 400
            XCTAssertEqual(outcome.recorded[itemID], settled, "status \(answer.statusCode): refusedUnder")
            XCTAssertEqual(outcome.sends[itemID], settled ? 1 : 2, "status \(answer.statusCode): sent on the next connection")
        }
        XCTAssertEqual(outcome.recorded.values.filter { $0 }.count, 1)
    }

    func testTheElevenAreNotSettledOnTheSaveOrStartPhase() async throws {
        let root = self.tempDirectory.appendingPathComponent("save-start", isDirectory: true)
        TransferURLProtocol.handler = { request, _ in
            let code = request.url?.lastPathComponent ?? ""
            return (Self.response(for: request, statusCode: 400), Self.refusalBody(code: String(code.split(separator: "-").last ?? "")))
        }
        let engine = self.makeEngine(spool: TransferSpool(rootURL: root), bodyBuilder: Self.saveStartBodyBuilder)
        self.pauseAtTeardown(engine)
        try await engine.start()
        var itemIDs: [UUID] = []
        for (index, code) in Self.settledLiterals.sorted().enumerated() {
            for (offset, phase) in [TransferSaveThenStartPhase.savePending, .startPending].enumerated() {
                let itemID = Self.uuid(5_300 + index * 2 + offset)
                itemIDs.append(itemID)
                _ = try await engine.enqueue(
                    manifest: Self.saveThenStartManifest(itemID: itemID, phase: phase, code: code),
                    payloads: ["file": Data("file".utf8)]
                )
            }
        }
        try await self.waitForQuiescence(engine, attentionCount: itemIDs.count, sentIDs: [])
        let firstRound = TransferURLProtocol.requests.count
        XCTAssertEqual(firstRound, itemIDs.count)
        for itemID in itemIDs {
            let attention = await engine.itemSnapshot(itemID: itemID)?.manifest.attention
            XCTAssertEqual(attention?.reason, TransferAttentionReason.httpClientErrorCode)
            XCTAssertNotNil(attention?.journalReasonCode)
            XCTAssertNil(attention?.refusedUnder)
        }
        try await self.connect(engine, attentionCount: itemIDs.count, sentIDs: [])
        XCTAssertEqual(TransferURLProtocol.requests.count, firstRound * 2, "every one is sent on the next connection")
    }

    /// A body cut off mid-send can come back as `multipart_malformed`; that answer is never paced.
    func testASettledItemAnsweredMultipartMalformedOnItsDailyRoundIsSentOnTheNextConnection() async throws {
        let root = self.tempDirectory.appendingPathComponent("cut-off", isDirectory: true)
        let itemID = Self.uuid(5_500)
        TransferURLProtocol.handler = Self.refusingEverything()
        let clock = FakeTransferClock(wall: Self.baseDate)
        let engine = self.makeEngine(spool: TransferSpool(rootURL: root), clock: clock)
        self.pauseAtTeardown(engine)
        try await engine.start()
        try await self.refuseOnce(engine, itemID: itemID)

        TransferURLProtocol.handler = Self.refusingEverything(body: Self.refusalBody(code: "multipart_malformed"))
        clock.advanceWall(by: TransferRefusalPacing.recheckInterval)
        try await self.connect(engine, attentionCount: 1, sentIDs: [itemID])
        XCTAssertEqual(Self.sends(of: itemID), 2)
        let attention = await engine.itemSnapshot(itemID: itemID)?.manifest.attention
        XCTAssertEqual(attention?.journalReasonCode, "multipart_malformed")
        XCTAssertNil(attention?.refusedUnder)

        try await self.connect(engine, attentionCount: 1, sentIDs: [itemID])
        XCTAssertEqual(Self.sends(of: itemID), 3, "sent on the very next connection")
    }
}

// MARK: - bytes on the wire after a re-offer

extension TransferRefusalPacingTests {
    func testAReofferWhoseCacheCannotBeDroppedStaysInAttentionAndSendsNothing() async throws {
        let root = self.tempDirectory.appendingPathComponent("cache-delete-fails", isDirectory: true)
        let held = Self.uuid(6_101)
        let other = Self.uuid(6_102)
        let fileSystem = BodyCacheDeleteFailingFileSystem()
        TransferURLProtocol.handler = Self.refusingEverything()
        let clock = FakeTransferClock(wall: Self.baseDate)
        let engine = self.makeEngine(spool: TransferSpool(rootURL: root, fileSystem: fileSystem), clock: clock)
        self.pauseAtTeardown(engine)
        try await engine.start()
        try await self.refuseOnce(engine, itemID: held)
        try await self.refuseOnce(engine, itemID: other, attentionCount: 2)
        let spool = TransferSpool(rootURL: root)
        let heldDirectory = spool.attentionDirectoryURL.appendingPathComponent(held.uuidString, isDirectory: true)
        let staleCache = try Data(contentsOf: heldDirectory.appendingPathComponent(TransferSpool.bodyUploadFilename))
        let manifestBefore = try Data(contentsOf: heldDirectory.appendingPathComponent(TransferSpool.manifestFilename))

        fileSystem.failCacheDelete(for: held)
        clock.advanceWall(by: TransferRefusalPacing.recheckInterval)
        try await self.connect(engine, attentionCount: 2, sentIDs: [held, other])
        XCTAssertEqual(Self.sends(of: held), 1, "nothing is sent from the stale cache")
        XCTAssertEqual(Self.sends(of: other), 2, "the rest of the round still goes")
        let observed10 = await engine.itemSnapshot(itemID: held)?.state
        XCTAssertEqual(observed10, .attention)
        XCTAssertEqual(try Data(contentsOf: heldDirectory.appendingPathComponent(TransferSpool.manifestFilename)), manifestBefore)
        XCTAssertEqual(try Data(contentsOf: heldDirectory.appendingPathComponent(TransferSpool.bodyUploadFilename)), staleCache)

        fileSystem.failCacheDelete(for: nil)
        try await self.connect(engine, attentionCount: 2, sentIDs: [held, other])
        XCTAssertEqual(Self.sends(of: held), 2, "offered on a later round once the cache drops")
    }

    func testANewBuildSendsItsOwnBuildersBytesNotTheCache() async throws {
        let root = self.tempDirectory.appendingPathComponent("new-builder", isDirectory: true)
        let itemID = Self.uuid(6_201)
        TransferURLProtocol.handler = Self.refusingEverything()
        let first = self.makeEngine(spool: TransferSpool(rootURL: root), appBuild: "300")
        self.pauseAtTeardown(first)
        try await first.start()
        try await self.refuseOnce(first, itemID: itemID)
        await first.pause()
        let staleCache = try XCTUnwrap(TransferURLProtocol.bodies.last)

        TransferURLProtocol.handler = Self.accepting()
        let builder: TransferBodyBuilder = { item, spool in
            var changed = item
            changed.manifest.observerIngest?.platform = "ios-next-envelope"
            return try DefaultTransferBodyBuilder.build(item: changed, spool: spool)
        }
        let next = self.makeEngine(spool: TransferSpool(rootURL: root), bodyBuilder: builder, appBuild: "301")
        self.pauseAtTeardown(next)
        try await next.start()
        await next.noteNewConnectionEstablished()
        await next.endpointAvailabilityChanged()
        try await self.waitFor("sent under the new build") { TransferURLProtocol.bodies.count >= 2 }
        let sent = TransferURLProtocol.bodies[1]
        XCTAssertNotEqual(sent, staleCache)
        XCTAssertTrue(Self.text(sent).contains("ios-next-envelope"))
    }
}

// MARK: - records from before this build, and the stored form

extension TransferRefusalPacingTests {
    func testARefusalStoredWithoutConditionsIsOfferedOnceThenPaced() async throws {
        let root = self.tempDirectory.appendingPathComponent("legacy", isDirectory: true)
        let ids = try self.seedStoredRefusals(spool: TransferSpool(rootURL: root), count: 1, firstID: 7_001)
        let itemID = try XCTUnwrap(ids.first)
        TransferURLProtocol.handler = Self.refusingEverything()
        let engine = self.makeEngine(spool: TransferSpool(rootURL: root))
        self.pauseAtTeardown(engine)
        try await engine.start()
        let observed11 = await engine.itemSnapshot(itemID: itemID)?.manifest.attention?.refusedUnder
        XCTAssertNil(observed11)
        let observed12 = await engine.itemSnapshot(itemID: itemID)?.refusalPaced
        XCTAssertEqual(observed12, false)

        try await self.connect(engine, attentionCount: 1, sentIDs: ids)
        XCTAssertEqual(Self.sends(of: itemID), 1, "offered once")
        let observed13 = await engine.itemSnapshot(itemID: itemID)?.manifest.attention?.refusedUnder
        XCTAssertNotNil(observed13)
        try await self.connect(engine, attentionCount: 1, sentIDs: ids)
        try await self.connect(engine, attentionCount: 1, sentIDs: ids)
        XCTAssertEqual(Self.sends(of: itemID), 1, "then paced")
    }

    func testAttentionRecordsRoundTripThroughTheSpoolCoder() throws {
        let fixture = #"{"appVersion":"1.0.0","attention":{"movedAt":"2024-04-20T15:00:00Z","reason":"http_client_error","shortDetail":"reason_code=segment_invalid"},"createdAt":"2024-04-20T14:40:00Z","diskState":"attention","endpoint":{"destinationKind":"observer_ingest","path":"\/app\/devices\/ingest"},"itemID":"00000000-0000-0000-0000-000000000050","meta":{},"observerIngest":{"day":"20240420","durationS":13,"ingestProtocolVersion":3,"platform":"ios","segment":"144000_13","sources":["audio"],"startedAt":"2024-04-20T14:40:00Z"},"payloadParts":[{"contentType":"audio\/mp4","filename":"audio.m4a","kind":"audio","partID":"audio","relativePath":"audio.m4a","requiredForDispatch":true}],"priority":{"basePriority":"normal","sourceKey":"audio","userInitiated":false},"retryCount":0,"schemaVersion":"solstone.transfer.item\/1","source":"audio"}"#
        let decoded = try TransferSpool.decoder().decode(TransferManifest.self, from: Data(fixture.utf8))
        XCTAssertNil(decoded.attention?.refusedUnder)
        XCTAssertEqual(String(decoding: try TransferSpool.encoder().encode(decoded), as: UTF8.self), fixture)

        let conditions = TransferRefusalConditions(
            appBuild: "125",
            pairingIdentity: "sha256:abc",
            journalVersion: "2.0.37",
            endpointPath: "/app/devices/ingest",
            source: "audio",
            day: "20240420",
            segment: "144000_13",
            ingestProtocolVersion: 3
        )
        for journalReasonCode in [nil, "segment_invalid"] as [String?] {
            var withCode = decoded
            withCode.attention?.journalReasonCode = journalReasonCode
            let codeOnly = try TransferSpool.encoder().encode(withCode)
            XCTAssertEqual(try TransferSpool.decoder().decode(TransferManifest.self, from: codeOnly), withCode)
            XCTAssertEqual(try TransferSpool.encoder().encode(TransferSpool.decoder().decode(TransferManifest.self, from: codeOnly)), codeOnly)

            var withBoth = withCode
            withBoth.attention?.refusedUnder = conditions
            let encoded = try TransferSpool.encoder().encode(withBoth)
            XCTAssertTrue(Self.text(encoded).contains(#""refusedUnder":{"#))
            let roundTripped = try TransferSpool.decoder().decode(TransferManifest.self, from: encoded)
            XCTAssertEqual(roundTripped, withBoth)
            XCTAssertEqual(roundTripped.attention?.journalReasonCode, journalReasonCode)
            XCTAssertEqual(try TransferSpool.encoder().encode(roundTripped), encoded)
        }

        let malformed = fixture.replacingOccurrences(
            of: #""shortDetail":"reason_code=segment_invalid"}"#,
            with: #""refusedUnder":{"segment":7},"shortDetail":"reason_code=segment_invalid"}"#
        )
        XCTAssertNotEqual(malformed, fixture)
        let tolerated = try TransferSpool.decoder().decode(TransferManifest.self, from: Data(malformed.utf8))
        XCTAssertEqual(tolerated.attention?.reason, TransferAttentionReason.httpClientErrorCode)
        XCTAssertNil(tolerated.attention?.refusedUnder, "an unreadable record is dropped, never the item")

        let unknownBuild = TransferRefusalConditions(
            endpointPath: "/app/devices/ingest",
            source: "audio",
            day: "20240420",
            segment: "144000_13"
        )
        let encodedUnknown = try TransferSpool.encoder().encode(unknownBuild)
        XCTAssertEqual(
            Self.text(encodedUnknown),
            #"{"day":"20240420","endpointPath":"\/app\/devices\/ingest","segment":"144000_13","source":"audio"}"#
        )
        XCTAssertEqual(try TransferSpool.decoder().decode(TransferRefusalConditions.self, from: encodedUnknown), unknownBuild)
    }
}

extension TransferRefusalPacingTests {
    func testAnUnreadableRefusalRecordNeverHidesTheItem() async throws {
        let root = self.tempDirectory.appendingPathComponent("unreadable-record", isDirectory: true)
        let ids = try self.seedSettledRefusals(spool: TransferSpool(rootURL: root), count: 1, source: "alpha", firstID: 7_101)
        let itemID = try XCTUnwrap(ids.first)
        let spool = TransferSpool(rootURL: root)
        let directory = spool.attentionDirectoryURL.appendingPathComponent(itemID.uuidString, isDirectory: true)
        let manifestURL = directory.appendingPathComponent(TransferSpool.manifestFilename)
        let stored = Self.text(try Data(contentsOf: manifestURL))
        let broken = stored.replacingOccurrences(of: #""segment":"120000_3","source":"alpha"}"#, with: #""segment":7}"#)
        XCTAssertNotEqual(broken, stored)
        try Data(broken.utf8).write(to: manifestURL)

        TransferURLProtocol.handler = Self.refusingEverything()
        let engine = self.makeEngine(spool: TransferSpool(rootURL: root))
        self.pauseAtTeardown(engine)
        try await engine.start()
        let loaded = await engine.itemSnapshot(itemID: itemID)
        XCTAssertEqual(loaded?.state, .attention, "still held and visible")
        XCTAssertNil(loaded?.manifest.attention?.refusedUnder)
        try await self.connect(engine, attentionCount: 1, sentIDs: ids)
        XCTAssertEqual(Self.sends(of: itemID), 1, "offered like any refusal without a record")
    }
}

// MARK: - order, and what the owner is told is held

extension TransferRefusalPacingTests {
    func testAPacedRefusalNeverHoldsItsSourceAndARoundSendsOldestFirst() async throws {
        let root = self.tempDirectory.appendingPathComponent("order", isDirectory: true)
        let refused = [Self.uuid(10_001), Self.uuid(10_002), Self.uuid(10_003)]
        let fresh = Self.uuid(10_010)
        TransferURLProtocol.handler = Self.refusing(Set(refused))
        let clock = FakeTransferClock(wall: Self.baseDate)
        let engine = self.makeEngine(spool: TransferSpool(rootURL: root), clock: clock, maxConcurrent: 1)
        self.pauseAtTeardown(engine)
        try await engine.start()
        // Enqueued newest first, so only the oldest-first rule can put them back in order.
        for (offset, itemID) in refused.enumerated().reversed() {
            _ = try await engine.enqueue(
                manifest: Self.ingestManifest(itemID: itemID, createdAt: Self.baseDate.addingTimeInterval(-3_600 + Double(offset) * 300)),
                payloads: Self.audioPayloads
            )
        }
        try await self.waitForQuiescence(engine, attentionCount: 3, sentIDs: Set(refused))
        for itemID in refused {
            let observed14 = await engine.itemSnapshot(itemID: itemID)?.refusalPaced
            XCTAssertEqual(observed14, true)
        }

        _ = try await engine.enqueue(
            manifest: Self.ingestManifest(itemID: fresh, createdAt: Self.baseDate.addingTimeInterval(-60)),
            payloads: Self.audioPayloads
        )
        try await self.waitFor("newer audio of the same source delivered") {
            (await engine.snapshot()).counters.deliveredCount == 1
        }
        try await self.connect(engine, attentionCount: 3, sentIDs: Set(refused))
        XCTAssertEqual(Self.sends(of: Set(refused)), 3, "the paced ones did not go ahead of it or with it")

        let before = TransferURLProtocol.requests.count
        clock.advanceWall(by: TransferRefusalPacing.recheckInterval)
        try await self.connect(engine, attentionCount: 3, sentIDs: Set(refused))
        let round = TransferURLProtocol.requests[before...].compactMap(Self.boundaryItemID(from:))
        XCTAssertEqual(round, refused, "the daily round goes oldest first")
    }

    @MainActor
    func testTheOwnersHeldCountStillCountsEveryPacedRefusal() async throws {
        let count = 160
        let root = self.tempDirectory.appendingPathComponent("held-count", isDirectory: true)
        let source = ObserverAudioTransferSource.mobileSegment
        let ids = try self.seedSettledRefusals(spool: TransferSpool(rootURL: root), count: count, source: source)
        TransferURLProtocol.handler = Self.refusing(ids)
        let mirror = TransferStatusMirror()
        let engine = self.makeEngine(spool: TransferSpool(rootURL: root), statusMirror: mirror)
        self.pauseAtTeardown(engine)
        try await engine.start()
        let holder = MobileSegmentTransferHolder(
            transferEngine: engine,
            mirror: mirror,
            uploader: MobileSegmentUploader(
                transferEngine: engine,
                store: MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("mobile-store", isDirectory: true)),
                clock: MockObserverClock()
            )
        )

        try await self.connect(engine, attentionCount: count, sentIDs: ids)
        XCTAssertEqual(Self.sends(of: ids), 0, "all paced")
        try await self.waitFor("held count published") {
            await MainActor.run { holder.failedCount == count && holder.pendingCount == 0 }
        }
        await holder.refreshFacetSummaries()
        XCTAssertEqual(holder.summary(for: .audio).failedCount, count)
        let paced = await engine.itemSnapshots(sourceKey: source).filter(\.refusalPaced).count
        XCTAssertEqual(paced, count)
    }
}

// MARK: - what the owner reads, and the app's own wiring

extension TransferRefusalPacingTests {
    func testThePacedFlagSelectsTheDetailLineWithAndWithoutAttempts() async throws {
        let root = self.tempDirectory.appendingPathComponent("detail-line", isDirectory: true)
        let itemID = Self.uuid(16_001)
        TransferURLProtocol.handler = Self.refusingEverything()
        let first = self.makeEngine(spool: TransferSpool(rootURL: root), appBuild: "400")
        self.pauseAtTeardown(first)
        try await first.start()
        try await self.refuseOnce(first, itemID: itemID)

        let withAttempts = try await self.detailMessage(engine: first, itemID: itemID)
        XCTAssertEqual(withAttempts.attempts, 1)
        XCTAssertTrue(withAttempts.paced)
        XCTAssertEqual(withAttempts.message, SourceVocabulary.onThisPhoneRefusalPacedMessage)
        await first.pause()

        let relaunched = self.makeEngine(spool: TransferSpool(rootURL: root), appBuild: "400")
        self.pauseAtTeardown(relaunched)
        try await relaunched.initialize()
        let afterRelaunch = try await self.detailMessage(engine: relaunched, itemID: itemID)
        XCTAssertEqual(afterRelaunch.attempts, 0)
        XCTAssertTrue(afterRelaunch.paced)
        XCTAssertEqual(afterRelaunch.message, SourceVocabulary.onThisPhoneRefusalPacedMessage)

        let dayLater = self.makeEngine(
            spool: TransferSpool(rootURL: root),
            clock: FakeTransferClock(wall: Self.baseDate.addingTimeInterval(TransferRefusalPacing.recheckInterval)),
            appBuild: "400"
        )
        self.pauseAtTeardown(dayLater)
        try await dayLater.initialize()
        let elapsed = try await self.detailMessage(engine: dayLater, itemID: itemID)
        XCTAssertFalse(elapsed.paced)
        XCTAssertEqual(elapsed.message, SourceVocabulary.onThisPhoneWaitingExplain, "today's line")

        let newBuild = self.makeEngine(spool: TransferSpool(rootURL: root), appBuild: "401")
        self.pauseAtTeardown(newBuild)
        try await newBuild.initialize()
        let rebuilt = try await self.detailMessage(engine: newBuild, itemID: itemID)
        XCTAssertFalse(rebuilt.paced)
        XCTAssertEqual(rebuilt.message, SourceVocabulary.onThisPhoneWaitingExplain, "today's line")
    }

    func testTheDetailLineFollowsOnlyTheFlag() throws {
        let now = Self.baseDate
        for attempts in [nil, 1, 4] as [Int?] {
            let paced = try XCTUnwrap(OnThisPhoneItemDetailPresentation.failureLegibility(
                for: Self.ownerItem(failureAttemptCount: attempts, refusalPaced: true),
                now: now
            ))
            XCTAssertEqual(paced.message, SourceVocabulary.onThisPhoneRefusalPacedMessage)
            let unpaced = try XCTUnwrap(OnThisPhoneItemDetailPresentation.failureLegibility(
                for: Self.ownerItem(failureAttemptCount: attempts, refusalPaced: false),
                now: now
            ))
            XCTAssertEqual(
                unpaced.message,
                attempts.map(SourceVocabulary.onThisPhoneFailureRetryableMessage(count:)) ?? SourceVocabulary.onThisPhoneWaitingExplain
            )
        }
    }

    @MainActor
    func testTheAppsJournalVersionChangeReachesTheEngineAndTheWatch() async throws {
        let suite = "TransferRefusalPacingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let metadata = JournalVersionMetadata(defaults: defaults) { _ in "2.0.38" }
        let session = MockWatchConnectivitySession()
        session.activationState = .activated
        let watchLink = WatchLink(
            session: session,
            receiver: nil,
            facts: WatchSourceFacts(defaults: defaults),
            phoneSessionHistoryStore: WatchPhoneSessionHistoryStore(
                fileURL: self.tempDirectory
                    .appendingPathComponent("history", isDirectory: true)
                    .appendingPathComponent(WatchPhoneSessionHistoryStore.historyFileName),
                clock: Date.init
            )
        )
        let engine = self.makeEngine(
            spool: TransferSpool(rootURL: self.tempDirectory.appendingPathComponent("wiring", isDirectory: true)),
            journalVersion: "2.0.37"
        )
        self.pauseAtTeardown(engine)

        SolstoneSwiftApp.wireJournalVersion(metadata, watchLink: watchLink, transferEngine: engine)
        metadata.setIdentity("pairing-a")
        await metadata.connected(localPort: 1)?.value

        let published = try XCTUnwrap(session.updatedApplicationContexts.last?[WatchJournalVersionPayload.contextKey] as? Data)
        XCTAssertEqual(try JSONDecoder().decode(WatchJournalVersionPayload.self, from: published).version, "2.0.38")
        try await self.waitFor("the engine learns the version") {
            await engine.knownJournalVersion == "2.0.38"
        }
    }
}

// MARK: - helpers

private extension TransferRefusalPacingTests {
    static let baseDate = Date(timeIntervalSince1970: 1_713_624_000)
    static let originalSegment = "120000_3"
    static let rewrittenSegment = "120500_3"
    static let originalDay = "20240420"
    static let rewrittenDay = "20240421"
    static let audioPayloads: [String: Data] = ["audio": Data("audio".utf8)]
    static let segmentInvalidBody = Data(
        #"{"error":"Ingest request refused","reason_code":"segment_invalid","detail":"segment must be HHMMSS_LEN"}"#.utf8
    )

    static func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    static func ingestManifest(
        itemID: UUID,
        source: String = "alpha",
        createdAt: Date = TransferRefusalPacingTests.baseDate,
        segment: String = TransferRefusalPacingTests.originalSegment
    ) -> TransferManifest {
        TransferManifest(
            itemID: itemID,
            source: source,
            createdAt: createdAt,
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
                day: "20240420",
                startedAt: createdAt,
                durationS: 3,
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

    func makeEngine(
        spool: TransferSpool,
        clock: FakeTransferClock = FakeTransferClock(wall: TransferRefusalPacingTests.baseDate),
        statusMirror: TransferStatusMirror? = nil,
        maxConcurrent: Int = 3,
        bodyBuilder: @escaping TransferBodyBuilder = DefaultTransferBodyBuilder.build,
        appBuild: String? = nil,
        journalVersion: String? = nil
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
            statusMirror: statusMirror,
            maxConcurrent: maxConcurrent,
            bodyBuilder: bodyBuilder,
            appBuild: appBuild,
            journalVersion: journalVersion
        )
    }

    struct Answer: Sendable {
        var statusCode: Int
        var body: Data
    }

    struct RoundOutcome {
        var engine: TransferEngine
        var recorded: [UUID: Bool]
        var sends: [UUID: Int]
    }

    static func refusalBody(code: String) -> Data {
        Data(#"{"error":"Ingest request refused","reason_code":"\#(code)","detail":"detail text"}"#.utf8)
    }

    /// Each item is refused once with its own answer, then one new connection runs a round.
    func refuseThenConnect(answers: [UUID: Answer], root: String) async throws -> RoundOutcome {
        TransferURLProtocol.handler = { request, _ in
            guard let itemID = Self.boundaryItemID(from: request), let answer = answers[itemID] else {
                return (Self.response(for: request, statusCode: 500), Data())
            }
            return (Self.response(for: request, statusCode: answer.statusCode), answer.body)
        }
        let engine = self.makeEngine(spool: TransferSpool(rootURL: self.tempDirectory.appendingPathComponent(root, isDirectory: true)))
        self.pauseAtTeardown(engine)
        try await engine.start()
        for itemID in answers.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            _ = try await engine.enqueue(manifest: Self.ingestManifest(itemID: itemID), payloads: Self.audioPayloads)
        }
        let ids = Set(answers.keys)
        try await self.waitForQuiescence(engine, attentionCount: answers.count, sentIDs: ids)
        XCTAssertEqual(Self.sends(of: ids), answers.count)
        var recorded: [UUID: Bool] = [:]
        for itemID in ids {
            let attention = await engine.itemSnapshot(itemID: itemID)?.manifest.attention
            XCTAssertEqual(attention?.reason, TransferAttentionReason.httpClientErrorCode)
            recorded[itemID] = attention?.refusedUnder != nil
        }
        try await self.connect(engine, attentionCount: answers.count, sentIDs: ids)
        var sends: [UUID: Int] = [:]
        for itemID in ids {
            sends[itemID] = Self.sends(of: itemID)
        }
        return RoundOutcome(engine: engine, recorded: recorded, sends: sends)
    }

    static func saveThenStartManifest(itemID: UUID, phase: TransferSaveThenStartPhase, code: String) -> TransferManifest {
        var manifest = Self.ingestManifest(itemID: itemID)
        manifest.payloadParts = [
            TransferPayloadPartDescriptor(
                partID: "file",
                kind: .file,
                relativePath: "file.txt",
                filename: "file.txt",
                contentType: "text/plain"
            ),
        ]
        manifest.endpoint = TransferEndpointDescriptor(
            destinationKind: .saveThenStart,
            path: "/save-\(code)",
            startPath: "/start-\(code)"
        )
        manifest.saveThenStart = phase == .startPending
            ? TransferSaveThenStartState(phase: .startPending, savedPath: "saved/file.txt", savedTimestamp: "20240420T120000")
            : TransferSaveThenStartState(phase: .savePending)
        return manifest
    }

    static let saveStartBodyBuilder: TransferBodyBuilder = { item, spool in
        if item.manifest.saveThenStart?.phase == .savePending {
            return .inMemory(Data("save-body".utf8))
        }
        return try DefaultTransferBodyBuilder.build(item: item, spool: spool)
    }

    static func ownerItem(failureAttemptCount: Int?, refusalPaced: Bool) -> OnThisPhoneItem {
        OnThisPhoneItem(
            id: UUID().uuidString,
            sourceKind: .audio,
            sendState: .needsAttention,
            contentType: "audio/mp4",
            filename: "audio.m4a",
            bytes: nil,
            originApp: nil,
            basis: nil,
            itemTime: Self.baseDate,
            targetJournal: nil,
            stream: nil,
            day: nil,
            segment: nil,
            deliveredAt: nil,
            rawFileURL: nil,
            failureReason: "your journal couldn't accept it",
            failureAttemptCount: failureAttemptCount,
            retryAvailable: true,
            lastAttemptAt: nil,
            refusalPaced: refusalPaced
        )
    }

    struct DetailMessage {
        var message: String
        var attempts: Int
        var paced: Bool
    }

    /// What the item's detail screen says, through the same mapping the screen uses.
    func detailMessage(engine: TransferEngine, itemID: UUID) async throws -> DetailMessage {
        let snapshot = try await XCTUnwrapAsync(await engine.itemSnapshot(itemID: itemID))
        let items = await ObserverAudioTransferSnapshotMapper.mobileSegmentItems(snapshots: [snapshot], engine: engine)
        let item = try XCTUnwrap(items.first)
        let legibility = try XCTUnwrap(OnThisPhoneItemDetailPresentation.failureLegibility(for: item, now: Self.baseDate))
        return DetailMessage(message: legibility.message, attempts: snapshot.attempts, paced: item.refusalPaced)
    }

    /// Settled refusals stored under exactly the conditions a default test engine reports.
    func seedSettledRefusals(spool: TransferSpool, count: Int, source: String, firstID: Int = 11_000) throws -> Set<UUID> {
        var ids: Set<UUID> = []
        for index in 0..<count {
            let itemID = Self.uuid(firstID + index)
            let manifest = Self.ingestManifest(
                itemID: itemID,
                source: source,
                createdAt: Self.baseDate.addingTimeInterval(-2 * 86_400 + Double(index) * 300)
            )
            let queued = try spool.commitStagedItem(
                itemID: spool.stage(manifest: manifest, payloads: Self.audioPayloads).item.manifest.itemID
            )
            _ = try spool.moveQueuedItemToAttention(
                queued,
                reason: TransferAttentionReason.httpClientErrorCode,
                detail: "reason_code=segment_invalid",
                journalReasonCode: "segment_invalid",
                refusedUnder: TransferRefusalConditions(
                    endpointPath: manifest.endpoint.path,
                    source: source,
                    day: manifest.observerIngest?.day ?? "",
                    segment: manifest.observerIngest?.segment ?? "",
                    ingestProtocolVersion: 3
                ),
                now: Self.baseDate.addingTimeInterval(-60)
            )
            ids.insert(itemID)
        }
        return ids
    }

    /// Enqueues one item, lets the journal refuse it, and waits until it rests in attention.
    func refuseOnce(_ engine: TransferEngine, itemID: UUID, attentionCount: Int = 1) async throws {
        _ = try await engine.enqueue(manifest: Self.ingestManifest(itemID: itemID), payloads: Self.audioPayloads)
        try await self.waitForQuiescence(engine, attentionCount: attentionCount, sentIDs: [itemID])
        XCTAssertEqual(Self.sends(of: itemID), 1)
    }

    /// A new connection, and the round it starts run to the end.
    func connect(
        _ engine: TransferEngine,
        pairingIdentity: String? = nil,
        attentionCount: Int,
        sentIDs: Set<UUID>
    ) async throws {
        await engine.noteNewConnectionEstablished(pairingIdentity: pairingIdentity)
        await engine.endpointAvailabilityChanged()
        try await self.waitForQuiescence(engine, attentionCount: attentionCount, sentIDs: sentIDs)
    }

    func pauseAtTeardown(_ engine: TransferEngine) {
        self.addTeardownBlock {
            await engine.pause()
        }
    }

    /// Refusals stored by a build that recorded nothing about the conditions they were made under.
    func seedStoredRefusals(spool: TransferSpool, count: Int, firstID: Int = 50_000) throws -> Set<UUID> {
        var ids: Set<UUID> = []
        for index in 0..<count {
            let itemID = Self.uuid(firstID + index)
            var manifest = Self.ingestManifest(
                itemID: itemID,
                createdAt: Self.baseDate.addingTimeInterval(-2 * 86_400 + Double(index) * 300)
            )
            manifest.retryCount = 1
            let queued = try spool.commitStagedItem(
                itemID: spool.stage(manifest: manifest, payloads: Self.audioPayloads).item.manifest.itemID
            )
            _ = try spool.moveQueuedItemToAttention(
                queued,
                reason: TransferAttentionReason.httpClientErrorCode,
                detail: "reason_code=segment_invalid",
                now: Self.baseDate.addingTimeInterval(-60)
            )
            ids.insert(itemID)
        }
        return ids
    }

    static func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }

    static func boundaryItemID(from request: URLRequest) -> UUID? {
        guard let contentType = request.value(forHTTPHeaderField: "Content-Type"),
              let boundaryRange = contentType.range(of: "boundary=Boundary-")
        else {
            return nil
        }
        return UUID(uuidString: String(contentType[boundaryRange.upperBound...]))
    }

    static func refusing(_ refused: Set<UUID>) -> TransferURLProtocol.Handler {
        { request, body in
            if let itemID = Self.boundaryItemID(from: request), refused.contains(itemID) {
                return (Self.response(for: request, statusCode: 400), Self.segmentInvalidBody)
            }
            return (
                Self.response(for: request, statusCode: 200),
                transferTestMatchingReceipt(body: body, contentType: request.value(forHTTPHeaderField: "Content-Type"))
            )
        }
    }

    static func refusingEverything(statusCode: Int = 400, body: Data = TransferRefusalPacingTests.segmentInvalidBody) -> TransferURLProtocol.Handler {
        { request, _ in
            (Self.response(for: request, statusCode: statusCode), body)
        }
    }

    static func accepting() -> TransferURLProtocol.Handler {
        { request, body in
            (
                Self.response(for: request, statusCode: 200),
                transferTestMatchingReceipt(body: body, contentType: request.value(forHTTPHeaderField: "Content-Type"))
            )
        }
    }

    static func sends(of ids: Set<UUID>) -> Int {
        TransferURLProtocol.requests.compactMap(Self.boundaryItemID(from:)).filter { ids.contains($0) }.count
    }

    static func sends(of itemID: UUID) -> Int {
        Self.sends(of: [itemID])
    }

    static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    func waitFor(
        _ label: String,
        timeout: Duration = .seconds(5),
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

    /// Waits until the round a connection started has finished: nothing queued or in flight,
    /// every item back in attention, and no new send for three consecutive polls.
    func waitForQuiescence(
        _ engine: TransferEngine,
        attentionCount: Int,
        sentIDs: Set<UUID>,
        timeout: Duration = .seconds(60),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await Task.sleep(for: .milliseconds(250))
        let deadline = ContinuousClock.now + timeout
        var lastSends = -1
        var stablePolls = 0
        while ContinuousClock.now < deadline {
            let snapshot = await engine.snapshot()
            let sends = Self.sends(of: sentIDs)
            let settled = snapshot.counters.attentionCount == attentionCount
                && snapshot.counters.queuedCount == 0
                && snapshot.counters.inFlightCount == 0
            if settled, sends == lastSends {
                stablePolls += 1
                if stablePolls >= 3 { return }
            } else {
                stablePolls = 0
            }
            lastSends = sends
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Timed out waiting for the round to settle", file: file, line: line)
    }
}

/// Fails the throwing delete of chosen items' cached request bodies; everything else is real.
nonisolated final class BodyCacheDeleteFailingFileSystem: TransferFileSystem, @unchecked Sendable {
    private let base = FoundationTransferFileSystem()
    private let failing = OSAllocatedUnfairLock<UUID?>(initialState: nil)

    func failCacheDelete(for itemID: UUID?) {
        self.failing.withLock { $0 = itemID }
    }

    func fileExists(atPath path: String) -> Bool { self.base.fileExists(atPath: path) }
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try self.base.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories)
    }
    func contentsOfDirectory(at url: URL) throws -> [URL] { try self.base.contentsOfDirectory(at: url) }
    func removeItem(at url: URL) throws {
        if url.lastPathComponent == TransferSpool.bodyUploadFilename,
           let itemID = self.failing.withLock({ $0 }),
           url.deletingLastPathComponent().lastPathComponent == itemID.uuidString {
            throw CocoaError(.fileWriteNoPermission)
        }
        try self.base.removeItem(at: url)
    }
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws { try self.base.moveItem(at: sourceURL, to: destinationURL) }
    func replaceItem(at originalURL: URL, withItemAt newURL: URL) throws { try self.base.replaceItem(at: originalURL, withItemAt: newURL) }
    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws { try self.base.write(data, to: url, options: options) }
    func data(contentsOf url: URL) throws -> Data { try self.base.data(contentsOf: url) }
    func byteCount(at url: URL) throws -> Int { try self.base.byteCount(at: url) }
    func readChunks(at url: URL, chunkSize: Int, _ consume: (Data) throws -> Void) throws {
        try self.base.readChunks(at: url, chunkSize: chunkSize, consume)
    }
    func writeStream(to url: URL, _ body: (any TransferByteSink) throws -> Void) throws -> Int {
        try self.base.writeStream(to: url, body)
    }
}

nonisolated func XCTUnwrapAsync<T>(
    _ expression: @autoclosure () async throws -> T?,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> T {
    let value = try await expression()
    return try XCTUnwrap(value, file: file, line: line)
}
