// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class LocationAppWiringSmokeTests: XCTestCase {
    private var tempDirectory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocationAppWiringSmokeTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        self.suiteName = "LocationAppWiringSmokeTests.\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: self.suiteName)
        self.defaults.removePersistentDomain(forName: self.suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        self.defaults.removePersistentDomain(forName: self.suiteName)
        self.defaults = nil
        self.suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testLocationManagerConstructibleWithObserverRegistrationBackedUploaderClosures() {
        let uploader = LocationUploader(
            cacheRootURL: self.tempDirectory,
            sessionConfiguration: .ephemeral,
            ensureRegistered: { "test-location-key" },
            localPortProvider: { 7071 },
            startPathMonitor: false
        )
        let manager = LocationManager(
            provider: MockLocationProvider(),
            uploader: uploader,
            clock: MockObserverClock(),
            defaults: self.defaults
        )

        XCTAssertEqual(manager.tier, .balanced)
        XCTAssertEqual(manager.sourceState, .off)
    }

    @MainActor
    func testPendingLocationPauseCommandClearsAndPausesManager() async {
        let provider = MockLocationProvider()
        provider.capability = .always(accuracy: .full)
        let liveActivity = MockLocationLiveActivity()
        let manager = LocationManager(
            provider: provider,
            uploader: RecordingLocationUploader(),
            clock: MockObserverClock(),
            defaults: self.defaults,
            liveActivity: liveActivity
        )
        let pending = PendingLocationCommandState()
        await manager.start(tier: .balanced)

        pending.command = .pauseRequested
        guard pending.command == .pauseRequested else {
            return XCTFail("Expected pending pause command")
        }
        pending.command = nil
        await manager.pause()

        XCTAssertNil(pending.command)
        XCTAssertEqual(manager.sourceState, .paused)
        XCTAssertEqual(liveActivity.endCallCount, 1)
    }
}
