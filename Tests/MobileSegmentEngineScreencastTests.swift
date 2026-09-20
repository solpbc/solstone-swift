// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class MobileSegmentEngineScreencastTests: XCTestCase {
    private var tempDirectory: URL!
    private var clock: MockObserverClock!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileSegmentEngineScreencastTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        self.clock = MockObserverClock(now: Self.date(hour: 10, minute: 0, second: 0))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        self.clock = nil
        super.tearDown()
    }

    func testStartScreencastUnionsCurrentSources() async throws {
        for priorSources in Self.priorSourceSets {
            let harness = self.makeHarness()
            try await self.open(sources: priorSources, harness: harness)
            self.clock.advance(by: 10)

            let handoff = try await harness.engine.startScreencast(at: self.clock.now())

            let activeDirectory = try XCTUnwrap(try harness.store.list(.active).first)
            let manifest = try harness.store.readManifest(in: activeDirectory)
            XCTAssertEqual(Set(manifest.openedWithSources), priorSources.union([.screencast]))
            XCTAssertEqual(handoff.segmentID.uuidString, activeDirectory.lastPathComponent)
            XCTAssertEqual(Set(handoff.sourceSet), priorSources.union([.screencast]))
            XCTAssertEqual(handoff.screenFinalRelativePath, MobileSegmentScreencastPaths.screenRelativePath(segmentID: handoff.segmentID))
        }
    }

    func testStopScreencastSubtractsOnlyScreencast() async throws {
        for remainingSources in Self.priorSourceSets {
            let harness = self.makeHarness()
            try await self.open(sources: remainingSources, harness: harness)
            self.clock.advance(by: 10)
            let handoff = try await harness.engine.startScreencast(at: self.clock.now())
            try harness.uploader.recordScreencastNoArtifact(
                segmentID: handoff.segmentID,
                startedAt: handoff.startedAt,
                endedAt: self.clock.now(),
                durationS: 0,
                reason: "test_no_video"
            )

            self.clock.advance(by: 5)
            try await harness.engine.stopScreencast(at: self.clock.now())

            let activeDirectories = try harness.store.list(.active)
            if remainingSources.isEmpty {
                XCTAssertTrue(activeDirectories.isEmpty)
            } else {
                let activeDirectory = try XCTUnwrap(activeDirectories.first)
                let manifest = try harness.store.readManifest(in: activeDirectory)
                XCTAssertEqual(Set(manifest.openedWithSources), remainingSources)
            }
        }
    }

    func testTimerRolloverKeepsScreencastInStableSourceSet() async throws {
        let harness = self.makeHarness()
        var publishedHandoffs: [MobileSegmentScreencastHandoffRecord] = []
        harness.engine.screencastRolloverHandler = { handoff in
            publishedHandoffs.append(handoff)
            return true
        }
        try await self.open(sources: [.audio, .location], harness: harness)
        self.clock.advance(by: 10)
        let closingHandoff = try await harness.engine.startScreencast(at: self.clock.now())
        let closingDirectory = harness.store.segmentDirectoryURL(.active, segmentID: closingHandoff.segmentID)
        try Data("live-screen".utf8).write(to: harness.store.screenPartURL(in: closingDirectory), options: .atomic)
        try self.writeScreencastLiveness(segmentID: closingHandoff.segmentID, store: harness.store, lastSeenAt: self.clock.now())
        await Task.yield()

        self.clock.advance(by: 295)
        try self.writeScreencastLiveness(segmentID: closingHandoff.segmentID, store: harness.store, lastSeenAt: self.clock.now())
        self.clock.advance(by: 5)
        try await self.waitFor("screencast rollover") {
            (try? harness.store.list(.active).count) == 2
                && publishedHandoffs.count == 1
        }
        let activeIDs = try harness.store.list(.active).map(\.lastPathComponent).sorted()
        let pendingIDs = try harness.store.list(.pending).map(\.lastPathComponent).sorted()
        let failedIDs = try harness.store.list(.failed).map(\.lastPathComponent).sorted()
        let rolloverState = "active=\(activeIDs) pending=\(pendingIDs) failed=\(failedIDs) published=\(publishedHandoffs.map(\.segmentID.uuidString))"
        XCTAssertEqual(activeIDs.count, 2, rolloverState)
        XCTAssertEqual(publishedHandoffs.count, 1, rolloverState)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: closingDirectory.appendingPathComponent("manifest.json").path),
            "closing active manifest missing \(rolloverState)"
        )

        let closingManifest = try harness.store.readManifest(in: closingDirectory)
        XCTAssertEqual(closingManifest.screencast.state, .unresolved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.failed, segmentID: closingHandoff.segmentID).path))
        let nextHandoff = try XCTUnwrap(publishedHandoffs.first)
        XCTAssertNotEqual(nextHandoff.segmentID, closingHandoff.segmentID)
        XCTAssertEqual(nextHandoff.scheduleAnchorMs, closingHandoff.scheduleAnchorMs)
        XCTAssertEqual(Set(nextHandoff.sourceSet), [.audio, .location, .screencast])
        let nextDirectory = harness.store.segmentDirectoryURL(.active, segmentID: nextHandoff.segmentID)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: nextDirectory.appendingPathComponent("manifest.json").path),
            "next active manifest missing \(rolloverState)"
        )
        let nextManifest = try harness.store.readManifest(in: nextDirectory)
        XCTAssertEqual(Set(nextManifest.openedWithSources), [.audio, .location, .screencast])
    }

    func testHeldScreencastAdoptionSkipSegmentIDMatchesDerivedWindow() async throws {
        let harness = self.makeHarness()
        let start = self.clock.now()
        let handoff = try await harness.engine.startScreencast(at: start)

        let expectedID = MobileSegmentScreencastIdentity.segmentID(
            sessionID: handoff.sessionID,
            scheduleAnchorMs: handoff.scheduleAnchorMs,
            windowIndex: 0,
            schedulePeriodSeconds: handoff.schedulePeriodSeconds
        )
        XCTAssertEqual(harness.engine.heldScreencastAdoptionSkipSegmentID, expectedID)
    }

    // MARK: - Acceptance Test A: Audio join at +150s with snapshot assertions
    func testSourceSetChangeWhileScreenRunningReAnchorsSchedule() async throws {
        let harness = self.makeHarness()
        var publishedHandoffs: [MobileSegmentScreencastHandoffRecord] = []
        var oldManifestBytesInHandler: Data?

        let initialHandoff = try await harness.engine.startScreencast(at: self.clock.now())
        let initialAnchor = initialHandoff.scheduleAnchorMs
        let oldManifestURL = harness.store.manifestURL(in: harness.store.segmentDirectoryURL(.active, segmentID: initialHandoff.segmentID))
        self.clock.advance(by: 150)

        let preCallManifestBytes = try Data(contentsOf: oldManifestURL)

        harness.engine.screencastRolloverHandler = { handoff in
            publishedHandoffs.append(handoff)
            oldManifestBytesInHandler = try? Data(contentsOf: oldManifestURL)
            return true
        }

        let audioURL = try await harness.engine.startAudio(mode: .meeting)
        XCTAssertNotNil(audioURL)
        XCTAssertEqual(publishedHandoffs.count, 1)

        XCTAssertEqual(oldManifestBytesInHandler, preCallManifestBytes)

        let reanchoredHandoff = try XCTUnwrap(publishedHandoffs.first)
        XCTAssertEqual(reanchoredHandoff.sourceSetVersion, 2)
        XCTAssertEqual(reanchoredHandoff.revision, 2)
        XCTAssertEqual(Set(reanchoredHandoff.sourceSet), [.audio, .screencast])
        XCTAssertGreaterThan(reanchoredHandoff.scheduleAnchorMs, initialAnchor)

        let expectedNewID = MobileSegmentScreencastIdentity.segmentID(
            sessionID: reanchoredHandoff.sessionID,
            scheduleAnchorMs: reanchoredHandoff.scheduleAnchorMs,
            windowIndex: 0,
            schedulePeriodSeconds: reanchoredHandoff.schedulePeriodSeconds
        )
        XCTAssertEqual(reanchoredHandoff.segmentID, expectedNewID)

        let activeDirectories = try harness.store.list(.active)
        XCTAssertEqual(activeDirectories.count, 1)
        let activeDir = try XCTUnwrap(activeDirectories.first)
        XCTAssertEqual(activeDir.lastPathComponent, expectedNewID.uuidString)
        let newManifest = try harness.store.readManifest(in: activeDir)
        XCTAssertEqual(newManifest.segmentID, reanchoredHandoff.segmentID)
        XCTAssertEqual(Set(newManifest.openedWithSources), [.audio, .screencast])
        XCTAssertEqual(newManifest.activeSourceSetVersion, 2)
        XCTAssertEqual(newManifest.startedAt, reanchoredHandoff.startedAt)
    }

    // MARK: - Acceptance Test B: Location join while audio+screen run
    func testLocationJoinWhileAudioAndScreenRun() async throws {
        let harness = self.makeHarness()
        try await self.open(sources: [.audio], harness: harness)
        self.clock.advance(by: 10)
        let screenHandoff = try await harness.engine.startScreencast(at: self.clock.now())
        self.clock.advance(by: 50)

        let oldAudioURL = harness.uploader.activeAudioURL(segmentID: screenHandoff.segmentID)
        let oldAudioBytes = try Data(contentsOf: oldAudioURL)

        var rotateCallNextURL: URL?
        var rotateCallOldBytes: Data?
        var rotateCallNextURLExists: Bool?
        harness.engine.rotateAudio = { nextURL in
            rotateCallNextURL = nextURL
            rotateCallNextURLExists = FileManager.default.fileExists(atPath: nextURL.path)
            rotateCallOldBytes = try? Data(contentsOf: oldAudioURL)
            try? Data("rotated-audio".utf8).write(to: nextURL, options: .atomic)
            return ObserverRecordedChunk(url: oldAudioURL, duration: 50)
        }

        try harness.uploader.recordScreencastNoArtifact(
            segmentID: screenHandoff.segmentID,
            startedAt: screenHandoff.startedAt,
            endedAt: self.clock.now(),
            durationS: 50,
            reason: "test_rotation"
        )

        try await harness.engine.startLocation(tier: .balanced, accuracy: .full, startedAt: self.clock.now())

        XCTAssertEqual(rotateCallNextURLExists, false)
        XCTAssertNotEqual(rotateCallNextURL, oldAudioURL)
        XCTAssertEqual(rotateCallOldBytes, oldAudioBytes)

        guard case .open(let activeID, let activeSources, _) = harness.engine.state else {
            XCTFail("expected segment to be open")
            return
        }
        XCTAssertEqual(activeSources, [.audio, .location, .screencast])
        XCTAssertNotEqual(activeID, screenHandoff.segmentID)
    }

    // MARK: - Acceptance Test C: Two source-set changes at same clock instant coalesce
    func testTwoSourceSetChangesAtSameInstantCoalesce() async throws {
        let harness = self.makeHarness()
        var publishedHandoffs: [MobileSegmentScreencastHandoffRecord] = []
        harness.engine.screencastRolloverHandler = { handoff in
            publishedHandoffs.append(handoff)
            return true
        }

        let initialHandoff = try await harness.engine.startScreencast(at: self.clock.now())
        self.clock.advance(by: 30)

        harness.engine.rotateAudio = { nextURL in
            try? Data("audio".utf8).write(to: nextURL, options: .atomic)
            return nil
        }

        _ = try await harness.engine.startAudio(mode: .meeting)
        try await harness.engine.startLocation(tier: .balanced, accuracy: .full, startedAt: self.clock.now())

        XCTAssertGreaterThanOrEqual(publishedHandoffs.count, 2)
        var previousAnchor: Int64 = initialHandoff.scheduleAnchorMs
        var seenIDs: Set<UUID> = [initialHandoff.segmentID]
        for handoff in publishedHandoffs {
            XCTAssertGreaterThan(handoff.scheduleAnchorMs, previousAnchor)
            XCTAssertFalse(seenIDs.contains(handoff.segmentID))
            seenIDs.insert(handoff.segmentID)
            previousAnchor = handoff.scheduleAnchorMs
        }
    }

    // MARK: - Acceptance Test D: Failed create and failed publish rollback tests (start vs stop)
    func testAudioStartReAnchorRollbackOnStoreFailure() async throws {
        let harness = self.makeHarness()
        var handlerInvoked = false
        harness.engine.screencastRolloverHandler = { _ in
            handlerInvoked = true
            return true
        }

        let initialHandoff = try await harness.engine.startScreencast(at: self.clock.now())
        self.clock.advance(by: 30)

        let oldManifestURL = harness.store.manifestURL(in: harness.store.segmentDirectoryURL(.active, segmentID: initialHandoff.segmentID))
        let preManifestBytes = try Data(contentsOf: oldManifestURL)

        harness.store.testCreateActiveError = NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "simulated store write failure"])

        do {
            _ = try await harness.engine.startAudio(mode: .meeting)
            XCTFail("expected startAudio to throw on store failure")
        } catch {
            // expected error
        }

        XCTAssertFalse(handlerInvoked)
        guard case .open(let activeID, let activeSources, _) = harness.engine.state else {
            XCTFail("expected old segment to remain open")
            return
        }
        XCTAssertEqual(activeID, initialHandoff.segmentID)
        XCTAssertEqual(activeSources, [.screencast])

        let currentHandoff = try XCTUnwrap(harness.engine.currentScreencastHandoff())
        XCTAssertEqual(currentHandoff.scheduleAnchorMs, initialHandoff.scheduleAnchorMs)
        XCTAssertEqual(currentHandoff.revision, initialHandoff.revision)

        let postManifestBytes = try Data(contentsOf: oldManifestURL)
        XCTAssertEqual(postManifestBytes, preManifestBytes)

        let activeDirectories = try harness.store.list(.active)
        XCTAssertEqual(activeDirectories.count, 1)
        XCTAssertEqual(activeDirectories.first?.lastPathComponent, initialHandoff.segmentID.uuidString)

        // Allow rollback to restart timer task and register sleeper
        for _ in 0..<20 {
            await Task.yield()
        }
        // Advance clock exactly to old window end (300s total from start)
        self.clock.advance(by: 270)
        let expectedOldAnchorWindow1ID = MobileSegmentScreencastIdentity.segmentID(
            sessionID: initialHandoff.sessionID,
            scheduleAnchorMs: initialHandoff.scheduleAnchorMs,
            windowIndex: 1,
            schedulePeriodSeconds: initialHandoff.schedulePeriodSeconds
        )
        try await self.waitFor("timer rollover") {
            guard case .open(let activeID, let sources, _) = harness.engine.state else { return false }
            return activeID == expectedOldAnchorWindow1ID && sources == [.screencast]
        }
        guard case .open(let activeID, let sources, _) = harness.engine.state else {
            XCTFail("expected rolled over active segment to remain open")
            return
        }
        XCTAssertEqual(activeID, expectedOldAnchorWindow1ID)
        XCTAssertEqual(sources, [.screencast])
    }

    func testLocationStartReAnchorRollbackOnStoreFailure() async throws {
        let harness = self.makeHarness()
        let initialHandoff = try await harness.engine.startScreencast(at: self.clock.now())
        self.clock.advance(by: 30)

        harness.store.testCreateActiveError = NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "simulated store failure"])

        do {
            try await harness.engine.startLocation(tier: .balanced, accuracy: .full, startedAt: self.clock.now())
            XCTFail("expected startLocation to throw")
        } catch {
            // expected error
        }

        guard case .open(let activeID, let activeSources, _) = harness.engine.state else {
            XCTFail("expected old segment to remain open")
            return
        }
        XCTAssertEqual(activeID, initialHandoff.segmentID)
        XCTAssertEqual(activeSources, [.screencast])
    }

    func testAudioStopReAnchorRollbackOnStoreFailure() async throws {
        let harness = self.makeHarness()
        try await self.open(sources: [.audio], harness: harness)
        self.clock.advance(by: 10)
        let screenHandoff = try await harness.engine.startScreencast(at: self.clock.now())
        self.clock.advance(by: 20)

        let audioURL = harness.uploader.activeAudioURL(segmentID: screenHandoff.segmentID)
        harness.store.testCreateActiveError = NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "simulated failure"])

        await harness.engine.stopAudio(finalized: ObserverRecordedChunk(url: audioURL, duration: 20))

        guard case .open(let activeID, let activeSources, _) = harness.engine.state else {
            XCTFail("expected old segment to remain open")
            return
        }
        XCTAssertEqual(activeID, screenHandoff.segmentID)
        XCTAssertEqual(activeSources, [.screencast])

        let oldManifest = try harness.store.readManifest(in: harness.store.segmentDirectoryURL(.active, segmentID: screenHandoff.segmentID))
        XCTAssertEqual(oldManifest.audio.state, .finalizedArtifact)
    }

    func testLocationStopReAnchorRollbackOnStoreFailure() async throws {
        let harness = self.makeHarness()
        try await self.open(sources: [.location], harness: harness)
        self.clock.advance(by: 10)
        let screenHandoff = try await harness.engine.startScreencast(at: self.clock.now())
        self.clock.advance(by: 20)

        harness.store.testCreateActiveError = NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "simulated failure"])

        await harness.engine.stopLocation()

        guard case .open(let activeID, let activeSources, _) = harness.engine.state else {
            XCTFail("expected old segment to remain open")
            return
        }
        XCTAssertEqual(activeID, screenHandoff.segmentID)
        XCTAssertEqual(activeSources, [.screencast])

        let oldManifest = try harness.store.readManifest(in: harness.store.segmentDirectoryURL(.active, segmentID: screenHandoff.segmentID))
        XCTAssertEqual(oldManifest.location.state, .noArtifact)

        let failedDirectories = try harness.store.list(.failed)
        XCTAssertTrue(failedDirectories.isEmpty)
    }

    // MARK: - Acceptance Test E: Screen start with audio running earlier instant uses clock anchor
    func testScreenStartWithAudioRunningEarlierInstantUsesClockAnchor() async throws {
        let harness = self.makeHarness()
        try await self.open(sources: [.audio], harness: harness)
        self.clock.advance(by: 100)

        let clockNow = self.clock.now()
        let earlier = clockNow.addingTimeInterval(-60)
        let handoff = try await harness.engine.startScreencast(at: earlier)

        let expectedAnchorMs = MobileSegmentScreencastIdentity.nowMs(from: clockNow)
        XCTAssertGreaterThanOrEqual(handoff.scheduleAnchorMs, expectedAnchorMs)

        let expectedWindow0Start = MobileSegmentScreencastIdentity.windowStart(
            scheduleAnchorMs: handoff.scheduleAnchorMs,
            windowIndex: 0,
            schedulePeriodSeconds: handoff.schedulePeriodSeconds
        )
        XCTAssertEqual(handoff.startedAt, expectedWindow0Start)

        let activeDirectory = harness.store.segmentDirectoryURL(.active, segmentID: handoff.segmentID)
        let manifest = try harness.store.readManifest(in: activeDirectory)
        XCTAssertEqual(manifest.startedAt, expectedWindow0Start)
    }

    // MARK: - Acceptance Test F: Screen stop uses random ID
    func testScreenStopUsesRandomIDNotOldAnchorID() async throws {
        let harness = self.makeHarness()
        try await self.open(sources: [.audio], harness: harness)
        self.clock.advance(by: 10)
        let screenHandoff = try await harness.engine.startScreencast(at: self.clock.now())
        self.clock.advance(by: 20)

        try await harness.engine.stopScreencast(at: self.clock.now())

        guard case .open(let nextID, let nextSources, _) = harness.engine.state else {
            XCTFail("expected segment to be open")
            return
        }
        XCTAssertEqual(nextSources, [.audio])

        for k in 0..<10 {
            let oldAnchorID = MobileSegmentScreencastIdentity.segmentID(
                sessionID: screenHandoff.sessionID,
                scheduleAnchorMs: screenHandoff.scheduleAnchorMs,
                windowIndex: k,
                schedulePeriodSeconds: screenHandoff.schedulePeriodSeconds
            )
            XCTAssertNotEqual(nextID, oldAnchorID)
        }
    }

    // MARK: - Acceptance Test G: Engine relaunch with adopted extension window
    func testEngineRelaunchAdoptedExtensionWindow() async throws {
        let harness = self.makeHarness()
        let adoptedID = UUID()
        let adoptedAnchorMs = MobileSegmentScreencastIdentity.nowMs(from: self.clock.now())
        let adoptedWindowStart = MobileSegmentScreencastIdentity.windowStart(
            scheduleAnchorMs: adoptedAnchorMs,
            windowIndex: 0,
            schedulePeriodSeconds: 300
        )

        let adoptedDir = harness.store.segmentDirectoryURL(.active, segmentID: adoptedID)
        try FileManager.default.createDirectory(at: adoptedDir, withIntermediateDirectories: true)
        let adoptedManifest = MobileSegmentManifest(
            segmentID: adoptedID,
            startedAt: adoptedWindowStart,
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        )
        try harness.store.writeManifest(adoptedManifest, in: adoptedDir)
        let adoptedManifestBytes = try Data(contentsOf: harness.store.manifestURL(in: adoptedDir))

        self.clock.advance(by: 50)
        let newHandoff = try await harness.engine.startScreencast(at: adoptedWindowStart)

        XCTAssertNotEqual(newHandoff.segmentID, adoptedID)
        XCTAssertGreaterThan(newHandoff.scheduleAnchorMs, adoptedAnchorMs)

        let postAdoptedBytes = try Data(contentsOf: harness.store.manifestURL(in: adoptedDir))
        XCTAssertEqual(postAdoptedBytes, adoptedManifestBytes)
    }

    func testReAnchorRollbackOnHandlerFailureCleansUpCandidateDirectoryAndPreservesOldSegment() async throws {
        let harness = self.makeHarness()
        harness.engine.screencastRolloverHandler = { _ in
            return false
        }

        let initialHandoff = try await harness.engine.startScreencast(at: self.clock.now())
        self.clock.advance(by: 30)

        do {
            _ = try await harness.engine.startAudio(mode: .meeting)
            XCTFail("expected startAudio to throw on handler failure")
        } catch {
            XCTAssertEqual(error as? MobileSegmentEngineError, .handoffPublishFailed)
        }

        guard case .open(let activeID, let activeSources, _) = harness.engine.state else {
            XCTFail("expected old segment to remain open")
            return
        }
        XCTAssertEqual(activeID, initialHandoff.segmentID)
        XCTAssertEqual(activeSources, [.screencast])

        let activeDirectories = try harness.store.list(.active)
        XCTAssertEqual(activeDirectories.count, 1)
        XCTAssertEqual(activeDirectories.first?.lastPathComponent, initialHandoff.segmentID.uuidString)
    }

    func testReAnchorWhenAudioStopsWhileScreenRunning() async throws {
        let harness = self.makeHarness()
        var publishedHandoffs: [MobileSegmentScreencastHandoffRecord] = []
        harness.engine.screencastRolloverHandler = { handoff in
            publishedHandoffs.append(handoff)
            return true
        }

        try await self.open(sources: [.audio], harness: harness)
        self.clock.advance(by: 10)
        let screenHandoff = try await harness.engine.startScreencast(at: self.clock.now())
        XCTAssertEqual(Set(screenHandoff.sourceSet), [.audio, .screencast])

        self.clock.advance(by: 20)
        let audioURL = harness.uploader.activeAudioURL(segmentID: screenHandoff.segmentID)
        await harness.engine.stopAudio(finalized: ObserverRecordedChunk(url: audioURL, duration: 20))

        guard case .open(let activeID, let activeSources, _) = harness.engine.state else {
            XCTFail("expected segment to remain open after audio stop")
            return
        }
        XCTAssertEqual(activeSources, [.screencast])
        XCTAssertNotEqual(activeID, screenHandoff.segmentID)

        let pendingDirectories = try harness.store.list(.pending)
        XCTAssertEqual(pendingDirectories.count, 2)
    }
}

