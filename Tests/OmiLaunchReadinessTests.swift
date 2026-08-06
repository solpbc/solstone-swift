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
        manager.buildOpusDecoder()
        manager.handleAudioData(Self.audioPacket(0), peripheralID: UUID())
        manager.handleAudioData(Self.audioPacket(1), peripheralID: UUID())
        XCTAssertFalse(writer.isRunning)
        XCTAssertEqual(decodedSampleHandoffs, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.rootURL.path))

        await manager.openLaunchReadiness()
        manager.handleAudioData(Self.audioPacket(2), peripheralID: UUID())
        XCTAssertGreaterThan(decodedSampleHandoffs, 0)
        XCTAssertTrue(writer.isRunning)
        await manager.openLaunchReadiness()
        manager.handleCentralStateUpdate(.poweredOn)
        manager.handleCentralStateUpdate(.poweredOn)
        manager.enable()
        manager.enable()
        XCTAssertTrue(writer.isRunning)
        let sessions = try FileManager.default.contentsOfDirectory(
            at: self.rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        XCTAssertEqual(sessions.count, 1)
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

    private static func audioPacket(_ packetNumber: UInt16) -> Data {
        var data = Data([
            UInt8(packetNumber & 0x00FF),
            UInt8(packetNumber >> 8),
            0,
        ])
        data.append(0xF8)
        return data
    }
}
