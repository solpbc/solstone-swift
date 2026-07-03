// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class ProblemReportShareTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProblemReportShareTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    @MainActor
    func testSingleReportShareEqualsRedactedPersistedBytes() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let store = ProblemReportStore(rootURL: self.tempDirectory, now: { now })
        let raw = #"{"timeStampBegin":"2026-07-02 00:00:00 +0000","timeStampEnd":"2026-07-03 00:00:00 +0000","crashDiagnostics":[{"note":"Authorization: Bearer abc123TOKEN"}]}"#
        store.ingest([ProblemReportPayloadInput(source: .diagnostic, jsonData: Data(raw.utf8), receivedAt: now)])
        let report = try XCTUnwrap(store.all().first)

        let shareURL = try XCTUnwrap(store.exportFileURL(for: report))
        let shareText = try String(contentsOf: shareURL, encoding: .utf8)
        let persisted = try String(
            contentsOf: self.tempDirectory.appendingPathComponent(report.filename, isDirectory: false),
            encoding: .utf8
        )

        XCTAssertEqual(shareURL.lastPathComponent, "solstone-problem-report-\(Self.sanitized(AppVersion.shortVersion))-\(Self.sanitized(AppVersion.build))-2026-05-28.json")
        XCTAssertEqual(shareText, DiagnosticLog.redact(persisted))
        XCTAssertFalse(shareText.contains("abc123TOKEN"))
        XCTAssertTrue(shareText.contains("‹redacted›"))
    }

    @MainActor
    func testShareAllWritesOneRedactedArray() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let store = ProblemReportStore(rootURL: self.tempDirectory, now: { now })
        let rawA = #"{"timeStampBegin":"2026-07-02 00:00:00 +0000","crashDiagnostics":[{"note":"Bearer firstTOKEN"}]}"#
        let rawB = #"{"timeStampBegin":"2026-07-02 00:00:00 +0000","applicationExitMetrics":{"foregroundExitData":{"cumulativeNormalAppExitCount":1}},"note":"secret=hunter2"}"#
        store.ingest([
            ProblemReportPayloadInput(source: .diagnostic, jsonData: Data(rawA.utf8), receivedAt: now),
            ProblemReportPayloadInput(source: .metric, jsonData: Data(rawB.utf8), receivedAt: now.addingTimeInterval(1)),
        ])

        let reports = store.all()
        let shareURL = try XCTUnwrap(store.exportAllFileURL(reports: reports))
        let shareText = try String(contentsOf: shareURL, encoding: .utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([ProblemReport].self, from: Data(shareText.utf8))

        XCTAssertEqual(shareURL.pathExtension, "json")
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded.map(\.kind), [.appExit, .crash])
        XCTAssertFalse(shareText.contains("firstTOKEN"))
        XCTAssertFalse(shareText.contains("hunter2"))
        XCTAssertTrue(shareText.contains("‹redacted›"))
    }
}

private extension ProblemReportShareTests {
    static func sanitized(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return String(value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        })
    }
}
