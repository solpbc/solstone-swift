// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

/// Picked and dropped items reach the share route's store through real `NSItemProvider`s,
/// so these run the same coordinator and landing the share extension does.
nonisolated final class InAppImportTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InAppImportTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    @MainActor
    func testPickedFilesLandAsOrdinaryShareImports() async throws {
        let queueRoot = self.tempDirectory.appendingPathComponent("queue", isDirectory: true)
        let store = ShareImportStore(cacheRootURL: queueRoot)
        let pdf = try self.makeFile(named: "report.pdf", data: Data("%PDF-1.4 picked".utf8))
        let note = try self.makeFile(named: "note.txt", data: Data("picked from files".utf8))

        let results = await InAppImport.accept(fileURLs: [pdf, note], queue: store)

        XCTAssertEqual(results.count, 2)
        let pdfRow = try self.pendingRow(for: results[0], queueRoot: queueRoot)
        XCTAssertEqual(pdfRow["source"] as? String, "document")
        XCTAssertEqual(pdfRow["filename"] as? String, "report.pdf")
        XCTAssertEqual(pdfRow["target_journal"] as? String, "")
        let noteRow = try self.pendingRow(for: results[1], queueRoot: queueRoot)
        XCTAssertEqual(noteRow["source"] as? String, "quick")
        XCTAssertEqual(store.pendingCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdf.path), "the picked original is never moved")
        XCTAssertEqual(InAppImport.outcomeText(for: results), "saved 2 of 2")
    }

    @MainActor
    func testDroppedImageProviderLandsAsAnImageImport() async throws {
        let queueRoot = self.tempDirectory.appendingPathComponent("queue", isDirectory: true)
        let store = ShareImportStore(cacheRootURL: queueRoot)
        let png = try self.makeFile(named: "drop.png", data: Self.onePixelPNG)
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: png))

        let results = await InAppImport.accept(itemProviders: [provider], queue: store)

        let row = try self.pendingRow(for: try XCTUnwrap(results.first), queueRoot: queueRoot)
        XCTAssertEqual(row["source"] as? String, "image")
        XCTAssertEqual(InAppImport.outcomeText(for: results), "saved")
    }

    @MainActor
    func testUnsupportedFileIsRefusedAndNothingLands() async throws {
        let queueRoot = self.tempDirectory.appendingPathComponent("queue", isDirectory: true)
        let store = ShareImportStore(cacheRootURL: queueRoot)
        let archive = try self.makeFile(named: "bundle.zip", data: Data("PK".utf8))

        let results = await InAppImport.accept(fileURLs: [archive], queue: store)

        XCTAssertEqual(results, [.failure(.unsupported)])
        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertEqual(InAppImport.outcomeText(for: results), ShareImportFailure.unsupported.message)
    }

    func testOutcomeTextUsesTheShareExtensionsWording() {
        let id = UUID()
        XCTAssertNil(InAppImport.outcomeText(for: []))
        XCTAssertNil(InAppImport.outcomeText(for: [.dropped]))
        XCTAssertEqual(InAppImport.outcomeText(for: [.success(id), .failure(.unreadable)]), "1 saved · 1 couldn't")
        XCTAssertEqual(
            InAppImport.outcomeText(for: [.failure(.unsupported), .failure(.unreadable)]),
            "couldn't save 2 items — nothing was added."
        )
    }

    @MainActor
    private func pendingRow(for result: ShareImportResult, queueRoot: URL) throws -> [String: Any] {
        guard case .success(let itemID) = result else {
            XCTFail("expected success, got \(result)")
            return [:]
        }
        let url = queueRoot.appendingPathComponent("pending/\(itemID.uuidString.lowercased())/item.json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeFile(named name: String, data: Data) throws -> URL {
        let url = self.tempDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    )!
}
