// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class ScreencastManagerTests: XCTestCase {
    private var tempDirectory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreencastManagerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        self.suiteName = "ScreencastManagerTests.\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: self.suiteName)
        self.defaults.removePersistentDomain(forName: self.suiteName)
    }

    override func tearDown() {
        self.defaults.removePersistentDomain(forName: self.suiteName)
        self.defaults = nil
        self.suiteName = nil
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    @MainActor
    func testPickerTapOnlyEntersBoundedStarting() {
        let clock = MockObserverClock(now: ScreencastFixtures.start)
        let log = ScreencastCallLog()
        let manager = self.makeManager(clock: clock, callLog: log)

        manager.beginStarting()

        XCTAssertEqual(
            manager.state,
            .starting(startedAt: ScreencastFixtures.start, deadline: ScreencastFixtures.start.addingTimeInterval(20))
        )
        XCTAssertEqual(log.entries, [])
    }

    @MainActor
    func testPickerCancelLeavesNoActiveState() {
        let manager = self.makeManager()

        manager.beginStarting()
        manager.cancelStarting()

        XCTAssertEqual(manager.state, .off)
    }

    @MainActor
    func testAppGroupUnavailableSurfacesUnavailableNoBoundary() async {
        let log = ScreencastCallLog()
        let manager = self.makeManager(
            callLog: log,
            rootURLProvider: { throw AppGroupContainerError.unavailable(identifier: AppGroupContainer.identifier) }
        )

        await manager.reconcileScreencast(reason: .foreground)

        XCTAssertEqual(manager.state, .unavailable(.appGroupUnavailable))
        XCTAssertEqual(log.entries, [])
    }

    @MainActor
    func testStartingTimesOutToOff() async {
        let clock = MockObserverClock(now: ScreencastFixtures.start)
        let log = ScreencastCallLog()
        let manager = self.makeManager(clock: clock, callLog: log)

        manager.beginStarting()
        await self.yieldToMainActor()
        clock.advance(by: 20)
        await self.yieldToMainActor()

        XCTAssertEqual(manager.state, .off)
    }

    @MainActor
    func testForegroundWhileStartingWithoutRuntimeClearsToOff() async {
        let clock = MockObserverClock(now: ScreencastFixtures.start)
        let log = ScreencastCallLog()
        let manager = self.makeManager(clock: clock, callLog: log)

        manager.beginStarting()
        await manager.reconcileScreencast(reason: .foreground)

        XCTAssertEqual(manager.state, .off)
    }

    @MainActor
    func testForegroundWhileStartingWithFailedRuntimeSurfacesFinalizeFailed() async throws {
        let clock = MockObserverClock(now: ScreencastFixtures.start)
        let log = ScreencastCallLog()
        let manager = self.makeManager(clock: clock, callLog: log)

        try self.write(
            ScreencastFixtures.runtime(state: .failed),
            relativePath: MobileSegmentScreencastPaths.runtimeRelativePath()
        )

        manager.beginStarting()
        await manager.reconcileScreencast(reason: .foreground)

        XCTAssertEqual(manager.state, .needsAttention(.finalizeFailed))
    }

    @MainActor
    func testRelaunchWhileStartingWithoutMarkerNoBoundary() {
        self.defaults.set(ScreencastFixtures.start.addingTimeInterval(-1), forKey: "screencast.startingDeadline")
        let clock = MockObserverClock(now: ScreencastFixtures.start)
        let log = ScreencastCallLog()

        let manager = self.makeManager(clock: clock, callLog: log)

        XCTAssertEqual(manager.state, .off)
        XCTAssertEqual(log.entries, [])
    }

    @MainActor
    func testFinalizedScreenRecordsClosingSegmentBeforeStopBoundary() async throws {
        let log = ScreencastCallLog()
        let engine = FakeScreencastEngine(sources: [.audio, .location, .screencast], callLog: log)
        let uploader = FakeScreencastUploader(callLog: log)
        let manager = self.makeManager(engine: engine, uploader: uploader, rootURLProvider: { self.tempDirectory })
        try self.write(ScreencastFixtures.runtime(state: .finalized, segmentID: ScreencastFixtures.segmentID), relativePath: MobileSegmentScreencastPaths.runtimeRelativePath())
        try self.write(ScreencastFixtures.handoff(), relativePath: MobileSegmentScreencastPaths.handoffRelativePath())
        try self.writeScreenFile(segmentID: ScreencastFixtures.segmentID)

        await manager.reconcileScreencast(reason: .darwinNotification)

        XCTAssertEqual(log.entries, ["reconcileActiveSegments", "recordFinalized", "stopBoundary"])
        XCTAssertEqual(engine.currentScreencastSources, [.audio, .location])
        XCTAssertEqual(uploader.finalized, [ScreencastFixtures.segmentID])
        XCTAssertEqual(manager.state, .off)
    }

    @MainActor
    func testFinalizedScreenDurationIsCeilingClampedWithoutChangingStopTime() async throws {
        let log = ScreencastCallLog()
        let endedAt = ScreencastFixtures.start.addingTimeInterval(450)
        let engine = FakeScreencastEngine(sources: [.audio, .location, .screencast], callLog: log)
        let uploader = FakeScreencastUploader(callLog: log)
        let manager = self.makeManager(engine: engine, uploader: uploader, rootURLProvider: { self.tempDirectory })
        try self.write(
            ScreencastFixtures.runtime(state: .finalized, segmentID: ScreencastFixtures.segmentID, lastSeenAt: endedAt),
            relativePath: MobileSegmentScreencastPaths.runtimeRelativePath()
        )
        try self.write(ScreencastFixtures.handoff(), relativePath: MobileSegmentScreencastPaths.handoffRelativePath())
        try self.writeScreenFile(segmentID: ScreencastFixtures.segmentID)

        await manager.reconcileScreencast(reason: .darwinNotification)

        XCTAssertEqual(uploader.finalizedDurationsBySegmentID[ScreencastFixtures.segmentID], 300)
        XCTAssertEqual(engine.stoppedAt, [endedAt])
        XCTAssertEqual(log.entries, ["reconcileActiveSegments", "recordFinalized", "stopBoundary"])
    }

    @MainActor
    func testRolloverHandlerPublishesNewHandoff() async throws {
        let darwin = StubScreencastDarwin()
        let engine = FakeScreencastEngine(
            sources: [.audio, .location, .screencast],
            handoff: ScreencastFixtures.handoff(sourceSet: [.audio, .location, .screencast])
        )
        let manager = self.makeManager(
            engine: engine,
            uploader: FakeScreencastUploader(),
            rootURLProvider: { self.tempDirectory },
            darwin: darwin
        )
        try self.write(ScreencastFixtures.handoff(sourceSet: [.audio, .location, .screencast]), relativePath: MobileSegmentScreencastPaths.handoffRelativePath())

        engine.screencastRolloverHandler?(ScreencastFixtures.handoff(
            revision: 3,
            sourceSet: [.audio, .location, .screencast],
            segmentID: ScreencastFixtures.nextSegmentID
        ))

        let handoff = try self.readHandoff()
        XCTAssertEqual(handoff.segmentID, ScreencastFixtures.nextSegmentID)
        XCTAssertEqual(Set(handoff.sourceSet), [.audio, .location, .screencast])
        XCTAssertGreaterThan(handoff.revision, 1)
        XCTAssertEqual(darwin.postCallCount, 1)
        XCTAssertEqual(self.defaults.bool(forKey: "screencast.enrolled"), true)
        _ = manager
    }

    @MainActor
    func testStartBoundaryWritesEnrolled() async throws {
        let engine = FakeScreencastEngine(
            sources: [.audio, .location],
            handoff: ScreencastFixtures.handoff(sourceSet: [.audio, .location, .screencast])
        )
        let manager = self.makeManager(engine: engine, uploader: FakeScreencastUploader(), rootURLProvider: { self.tempDirectory })
        try self.write(ScreencastFixtures.runtime(state: .broadcastStarted), relativePath: MobileSegmentScreencastPaths.runtimeRelativePath())

        await manager.reconcileScreencast(reason: .darwinNotification)

        XCTAssertEqual(self.defaults.bool(forKey: "screencast.enrolled"), true)
    }

    @MainActor
    func testKeepLivePartWritesEnrolled() async throws {
        let engine = FakeScreencastEngine(sources: [.audio, .location, .screencast])
        let manager = self.makeManager(engine: engine, uploader: FakeScreencastUploader(), rootURLProvider: { self.tempDirectory })
        try self.write(
            ScreencastFixtures.runtime(state: .finishing, segmentID: ScreencastFixtures.segmentID),
            relativePath: MobileSegmentScreencastPaths.runtimeRelativePath()
        )
        try self.write(
            ScreencastFixtures.handoff(sourceSet: [.audio, .location, .screencast], segmentID: ScreencastFixtures.segmentID),
            relativePath: MobileSegmentScreencastPaths.handoffRelativePath()
        )
        try self.writePartFile(segmentID: ScreencastFixtures.segmentID)
        try self.writeLiveness(segmentID: ScreencastFixtures.segmentID, lastSeenAt: ScreencastFixtures.start.addingTimeInterval(5))

        await manager.reconcileScreencast(reason: .darwinNotification)

        XCTAssertEqual(self.defaults.bool(forKey: "screencast.enrolled"), true)
    }

    @MainActor
    func testDarwinObserverReceivesNotification() async {
        let darwin = StubScreencastDarwin()
        let log = ScreencastCallLog()
        let manager = self.makeManager(
            callLog: log,
            rootURLProvider: { self.tempDirectory },
            darwin: darwin
        )

        manager.startObservingDarwin()
        darwin.fire()
        await self.yieldToMainActor()

        XCTAssertEqual(darwin.startCallCount, 1)
        XCTAssertEqual(log.entries, ["reconcileActiveSegments"])
    }

    @MainActor
    func testEnrolledStatePersistsAcrossManagerInstances() {
        let firstManager = self.makeManager(defaults: self.defaults)
        firstManager.beginStarting()
        self.defaults.set(true, forKey: "screencast.enrolled")

        let secondManager = self.makeManager(defaults: self.defaults)

        XCTAssertTrue(secondManager.isEnrolled)
    }

    @MainActor
    func testEnrolledStateIsFalseByDefault() {
        let manager = self.makeManager(defaults: self.defaults)

        XCTAssertFalse(manager.isEnrolled)
    }

    @MainActor
    func testEnrolledDefaultsSuiteIsolation() {
        let customDefaults = self.defaults!
        customDefaults.set(true, forKey: "screencast.enrolled")

        let manager = ScreencastManager(
            engine: FakeScreencastEngine(),
            uploader: FakeScreencastUploader(),
            clock: MockObserverClock(now: ScreencastFixtures.start),
            defaults: customDefaults,
            rootURLProvider: { self.tempDirectory },
            darwin: StubScreencastDarwin()
        )

        _ = manager
        XCTAssertNil(UserDefaults.standard.object(forKey: "screencast.enrolled"))
    }

    @MainActor
    func testMissedTerminalStateClosesRetainedBoundaryBeforeNewRecording() async throws {
        let log = ScreencastCallLog()
        let engine = FakeScreencastEngine(sources: [], callLog: log)
        let uploader = FakeScreencastUploader(callLog: log)
        let manager = self.makeManager(engine: engine, uploader: uploader, rootURLProvider: { self.tempDirectory })

        let session1 = UUID(uuidString: "00000000-0000-0000-0000-000000000111")!
        let segment1 = UUID(uuidString: "00000000-0000-0000-0000-000000000222")!
        try self.write(
            ScreencastFixtures.runtime(sessionID: session1, revision: 1, state: .broadcastStarted, segmentID: nil),
            relativePath: MobileSegmentScreencastPaths.runtimeRelativePath()
        )
        await manager.reconcileScreencast(reason: .darwinNotification)
        XCTAssertEqual(engine.currentScreencastSources, [.screencast])

        try self.write(
            ScreencastFixtures.handoff(sessionID: session1, revision: 2, segmentID: segment1),
            relativePath: MobileSegmentScreencastPaths.handoffRelativePath()
        )

        let session2 = UUID(uuidString: "00000000-0000-0000-0000-000000000333")!
        try self.write(
            ScreencastFixtures.runtime(sessionID: session2, revision: 1, state: .broadcastStarted, segmentID: nil),
            relativePath: MobileSegmentScreencastPaths.runtimeRelativePath()
        )

        await manager.reconcileScreencast(reason: .darwinNotification)

        XCTAssertEqual(engine.currentScreencastSources, [.screencast])
        XCTAssertEqual(log.entries, ["reconcileActiveSegments", "startBoundary", "reconcileActiveSegments", "stopBoundary", "startBoundary"])
        let published = try MobileSegmentScreencastJSONStore.read(
            MobileSegmentScreencastHandoffRecord.self,
            from: MobileSegmentScreencastPaths.url(
                root: self.tempDirectory,
                relativePath: MobileSegmentScreencastPaths.handoffRelativePath()
            )
        )
        XCTAssertEqual(published.sessionID, session2)
    }

    @MainActor
    func testStorageLowAttentionState() async throws {
        let log = ScreencastCallLog()
        let engine = FakeScreencastEngine(sources: [.screencast], callLog: log)
        let uploader = FakeScreencastUploader(callLog: log)
        let manager = self.makeManager(engine: engine, uploader: uploader, rootURLProvider: { self.tempDirectory })

        let diagnostic = ScreencastFixtures.diagnostic(reason: .storageLow, segmentID: ScreencastFixtures.segmentID)
        try self.write(diagnostic, relativePath: MobileSegmentScreencastPaths.screenDiagnosticRelativePath(segmentID: ScreencastFixtures.segmentID))
        try self.write(ScreencastFixtures.runtime(state: .failed, segmentID: ScreencastFixtures.segmentID), relativePath: MobileSegmentScreencastPaths.runtimeRelativePath())
        try self.write(ScreencastFixtures.handoff(), relativePath: MobileSegmentScreencastPaths.handoffRelativePath())

        await manager.reconcileScreencast(reason: .darwinNotification)

        XCTAssertEqual(manager.state, .needsAttention(.storageLow))
    }
}

