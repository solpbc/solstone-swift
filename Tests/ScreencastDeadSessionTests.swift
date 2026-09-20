// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class ScreencastDeadSessionTests: XCTestCase {
    private var tempDirectory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var clock: MockObserverClock!

    override func setUp() {
        super.setUp()
        self.suiteName = "app.solstone.swift.tests.\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: self.suiteName)
        self.tempDirectory = URL(fileURLWithPath: "/var/tmp")
            .appendingPathComponent("screencast_dead_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        self.clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_780_480_800))
    }

    override func tearDown() {
        if let tempDirectory = self.tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        if let suiteName = self.suiteName {
            self.defaults?.removePersistentDomain(forName: suiteName)
        }
        self.defaults = nil
        self.clock = nil
        super.tearDown()
    }

    private func makeRealHarness() -> (root: URL, engine: MobileSegmentEngine, uploader: MobileSegmentUploader, store: MobileSegmentStore, manager: ScreencastManager) {
        let storeURL = self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true)
        let store = MobileSegmentStore(rootURL: storeURL)
        let uploader = MobileSegmentUploader(store: store, clock: self.clock)
        let engine = MobileSegmentEngine(uploader: uploader, clock: self.clock)
        let manager = ScreencastManager(
            engine: engine,
            uploader: uploader,
            clock: self.clock,
            defaults: self.defaults,
            rootURLProvider: { self.tempDirectory },
            darwin: StubScreencastDarwin()
        )
        return (self.tempDirectory, engine, uploader, store, manager)
    }

    private func drainUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Scan Active Liveness Tests

    func testScanActiveLivenessMissingDirectory() {
        let sessionID = UUID()
        let result = scanActiveLiveness(
            root: self.tempDirectory,
            sessionID: sessionID,
            candidateSegmentIDs: [],
            now: self.clock.now()
        )
        XCTAssertEqual(result, .observed(newestLastSeenAt: nil, hasSessionUndecodableLiveness: false, hasFreshLiveness: false))
    }

    func testScanActiveLivenessFreshAndStaleObserved() throws {
        let sessionID = UUID()
        let segmentID = UUID()
        let now = self.clock.now()

        // Fresh (< 10s)
        try writeLiveness(root: self.tempDirectory, sessionID: sessionID, segmentID: segmentID, lastSeenAt: now.addingTimeInterval(-2))
        let freshResult = scanActiveLiveness(root: self.tempDirectory, sessionID: sessionID, candidateSegmentIDs: [segmentID], now: now)
        XCTAssertEqual(freshResult, .observed(newestLastSeenAt: now.addingTimeInterval(-2), hasSessionUndecodableLiveness: false, hasFreshLiveness: true))

        // Stale (>= 10s)
        try writeLiveness(root: self.tempDirectory, sessionID: sessionID, segmentID: segmentID, lastSeenAt: now.addingTimeInterval(-15))
        let staleResult = scanActiveLiveness(root: self.tempDirectory, sessionID: sessionID, candidateSegmentIDs: [segmentID], now: now)
        XCTAssertEqual(staleResult, .observed(newestLastSeenAt: now.addingTimeInterval(-15), hasSessionUndecodableLiveness: false, hasFreshLiveness: false))
    }

    func testScanActiveLivenessDifferentSessionIgnored() throws {
        let sessionID = UUID()
        let otherSessionID = UUID()
        let segmentID = UUID()
        let now = self.clock.now()

        try writeLiveness(root: self.tempDirectory, sessionID: otherSessionID, segmentID: segmentID, lastSeenAt: now.addingTimeInterval(-2))
        let result = scanActiveLiveness(root: self.tempDirectory, sessionID: sessionID, candidateSegmentIDs: [segmentID], now: now)
        XCTAssertEqual(result, .observed(newestLastSeenAt: nil, hasSessionUndecodableLiveness: false, hasFreshLiveness: false))
    }

    func testScanActiveLivenessCorruptFileInCandidateSegment() throws {
        let sessionID = UUID()
        let segmentID = UUID()
        let nonCandidateSegmentID = UUID()
        let now = self.clock.now()

        let segDir = self.tempDirectory
            .appendingPathComponent("MobileSegment", isDirectory: true)
            .appendingPathComponent("active", isDirectory: true)
            .appendingPathComponent(segmentID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: segDir, withIntermediateDirectories: true)
        let liveURL = segDir.appendingPathComponent(MobileSegmentScreencastPaths.screenLivenessFilename, isDirectory: false)
        try "corrupt json".write(to: liveURL, atomically: true, encoding: .utf8)

        let resultWithCandidate = scanActiveLiveness(root: self.tempDirectory, sessionID: sessionID, candidateSegmentIDs: [segmentID], now: now)
        XCTAssertEqual(resultWithCandidate, .observed(newestLastSeenAt: nil, hasSessionUndecodableLiveness: true, hasFreshLiveness: false))

        let resultWithoutCandidate = scanActiveLiveness(root: self.tempDirectory, sessionID: sessionID, candidateSegmentIDs: [nonCandidateSegmentID], now: now)
        XCTAssertEqual(resultWithoutCandidate, .observed(newestLastSeenAt: nil, hasSessionUndecodableLiveness: false, hasFreshLiveness: false))
    }

    // MARK: - Deadness Predicate Tests

    func testIsDeadShapedDiskEvaluations() {
        let now = self.clock.now()
        let runtime = ScreencastFixtures.runtime(
            lastSeenAt: now.addingTimeInterval(-13)
        )
        let deadScan = ScreencastLivenessScanResult.observed(newestLastSeenAt: nil, hasSessionUndecodableLiveness: false, hasFreshLiveness: false)

        XCTAssertTrue(isDeadShapedDisk(runtime: runtime, diagnostic: nil, scanResult: deadScan, now: now))

        // Fresh cancels
        let freshScan = ScreencastLivenessScanResult.observed(newestLastSeenAt: now, hasSessionUndecodableLiveness: false, hasFreshLiveness: true)
        XCTAssertFalse(isDeadShapedDisk(runtime: runtime, diagnostic: nil, scanResult: freshScan, now: now))

        // Undecodable cancels
        let undecodableScan = ScreencastLivenessScanResult.observed(newestLastSeenAt: nil, hasSessionUndecodableLiveness: true, hasFreshLiveness: false)
        XCTAssertFalse(isDeadShapedDisk(runtime: runtime, diagnostic: nil, scanResult: undecodableScan, now: now))

        // Listing failed cancels
        XCTAssertFalse(isDeadShapedDisk(runtime: runtime, diagnostic: nil, scanResult: .listingFailed, now: now))

        // Diagnostic present cancels
        let diagnostic = ScreencastFixtures.diagnostic(reason: .noVideo)
        XCTAssertFalse(isDeadShapedDisk(runtime: runtime, diagnostic: diagnostic, scanResult: deadScan, now: now))

        // Young runtime (< 12s) cancels
        let youngRuntime = ScreencastFixtures.runtime(lastSeenAt: now.addingTimeInterval(-5))
        XCTAssertFalse(isDeadShapedDisk(runtime: youngRuntime, diagnostic: nil, scanResult: deadScan, now: now))

        // Finalized runtime cancels
        let finalizedRuntime = ScreencastFixtures.runtime(state: .finalized, lastSeenAt: now.addingTimeInterval(-20))
        XCTAssertFalse(isDeadShapedDisk(runtime: finalizedRuntime, diagnostic: nil, scanResult: deadScan, now: now))
    }

    func testIsDeadScreencastSessionRequiresActiveStateOrEngine() {
        let now = self.clock.now()
        let runtime = ScreencastFixtures.runtime(lastSeenAt: now.addingTimeInterval(-13))
        let deadScan = ScreencastLivenessScanResult.observed(newestLastSeenAt: nil, hasSessionUndecodableLiveness: false, hasFreshLiveness: false)

        XCTAssertTrue(isDeadScreencastSession(
            runtime: runtime,
            diagnostic: nil,
            scanResult: deadScan,
            engineSources: [.screencast],
            managerState: .off,
            now: now
        ))

        XCTAssertTrue(isDeadScreencastSession(
            runtime: runtime,
            diagnostic: nil,
            scanResult: deadScan,
            engineSources: [],
            managerState: .active(sessionID: runtime.sessionID, segmentID: UUID(), startedAt: runtime.startedAt),
            now: now
        ))

        XCTAssertFalse(isDeadScreencastSession(
            runtime: runtime,
            diagnostic: nil,
            scanResult: deadScan,
            engineSources: [],
            managerState: .off,
            now: now
        ))
    }

    // MARK: - Real Pair Tests

    func testRealPairConcludesDeadSessionFinalizesPartial() async throws {
        let (root, engine, uploader, store, manager) = self.makeRealHarness()
        let sessionID = UUID()

        let handoff = try await engine.startScreencast(at: self.clock.now(), sessionID: sessionID)
        let segmentID = handoff.segmentID

        manager.state = .active(sessionID: sessionID, segmentID: segmentID, startedAt: self.clock.now())

        // Plant playable fragmented part
        let segDir = store.segmentDirectoryURL(.active, segmentID: segmentID)
        let partURL = MobileSegmentScreencastPaths.screenPartURL(inSegmentDirectory: segDir)
        try writeFragmentedMovie(to: partURL, frames: 3)

        // Stale liveness (15s ago)
        self.clock.advance(by: 15)
        try writeLiveness(root: root, sessionID: sessionID, segmentID: segmentID, lastSeenAt: self.clock.now().addingTimeInterval(-15))

        // Stale runtime on disk
        let runtime = ScreencastFixtures.runtime(
            sessionID: sessionID,
            state: .writerOpen,
            segmentID: segmentID,
            lastSeenAt: self.clock.now().addingTimeInterval(-15)
        )
        let runtimeURL = MobileSegmentScreencastPaths.url(root: root, relativePath: MobileSegmentScreencastPaths.runtimeRelativePath())
        try MobileSegmentScreencastJSONStore.write(runtime, to: runtimeURL)

        await manager.reconcileScreencast(reason: .foreground)

        // 1. Partial finalized and pending
        let pending = try store.list(.pending)
        XCTAssertTrue(pending.contains { $0.lastPathComponent == segmentID.uuidString })

        // 2. Manager .off with system-ended marker
        XCTAssertEqual(manager.state, .off)
        XCTAssertEqual(manager.systemEndedAt, self.clock.now())

        // 3. Engine without .screencast
        XCTAssertFalse(engine.currentScreencastSources.contains(.screencast))
    }

    func testRealPairKilledWindowAlreadyDelivered() async throws {
        let (root, engine, _, store, manager) = self.makeRealHarness()
        let sessionID = UUID()
        let handoff = try await engine.startScreencast(at: self.clock.now(), sessionID: sessionID)
        let segmentID = handoff.segmentID

        manager.state = .active(sessionID: sessionID, segmentID: segmentID, startedAt: self.clock.now())

        // Simulate segment finalized & retired
        try await engine.stopScreencast(at: self.clock.now())
        _ = try await engine.startScreencast(at: self.clock.now(), sessionID: sessionID)
        try? FileManager.default.removeItem(at: store.segmentDirectoryURL(.active, segmentID: segmentID))

        self.clock.advance(by: 15)
        let runtime = ScreencastFixtures.runtime(
            sessionID: sessionID,
            state: .writerOpen,
            segmentID: segmentID,
            lastSeenAt: self.clock.now().addingTimeInterval(-15)
        )
        let runtimeURL = MobileSegmentScreencastPaths.url(root: root, relativePath: MobileSegmentScreencastPaths.runtimeRelativePath())
        try MobileSegmentScreencastJSONStore.write(runtime, to: runtimeURL)

        await manager.reconcileScreencast(reason: .foreground)

        XCTAssertEqual(manager.state, .off)
        XCTAssertEqual(manager.systemEndedAt, self.clock.now())
        XCTAssertFalse(engine.currentScreencastSources.contains(.screencast))
    }

    func testRealPairNoLivenessFileAnywhere() async throws {
        let (root, engine, _, _, manager) = self.makeRealHarness()
        let sessionID = UUID()
        let handoff = try await engine.startScreencast(at: self.clock.now(), sessionID: sessionID)
        manager.state = .active(sessionID: sessionID, segmentID: handoff.segmentID, startedAt: self.clock.now())

        self.clock.advance(by: 15)
        let runtime = ScreencastFixtures.runtime(
            sessionID: sessionID,
            state: .writerOpen,
            segmentID: handoff.segmentID,
            lastSeenAt: self.clock.now().addingTimeInterval(-15)
        )
        let runtimeURL = MobileSegmentScreencastPaths.url(root: root, relativePath: MobileSegmentScreencastPaths.runtimeRelativePath())
        try MobileSegmentScreencastJSONStore.write(runtime, to: runtimeURL)

        await manager.reconcileScreencast(reason: .foreground)

        XCTAssertEqual(manager.state, .off)
        XCTAssertEqual(manager.systemEndedAt, self.clock.now())
        XCTAssertFalse(engine.currentScreencastSources.contains(.screencast))
    }

    func testRealPairBroadcastStartedNoWindowOpened() async throws {
        let (root, engine, _, _, manager) = self.makeRealHarness()
        let sessionID = UUID()
        _ = try await engine.startScreencast(at: self.clock.now(), sessionID: sessionID)
        manager.state = .active(sessionID: sessionID, segmentID: UUID(), startedAt: self.clock.now())

        self.clock.advance(by: 15)
        let runtime = ScreencastFixtures.runtime(
            sessionID: sessionID,
            state: .broadcastStarted,
            segmentID: nil,
            lastSeenAt: self.clock.now().addingTimeInterval(-15)
        )
        let runtimeURL = MobileSegmentScreencastPaths.url(root: root, relativePath: MobileSegmentScreencastPaths.runtimeRelativePath())
        try MobileSegmentScreencastJSONStore.write(runtime, to: runtimeURL)

        await manager.reconcileScreencast(reason: .foreground)

        XCTAssertEqual(manager.state, .off)
        XCTAssertEqual(manager.systemEndedAt, self.clock.now())
        XCTAssertFalse(engine.currentScreencastSources.contains(.screencast))
    }

    func testNegativeTwinDeadDiskIdleEngineStaysOff() async throws {
        let (root, engine, _, _, manager) = self.makeRealHarness()
        let sessionID = UUID()
        manager.state = .off

        self.clock.advance(by: 15)
        let runtime = ScreencastFixtures.runtime(
            sessionID: sessionID,
            state: .broadcastStarted,
            segmentID: nil,
            lastSeenAt: self.clock.now().addingTimeInterval(-15)
        )
        let runtimeURL = MobileSegmentScreencastPaths.url(root: root, relativePath: MobileSegmentScreencastPaths.runtimeRelativePath())
        try MobileSegmentScreencastJSONStore.write(runtime, to: runtimeURL)

        await manager.reconcileScreencast(reason: .launch)

        XCTAssertEqual(manager.state, .off)
        XCTAssertNil(manager.systemEndedAt)
        XCTAssertFalse(engine.currentScreencastSources.contains(.screencast))
    }

    // MARK: - Never Concluded Tests

    func testNeverConcludedFreshLivenessCurrentWindow() async throws {
        let (root, engine, _, _, manager) = self.makeRealHarness()
        let sessionID = UUID()
        let handoff = try await engine.startScreencast(at: self.clock.now(), sessionID: sessionID)
        manager.state = .active(sessionID: sessionID, segmentID: handoff.segmentID, startedAt: self.clock.now())

        self.clock.advance(by: 15)
        // Fresh liveness (1s ago)
        try writeLiveness(root: root, sessionID: sessionID, segmentID: handoff.segmentID, lastSeenAt: self.clock.now().addingTimeInterval(-1))

        let runtime = ScreencastFixtures.runtime(
            sessionID: sessionID,
            state: .writerOpen,
            segmentID: handoff.segmentID,
            lastSeenAt: self.clock.now().addingTimeInterval(-15)
        )
        let runtimeURL = MobileSegmentScreencastPaths.url(root: root, relativePath: MobileSegmentScreencastPaths.runtimeRelativePath())
        try MobileSegmentScreencastJSONStore.write(runtime, to: runtimeURL)

        await manager.reconcileScreencast(reason: .foreground)

        if case .active = manager.state {} else {
            XCTFail("Manager should have remained active")
        }
        XCTAssertNil(manager.systemEndedAt)
    }

    func testNeverConcludedFreshLivenessDifferentActiveWindow() async throws {
        let (root, engine, _, _, manager) = self.makeRealHarness()
        let sessionID = UUID()
        let handoff = try await engine.startScreencast(at: self.clock.now(), sessionID: sessionID)
        let otherSegmentID = UUID()
        manager.state = .active(sessionID: sessionID, segmentID: handoff.segmentID, startedAt: self.clock.now())

        self.clock.advance(by: 15)
        // Fresh liveness in different segment of same session
        try writeLiveness(root: root, sessionID: sessionID, segmentID: otherSegmentID, lastSeenAt: self.clock.now().addingTimeInterval(-1))

        let runtime = ScreencastFixtures.runtime(
            sessionID: sessionID,
            state: .writerOpen,
            segmentID: handoff.segmentID,
            lastSeenAt: self.clock.now().addingTimeInterval(-15)
        )
        let runtimeURL = MobileSegmentScreencastPaths.url(root: root, relativePath: MobileSegmentScreencastPaths.runtimeRelativePath())
        try MobileSegmentScreencastJSONStore.write(runtime, to: runtimeURL)

        await manager.reconcileScreencast(reason: .foreground)

        if case .active = manager.state {} else {
            XCTFail("Manager should have remained active")
        }
        XCTAssertNil(manager.systemEndedAt)
    }

    func testNeverConcludedYoungRuntime() async throws {
        let (root, engine, _, _, manager) = self.makeRealHarness()
        let sessionID = UUID()
        let handoff = try await engine.startScreencast(at: self.clock.now(), sessionID: sessionID)
        manager.state = .active(sessionID: sessionID, segmentID: handoff.segmentID, startedAt: self.clock.now())

        // Runtime only 3s old (< 12s)
        self.clock.advance(by: 3)
        let runtime = ScreencastFixtures.runtime(
            sessionID: sessionID,
            state: .writerOpen,
            segmentID: handoff.segmentID,
            lastSeenAt: self.clock.now()
        )
        let runtimeURL = MobileSegmentScreencastPaths.url(root: root, relativePath: MobileSegmentScreencastPaths.runtimeRelativePath())
        try MobileSegmentScreencastJSONStore.write(runtime, to: runtimeURL)

        await manager.reconcileScreencast(reason: .foreground)

        if case .active = manager.state {} else {
            XCTFail("Manager should have remained active")
        }
        XCTAssertNil(manager.systemEndedAt)
    }

    func testNeverConcludedTerminalDiagnosticPresent() async throws {
        let sessionID = UUID()
        let segmentID = UUID()
        let engine = FakeScreencastEngine(sources: [.screencast])
        let uploader = FakeScreencastUploader()
        let manager = ScreencastManager(
            engine: engine,
            uploader: uploader,
            clock: self.clock,
            defaults: self.defaults,
            rootURLProvider: { self.tempDirectory },
            darwin: StubScreencastDarwin()
        )
        manager.state = .active(sessionID: sessionID, segmentID: segmentID, startedAt: self.clock.now())

        self.clock.advance(by: 15)
        let runtime = ScreencastFixtures.runtime(
            sessionID: sessionID,
            state: .writerOpen,
            segmentID: segmentID,
            lastSeenAt: self.clock.now().addingTimeInterval(-15)
        )
        let runtimeURL = MobileSegmentScreencastPaths.url(root: self.tempDirectory, relativePath: MobileSegmentScreencastPaths.runtimeRelativePath())
        try MobileSegmentScreencastJSONStore.write(runtime, to: runtimeURL)

        let diagnostic = ScreencastFixtures.diagnostic(sessionID: sessionID, reason: .storageLow, segmentID: segmentID)
        let diagURL = MobileSegmentScreencastPaths.url(root: self.tempDirectory, relativePath: MobileSegmentScreencastPaths.screenDiagnosticRelativePath(segmentID: segmentID))
        try MobileSegmentScreencastJSONStore.write(diagnostic, to: diagURL)

        await manager.reconcileScreencast(reason: .foreground)

        // StorageLow maps to .needsAttention or keeps active, NOT .off with systemEnded marker
        XCTAssertNotEqual(manager.state, .off)
        XCTAssertNil(manager.systemEndedAt)
    }

    func testNeverConcludedUndecodableLivenessInCandidateDir() async throws {
        let sessionID = UUID()
        let segmentID = UUID()
        let engine = FakeScreencastEngine(sources: [.screencast])
        let uploader = FakeScreencastUploader()
        let manager = ScreencastManager(
            engine: engine,
            uploader: uploader,
            clock: self.clock,
            defaults: self.defaults,
            rootURLProvider: { self.tempDirectory },
            darwin: StubScreencastDarwin()
        )
        manager.state = .active(sessionID: sessionID, segmentID: segmentID, startedAt: self.clock.now())

        self.clock.advance(by: 15)
        let segDir = self.tempDirectory
            .appendingPathComponent("MobileSegment", isDirectory: true)
            .appendingPathComponent("active", isDirectory: true)
            .appendingPathComponent(segmentID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: segDir, withIntermediateDirectories: true)
        let liveURL = segDir.appendingPathComponent(MobileSegmentScreencastPaths.screenLivenessFilename, isDirectory: false)
        try "corrupt liveness".write(to: liveURL, atomically: true, encoding: .utf8)

        let runtime = ScreencastFixtures.runtime(
            sessionID: sessionID,
            state: .writerOpen,
            segmentID: segmentID,
            lastSeenAt: self.clock.now().addingTimeInterval(-15)
        )
        let runtimeURL = MobileSegmentScreencastPaths.url(root: self.tempDirectory, relativePath: MobileSegmentScreencastPaths.runtimeRelativePath())
        try MobileSegmentScreencastJSONStore.write(runtime, to: runtimeURL)

        await manager.reconcileScreencast(reason: .foreground)

        if case .active = manager.state {} else {
            XCTFail("Manager should have remained active")
        }
        XCTAssertNil(manager.systemEndedAt)
    }

    func testNeverConcludedFailedDirectoryListing() async throws {
        let sessionID = UUID()
        let segmentID = UUID()
        let engine = FakeScreencastEngine(sources: [.screencast])
        let uploader = FakeScreencastUploader()
        let manager = ScreencastManager(
            engine: engine,
            uploader: uploader,
            clock: self.clock,
            defaults: self.defaults,
            rootURLProvider: { self.tempDirectory },
            darwin: StubScreencastDarwin()
        )
        manager.state = .active(sessionID: sessionID, segmentID: segmentID, startedAt: self.clock.now())

        self.clock.advance(by: 15)
        // Make active a regular file instead of a directory
        let activeURL = self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true).appendingPathComponent("active")
        try? FileManager.default.removeItem(at: activeURL)
        try FileManager.default.createDirectory(at: activeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "regular file".write(to: activeURL, atomically: true, encoding: .utf8)

        let runtime = ScreencastFixtures.runtime(
            sessionID: sessionID,
            state: .writerOpen,
            segmentID: segmentID,
            lastSeenAt: self.clock.now().addingTimeInterval(-15)
        )
        let runtimeURL = MobileSegmentScreencastPaths.url(root: self.tempDirectory, relativePath: MobileSegmentScreencastPaths.runtimeRelativePath())
        try MobileSegmentScreencastJSONStore.write(runtime, to: runtimeURL)

        await manager.reconcileScreencast(reason: .foreground)

        if case .active = manager.state {} else {
            XCTFail("Manager should have remained active")
        }
        XCTAssertNil(manager.systemEndedAt)
    }

    // MARK: - Audio + Past Liveness Tests

    func testAudioAndScreencastPastLivenessRollsCorrectly() async throws {
        let (root, engine, uploader, store, manager) = self.makeRealHarness()
        let sessionID = UUID()

        // Open engine with audio + screencast at T0
        var currentAudioURL: URL?
        engine.rotateAudio = { nextURL in
            if let finalizedURL = currentAudioURL {
                try Data("rotated-audio".utf8).write(to: nextURL, options: .atomic)
                currentAudioURL = nextURL
                return ObserverRecordedChunk(url: finalizedURL, duration: 1)
            }
            try Data("rotated-audio".utf8).write(to: nextURL, options: .atomic)
            currentAudioURL = nextURL
            return nil
        }
        currentAudioURL = try await engine.startAudio(mode: .meeting)
        if let currentAudioURL {
            try Data("audio".utf8).write(to: currentAudioURL, options: .atomic)
        }

        let handoff = try await engine.startScreencast(at: self.clock.now(), sessionID: sessionID)
        let segmentID = handoff.segmentID
        let segmentStartedAt = handoff.startedAt

        // Advance 20s without periodicCheck (do NOT roll 300s window)
        self.clock.advance(by: 20)

        // Plant liveness for this session with lastSeenAt earlier than the open segment's startedAt
        try writeLiveness(
            root: root,
            sessionID: sessionID,
            segmentID: segmentID,
            lastSeenAt: segmentStartedAt.addingTimeInterval(-5)
        )

        // Stale runtime on disk (>= 12s before now)
        let runtime = ScreencastFixtures.runtime(
            sessionID: sessionID,
            state: .writerOpen,
            segmentID: segmentID,
            lastSeenAt: self.clock.now().addingTimeInterval(-15)
        )
        let runtimeURL = MobileSegmentScreencastPaths.url(root: root, relativePath: MobileSegmentScreencastPaths.runtimeRelativePath())
        try MobileSegmentScreencastJSONStore.write(runtime, to: runtimeURL)

        manager.state = .active(sessionID: sessionID, segmentID: segmentID, startedAt: segmentStartedAt)

        await manager.reconcileScreencast(reason: .foreground)

        // After reconcile: closing segment manifest endedAt == clock.now() and >= startedAt
        let pending = try store.list(.pending)
        let closedDir = try XCTUnwrap(pending.first { $0.lastPathComponent == segmentID.uuidString })
        let closedManifest = try store.readManifest(in: closedDir)
        let closedEndedAt = try XCTUnwrap(closedManifest.endedAt)
        XCTAssertEqual(closedEndedAt, self.clock.now())
        XCTAssertGreaterThanOrEqual(closedEndedAt, closedManifest.startedAt)

        // Next active segment (audio remaining) startedAt == clock.now()
        let activeDirs = try store.list(.active)
        XCTAssertEqual(activeDirs.count, 1)
        let activeDir = try XCTUnwrap(activeDirs.first)
        let activeManifest = try store.readManifest(in: activeDir)
        XCTAssertEqual(activeManifest.startedAt, self.clock.now())

        // Engine still has .audio, not .screencast
        XCTAssertTrue(engine.currentScreencastSources.contains(.audio))
        XCTAssertFalse(engine.currentScreencastSources.contains(.screencast))

        // Manager is off with marker
        XCTAssertEqual(manager.state, .off)
        XCTAssertEqual(manager.systemEndedAt, self.clock.now())
    }

    // MARK: - Resurrection Tests

    func testResurrectionAndSecondConclusion() async throws {
        let (root, engine, _, store, manager) = self.makeRealHarness()
        let sessionID = UUID()
        let handoff = try await engine.startScreencast(at: self.clock.now(), sessionID: sessionID)
        let segmentID = handoff.segmentID
        manager.state = .active(sessionID: sessionID, segmentID: segmentID, startedAt: self.clock.now())

        // 1. First conclusion
        self.clock.advance(by: 15)
        let runtimeURL = MobileSegmentScreencastPaths.url(root: root, relativePath: MobileSegmentScreencastPaths.runtimeRelativePath())
        let runtime1 = ScreencastFixtures.runtime(sessionID: sessionID, state: .writerOpen, segmentID: segmentID, lastSeenAt: self.clock.now().addingTimeInterval(-15))
        try MobileSegmentScreencastJSONStore.write(runtime1, to: runtimeURL)

        await manager.reconcileScreencast(reason: .foreground)
        XCTAssertEqual(manager.state, .off)
        XCTAssertNotNil(manager.systemEndedAt)

        // 2. Resurrection via keepLivePart (part + fresh liveness on current segment)
        self.clock.advance(by: 5)
        let segDir = store.segmentDirectoryURL(.active, segmentID: segmentID)
        try FileManager.default.createDirectory(at: segDir, withIntermediateDirectories: true)
        let partURL = MobileSegmentScreencastPaths.screenPartURL(inSegmentDirectory: segDir)
        try writeFragmentedMovie(to: partURL, frames: 3)
        try writeLiveness(root: root, sessionID: sessionID, segmentID: segmentID, lastSeenAt: self.clock.now())

        let runtime2 = ScreencastFixtures.runtime(sessionID: sessionID, state: .writerOpen, segmentID: segmentID, lastSeenAt: self.clock.now())
        try MobileSegmentScreencastJSONStore.write(runtime2, to: runtimeURL)

        await manager.reconcileScreencast(reason: .foreground)

        // Manager is active again and marker was cleared
        if case .active = manager.state {} else {
            XCTFail("Manager should be active after resurrection via keepLivePart")
        }
        XCTAssertNil(manager.systemEndedAt)

        // 3. Second deadness & conclusion
        self.clock.advance(by: 20)
        let runtime3 = ScreencastFixtures.runtime(sessionID: sessionID, state: .writerOpen, segmentID: segmentID, lastSeenAt: self.clock.now().addingTimeInterval(-15))
        try MobileSegmentScreencastJSONStore.write(runtime3, to: runtimeURL)
        try writeLiveness(root: root, sessionID: sessionID, segmentID: segmentID, lastSeenAt: self.clock.now().addingTimeInterval(-15))

        await manager.reconcileScreencast(reason: .foreground)
        XCTAssertEqual(manager.state, .off)
        XCTAssertEqual(manager.systemEndedAt, self.clock.now())
    }

    // MARK: - Starting Keep & notePickerWillOpen Tests

    func testStartingKeepsDeadlineOnDeadRuntime() async throws {
        let (root, _, _, _, manager) = self.makeRealHarness()
        let sessionID = UUID()

        manager.beginStarting()
        XCTAssertNotNil(self.defaults.object(forKey: "screencast.startingDeadline"))

        self.clock.advance(by: 5)
        let runtime = ScreencastFixtures.runtime(
            sessionID: sessionID,
            state: .broadcastStarted,
            segmentID: nil,
            lastSeenAt: self.clock.now().addingTimeInterval(-20)
        )
        let runtimeURL = MobileSegmentScreencastPaths.url(root: root, relativePath: MobileSegmentScreencastPaths.runtimeRelativePath())
        try MobileSegmentScreencastJSONStore.write(runtime, to: runtimeURL)

        await manager.reconcileScreencast(reason: .foreground)

        if case .starting = manager.state {} else {
            XCTFail("State should remain .starting")
        }
        XCTAssertNil(manager.systemEndedAt)
        XCTAssertNotNil(self.defaults.object(forKey: "screencast.startingDeadline"))
    }

    func testNotePickerWillOpenNoOpWhileActive() {
        let (_, _, _, _, manager) = self.makeRealHarness()
        manager.state = .active(sessionID: UUID(), segmentID: UUID(), startedAt: self.clock.now())

        manager.notePickerWillOpen()

        if case .active = manager.state {} else {
            XCTFail("State should remain .active")
        }
        XCTAssertNil(self.defaults.object(forKey: "screencast.startingDeadline"))

        // When .off, notePickerWillOpen begins starting
        manager.state = .off
        manager.notePickerWillOpen()
        if case .starting = manager.state {} else {
            XCTFail("State should be .starting")
        }
        XCTAssertNotNil(self.defaults.object(forKey: "screencast.startingDeadline"))
    }

    // MARK: - Watchdog Lifecycle & Scanner Seam Tests

    func testWatchdogLifecycleWithMockClock() async throws {
        let callLog = ScreencastCallLog()
        let engine = FakeScreencastEngine(sources: [.screencast], callLog: callLog)
        let uploader = FakeScreencastUploader(callLog: callLog)
        let sessionID = UUID()

        var scanCount = 0
        var returnDeadScan = false

        let manager = ScreencastManager(
            engine: engine,
            uploader: uploader,
            clock: self.clock,
            defaults: self.defaults,
            rootURLProvider: { self.tempDirectory },
            darwin: StubScreencastDarwin(),
            sessionLivenessScanner: { _, _, _, _ in
                scanCount += 1
                if returnDeadScan {
                    return .observed(newestLastSeenAt: nil, hasSessionUndecodableLiveness: false, hasFreshLiveness: false)
                } else {
                    return .observed(newestLastSeenAt: Date(), hasSessionUndecodableLiveness: false, hasFreshLiveness: true)
                }
            }
        )

        manager.state = .active(sessionID: sessionID, segmentID: UUID(), startedAt: self.clock.now())
        manager.receiveScenePhase(.active)

        // Stale runtime on disk
        let runtime = ScreencastFixtures.runtime(
            sessionID: sessionID,
            state: .writerOpen,
            segmentID: UUID(),
            lastSeenAt: self.clock.now().addingTimeInterval(-15)
        )
        let runtimeURL = MobileSegmentScreencastPaths.url(root: self.tempDirectory, relativePath: MobileSegmentScreencastPaths.runtimeRelativePath())
        try MobileSegmentScreencastJSONStore.write(runtime, to: runtimeURL)

        // N=3 live scans
        for i in 1...3 {
            await self.drainUntil { self.clock.pendingSleeperCount == 1 }
            self.clock.advance(by: 10)
            await Task.yield()
            XCTAssertEqual(scanCount, i)
        }

        XCTAssertEqual(scanCount, 3)
        let reconcilesBefore = uploader.callLog.entries.filter { $0 == "reconcileActiveSegments" }.count
        XCTAssertEqual(reconcilesBefore, 0)

        // Rollover handoff published several times
        _ = manager.publishRolloverHandoff(ScreencastFixtures.handoff(sessionID: sessionID))
        _ = manager.publishRolloverHandoff(ScreencastFixtures.handoff(sessionID: sessionID))

        await self.drainUntil { self.clock.pendingSleeperCount == 1 }
        self.clock.advance(by: 10)
        await Task.yield()
        XCTAssertEqual(scanCount, 4)
        XCTAssertEqual(uploader.callLog.entries.filter { $0 == "reconcileActiveSegments" }.count, 0)

        // Flip scanner to dead -> exactly one reconcileActiveSegments and manager .off with marker
        returnDeadScan = true
        await self.drainUntil { self.clock.pendingSleeperCount == 1 }
        self.clock.advance(by: 10)
        await Task.yield()

        XCTAssertEqual(uploader.callLog.entries.filter { $0 == "reconcileActiveSegments" }.count, 1)
        XCTAssertEqual(manager.state, .off)
        XCTAssertEqual(manager.systemEndedAt, self.clock.now())

        // Inactive phase cancels further scans
        manager.receiveScenePhase(.inactive)
        let scanCountAtInactive = scanCount
        self.clock.advance(by: 30)
        await Task.yield()
        XCTAssertEqual(scanCount, scanCountAtInactive)
    }

    // MARK: - Marker Persistence & Lifecycle Tests

    func testSystemEndedMarkerPersistsAcrossManagerInstances() {
        let (root, engine, uploader, _, manager1) = self.makeRealHarness()
        let now = self.clock.now()

        // Set marker in manager1
        self.defaults.set(now, forKey: "screencast.systemEndedAt")
        XCTAssertEqual(manager1.systemEndedAt, now)

        // Create manager2 on same suite
        let manager2 = ScreencastManager(
            engine: engine,
            uploader: uploader,
            clock: self.clock,
            defaults: self.defaults,
            rootURLProvider: { root },
            darwin: StubScreencastDarwin()
        )
        XCTAssertEqual(manager2.systemEndedAt, now)

        // beginStarting clears marker
        manager2.beginStarting()
        XCTAssertNil(manager2.systemEndedAt)
        XCTAssertNil(self.defaults.object(forKey: "screencast.systemEndedAt"))
    }

    func testOwnerFinalizedStopDoesNotSetMarker() async throws {
        let sessionID = UUID()
        let segmentID = UUID()
        let engine = FakeScreencastEngine(sources: [.screencast])
        let uploader = FakeScreencastUploader()
        let manager = ScreencastManager(
            engine: engine,
            uploader: uploader,
            clock: self.clock,
            defaults: self.defaults,
            rootURLProvider: { self.tempDirectory },
            darwin: StubScreencastDarwin()
        )
        manager.state = .active(sessionID: sessionID, segmentID: segmentID, startedAt: self.clock.now())

        // Write dummy screen.mp4 via MobileSegmentScreencastPaths
        let finalMovieURL = MobileSegmentScreencastPaths.url(
            root: self.tempDirectory,
            relativePath: MobileSegmentScreencastPaths.screenRelativePath(segmentID: segmentID)
        )
        try FileManager.default.createDirectory(at: finalMovieURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("dummy-screen".utf8).write(to: finalMovieURL, options: .atomic)

        // Normal owner finalized stop
        self.clock.advance(by: 10)
        let runtime = ScreencastFixtures.runtime(
            sessionID: sessionID,
            state: .finalized,
            segmentID: segmentID,
            lastSeenAt: self.clock.now()
        )
        let runtimeURL = MobileSegmentScreencastPaths.url(root: self.tempDirectory, relativePath: MobileSegmentScreencastPaths.runtimeRelativePath())
        try MobileSegmentScreencastJSONStore.write(runtime, to: runtimeURL)

        await manager.reconcileScreencast(reason: .darwinNotification)

        XCTAssertEqual(manager.state, .off)
        XCTAssertNil(manager.systemEndedAt)

        // Full sequence:
        // 1. Conclude dead session -> marker set
        engine.currentScreencastSources = [.screencast]
        manager.state = .active(sessionID: sessionID, segmentID: segmentID, startedAt: self.clock.now())
        self.clock.advance(by: 15)
        let deadRuntime = ScreencastFixtures.runtime(
            sessionID: sessionID,
            state: .writerOpen,
            segmentID: segmentID,
            lastSeenAt: self.clock.now().addingTimeInterval(-15)
        )
        try MobileSegmentScreencastJSONStore.write(deadRuntime, to: runtimeURL)
        await manager.reconcileScreencast(reason: .foreground)
        XCTAssertEqual(manager.state, .off)
        XCTAssertNotNil(manager.systemEndedAt)

        // 2. Young live runtime -> startBoundary -> .active, marker cleared
        let newSessionID = UUID()
        let newSegmentID = UUID()
        engine.nextHandoff = ScreencastFixtures.handoff(sessionID: newSessionID, segmentID: newSegmentID)
        let liveRuntime = ScreencastFixtures.runtime(
            sessionID: newSessionID,
            state: .broadcastStarted,
            segmentID: nil,
            lastSeenAt: self.clock.now().addingTimeInterval(5)
        )
        try MobileSegmentScreencastJSONStore.write(liveRuntime, to: runtimeURL)
        await manager.reconcileScreencast(reason: .foreground)
        if case .active(let sid, let segID, _) = manager.state {
            XCTAssertEqual(sid, newSessionID)
            XCTAssertEqual(segID, newSegmentID)
        } else {
            XCTFail("Manager should be active after young runtime")
        }
        XCTAssertNil(manager.systemEndedAt)

        // 3. Finalized + screen file -> off, marker nil
        let newFinalURL = MobileSegmentScreencastPaths.url(
            root: self.tempDirectory,
            relativePath: MobileSegmentScreencastPaths.screenRelativePath(segmentID: newSegmentID)
        )
        try FileManager.default.createDirectory(at: newFinalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("dummy-screen-2".utf8).write(to: newFinalURL, options: .atomic)

        let finalRuntime2 = ScreencastFixtures.runtime(
            sessionID: newSessionID,
            state: .finalized,
            segmentID: newSegmentID,
            lastSeenAt: self.clock.now()
        )
        try MobileSegmentScreencastJSONStore.write(finalRuntime2, to: runtimeURL)
        await manager.reconcileScreencast(reason: .foreground)
        XCTAssertEqual(manager.state, .off)
        XCTAssertNil(manager.systemEndedAt)
    }

    func testAttentionPreservedAtConclusionWithoutMarker() async throws {
        let (root, engine, _, _, manager) = self.makeRealHarness()
        let sessionID = UUID()

        // Start screencast so engine holds .screencast
        _ = try await engine.startScreencast(at: self.clock.now(), sessionID: sessionID)
        XCTAssertTrue(engine.currentScreencastSources.contains(.screencast))

        manager.state = .needsAttention(.finalizeFailed)

        self.clock.advance(by: 15)
        let runtime = ScreencastFixtures.runtime(
            sessionID: sessionID,
            state: .writerOpen,
            segmentID: nil,
            lastSeenAt: self.clock.now().addingTimeInterval(-15)
        )
        let runtimeURL = MobileSegmentScreencastPaths.url(root: root, relativePath: MobileSegmentScreencastPaths.runtimeRelativePath())
        try MobileSegmentScreencastJSONStore.write(runtime, to: runtimeURL)

        await manager.reconcileScreencast(reason: .foreground)

        XCTAssertEqual(manager.state, .needsAttention(.finalizeFailed))
        XCTAssertNil(manager.systemEndedAt)
        XCTAssertFalse(engine.currentScreencastSources.contains(.screencast))
    }

    func testDoubleStopIsNoOp() async throws {
        let (_, engine, _, _, _) = self.makeRealHarness()
        let now = self.clock.now()

        try await engine.stopScreencast(at: now)
        XCTAssertFalse(engine.currentScreencastSources.contains(.screencast))

        // Second stop does not throw or invert state
        try await engine.stopScreencast(at: now)
        XCTAssertFalse(engine.currentScreencastSources.contains(.screencast))
    }
}
