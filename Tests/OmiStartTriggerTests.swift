// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AVFoundation
import Foundation
import XCTest

nonisolated final class OmiStartTriggerTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmiStartTriggerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    @MainActor
    func testFailedWriterStartDoesNotChurnThenResetsOnTransition() async throws {
        let clock = MockObserverClock()
        let failingUploader = try self.makeFailingUploader()
        let failingWriter = OmiSegmentWriter(
            transferEnqueuer: failingUploader.transferEnqueuer,
            cacheRootURL: failingUploader.cacheRootURL,
            clock: clock
        )
        let defaultsName = "OmiStartTriggerTests-Omi-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let diagnosticsURL = self.tempDirectory.appendingPathComponent("omi-diagnostics.json", isDirectory: false)
        let manager = OmiSourceManager(
            defaults: defaults,
            diagnostics: OmiDiagnostics(clock: MockObserverClock(), fileURL: diagnosticsURL),
            clock: MockObserverClock()
        )
        manager.omiSegmentWriter = failingWriter
        await manager.openLaunchReadiness()

        for _ in 0..<5 {
            manager.startSegmentWriterIfNeeded()
        }

        XCTAssertFalse(failingWriter.isRunning)
        XCTAssertTrue(manager.didAttemptWriterStart)
        XCTAssertEqual(failingUploader.pendingCount, 0)

        manager.disable()
        XCTAssertFalse(manager.didAttemptWriterStart)

        manager.startSegmentWriterIfNeeded()
        XCTAssertTrue(manager.didAttemptWriterStart)
        XCTAssertFalse(failingWriter.isRunning)
        XCTAssertEqual(failingUploader.pendingCount, 0)
    }
}

@MainActor
private extension OmiStartTriggerTests {
    struct FailingUploader {
        let transferEnqueuer: ObserverAudioTransferEnqueuer
        let cacheRootURL: URL

        var pendingCount: Int { 0 }
    }

    func makeFailingUploader() throws -> FailingUploader {
        let cacheRootFile = self.tempDirectory.appendingPathComponent("cache-root-file", isDirectory: false)
        try Data([0]).write(to: cacheRootFile)
        let harness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        )
        return FailingUploader(
            transferEnqueuer: harness.enqueuer,
            cacheRootURL: cacheRootFile
        )
    }
}