private extension ScreencastManagerTests {
    @MainActor
    func makeManager(
        engine: FakeScreencastEngine = FakeScreencastEngine(),
        uploader: FakeScreencastUploader = FakeScreencastUploader(),
        clock: any ObserverClock = MockObserverClock(now: ScreencastFixtures.start),
        defaults: UserDefaults? = nil,
        callLog: ScreencastCallLog? = nil,
        rootURLProvider: (() throws -> URL)? = nil,
        darwin: any ScreencastDarwinNotifying = ScreencastDarwinNotificationCenter()
    ) -> ScreencastManager {
        let chosenEngine = callLog.map { FakeScreencastEngine(sources: engine.currentScreencastSources, handoff: engine.nextHandoff, callLog: $0) } ?? engine
        let chosenUploader = callLog.map { FakeScreencastUploader(callLog: $0) } ?? uploader
        return ScreencastManager(
            engine: chosenEngine,
            uploader: chosenUploader,
            clock: clock,
            defaults: defaults ?? self.defaults,
            rootURLProvider: rootURLProvider ?? { self.tempDirectory },
            darwin: darwin
        )
    }

    func write<T: Encodable>(_ value: T, relativePath: String) throws {
        let url = MobileSegmentScreencastPaths.url(root: self.tempDirectory, relativePath: relativePath)
        try MobileSegmentScreencastJSONStore.write(value, to: url)
    }

