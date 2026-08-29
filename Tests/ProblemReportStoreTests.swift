// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class ProblemReportStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProblemReportStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    @MainActor
    func testIngestPersistsAndLoadsNewestFirst() {
        let store = self.makeStore()
        store.ingest([
            Self.input(Self.crashJSON(), source: .diagnostic, date: Self.date(10)),
            Self.input(Self.appExitJSON(normalCount: 2), source: .metric, date: Self.date(20)),
        ])

        let reports = store.all()
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports.map(\.kind), [.appExit, .crash])
        XCTAssertEqual(reports.first?.rawJSON, Self.appExitJSON(normalCount: 2))
    }

    @MainActor
    func testIngestSkipsDuplicateRawJSONUsingFilenameHash() {
        let store = self.makeStore()
        let input = Self.input(Self.crashJSON(), source: .diagnostic, date: Self.date(10))

        store.ingest([input])
        store.ingest([Self.input(Self.crashJSON(), source: .diagnostic, date: Self.date(20))])

        let reports = store.all()
        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(reports[0].filename.contains("-\(reports[0].contentHash)-"))
    }

    @MainActor
    func testMultipleInputsWriteMultipleFiles() throws {
        let store = self.makeStore()
        store.ingest([
            Self.input(Self.crashJSON(), source: .diagnostic, date: Self.date(10)),
            Self.input(Self.hangJSON(), source: .diagnostic, date: Self.date(11)),
            Self.input(Self.appExitJSON(normalCount: 3), source: .metric, date: Self.date(12)),
        ])

        XCTAssertEqual(store.all().count, 3)
        let filenames = try FileManager.default.contentsOfDirectory(atPath: self.tempDirectory.path)
        XCTAssertEqual(filenames.filter { $0.hasSuffix(".json") }.count, 3)
    }

    @MainActor
    func testDeleteAndDeleteAll() {
        let store = self.makeStore()
        store.ingest([
            Self.input(Self.crashJSON(), source: .diagnostic, date: Self.date(10)),
            Self.input(Self.hangJSON(), source: .diagnostic, date: Self.date(11)),
        ])
        let first = store.all()[0]

        store.delete(id: first.id)
        XCTAssertEqual(store.all().count, 1)

        store.deleteAll()
        XCTAssertEqual(store.all().count, 0)
    }

    @MainActor
    func testReloadSurvivesFreshStoreInstance() {
        let store = self.makeStore()
        store.ingest([Self.input(Self.crashJSON(), source: .diagnostic, date: Self.date(10))])

        let reloaded = self.makeStore()
        XCTAssertEqual(reloaded.all().count, 1)
        XCTAssertEqual(reloaded.all()[0].kind, .crash)
    }

    @MainActor
    func testRotationKeepsMostRecentFifty() {
        let store = self.makeStore()
        let inputs = (0..<55).map { index in
            Self.input(Self.appExitJSON(normalCount: index), source: .metric, date: Self.date(TimeInterval(index)))
        }

        store.ingest(inputs)

        let reports = store.all()
        XCTAssertEqual(reports.count, 50)
        XCTAssertEqual(reports.last?.rawJSON, Self.appExitJSON(normalCount: 5))
        XCTAssertEqual(reports.first?.rawJSON, Self.appExitJSON(normalCount: 54))
    }

    @MainActor
    func testRotationDeletesReportsOlderThanNinetyDays() {
        let now = Self.date(0)
        let store = self.makeStore(now: { now })
        store.ingest([
            Self.input(Self.crashJSON(), source: .diagnostic, date: now.addingTimeInterval(-91 * 24 * 60 * 60)),
            Self.input(Self.hangJSON(), source: .diagnostic, date: now.addingTimeInterval(-10)),
        ])

        let reports = store.all()
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].kind, .hang)
    }

    @MainActor
    func testKindMappingIncludesKnownAndUnknownKinds() {
        let store = self.makeStore()
        store.ingest([
            Self.input(Self.crashJSON(), source: .diagnostic, date: Self.date(10)),
            Self.input(Self.hangJSON(), source: .diagnostic, date: Self.date(11)),
            Self.input(Self.cpuJSON(), source: .diagnostic, date: Self.date(12)),
            Self.input(Self.diskJSON(), source: .diagnostic, date: Self.date(13)),
            Self.input(Self.appLaunchJSON(), source: .diagnostic, date: Self.date(14)),
            Self.input(Self.unknownDiagnosticJSON(), source: .diagnostic, date: Self.date(15)),
            Self.input(Self.appExitJSON(normalCount: 9), source: .metric, date: Self.date(16)),
        ])

        let kinds = Set(store.all().map(\.kind))
        XCTAssertTrue(kinds.contains(.crash))
        XCTAssertTrue(kinds.contains(.hang))
        XCTAssertTrue(kinds.contains(.cpuException))
        XCTAssertTrue(kinds.contains(.diskWriteException))
        XCTAssertTrue(kinds.contains(.appLaunch))
        XCTAssertTrue(kinds.contains(.unknown("futureThermalDiagnostics")))
        XCTAssertTrue(kinds.contains(.appExit))
    }

    @MainActor
    func testMultiKindPayloadPersistsOneReportWithAllKinds() {
        let store = self.makeStore()
        store.ingest([Self.input(Self.multiKindJSON(), source: .diagnostic, date: Self.date(10))])

        let report = try! XCTUnwrap(store.all().first)
        XCTAssertEqual(report.kind, .crash)
        XCTAssertEqual(report.allKinds, [.crash, .hang])
        XCTAssertEqual(store.all().count, 1)
    }

    @MainActor
    func testDecodeFailureLogsKindCountOnly() {
        let log = DiagnosticLog()
        let store = self.makeStore(log: log)
        let body = #"{"token":"abc123TOKEN""#

        store.ingest([Self.input(body, source: .diagnostic, date: Self.date(10))])

        XCTAssertEqual(store.all().count, 0)
        let event = log.events.last
        XCTAssertEqual(event?.category, .diagnostics)
        XCTAssertEqual(event?.message, "problem report could not be read")
        XCTAssertEqual(event?.detail, "kind=unknown count=1 stage=decode")
        XCTAssertFalse(event?.detail?.contains("abc123TOKEN") ?? true)
    }

    @MainActor
    private func makeStore(
        log: DiagnosticLog? = nil,
        now: @escaping @Sendable () -> Date = {
            Date(timeIntervalSince1970: 1_780_086_400)
        }
    ) -> ProblemReportStore {
        ProblemReportStore(rootURL: self.tempDirectory, diagnosticLog: log, now: now)
    }
}

