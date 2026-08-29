// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
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
