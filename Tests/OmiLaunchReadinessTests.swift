// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class OmiLaunchReadinessTests: XCTestCase {
    private var rootURL: URL!
    private var defaultsName: String!

    override func setUp() {
        super.setUp()
        self.rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmiLaunchReadinessTests-\(UUID().uuidString)", isDirectory: true)
        self.defaultsName = "OmiLaunchReadinessTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.rootURL)
        UserDefaults.standard.removePersistentDomain(forName: self.defaultsName)
        self.rootURL = nil
        self.defaultsName = nil
        super.tearDown()
    }

    func testWriterStartWaitsForLaunchReadinessAndIsIdempotent() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: self.defaultsName))
        let harness = makeTransferCutoverHarness(rootURL: self.rootURL.appendingPathComponent("Transfers", isDirectory: true))
        let writer = OmiSegmentWriter(transferEnqueuer: harness.enqueuer, cacheRootURL: self.rootURL)
        let manager = OmiSourceManager(defaults: defaults, clock: MockObserverClock())
        var decodedSampleHandoffs = 0
        manager.onDecodedSamples = { _ in
            decodedSampleHandoffs += 1
        }
        manager.omiSegmentWriter = writer

        manager.enable()
        manager.handleCentralStateUpdate(.poweredOn)
        manager.handleAudioData(Data())
        manager.startSegmentWriterIfNeeded()
        XCTAssertFalse(writer.isRunning)
        XCTAssertEqual(decodedSampleHandoffs, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.rootURL.path))

        await manager.openLaunchReadiness()
        manager.startSegmentWriterIfNeeded()
        XCTAssertTrue(writer.isRunning)
        manager.startSegmentWriterIfNeeded()
        XCTAssertTrue(writer.isRunning)
    }

    func testDisableBeforeOpeningReadinessDoesNotResurrectEnabledIntent() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: self.defaultsName))
        let manager = OmiSourceManager(defaults: defaults, clock: MockObserverClock())

        manager.enable()
        manager.disable()
        await manager.openLaunchReadiness()

        XCTAssertFalse(manager.enabled)
        XCTAssertFalse(defaults.bool(forKey: "omiSource.enabled"))
    }
}