private extension MobileSegmentEngineScreencastTests {
    struct Harness {
        let engine: MobileSegmentEngine
        let uploader: MobileSegmentUploader
        let store: MobileSegmentStore
    }

    static let priorSourceSets: [Set<MobileSegmentSource>] = [
        [],
        [.audio],
        [.location],
        [.audio, .location],
    ]

    func makeHarness() -> Harness {
        let root = self.tempDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = MobileSegmentStore(rootURL: root.appendingPathComponent("MobileSegment", isDirectory: true))
        let uploader = MobileSegmentUploader(store: store, clock: self.clock)
        let engine = MobileSegmentEngine(uploader: uploader, clock: self.clock)
        return Harness(engine: engine, uploader: uploader, store: store)
    }

    func open(sources: Set<MobileSegmentSource>, harness: Harness) async throws {
        var currentAudioURL: URL?
        harness.engine.rotateAudio = { nextURL in
            if let finalizedURL = currentAudioURL {
                try Data("rotated-audio".utf8).write(to: nextURL, options: .atomic)
                let finalized = ObserverRecordedChunk(url: finalizedURL, duration: 1)
                currentAudioURL = nextURL
                return finalized
            }
            try Data("rotated-audio".utf8).write(to: nextURL, options: .atomic)
            currentAudioURL = nextURL
            return nil
        }

        if sources.contains(.audio) {
            currentAudioURL = try await harness.engine.startAudio(mode: .meeting)
            if let currentAudioURL {
                try Data("audio".utf8).write(to: currentAudioURL, options: .atomic)
            }
        }
        if sources.contains(.location) {
            try await harness.engine.startLocation(tier: .balanced, accuracy: .full, startedAt: self.clock.now())
            harness.engine.recordLocationFix(Self.fix(at: self.clock.now()))
        }
    }

    func waitFor(_ label: String, timeout: Duration = .seconds(2), condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(label)")
    }

    static func fix(at date: Date) -> LocationFix {
        LocationFix(
            t: date,
            lat: 37.3349,
            lon: -122.0090,
            hAcc: 12,
            alt: nil,
            vAcc: nil,
            speed: nil,
            course: nil,
            stationary: false
        )
    }

    static func date(hour: Int, minute: Int, second: Int) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = 2026
        components.month = 6
        components.day = 28
        components.hour = hour
        components.minute = minute
        components.second = second
        return components.calendar!.date(from: components)!
    }

    func writeScreencastLiveness(segmentID: UUID, store: MobileSegmentStore, lastSeenAt: Date) throws {
        let directory = store.segmentDirectoryURL(.active, segmentID: segmentID)
        let liveness = MobileSegmentScreencastSegmentLiveness(
            sessionID: UUID(),
            segmentID: segmentID,
            handoffRevision: 1,
            lastSeenAt: lastSeenAt,
            acceptedFrameCount: 1,
            droppedFrameCount: 0
        )
        try MobileSegmentScreencastJSONStore.write(
            liveness,
            to: MobileSegmentScreencastPaths.screenLivenessURL(inSegmentDirectory: directory)
        )
    }
}
