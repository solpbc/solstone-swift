// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreMedia
@testable import solstone_swift
import XCTest

private final class TestBroadcastWriter: ScreencastBroadcastWriting, @unchecked Sendable {
    var isOpen = false
    var openedHandoff: MobileSegmentScreencastHandoffRecord?
    var acceptedFrameCount: Int = 0
    var droppedFrameCount: Int = 0
    var writtenLivenessCount: Int = 0
    var shouldFailLiveness: Bool = false

    func open(rootURL: URL, handoff: MobileSegmentScreencastHandoffRecord, now: Date) throws {
        self.isOpen = true
        self.openedHandoff = handoff
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer, now: Date) {
        guard self.isOpen else { return }
        self.acceptedFrameCount += 1
    }

    func finish(now: Date) -> ScreencastBroadcastWriterOutcome {
        self.isOpen = false
        return self.acceptedFrameCount > 0 ? .completed : .noVideo
    }

    func writeLiveness(now: Date, force: Bool) throws {
        if self.shouldFailLiveness {
            throw NSError(domain: "test", code: -1, userInfo: nil)
        }
        self.writtenLivenessCount += 1
    }
}

private final class TestSessionClock: @unchecked Sendable {
    var currentDate: Date

    init(initialDate: Date) {
        self.currentDate = initialDate
    }

    func now() -> Date {
        self.currentDate
    }

    func advance(by seconds: TimeInterval) {
        self.currentDate = self.currentDate.addingTimeInterval(seconds)
    }

    func set(to date: Date) {
        self.currentDate = date
    }
}

private final class TestSessionState: @unchecked Sendable {
    var finishedError: NSError?
    var availableBytes: Int64 = MobileSegmentScreencastStoragePolicy.minimumFreeBytes + 10_000_000
}

