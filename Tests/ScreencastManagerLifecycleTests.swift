// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class ScreencastManagerLifecycleTests: XCTestCase {
    private var tempDirectory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreencastManagerLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        self.suiteName = "ScreencastManagerLifecycleTests.\(UUID().uuidString)"
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
    func testLaunchForegroundDarwinAndResumeAllCallReconcile() async throws {
        for (index, reason) in [ScreencastReconcileReason.launch, .foreground, .mobileSegmentResume].enumerated() {
            self.defaults.removePersistentDomain(forName: self.suiteName)
            try self.write(
                ScreencastFixtures.runtime(revision: Int64(index + 1)),
                relativePath: MobileSegmentScreencastPaths.runtimeRelativePath()
            )
            let log = ScreencastCallLog()
            let manager = self.makeManager(callLog: log)

            await manager.reconcileScreencast(reason: reason)

            XCTAssertEqual(log.entries, ["startBoundary"], "reason \(reason.rawValue)")
        }

        self.defaults.removePersistentDomain(forName: self.suiteName)
        try self.write(ScreencastFixtures.runtime(revision: 10), relativePath: MobileSegmentScreencastPaths.runtimeRelativePath())
        let log = ScreencastCallLog()
        let darwin = StubScreencastDarwin()
        let manager = self.makeManager(callLog: log, darwin: darwin)
        manager.startObservingDarwin()

        darwin.fire()
        await self.yieldToMainActor()

        XCTAssertEqual(log.entries, ["startBoundary"])
    }
}

private extension ScreencastManagerLifecycleTests {
    @MainActor
    func makeManager(
        callLog: ScreencastCallLog,
        darwin: StubScreencastDarwin = StubScreencastDarwin()
    ) -> ScreencastManager {
        ScreencastManager(
            engine: FakeScreencastEngine(callLog: callLog),
            uploader: FakeScreencastUploader(callLog: callLog),
            clock: MockObserverClock(now: ScreencastFixtures.start),
            defaults: self.defaults,
            rootURLProvider: { self.tempDirectory },
            darwin: darwin
        )
    }

    func write<T: Encodable>(_ value: T, relativePath: String) throws {
        let url = MobileSegmentScreencastPaths.url(root: self.tempDirectory, relativePath: relativePath)
        try MobileSegmentScreencastJSONStore.write(value, to: url)
    }

    @MainActor
    func yieldToMainActor() async {
        await Task.yield()
        await Task.yield()
    }
}
