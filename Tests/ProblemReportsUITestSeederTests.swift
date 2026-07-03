// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

#if DEBUG
nonisolated final class ProblemReportsUITestSeederTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProblemReportsUITestSeederTests-\(UUID().uuidString)", isDirectory: true)
        UserSettings.problemReportsEnabled = false
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        UserSettings.problemReportsEnabled = false
        self.tempDirectory = nil
        super.tearDown()
    }

    @MainActor
    func testSeederNoOpsWithoutUITestFlag() {
        ProblemReportsUITestSeeder.runIfRequested(
            arguments: ["--ui-test-seed-problem-reports=populated-list"],
            rootURL: self.tempDirectory
        )

        XCTAssertFalse(UserSettings.problemReportsEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.tempDirectory.path))
    }

    @MainActor
    func testOptedOutAndOptedInEmptyStates() {
        ProblemReportsUITestSeeder.runIfRequested(
            arguments: ["--ui-test", "--ui-test-seed-problem-reports=opted-out"],
            rootURL: self.tempDirectory
        )
        XCTAssertFalse(UserSettings.problemReportsEnabled)
        XCTAssertEqual(self.reports().count, 0)

        ProblemReportsUITestSeeder.runIfRequested(
            arguments: ["--ui-test", "--ui-test-seed-problem-reports=opted-in-empty"],
            rootURL: self.tempDirectory
        )
        XCTAssertTrue(UserSettings.problemReportsEnabled)
        XCTAssertEqual(self.reports().count, 0)
    }

    @MainActor
    func testPopulatedAndDetailSeedsWriteExpectedReports() {
        ProblemReportsUITestSeeder.runIfRequested(
            arguments: ["--ui-test", "--ui-test-seed-problem-reports=populated-list"],
            rootURL: self.tempDirectory
        )
        XCTAssertTrue(UserSettings.problemReportsEnabled)
        XCTAssertEqual(Set(self.reports().map(\.kind)), [.crash, .appExit, .unknown("futureThermalDiagnostics")])

        ProblemReportsUITestSeeder.runIfRequested(
            arguments: ["--ui-test", "--ui-test-seed-problem-reports=detail"],
            rootURL: self.tempDirectory
        )
        let reports = self.reports()
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].id, ProblemReportsUITestSeeder.detailReportID)
        XCTAssertEqual(reports[0].kind, .crash)
    }

    @MainActor
    func testResetRemovesFilesAndDisablesFlag() {
        ProblemReportsUITestSeeder.runIfRequested(
            arguments: ["--ui-test", "--ui-test-seed-problem-reports=populated-list"],
            rootURL: self.tempDirectory
        )
        XCTAssertEqual(self.reports().count, 3)

        ProblemReportsUITestSeeder.runIfRequested(
            arguments: ["--ui-test", "--ui-test-reset-problem-reports"],
            rootURL: self.tempDirectory
        )
        XCTAssertFalse(UserSettings.problemReportsEnabled)
        XCTAssertEqual(self.reports().count, 0)
    }

    @MainActor
    private func reports() -> [ProblemReport] {
        ProblemReportStore(rootURL: self.tempDirectory).all()
    }
}
#endif