private extension ProblemReportStoreTests {
    static func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_780_000_000 + offset)
    }

    static func input(_ json: String, source: ProblemReportPayloadSource, date: Date) -> ProblemReportPayloadInput {
        ProblemReportPayloadInput(source: source, jsonData: Data(json.utf8), receivedAt: date)
    }

    static func crashJSON() -> String {
        #"{"timeStampBegin":"2026-07-02 00:00:00 +0000","timeStampEnd":"2026-07-03 00:00:00 +0000","crashDiagnostics":[{"version":"0.1.0"}]}"#
    }

    static func hangJSON() -> String {
        #"{"timeStampBegin":"2026-07-02 00:00:00 +0000","timeStampEnd":"2026-07-03 00:00:00 +0000","hangDiagnostics":[{"version":"0.1.0"}]}"#
    }

    static func cpuJSON() -> String {
        #"{"timeStampBegin":"2026-07-02 00:00:00 +0000","timeStampEnd":"2026-07-03 00:00:00 +0000","cpuExceptionDiagnostics":[{"version":"0.1.0"}]}"#
    }

    static func diskJSON() -> String {
        #"{"timeStampBegin":"2026-07-02 00:00:00 +0000","timeStampEnd":"2026-07-03 00:00:00 +0000","diskWriteExceptionDiagnostics":[{"version":"0.1.0"}]}"#
    }

    static func appLaunchJSON() -> String {
        #"{"timeStampBegin":"2026-07-02 00:00:00 +0000","timeStampEnd":"2026-07-03 00:00:00 +0000","appLaunchDiagnostics":[{"version":"0.1.0"}]}"#
    }

    static func unknownDiagnosticJSON() -> String {
        #"{"timeStampBegin":"2026-07-02 00:00:00 +0000","timeStampEnd":"2026-07-03 00:00:00 +0000","futureThermalDiagnostics":[{"version":"0.1.0"}]}"#
    }

    static func multiKindJSON() -> String {
        #"{"timeStampBegin":"2026-07-02 00:00:00 +0000","timeStampEnd":"2026-07-03 00:00:00 +0000","crashDiagnostics":[{"version":"0.1.0"}],"hangDiagnostics":[{"version":"0.1.0"}]}"#
    }

    static func appExitJSON(normalCount: Int) -> String {
        #"{"timeStampBegin":"2026-07-02 00:00:00 +0000","timeStampEnd":"2026-07-03 00:00:00 +0000","appVersion":"0.1.0","applicationExitMetrics":{"foregroundExitData":{"cumulativeNormalAppExitCount":\#(normalCount)},"backgroundExitData":{"cumulativeNormalAppExitCount":0}}}"#
    }
}