    func writeScreenFile(segmentID: UUID) throws {
        let url = MobileSegmentScreencastPaths.url(root: self.tempDirectory, relativePath: MobileSegmentScreencastPaths.screenRelativePath(segmentID: segmentID))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("screen".utf8).write(to: url)
    }

    func writePartFile(segmentID: UUID) throws {
        let url = MobileSegmentScreencastPaths.url(root: self.tempDirectory, relativePath: MobileSegmentScreencastPaths.screenPartRelativePath(segmentID: segmentID))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("part".utf8).write(to: url)
    }

    func writeLiveness(segmentID: UUID, lastSeenAt: Date) throws {
        let liveness = MobileSegmentScreencastSegmentLiveness(
            sessionID: ScreencastFixtures.sessionID,
            segmentID: segmentID,
            handoffRevision: 1,
            lastSeenAt: lastSeenAt,
            acceptedFrameCount: 1,
            droppedFrameCount: 0
        )
        try self.write(liveness, relativePath: MobileSegmentScreencastPaths.screenLivenessRelativePath(segmentID: segmentID))
    }

    func readHandoff() throws -> MobileSegmentScreencastHandoffRecord {
        let url = MobileSegmentScreencastPaths.url(
            root: self.tempDirectory,
            relativePath: MobileSegmentScreencastPaths.handoffRelativePath()
        )
        return try MobileSegmentScreencastJSONStore.read(MobileSegmentScreencastHandoffRecord.self, from: url)
    }

    @MainActor
    func yieldToMainActor() async {
        await Task.yield()
        await Task.yield()
    }
}
