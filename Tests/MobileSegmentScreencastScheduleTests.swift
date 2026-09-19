// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class MobileSegmentScreencastScheduleTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        self.tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir = self.tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    func testWindowIndexDerivation() {
        let anchorMs: Int64 = 1_000_000
        let periodSeconds = 300 // 5 minutes = 300,000 ms

        XCTAssertEqual(MobileSegmentScreencastIdentity.windowIndex(nowMs: 1_000_000, scheduleAnchorMs: anchorMs, schedulePeriodSeconds: periodSeconds), 0)
        XCTAssertEqual(MobileSegmentScreencastIdentity.windowIndex(nowMs: 1_299_999, scheduleAnchorMs: anchorMs, schedulePeriodSeconds: periodSeconds), 0)
        XCTAssertEqual(MobileSegmentScreencastIdentity.windowIndex(nowMs: 1_300_000, scheduleAnchorMs: anchorMs, schedulePeriodSeconds: periodSeconds), 1)
        XCTAssertEqual(MobileSegmentScreencastIdentity.windowIndex(nowMs: 1_600_000, scheduleAnchorMs: anchorMs, schedulePeriodSeconds: periodSeconds), 2)
        // Negative delta clamps to 0
        XCTAssertEqual(MobileSegmentScreencastIdentity.windowIndex(nowMs: 900_000, scheduleAnchorMs: anchorMs, schedulePeriodSeconds: periodSeconds), 0)
    }

    func testWindowStartAndEnd() {
        let anchorMs: Int64 = 1_700_000_000_000
        let periodSeconds = 300

        let start0 = MobileSegmentScreencastIdentity.windowStart(scheduleAnchorMs: anchorMs, windowIndex: 0, schedulePeriodSeconds: periodSeconds)
        let end0 = MobileSegmentScreencastIdentity.windowEnd(scheduleAnchorMs: anchorMs, windowIndex: 0, schedulePeriodSeconds: periodSeconds)
        let start1 = MobileSegmentScreencastIdentity.windowStart(scheduleAnchorMs: anchorMs, windowIndex: 1, schedulePeriodSeconds: periodSeconds)

        XCTAssertEqual(start0, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(end0, Date(timeIntervalSince1970: 1_700_000_300))
        XCTAssertEqual(start1, end0)
    }

    func testSegmentIDDerivationIsDeterministic() {
        let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let anchorMs: Int64 = 1_700_000_000_000
        let periodSeconds = 300

        let id0_a = MobileSegmentScreencastIdentity.segmentID(
            sessionID: sessionID,
            scheduleAnchorMs: anchorMs,
            windowIndex: 0,
            schedulePeriodSeconds: periodSeconds
        )
        let id0_b = MobileSegmentScreencastIdentity.segmentID(
            sessionID: sessionID,
            scheduleAnchorMs: anchorMs,
            windowIndex: 0,
            schedulePeriodSeconds: periodSeconds
        )
        let id1 = MobileSegmentScreencastIdentity.segmentID(
            sessionID: sessionID,
            scheduleAnchorMs: anchorMs,
            windowIndex: 1,
            schedulePeriodSeconds: periodSeconds
        )

        XCTAssertEqual(id0_a, id0_b)
        XCTAssertNotEqual(id0_a, id1)

        // Verify RFC 4122 v5 format
        var uuidBytes = id0_a.uuid
        let bytes = withUnsafeBytes(of: &uuidBytes) { Array($0) }
        XCTAssertEqual(bytes[6] >> 4, 0x5, "Version nibble must be 5")
        XCTAssertEqual(bytes[8] >> 6, 0x2, "Variant bits must be 10 (RFC 4122)")
    }

    func testRecordRoundtripDeterminism() throws {
        let sessionID = UUID()
        let anchorMs: Int64 = 1_700_000_000_123
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let periodSeconds = 300
        let segmentID0 = MobileSegmentScreencastIdentity.segmentID(
            sessionID: sessionID,
            scheduleAnchorMs: anchorMs,
            windowIndex: 0,
            schedulePeriodSeconds: periodSeconds
        )

        let record = MobileSegmentScreencastHandoffRecord(
            revision: 42,
            eventID: UUID(),
            sessionID: sessionID,
            segmentID: segmentID0,
            sourceSetVersion: 3,
            sourceSet: [.audio, .screencast],
            startedAt: startedAt,
            segmentDirectoryRelativePath: MobileSegmentScreencastPaths.activeSegmentRelativeDirectory(segmentID: segmentID0),
            screenPartRelativePath: MobileSegmentScreencastPaths.screenPartRelativePath(segmentID: segmentID0),
            screenFinalRelativePath: MobileSegmentScreencastPaths.screenRelativePath(segmentID: segmentID0),
            scheduleAnchorMs: anchorMs,
            schedulePeriodSeconds: periodSeconds,
            lastHostUpdateAt: startedAt
        )

        let fileURL = self.tempDir.appendingPathComponent("handoff.json")
        try MobileSegmentScreencastJSONStore.write(record, to: fileURL)
        let decoded = try MobileSegmentScreencastJSONStore.read(MobileSegmentScreencastHandoffRecord.self, from: fileURL)

        XCTAssertEqual(record, decoded)
        for k in 0...5 {
            let originalID = MobileSegmentScreencastIdentity.segmentID(
                sessionID: record.sessionID,
                scheduleAnchorMs: record.scheduleAnchorMs,
                windowIndex: k,
                schedulePeriodSeconds: record.schedulePeriodSeconds
            )
            let decodedID = MobileSegmentScreencastIdentity.segmentID(
                sessionID: decoded.sessionID,
                scheduleAnchorMs: decoded.scheduleAnchorMs,
                windowIndex: k,
                schedulePeriodSeconds: decoded.schedulePeriodSeconds
            )
            XCTAssertEqual(originalID, decodedID)
        }
    }

    func testTwoRecordsSameSessionDifferentAnchors() {
        let sessionID = UUID()
        let anchorA: Int64 = 1_700_000_000_000
        let anchorB: Int64 = 1_700_000_005_000
        let periodSeconds = 300

        for k in 0...5 {
            let idA = MobileSegmentScreencastIdentity.segmentID(sessionID: sessionID, scheduleAnchorMs: anchorA, windowIndex: k, schedulePeriodSeconds: periodSeconds)
            let idB = MobileSegmentScreencastIdentity.segmentID(sessionID: sessionID, scheduleAnchorMs: anchorB, windowIndex: k, schedulePeriodSeconds: periodSeconds)
            XCTAssertNotEqual(idA, idB)
        }
    }

    @MainActor
    func testEngineOpenAtWindowKUsesDerivedID() async throws {
        let store = MobileSegmentStore(rootURL: self.tempDir.appendingPathComponent("MobileSegment", isDirectory: true))
        try store.ensureRoot()
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let uploader = MobileSegmentUploader(store: store, clock: clock)
        let engine = MobileSegmentEngine(uploader: uploader, clock: clock)

        let handoff = try await engine.startScreencast(at: clock.now())
        let window0ID = handoff.segmentID

        let expectedID_k1 = MobileSegmentScreencastIdentity.segmentID(
            sessionID: handoff.sessionID,
            scheduleAnchorMs: handoff.scheduleAnchorMs,
            windowIndex: 1,
            schedulePeriodSeconds: 300
        )

        // Advance clock by 300 seconds to window 1 boundary
        clock.advance(by: 300)
        await engine.finishCurrentAndMaybeOpenNext(nextSources: [.screencast], at: clock.now())

        let activeDirectories = try store.list(.active)
        let activeIDs = Set(activeDirectories.map { UUID(uuidString: $0.lastPathComponent)! })
        XCTAssertTrue(activeIDs.contains(expectedID_k1))

        // Extension finishes window 1 in that directory
        let k1Directory = store.segmentDirectoryURL(.active, segmentID: expectedID_k1)
        let sidecar = MobileSegmentScreencastWindowSidecar(
            schemaVersion: 1,
            sessionID: handoff.sessionID,
            revision: 1,
            windowIndex: 1,
            startedAt: Date(timeIntervalSince1970: 1_700_000_300),
            endedAt: Date(timeIntervalSince1970: 1_700_000_600),
            acceptedFrameCount: 100,
            droppedFrameCount: 0
        )
        try MobileSegmentScreencastJSONStore.write(
            sidecar,
            to: MobileSegmentScreencastPaths.screenWindowURL(inSegmentDirectory: k1Directory)
        )
        try Data("screen-k1-video".utf8).write(to: store.screenURL(in: k1Directory))

        // Boundary at +600s closes window 1 and finalizes it
        clock.advance(by: 300)
        await engine.finishCurrentAndMaybeOpenNext(nextSources: [.screencast], at: clock.now())

        let pendingDirectories = try store.list(.pending)
        let pendingIDs = Set(pendingDirectories.map { UUID(uuidString: $0.lastPathComponent)! })
        XCTAssertTrue(pendingIDs.contains(expectedID_k1))

        let pendingManifest = try store.readManifest(in: store.segmentDirectoryURL(.pending, segmentID: expectedID_k1))
        XCTAssertEqual(pendingManifest.segmentID, expectedID_k1)
        XCTAssertEqual(pendingManifest.screencast.state, .finalizedArtifact)
    }

    @MainActor
    func testAbsoluteTimerSlowFinalizeDoesNotShiftNext() async throws {
        let store = MobileSegmentStore(rootURL: self.tempDir.appendingPathComponent("MobileSegment", isDirectory: true))
        try store.ensureRoot()
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let uploader = MobileSegmentUploader(store: store, clock: clock)
        let engine = MobileSegmentEngine(uploader: uploader, clock: clock)

        let handoff = try await engine.startScreencast(at: clock.now())
        let anchorMs = handoff.scheduleAnchorMs

        // Boundary 1 at +300s
        clock.advance(by: 300)
        await engine.finishCurrentAndMaybeOpenNext(nextSources: [.screencast], at: clock.now())

        // Delay / slow operation takes 15s after boundary
        clock.advance(by: 15)

        // Advance the rest of the way to +600s (+285s more)
        let expectedID_k2 = MobileSegmentScreencastIdentity.segmentID(
            sessionID: handoff.sessionID,
            scheduleAnchorMs: anchorMs,
            windowIndex: 2,
            schedulePeriodSeconds: 300
        )

        clock.advance(by: 285)
        await engine.finishCurrentAndMaybeOpenNext(nextSources: [.screencast], at: clock.now())

        let activeDirectories = try store.list(.active)
        let activeIDs = Set(activeDirectories.map { UUID(uuidString: $0.lastPathComponent)! })
        XCTAssertTrue(activeIDs.contains(expectedID_k2))
    }

    @MainActor
    func testLateBoundaryOpensIndexContainingNowAndSkippedIndexAdopts() async throws {
        let store = MobileSegmentStore(rootURL: self.tempDir.appendingPathComponent("MobileSegment", isDirectory: true))
        try store.ensureRoot()
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let uploader = MobileSegmentUploader(store: store, clock: clock)
        let engine = MobileSegmentEngine(uploader: uploader, clock: clock)

        let handoff = try await engine.startScreencast(at: clock.now())
        let anchorMs = handoff.scheduleAnchorMs
        let sessionID = handoff.sessionID

        // Simulate extension creating window 1 on disk at +300s
        let k1ID = MobileSegmentScreencastIdentity.segmentID(
            sessionID: sessionID,
            scheduleAnchorMs: anchorMs,
            windowIndex: 1,
            schedulePeriodSeconds: 300
        )
        let k1Directory = store.segmentDirectoryURL(.active, segmentID: k1ID)
        try FileManager.default.createDirectory(at: k1Directory, withIntermediateDirectories: true)
        let k1Sidecar = MobileSegmentScreencastWindowSidecar(
            schemaVersion: 1,
            sessionID: sessionID,
            revision: 1,
            windowIndex: 1,
            startedAt: Date(timeIntervalSince1970: 1_700_000_300),
            endedAt: Date(timeIntervalSince1970: 1_700_000_600),
            acceptedFrameCount: 50,
            droppedFrameCount: 0
        )
        try MobileSegmentScreencastJSONStore.write(
            k1Sidecar,
            to: MobileSegmentScreencastPaths.screenWindowURL(inSegmentDirectory: k1Directory)
        )
        try Data("screen-k1".utf8).write(to: store.screenURL(in: k1Directory))

        // Late jump: engine boundary fires at +650s (in window 2)
        clock.advance(by: 650)
        await engine.finishCurrentAndMaybeOpenNext(nextSources: [.screencast], at: clock.now())

        let expectedID_k2 = MobileSegmentScreencastIdentity.segmentID(
            sessionID: sessionID,
            scheduleAnchorMs: anchorMs,
            windowIndex: 2,
            schedulePeriodSeconds: 300
        )

        let activeDirectories = try store.list(.active)
        let activeIDs = Set(activeDirectories.map { UUID(uuidString: $0.lastPathComponent)! })
        XCTAssertTrue(activeIDs.contains(expectedID_k2))

        // Reconcile runs: adopts skipped window 1 as its own screen-only segment
        try await uploader.reconcileActiveSegments()

        let pendingDirectory = store.segmentDirectoryURL(.pending, segmentID: k1ID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingDirectory.path))
        let k1Manifest = try store.readManifest(in: pendingDirectory)
        XCTAssertEqual(k1Manifest.openedWithSources, [.screencast])
        XCTAssertEqual(k1Manifest.screencast.state, .finalizedArtifact)
    }

    @MainActor
    func testReconcileBeforeEngineOpenDoesNotAdoptWhenEngineHoldsWindow() async throws {
        let store = MobileSegmentStore(rootURL: self.tempDir)
        try store.ensureRoot()
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_700_000_300))
        let uploader = MobileSegmentUploader(store: store, clock: clock)

        let sessionID = UUID()
        let anchorMs: Int64 = 1_700_000_000_000
        let k1ID = MobileSegmentScreencastIdentity.segmentID(
            sessionID: sessionID,
            scheduleAnchorMs: anchorMs,
            windowIndex: 1,
            schedulePeriodSeconds: 300
        )

        // Extension created directory for window 1 with sidecar + .part but NO manifest
        let k1Directory = store.segmentDirectoryURL(.active, segmentID: k1ID)
        try FileManager.default.createDirectory(at: k1Directory, withIntermediateDirectories: true)
        let sidecar = MobileSegmentScreencastWindowSidecar(
            schemaVersion: 1,
            sessionID: sessionID,
            revision: 1,
            windowIndex: 1,
            startedAt: Date(timeIntervalSince1970: 1_700_000_300),
            endedAt: nil,
            acceptedFrameCount: 0,
            droppedFrameCount: 0
        )
        try MobileSegmentScreencastJSONStore.write(
            sidecar,
            to: MobileSegmentScreencastPaths.screenWindowURL(inSegmentDirectory: k1Directory)
        )
        try Data("part".utf8).write(to: store.screenPartURL(in: k1Directory))

        // Engine holds k1ID from adoption
        uploader.heldScreencastAdoptionSkipSegmentID = { k1ID }

        // Reconcile runs BEFORE engine opens k1
        try await uploader.reconcileActiveSegments()

        // Manifest must NOT have been written by adoption because engine held it
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.manifestURL(in: k1Directory).path))

        // Now engine opens k1 with [.audio, .screencast]
        let manifest = MobileSegmentManifest(
            segmentID: k1ID,
            startedAt: Date(timeIntervalSince1970: 1_700_000_300),
            openedWithSources: [.audio, .screencast],
            activeSourceSetVersion: 2
        )
        try store.writeManifest(manifest, in: k1Directory)

        let writtenManifest = try store.readManifest(in: k1Directory)
        XCTAssertEqual(Set(writtenManifest.openedWithSources), [.audio, .screencast])
    }
}
