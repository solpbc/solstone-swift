// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

nonisolated final class ProblemReportsManagerTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProblemReportsManagerTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    @MainActor
    func testSetEnabledDrivesSubscriberLifecycleWithoutDuplicates() {
        let mock = MockMetricSubscriber()
        let manager = self.makeManager(mock: mock, initialEnabled: false)

        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(mock.addSubscriberCallCount, 0)

        manager.setEnabled(true)
        XCTAssertTrue(manager.isEnabled)
        XCTAssertEqual(mock.addSubscriberCallCount, 1)

        manager.setEnabled(true)
        XCTAssertEqual(mock.addSubscriberCallCount, 1)

        manager.setEnabled(false)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(mock.removeSubscriberCallCount, 1)

        manager.setEnabled(false)
        XCTAssertEqual(mock.removeSubscriberCallCount, 1)

        manager.setEnabled(true)
        XCTAssertEqual(mock.addSubscriberCallCount, 2)
    }

    @MainActor
    func testMockCanEmitFixtureIntoManager() throws {
        let mock = MockMetricSubscriber()
        let manager = self.makeManagerWithFactory(mock: mock)

        mock.emit([
            ProblemReportPayloadInput(
                source: .diagnostic,
                jsonData: Data(#"{"crashDiagnostics":[{"version":"0.1.0"}]}"#.utf8),
                receivedAt: Date(timeIntervalSince1970: 1_780_000_000)
            )
        ])

        XCTAssertEqual(manager.reports.count, 1)
        let report = try XCTUnwrap(manager.reports.first)
        XCTAssertEqual(report.kind, .crash)
    }

    // MARK: - Phase 1 Startup & Foreground Unblock Tests

    @MainActor
    func testRefreshAsyncRunsOffMainLogsDecodeFailuresAndRespectsGenerationAcrossMutations() async throws {
        let suiteName = "ProblemReportsManagerTests.Async.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let log = DiagnosticLog(defaults: defaults)
        let store = ProblemReportStore(
            rootURL: self.tempDirectory,
            diagnosticLog: log,
            now: { Date(timeIntervalSince1970: 1_780_086_400) }
        )
        store.ingest([
            ProblemReportPayloadInput(
                source: .diagnostic,
                jsonData: Data(#"{"crashDiagnostics":[{"version":"0.1.0"}]}"#.utf8),
                receivedAt: Date(timeIntervalSince1970: 1_780_000_000)
            )
        ])
        try Data("{corrupt".utf8).write(to: self.tempDirectory.appendingPathComponent("corrupt.json"))

        // 1. deferInitialLoad starts empty without touching disk; refreshAsync loads off-main & logs decode failure.
        let ranOffMain = OSAllocatedUnfairLock<Bool>(initialState: false)
        store.testDecodeObserver = { _ in
            ranOffMain.withLock { $0 = !Thread.isMainThread }
        }
        let manager = ProblemReportsManager(
            store: store,
            subscriber: MockMetricSubscriber(),
            initialEnabled: false,
            deferInitialLoad: true
        )
        XCTAssertEqual(manager.reports.count, 0)
        await manager.refreshAsync()
        XCTAssertTrue(ranOffMain.withLock { $0 }, "refreshAsync() must load off @MainActor")
        XCTAssertEqual(manager.reports.count, 1)
        XCTAssertEqual(log.events.count, 1)
        XCTAssertEqual(log.events.first?.detail, "kind=unknown count=1 stage=decode")

        // Clean corrupt file so subsequent mutation tests check generation guards cleanly.
        try FileManager.default.removeItem(at: self.tempDirectory.appendingPathComponent("corrupt.json"))

        // 2. Stale refreshAsync() never overwrites ingest, delete(id:), or deleteAll().
        let firstID = try XCTUnwrap(manager.reports.first?.id)
        for mutation in ["ingest", "delete", "deleteAll"] {
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let armed = OSAllocatedUnfairLock<Bool>(initialState: true)
            store.testDecodeObserver = { _ in
                let shouldBlock = armed.withLock { flag -> Bool in
                    if flag { flag = false; return true }
                    return false
                }
                if shouldBlock {
                    entered.signal()
                    release.wait()
                }
            }
            let staleTask = Task { await manager.refreshAsync() }
            let waited = await TestSemaphore.wait(entered, timeout: .now() + 5)
            XCTAssertEqual(waited, .success)

            let expectedCount: Int
            switch mutation {
            case "ingest":
                manager.ingest([
                    ProblemReportPayloadInput(
                        source: .diagnostic,
                        jsonData: Data(#"{"hangDiagnostics":[{"version":"0.1.0"}]}"#.utf8),
                        receivedAt: Date(timeIntervalSince1970: 1_780_000_050)
                    )
                ])
                expectedCount = 2
            case "delete":
                manager.delete(id: firstID)
                expectedCount = 1
            default:
                manager.deleteAll()
                expectedCount = 0
            }
            XCTAssertEqual(manager.reports.count, expectedCount)
            release.signal()
            await staleTask.value
            XCTAssertEqual(manager.reports.count, expectedCount, "stale refreshAsync() must not overwrite \(mutation)")
        }
    }

    @MainActor
    private func makeManager(mock: MockMetricSubscriber, initialEnabled: Bool) -> ProblemReportsManager {
        let store = ProblemReportStore(
            rootURL: self.tempDirectory,
            now: { Date(timeIntervalSince1970: 1_780_086_400) }
        )
        return ProblemReportsManager(store: store, subscriber: mock, initialEnabled: initialEnabled)
    }

    @MainActor
    private func makeManagerWithFactory(mock: MockMetricSubscriber) -> ProblemReportsManager {
        let store = ProblemReportStore(
            rootURL: self.tempDirectory,
            now: { Date(timeIntervalSince1970: 1_780_086_400) }
        )
        return ProblemReportsManager(store: store, initialEnabled: false) { ingest in
            mock.ingest = ingest
            return mock
        }
    }
}