nonisolated final class ScreencastBroadcastSessionTests: XCTestCase {
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

    func testSelfMintWindowZeroAndSidecar() throws {
        let clock = TestSessionClock(initialDate: Date(timeIntervalSince1970: 1_700_000_000))
        let writer = TestBroadcastWriter()
        let state = TestSessionState()
        let sessionID = UUID()

        let session = ScreencastBroadcastSession(
            rootURL: self.tempDir,
            writer: writer,
            clock: { clock.now() },
            availableBytes: { _ in state.availableBytes },
            postChanged: {},
            finishWithError: { state.finishedError = $0 }
        )

        session.broadcastStarted(sessionID: sessionID)
        // Wait 2s to self-mint
        clock.advance(by: 2.1)
        session.tick()

        XCTAssertNil(state.finishedError)
        XCTAssertTrue(writer.isOpen)

        let segmentID = try XCTUnwrap(session.currentHandoff?.segmentID)
        let sidecarURL = MobileSegmentScreencastPaths.screenWindowURL(
            inSegmentDirectory: MobileSegmentScreencastPaths.url(
                root: self.tempDir,
                relativePath: MobileSegmentScreencastPaths.activeSegmentRelativeDirectory(segmentID: segmentID)
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))

        let sidecar = try MobileSegmentScreencastJSONStore.read(MobileSegmentScreencastWindowSidecar.self, from: sidecarURL)
        XCTAssertEqual(sidecar.windowIndex, 0)
        XCTAssertEqual(sidecar.sessionID, sessionID)
        XCTAssertNil(sidecar.endedAt)
    }

    func testStorageLowGatingOnStart() throws {
        let clock = TestSessionClock(initialDate: Date(timeIntervalSince1970: 1_700_000_000))
        let writer = TestBroadcastWriter()
        let state = TestSessionState()
        state.availableBytes = MobileSegmentScreencastStoragePolicy.minimumFreeBytes - 1
        let sessionID = UUID()

        let session = ScreencastBroadcastSession(
            rootURL: self.tempDir,
            writer: writer,
            clock: { clock.now() },
            availableBytes: { _ in state.availableBytes },
            postChanged: {},
            finishWithError: { state.finishedError = $0 }
        )

        session.broadcastStarted(sessionID: sessionID)
        XCTAssertNotNil(state.finishedError)
        XCTAssertEqual(state.finishedError?.domain, "app.solstone.swift.screencast")
        XCTAssertEqual(state.finishedError?.userInfo[NSLocalizedDescriptionKey] as? String, "screen stopped. this iphone is low on storage.")
        XCTAssertFalse(writer.isOpen)

        let runtimeURL = MobileSegmentScreencastPaths.url(
            root: self.tempDir,
            relativePath: MobileSegmentScreencastPaths.runtimeRelativePath()
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtimeURL.path))

        let diagURL = MobileSegmentScreencastPaths.url(
            root: self.tempDir,
            relativePath: MobileSegmentScreencastPaths.runtimeDiagnosticRelativePath(sessionID: sessionID)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: diagURL.path))
        let diag = try MobileSegmentScreencastJSONStore.read(MobileSegmentScreencastDiagnostic.self, from: diagURL)
        XCTAssertEqual(diag.reason, .storageLow)
    }

    func testStorageLowGatingAtPeriodBoundary() throws {
        let clock = TestSessionClock(initialDate: Date(timeIntervalSince1970: 1_700_000_000))
        let writer = TestBroadcastWriter()
        let state = TestSessionState()
        state.availableBytes = MobileSegmentScreencastStoragePolicy.minimumFreeBytes + 100
        let sessionID = UUID()

        let session = ScreencastBroadcastSession(
            rootURL: self.tempDir,
            writer: writer,
            clock: { clock.now() },
            availableBytes: { _ in state.availableBytes },
            postChanged: {},
            finishWithError: { state.finishedError = $0 }
        )

        session.broadcastStarted(sessionID: sessionID)
        clock.advance(by: 2.1)
        session.tick()
        XCTAssertNil(state.finishedError)

        // Drop storage below minimum during window 0
        state.availableBytes = MobileSegmentScreencastStoragePolicy.minimumFreeBytes - 1
        // Intermediate tick: storage is not checked on normal 2s tick
        clock.advance(by: 10.0)
        session.tick()
        XCTAssertNil(state.finishedError)

        // Advance past 300s to reach period boundary
        clock.advance(by: 295.0)
        session.tick()

        XCTAssertNotNil(state.finishedError)
        XCTAssertEqual(state.finishedError?.userInfo[NSLocalizedDescriptionKey] as? String, "screen stopped. this iphone is low on storage.")
        XCTAssertFalse(writer.isOpen)
    }

    func testStaticScreenThreePeriodsNoSamplesRegression() throws {
        let clock = TestSessionClock(initialDate: Date(timeIntervalSince1970: 1_700_000_000))
        let writer = TestBroadcastWriter()
        let state = TestSessionState()
        let sessionID = UUID()

        let session = ScreencastBroadcastSession(
            rootURL: self.tempDir,
            writer: writer,
            clock: { clock.now() },
            availableBytes: { _ in state.availableBytes },
            postChanged: {},
            finishWithError: { state.finishedError = $0 }
        )

        session.broadcastStarted(sessionID: sessionID)
        clock.advance(by: 2.1)
        session.tick()
        let window0ID = try XCTUnwrap(session.currentHandoff?.segmentID)

        // Window 0 gets some frames
        writer.acceptedFrameCount = 120

        // Advance past window 0 into window 1 (at 301s)
        clock.advance(by: 301.0)
        session.tick()
        XCTAssertNil(state.finishedError)
        let window1ID = try XCTUnwrap(session.currentHandoff?.segmentID)
        XCTAssertNotEqual(window0ID, window1ID)

        let sidecar0URL = MobileSegmentScreencastPaths.screenWindowURL(
            inSegmentDirectory: MobileSegmentScreencastPaths.url(
                root: self.tempDir,
                relativePath: MobileSegmentScreencastPaths.activeSegmentRelativeDirectory(segmentID: window0ID)
            )
        )
        let sidecar0 = try MobileSegmentScreencastJSONStore.read(MobileSegmentScreencastWindowSidecar.self, from: sidecar0URL)
        XCTAssertEqual(sidecar0.windowIndex, 0)
        XCTAssertNotNil(sidecar0.endedAt)
        XCTAssertEqual(sidecar0.acceptedFrameCount, 120)

        // Window 1 has NO samples (static screen). Liveness ticks occur every 2s
        writer.acceptedFrameCount = 0
        for _ in 1...10 {
            clock.advance(by: 2.0)
            session.tick()
            XCTAssertNil(state.finishedError)
        }

        // Advance past window 1 into window 2 (at 601s)
        clock.advance(by: 281.0)
        session.tick()
        XCTAssertNil(state.finishedError)
        let window2ID = try XCTUnwrap(session.currentHandoff?.segmentID)
        XCTAssertNotEqual(window1ID, window2ID)

        let sidecar1URL = MobileSegmentScreencastPaths.screenWindowURL(
            inSegmentDirectory: MobileSegmentScreencastPaths.url(
                root: self.tempDir,
                relativePath: MobileSegmentScreencastPaths.activeSegmentRelativeDirectory(segmentID: window1ID)
            )
        )
        let sidecar1 = try MobileSegmentScreencastJSONStore.read(MobileSegmentScreencastWindowSidecar.self, from: sidecar1URL)
        XCTAssertEqual(sidecar1.windowIndex, 1)
        XCTAssertNotNil(sidecar1.endedAt)
        XCTAssertEqual(sidecar1.acceptedFrameCount, 0)

        // Window 2 has NO samples
        writer.acceptedFrameCount = 0
        for _ in 1...10 {
            clock.advance(by: 2.0)
            session.tick()
            XCTAssertNil(state.finishedError)
        }

        // Advance past window 2 into window 3 (at 901s)
        clock.advance(by: 281.0)
        session.tick()
        XCTAssertNil(state.finishedError)
        let window3ID = try XCTUnwrap(session.currentHandoff?.segmentID)
        XCTAssertNotEqual(window2ID, window3ID)

        let sidecar2URL = MobileSegmentScreencastPaths.screenWindowURL(
            inSegmentDirectory: MobileSegmentScreencastPaths.url(
                root: self.tempDir,
                relativePath: MobileSegmentScreencastPaths.activeSegmentRelativeDirectory(segmentID: window2ID)
            )
        )
        let sidecar2 = try MobileSegmentScreencastJSONStore.read(MobileSegmentScreencastWindowSidecar.self, from: sidecar2URL)
        XCTAssertEqual(sidecar2.windowIndex, 2)
        XCTAssertNotNil(sidecar2.endedAt)
        XCTAssertEqual(sidecar2.acceptedFrameCount, 0)

        let sidecar3URL = MobileSegmentScreencastPaths.screenWindowURL(
            inSegmentDirectory: MobileSegmentScreencastPaths.url(
                root: self.tempDir,
                relativePath: MobileSegmentScreencastPaths.activeSegmentRelativeDirectory(segmentID: window3ID)
            )
        )
        let sidecar3 = try MobileSegmentScreencastJSONStore.read(MobileSegmentScreencastWindowSidecar.self, from: sidecar3URL)
        XCTAssertEqual(sidecar3.windowIndex, 3)
        XCTAssertNil(sidecar3.endedAt)

        // Liveness kept writing throughout static screen and session never stopped
        XCTAssertGreaterThan(writer.writtenLivenessCount, 20)
        XCTAssertNil(state.finishedError)
    }

    func testOwnSessionRecordAdoptedOnTickAndForeignIgnored() throws {
        let clock = TestSessionClock(initialDate: Date(timeIntervalSince1970: 1_700_000_000))
        let writer = TestBroadcastWriter()
        let state = TestSessionState()
        let sessionID = UUID()

        let session = ScreencastBroadcastSession(
            rootURL: self.tempDir,
            writer: writer,
            clock: { clock.now() },
            availableBytes: { _ in state.availableBytes },
            postChanged: {},
            finishWithError: { state.finishedError = $0 }
        )

        session.broadcastStarted(sessionID: sessionID)

        // Write a foreign session record
        let foreignHandoff = MobileSegmentScreencastHandoffRecord(
            revision: 1,
            eventID: UUID(),
            sessionID: UUID(),
            segmentID: UUID(),
            sourceSetVersion: 1,
            sourceSet: [.screencast],
            startedAt: clock.now(),
            segmentDirectoryRelativePath: "active/\(UUID().uuidString)",
            screenPartRelativePath: "screen.part",
            screenFinalRelativePath: "screen.mp4",
            desiredState: .writing,
            scheduleAnchorMs: 1_700_000_000_000,
            schedulePeriodSeconds: 300,
            lastHostUpdateAt: clock.now()
        )
        let handoffURL = MobileSegmentScreencastPaths.url(
            root: self.tempDir,
            relativePath: MobileSegmentScreencastPaths.handoffRelativePath()
        )
        try MobileSegmentScreencastJSONStore.write(foreignHandoff, to: handoffURL)

        // Tick: foreign record must NOT be adopted
        clock.advance(by: 0.5)
        session.tick()
        XCTAssertFalse(writer.isOpen)

        // Now write own session record
        let expectedOwnSegmentID = MobileSegmentScreencastIdentity.segmentID(
            sessionID: sessionID,
            scheduleAnchorMs: 1_700_000_000_500,
            windowIndex: 0,
            schedulePeriodSeconds: 300
        )
        let ownHandoff = MobileSegmentScreencastHandoffRecord(
            revision: 1,
            eventID: UUID(),
            sessionID: sessionID,
            segmentID: expectedOwnSegmentID,
            sourceSetVersion: 1,
            sourceSet: [.audio, .screencast],
            startedAt: clock.now(),
            segmentDirectoryRelativePath: "active/\(expectedOwnSegmentID.uuidString)",
            screenPartRelativePath: "active/\(expectedOwnSegmentID.uuidString)/screen.part",
            screenFinalRelativePath: "active/\(expectedOwnSegmentID.uuidString)/screen.mp4",
            desiredState: .writing,
            scheduleAnchorMs: 1_700_000_000_500,
            schedulePeriodSeconds: 300,
            lastHostUpdateAt: clock.now()
        )
        try MobileSegmentScreencastJSONStore.write(ownHandoff, to: handoffURL)

        clock.advance(by: 0.5)
        session.tick()

        XCTAssertTrue(writer.isOpen)
        XCTAssertEqual(session.currentHandoff?.segmentID, expectedOwnSegmentID)
        XCTAssertEqual(session.scheduleAnchorMs, 1_700_000_000_500)
    }

    func testForwardClockRotatesOnceIntoWindowContainingNow() throws {
        let clock = TestSessionClock(initialDate: Date(timeIntervalSince1970: 1_700_000_000))
        let writer = TestBroadcastWriter()
        let state = TestSessionState()
        let sessionID = UUID()

        let session = ScreencastBroadcastSession(
            rootURL: self.tempDir,
            writer: writer,
            clock: { clock.now() },
            availableBytes: { _ in state.availableBytes },
            postChanged: {},
            finishWithError: { state.finishedError = $0 }
        )

        session.broadcastStarted(sessionID: sessionID)
        clock.advance(by: 2.1)
        session.tick()
        XCTAssertEqual(session.currentWindowIndex, 0)

        // Jump clock forward by 1250 seconds (index 4)
        clock.advance(by: 1250.0)
        session.tick()

        XCTAssertNil(state.finishedError)
        XCTAssertEqual(session.currentWindowIndex, 4)
    }

    func testBackwardClockDoesNotReopenEarlierWindow() throws {
        let clock = TestSessionClock(initialDate: Date(timeIntervalSince1970: 1_700_000_000))
        let writer = TestBroadcastWriter()
        let state = TestSessionState()
        let sessionID = UUID()

        let session = ScreencastBroadcastSession(
            rootURL: self.tempDir,
            writer: writer,
            clock: { clock.now() },
            availableBytes: { _ in state.availableBytes },
            postChanged: {},
            finishWithError: { state.finishedError = $0 }
        )

        session.broadcastStarted(sessionID: sessionID)
        clock.advance(by: 2.1)
        session.tick()

        // Move to window 1
        clock.advance(by: 301.0)
        session.tick()
        XCTAssertEqual(session.currentWindowIndex, 1)

        // Move clock backward to window 0 time
        clock.set(to: Date(timeIntervalSince1970: 1_700_000_100))
        session.tick()

        XCTAssertNil(state.finishedError)
        XCTAssertEqual(session.currentWindowIndex, 1)
    }

    func testSelfMintFramesThenSupersededFinalizesPlayableSliver() throws {
        let clock = TestSessionClock(initialDate: Date(timeIntervalSince1970: 1_700_000_000))
        let writer = TestBroadcastWriter()
        let state = TestSessionState()
        let sessionID = UUID()

        let session = ScreencastBroadcastSession(
            rootURL: self.tempDir,
            writer: writer,
            clock: { clock.now() },
            availableBytes: { _ in state.availableBytes },
            postChanged: {},
            finishWithError: { state.finishedError = $0 }
        )

        session.broadcastStarted(sessionID: sessionID)
        clock.advance(by: 2.1)
        session.tick()
        let selfMintedID = try XCTUnwrap(session.currentHandoff?.segmentID)

        writer.acceptedFrameCount = 30
        clock.advance(by: 3.0)

        // Host writes a new handoff record at t=5.1
        let expectedHostSegmentID = MobileSegmentScreencastIdentity.segmentID(
            sessionID: sessionID,
            scheduleAnchorMs: 1_700_000_005_100,
            windowIndex: 0,
            schedulePeriodSeconds: 300
        )
        let hostHandoff = MobileSegmentScreencastHandoffRecord(
            revision: 2,
            eventID: UUID(),
            sessionID: sessionID,
            segmentID: expectedHostSegmentID,
            sourceSetVersion: 1,
            sourceSet: [.audio, .screencast],
            startedAt: clock.now(),
            segmentDirectoryRelativePath: "active/\(expectedHostSegmentID.uuidString)",
            screenPartRelativePath: "active/\(expectedHostSegmentID.uuidString)/screen.part",
            screenFinalRelativePath: "active/\(expectedHostSegmentID.uuidString)/screen.mp4",
            desiredState: .writing,
            scheduleAnchorMs: 1_700_000_005_100,
            schedulePeriodSeconds: 300,
            lastHostUpdateAt: clock.now()
        )
        let handoffURL = MobileSegmentScreencastPaths.url(
            root: self.tempDir,
            relativePath: MobileSegmentScreencastPaths.handoffRelativePath()
        )
        try MobileSegmentScreencastJSONStore.write(hostHandoff, to: handoffURL)

        session.tick()

        XCTAssertEqual(session.currentHandoff?.segmentID, expectedHostSegmentID)

        // Self-minted window was closed and finalized with frames
        let selfMintedSidecarURL = MobileSegmentScreencastPaths.screenWindowURL(
            inSegmentDirectory: MobileSegmentScreencastPaths.url(
                root: self.tempDir,
                relativePath: MobileSegmentScreencastPaths.activeSegmentRelativeDirectory(segmentID: selfMintedID)
            )
        )
        let selfMintedSidecar = try MobileSegmentScreencastJSONStore.read(MobileSegmentScreencastWindowSidecar.self, from: selfMintedSidecarURL)
        XCTAssertNotNil(selfMintedSidecar.endedAt)
        XCTAssertEqual(selfMintedSidecar.acceptedFrameCount, 30)
    }

    func testFailedHeartbeatWriteErrorExits() throws {
        let clock = TestSessionClock(initialDate: Date(timeIntervalSince1970: 1_700_000_000))
        let writer = TestBroadcastWriter()
        let state = TestSessionState()
        let sessionID = UUID()

        let session = ScreencastBroadcastSession(
            rootURL: self.tempDir,
            writer: writer,
            clock: { clock.now() },
            availableBytes: { _ in state.availableBytes },
            postChanged: {},
            finishWithError: { state.finishedError = $0 }
        )

        session.broadcastStarted(sessionID: sessionID)
        clock.advance(by: 2.1)
        session.tick()
        XCTAssertNil(state.finishedError)

        // Make heartbeat fail
        writer.shouldFailLiveness = true
        clock.advance(by: 2.0)
        session.tick()

        XCTAssertNotNil(state.finishedError)
        XCTAssertEqual(state.finishedError?.domain, "app.solstone.swift.screencast")
        XCTAssertEqual(state.finishedError?.userInfo[NSLocalizedDescriptionKey] as? String, "screen is unavailable")
        XCTAssertFalse(writer.isOpen)
    }

    func testTickSupersedingHandoffWithSameAnchorUpdatesRevisionOnly() throws {
        let anchorMs: Int64 = 1_700_000_000_000
        let clock = TestSessionClock(initialDate: Date(timeIntervalSince1970: 1_700_000_010))
        let writer = TestBroadcastWriter()
        let state = TestSessionState()
        let sessionID = UUID()

        let segmentID0 = MobileSegmentScreencastIdentity.segmentID(
            sessionID: sessionID,
            scheduleAnchorMs: anchorMs,
            windowIndex: 0,
            schedulePeriodSeconds: 300
        )
        let initialHandoff = MobileSegmentScreencastHandoffRecord(
            revision: 1,
            eventID: UUID(),
            sessionID: sessionID,
            segmentID: segmentID0,
            sourceSetVersion: 1,
            sourceSet: [.screencast],
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            segmentDirectoryRelativePath: "active/\(segmentID0.uuidString)",
            screenPartRelativePath: "active/\(segmentID0.uuidString)/screen.part",
            screenFinalRelativePath: "active/\(segmentID0.uuidString)/screen.mp4",
            desiredState: .writing,
            scheduleAnchorMs: anchorMs,
            schedulePeriodSeconds: 300,
            lastHostUpdateAt: clock.now()
        )
        let handoffURL = MobileSegmentScreencastPaths.url(
            root: self.tempDir,
            relativePath: MobileSegmentScreencastPaths.handoffRelativePath()
        )
        try MobileSegmentScreencastJSONStore.write(initialHandoff, to: handoffURL)

        let session = ScreencastBroadcastSession(
            rootURL: self.tempDir,
            writer: writer,
            clock: { clock.now() },
            availableBytes: { _ in state.availableBytes },
            postChanged: {},
            finishWithError: { state.finishedError = $0 }
        )

        session.broadcastStarted(sessionID: sessionID)
        session.tick()
        XCTAssertEqual(session.currentWindowIndex, 0)
        XCTAssertTrue(writer.isOpen)

        writer.acceptedFrameCount = 15

        // Same anchor, updated revision and source set
        let updatedHandoff = MobileSegmentScreencastHandoffRecord(
            revision: 2,
            eventID: UUID(),
            sessionID: sessionID,
            segmentID: segmentID0,
            sourceSetVersion: 2,
            sourceSet: [.audio, .screencast],
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            segmentDirectoryRelativePath: "active/\(segmentID0.uuidString)",
            screenPartRelativePath: "active/\(segmentID0.uuidString)/screen.part",
            screenFinalRelativePath: "active/\(segmentID0.uuidString)/screen.mp4",
            desiredState: .writing,
            scheduleAnchorMs: anchorMs,
            schedulePeriodSeconds: 300,
            lastHostUpdateAt: clock.now()
        )
        try MobileSegmentScreencastJSONStore.write(updatedHandoff, to: handoffURL)

        clock.advance(by: 5.0)
        session.tick()

        // Writer was NOT closed, window index still 0, revision updated
        XCTAssertTrue(writer.isOpen)
        XCTAssertEqual(session.currentWindowIndex, 0)
        XCTAssertEqual(session.currentHandoff?.revision, 2)
        XCTAssertEqual(session.currentHandoff?.sourceSet, [.audio, .screencast])
    }

    func testAdoptInitialHandoffOpensDerivedWindowContainingNow() throws {
        let anchorMs: Int64 = 1_700_000_000_000
        // Clock is 350s in -> window 1
        let clock = TestSessionClock(initialDate: Date(timeIntervalSince1970: 1_700_000_350))
        let writer = TestBroadcastWriter()
        let state = TestSessionState()
        let sessionID = UUID()

        let segmentID0 = MobileSegmentScreencastIdentity.segmentID(
            sessionID: sessionID,
            scheduleAnchorMs: anchorMs,
            windowIndex: 0,
            schedulePeriodSeconds: 300
        )
        let initialHandoff = MobileSegmentScreencastHandoffRecord(
            revision: 1,
            eventID: UUID(),
            sessionID: sessionID,
            segmentID: segmentID0,
            sourceSetVersion: 1,
            sourceSet: [.screencast],
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            segmentDirectoryRelativePath: "active/\(segmentID0.uuidString)",
            screenPartRelativePath: "active/\(segmentID0.uuidString)/screen.part",
            screenFinalRelativePath: "active/\(segmentID0.uuidString)/screen.mp4",
            desiredState: .writing,
            scheduleAnchorMs: anchorMs,
            schedulePeriodSeconds: 300,
            lastHostUpdateAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let handoffURL = MobileSegmentScreencastPaths.url(
            root: self.tempDir,
            relativePath: MobileSegmentScreencastPaths.handoffRelativePath()
        )
        try MobileSegmentScreencastJSONStore.write(initialHandoff, to: handoffURL)

        let session = ScreencastBroadcastSession(
            rootURL: self.tempDir,
            writer: writer,
            clock: { clock.now() },
            availableBytes: { _ in state.availableBytes },
            postChanged: {},
            finishWithError: { state.finishedError = $0 }
        )

        session.broadcastStarted(sessionID: sessionID)
        session.tick()

        let expectedSegmentID1 = MobileSegmentScreencastIdentity.segmentID(
            sessionID: sessionID,
            scheduleAnchorMs: anchorMs,
            windowIndex: 1,
            schedulePeriodSeconds: 300
        )
        XCTAssertEqual(session.currentWindowIndex, 1)
        XCTAssertEqual(session.currentHandoff?.segmentID, expectedSegmentID1)
        XCTAssertTrue(writer.isOpen)
    }

    // MARK: - Acceptance Test H: Earlier-anchor superseding closes current and opens derived window
    func testSupersedingHandoffWithEarlierAnchorClosesCurrentAndOpensDerivedWindow() throws {
        let clock = TestSessionClock(initialDate: Date(timeIntervalSince1970: 1_700_000_010))
        let writer = TestBroadcastWriter()
        let state = TestSessionState()
        let sessionID = UUID()

        let session = ScreencastBroadcastSession(
            rootURL: self.tempDir,
            writer: writer,
            clock: { clock.now() },
            availableBytes: { _ in state.availableBytes },
            postChanged: {},
            finishWithError: { state.finishedError = $0 }
        )

        // Session starts self-minting anchor at T=10s
        session.broadcastStarted(sessionID: sessionID)
        clock.advance(by: 2.1)
        session.tick()
        XCTAssertTrue(writer.isOpen)
        let initialSelfMintedID = try XCTUnwrap(session.currentHandoff?.segmentID)
        writer.acceptedFrameCount = 20

        // Host posts earlier anchor at T=0s with revision 2
        let earlierAnchorMs: Int64 = 1_700_000_000_000
        let segmentID0 = MobileSegmentScreencastIdentity.segmentID(
            sessionID: sessionID,
            scheduleAnchorMs: earlierAnchorMs,
            windowIndex: 0,
            schedulePeriodSeconds: 300
        )
        let hostHandoff = MobileSegmentScreencastHandoffRecord(
            revision: 2,
            eventID: UUID(),
            sessionID: sessionID,
            segmentID: segmentID0,
            sourceSetVersion: 2,
            sourceSet: [.screencast],
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            segmentDirectoryRelativePath: "active/\(segmentID0.uuidString)",
            screenPartRelativePath: "active/\(segmentID0.uuidString)/screen.part",
            screenFinalRelativePath: "active/\(segmentID0.uuidString)/screen.mp4",
            desiredState: .writing,
            scheduleAnchorMs: earlierAnchorMs,
            schedulePeriodSeconds: 300,
            lastHostUpdateAt: clock.now()
        )
        let handoffURL = MobileSegmentScreencastPaths.url(
            root: self.tempDir,
            relativePath: MobileSegmentScreencastPaths.handoffRelativePath()
        )
        try MobileSegmentScreencastJSONStore.write(hostHandoff, to: handoffURL)

        clock.advance(by: 1.0)
        session.tick()

        // Old self-minted sidecar closed with endedAt and acceptedFrameCount == 20
        let oldSidecarURL = MobileSegmentScreencastPaths.screenWindowURL(
            inSegmentDirectory: MobileSegmentScreencastPaths.url(
                root: self.tempDir,
                relativePath: MobileSegmentScreencastPaths.activeSegmentRelativeDirectory(segmentID: initialSelfMintedID)
            )
        )
        let oldSidecar = try MobileSegmentScreencastJSONStore.read(MobileSegmentScreencastWindowSidecar.self, from: oldSidecarURL)
        XCTAssertNotNil(oldSidecar.endedAt)
        XCTAssertEqual(oldSidecar.acceptedFrameCount, 20)

        // Session opened window containing now under earlier anchor (window 0)
        XCTAssertEqual(session.currentHandoff?.segmentID, segmentID0)
        XCTAssertEqual(session.currentHandoff?.scheduleAnchorMs, earlierAnchorMs)
        XCTAssertEqual(session.currentWindowIndex, 0)
    }

    // MARK: - Acceptance Test I: Same-anchor higher revision at window k points at k+1, updates revision only until boundary
    func testSupersedingHandoffWithSameAnchorAtWindow1PointsAtWindow2UpdatesRevisionOnlyUntilBoundary() throws {
        let anchorMs: Int64 = 1_700_000_000_000
        let clock = TestSessionClock(initialDate: Date(timeIntervalSince1970: 1_700_000_000))
        let writer = TestBroadcastWriter()
        let state = TestSessionState()
        let sessionID = UUID()

        let segmentID0 = MobileSegmentScreencastIdentity.segmentID(
            sessionID: sessionID,
            scheduleAnchorMs: anchorMs,
            windowIndex: 0,
            schedulePeriodSeconds: 300
        )
        let handoffURL = MobileSegmentScreencastPaths.url(
            root: self.tempDir,
            relativePath: MobileSegmentScreencastPaths.handoffRelativePath()
        )
        let initialHandoff = MobileSegmentScreencastHandoffRecord(
            revision: 1,
            eventID: UUID(),
            sessionID: sessionID,
            segmentID: segmentID0,
            sourceSetVersion: 1,
            sourceSet: [.screencast],
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            segmentDirectoryRelativePath: "active/\(segmentID0.uuidString)",
            screenPartRelativePath: "active/\(segmentID0.uuidString)/screen.part",
            screenFinalRelativePath: "active/\(segmentID0.uuidString)/screen.mp4",
            desiredState: .writing,
            scheduleAnchorMs: anchorMs,
            schedulePeriodSeconds: 300,
            lastHostUpdateAt: clock.now()
        )
        try MobileSegmentScreencastJSONStore.write(initialHandoff, to: handoffURL)

        let session = ScreencastBroadcastSession(
            rootURL: self.tempDir,
            writer: writer,
            clock: { clock.now() },
            availableBytes: { _ in state.availableBytes },
            postChanged: {},
            finishWithError: { state.finishedError = $0 }
        )

        session.broadcastStarted(sessionID: sessionID)
        session.tick()
        XCTAssertEqual(session.currentWindowIndex, 0)

        // Advance to window 1 (T=301s)
        clock.advance(by: 301.0)
        session.tick()
        XCTAssertEqual(session.currentWindowIndex, 1)
        let segmentID1 = try XCTUnwrap(session.currentHandoff?.segmentID)
        writer.acceptedFrameCount = 50

        // Host writes revision 2 pointing at window 2 with same anchor
        let segmentID2 = MobileSegmentScreencastIdentity.segmentID(
            sessionID: sessionID,
            scheduleAnchorMs: anchorMs,
            windowIndex: 2,
            schedulePeriodSeconds: 300
        )
        let republishHandoff = MobileSegmentScreencastHandoffRecord(
            revision: 2,
            eventID: UUID(),
            sessionID: sessionID,
            segmentID: segmentID2,
            sourceSetVersion: 2,
            sourceSet: [.screencast],
            startedAt: Date(timeIntervalSince1970: 1_700_000_600),
            segmentDirectoryRelativePath: "active/\(segmentID2.uuidString)",
            screenPartRelativePath: "active/\(segmentID2.uuidString)/screen.part",
            screenFinalRelativePath: "active/\(segmentID2.uuidString)/screen.mp4",
            desiredState: .writing,
            scheduleAnchorMs: anchorMs,
            schedulePeriodSeconds: 300,
            lastHostUpdateAt: clock.now()
        )
        try MobileSegmentScreencastJSONStore.write(republishHandoff, to: handoffURL)

        // Tick at T=305s (still within window 1)
        clock.advance(by: 4.0)
        session.tick()

        XCTAssertEqual(session.currentWindowIndex, 1)
        XCTAssertEqual(session.currentHandoff?.segmentID, segmentID1)
        XCTAssertEqual(session.currentHandoff?.revision, 2)
        XCTAssertTrue(writer.isOpen)

        let sidecar1URL = MobileSegmentScreencastPaths.screenWindowURL(
            inSegmentDirectory: MobileSegmentScreencastPaths.url(
                root: self.tempDir,
                relativePath: MobileSegmentScreencastPaths.activeSegmentRelativeDirectory(segmentID: segmentID1)
            )
        )
        let sidecar1 = try MobileSegmentScreencastJSONStore.read(MobileSegmentScreencastWindowSidecar.self, from: sidecar1URL)
        XCTAssertNil(sidecar1.endedAt)

        // Advance to T=601s (window 2)
        clock.advance(by: 296.0)
        session.tick()

        XCTAssertEqual(session.currentWindowIndex, 2)
        XCTAssertEqual(session.currentHandoff?.segmentID, segmentID2)

        let closedSidecar1 = try MobileSegmentScreencastJSONStore.read(MobileSegmentScreencastWindowSidecar.self, from: sidecar1URL)
        XCTAssertNotNil(closedSidecar1.endedAt)
    }

    // MARK: - Acceptance Test J: Anchor two periods behind on adoptInitial opens derived window 2
    func testAdoptInitialHandoffTwoPeriodsBehindOpensDerivedWindow() throws {
        let anchorMs: Int64 = 1_700_000_000_000
        // Clock is at +650s -> window index 2
        let clock = TestSessionClock(initialDate: Date(timeIntervalSince1970: 1_700_000_650))
        let writer = TestBroadcastWriter()
        let state = TestSessionState()
        let sessionID = UUID()

        let segmentID0 = MobileSegmentScreencastIdentity.segmentID(
            sessionID: sessionID,
            scheduleAnchorMs: anchorMs,
            windowIndex: 0,
            schedulePeriodSeconds: 300
        )
        let initialHandoff = MobileSegmentScreencastHandoffRecord(
            revision: 1,
            eventID: UUID(),
            sessionID: sessionID,
            segmentID: segmentID0,
            sourceSetVersion: 1,
            sourceSet: [.screencast],
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            segmentDirectoryRelativePath: "active/\(segmentID0.uuidString)",
            screenPartRelativePath: "active/\(segmentID0.uuidString)/screen.part",
            screenFinalRelativePath: "active/\(segmentID0.uuidString)/screen.mp4",
            desiredState: .writing,
            scheduleAnchorMs: anchorMs,
            schedulePeriodSeconds: 300,
            lastHostUpdateAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let handoffURL = MobileSegmentScreencastPaths.url(
            root: self.tempDir,
            relativePath: MobileSegmentScreencastPaths.handoffRelativePath()
        )
        try MobileSegmentScreencastJSONStore.write(initialHandoff, to: handoffURL)

        let session = ScreencastBroadcastSession(
            rootURL: self.tempDir,
            writer: writer,
            clock: { clock.now() },
            availableBytes: { _ in state.availableBytes },
            postChanged: {},
            finishWithError: { state.finishedError = $0 }
        )

        session.broadcastStarted(sessionID: sessionID)
        session.tick()

        let expectedSegmentID2 = MobileSegmentScreencastIdentity.segmentID(
            sessionID: sessionID,
            scheduleAnchorMs: anchorMs,
            windowIndex: 2,
            schedulePeriodSeconds: 300
        )
        XCTAssertEqual(session.currentWindowIndex, 2)
        XCTAssertEqual(session.currentHandoff?.segmentID, expectedSegmentID2)

        let sidecar2URL = MobileSegmentScreencastPaths.screenWindowURL(
            inSegmentDirectory: MobileSegmentScreencastPaths.url(
                root: self.tempDir,
                relativePath: MobileSegmentScreencastPaths.activeSegmentRelativeDirectory(segmentID: expectedSegmentID2)
            )
        )
        let sidecar2 = try MobileSegmentScreencastJSONStore.read(MobileSegmentScreencastWindowSidecar.self, from: sidecar2URL)
        XCTAssertEqual(sidecar2.windowIndex, 2)
    }
}
