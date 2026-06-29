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
    func testMissingExtensionSurfacesUnavailable() {
        let manager = self.makeManager()

        manager.beginStarting()
        manager.markExtensionUnavailable()

        XCTAssertEqual(manager.state, .unavailable(.extensionUnavailable))
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
        XCTAssertEqual(log.entries, [])
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

        XCTAssertEqual(log.entries, ["recordFinalized", "stopBoundary"])
        XCTAssertEqual(engine.currentScreencastSources, [.audio, .location])
        XCTAssertEqual(uploader.finalized, [ScreencastFixtures.segmentID])
        XCTAssertEqual(manager.state, .off)
    }

    @MainActor
    func testManagerPublishesValidLeaseWhileActive() async throws {
        let engine = FakeScreencastEngine(
            handoff: ScreencastFixtures.handoff(sourceSet: [.audio, .location, .screencast])
        )
        let manager = self.makeManager(engine: engine, uploader: FakeScreencastUploader(), rootURLProvider: { self.tempDirectory })
        try self.write(ScreencastFixtures.runtime(), relativePath: MobileSegmentScreencastPaths.runtimeRelativePath())

        await manager.reconcileScreencast(reason: .darwinNotification)

        let lease = try self.readLease(fromSegmentID: ScreencastFixtures.segmentID)
        XCTAssertEqual(lease.fromSegmentID, ScreencastFixtures.segmentID)
        XCTAssertEqual(Set(lease.sourceSet), [.audio, .location, .screencast])
        XCTAssertEqual(engine.preparedLeases.map(\.segmentID), [ScreencastFixtures.nextSegmentID])
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
        _ = manager
    }

    @MainActor
    func testLeaseAdoptionReplayNoOpsWhenClosingFacetIsTerminal() async throws {
        let lease = ScreencastFixtures.lease(sourceSet: [.audio, .location, .screencast])
        let log = ScreencastCallLog()
        let engine = FakeScreencastEngine(sources: [.audio, .location, .screencast], callLog: log)
        let uploader = FakeScreencastUploader(callLog: log)
        uploader.resolutions[lease.fromSegmentID] = MobileSegmentSourceResolution(state: .finalizedArtifact)
        let manager = self.makeManager(engine: engine, uploader: uploader, rootURLProvider: { self.tempDirectory })
        try self.write(
            ScreencastFixtures.runtime(state: .writerOpen, segmentID: lease.segmentID),
            relativePath: MobileSegmentScreencastPaths.runtimeRelativePath()
        )
        try self.write(
            ScreencastFixtures.handoff(sourceSet: lease.sourceSet, segmentID: lease.fromSegmentID),
            relativePath: MobileSegmentScreencastPaths.handoffRelativePath()
        )
        try self.write(
            lease,
            relativePath: MobileSegmentScreencastPaths.continuationLeaseRelativePath(fromSegmentID: lease.fromSegmentID)
        )
        try self.writeScreenFile(segmentID: lease.fromSegmentID)

        await manager.reconcileScreencast(reason: .foreground)

        XCTAssertEqual(log.entries, [])
        XCTAssertTrue(engine.adoptedLeases.isEmpty)
        XCTAssertTrue(uploader.finalized.isEmpty)
    }
}

private extension ScreencastManagerTests {
    @MainActor
    func makeManager(
        clock: MockObserverClock = MockObserverClock(now: ScreencastFixtures.start),
        callLog: ScreencastCallLog = ScreencastCallLog(),
        rootURLProvider: @escaping () throws -> URL,
        darwin: StubScreencastDarwin = StubScreencastDarwin()
    ) -> ScreencastManager {
        self.makeManager(
            engine: FakeScreencastEngine(callLog: callLog),
            uploader: FakeScreencastUploader(callLog: callLog),
            clock: clock,
            rootURLProvider: rootURLProvider,
            darwin: darwin
        )
    }

    @MainActor
    func makeManager(
        clock: MockObserverClock = MockObserverClock(now: ScreencastFixtures.start),
        callLog: ScreencastCallLog = ScreencastCallLog(),
        darwin: StubScreencastDarwin = StubScreencastDarwin()
    ) -> ScreencastManager {
        self.makeManager(
            clock: clock,
            callLog: callLog,
            rootURLProvider: { self.tempDirectory },
            darwin: darwin
        )
    }

    @MainActor
    func makeManager(
        engine: FakeScreencastEngine,
        uploader: FakeScreencastUploader,
        clock: MockObserverClock = MockObserverClock(now: ScreencastFixtures.start),
        rootURLProvider: @escaping () throws -> URL = { FileManager.default.temporaryDirectory },
        darwin: StubScreencastDarwin = StubScreencastDarwin()
    ) -> ScreencastManager {
        ScreencastManager(
            engine: engine,
            uploader: uploader,
            clock: clock,
            defaults: self.defaults,
            rootURLProvider: rootURLProvider,
            darwin: darwin
        )
    }

    func write<T: Encodable>(_ value: T, relativePath: String) throws {
        let url = MobileSegmentScreencastPaths.url(root: self.tempDirectory, relativePath: relativePath)
        try MobileSegmentScreencastJSONStore.write(value, to: url)
    }

    func writeScreenFile(segmentID: UUID) throws {
        let url = MobileSegmentScreencastPaths.url(
            root: self.tempDirectory,
            relativePath: MobileSegmentScreencastPaths.screenRelativePath(segmentID: segmentID)
        )
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("mp4".utf8).write(to: url)
    }

    func readLease(fromSegmentID: UUID) throws -> MobileSegmentScreencastContinuationLease {
        let url = MobileSegmentScreencastPaths.url(
            root: self.tempDirectory,
            relativePath: MobileSegmentScreencastPaths.continuationLeaseRelativePath(fromSegmentID: fromSegmentID)
        )
        return try MobileSegmentScreencastJSONStore.read(MobileSegmentScreencastContinuationLease.self, from: url)
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
