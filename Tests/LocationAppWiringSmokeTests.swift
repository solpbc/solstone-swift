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
    func testLocationManagerConstructibleWithMobileSegmentEngine() {
        let transport = ObserverUploader(
            cacheRootURL: self.tempDirectory.appendingPathComponent("Observer", isDirectory: true),
            sessionConfiguration: .ephemeral,
            ensureRegistered: { "test-observer-key" },
            localPortProvider: { 7071 },
            startPathMonitor: false
        )
        let mobileSegmentUploader = MobileSegmentUploader(
            transport: transport,
            store: MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true)),
            clock: MockObserverClock()
        )
        let manager = LocationManager(
            provider: MockLocationProvider(),
            mobileSegmentEngine: MobileSegmentEngine(uploader: mobileSegmentUploader, clock: MockObserverClock()),
            clock: MockObserverClock(),
            defaults: self.defaults
        )

        XCTAssertEqual(manager.tier, .balanced)
        XCTAssertEqual(manager.sourceState, .off)
    }
}
