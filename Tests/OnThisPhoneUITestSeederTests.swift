// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if DEBUG
@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class OnThisPhoneUITestSeederTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnThisPhoneUITestSeederTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    @MainActor
    func testLargeBacklogDefaultCountSplitsObserverAndOmi() throws {
        let roots = self.makeRoots(suffix: "default")

        let summary = try OnThisPhoneUITestSeeder.seedLargeBacklog(
            observerRoot: roots.observer,
            omiRoot: roots.omi,
            requestedCount: OnThisPhoneUITestSeeder.largeBacklogCount(arguments: []),
            fileManager: .default
        )

        XCTAssertEqual(summary, .init(observer: 400, omi: 400, total: 800))
        XCTAssertEqual(try self.audioFileCount(in: roots.observer), 400)
        XCTAssertEqual(try self.audioFileCount(in: roots.omi), 400)
    }

    @MainActor
    func testLargeBacklogCountClampsFloorAndCeiling() {
        XCTAssertEqual(OnThisPhoneUITestSeeder.largeBacklogCount(arguments: []), 800)
        XCTAssertEqual(OnThisPhoneUITestSeeder.largeBacklogCount(arguments: ["--ui-test-seed-large-backlog-count=invalid"]), 800)
        XCTAssertEqual(OnThisPhoneUITestSeeder.largeBacklogCount(arguments: ["--ui-test-seed-large-backlog-count=0"]), 1)
        XCTAssertEqual(OnThisPhoneUITestSeeder.largeBacklogCount(arguments: ["--ui-test-seed-large-backlog-count=3000"]), 2_000)
    }

    @MainActor
    func testLargeBacklogSeedIsDeterministic() throws {
        let first = self.makeRoots(suffix: "first")
        let second = self.makeRoots(suffix: "second")

        _ = try OnThisPhoneUITestSeeder.seedLargeBacklog(
            observerRoot: first.observer,
            omiRoot: first.omi,
            requestedCount: 5,
            fileManager: .default
        )
        _ = try OnThisPhoneUITestSeeder.seedLargeBacklog(
            observerRoot: second.observer,
            omiRoot: second.omi,
            requestedCount: 5,
            fileManager: .default
        )

        XCTAssertEqual(try self.collectTree(first.observer), try self.collectTree(second.observer))
        XCTAssertEqual(try self.collectTree(first.omi), try self.collectTree(second.omi))
    }

    @MainActor
    func testResetIncludesOmiRootAndLeavesSiblingOutsideResetRoots() throws {
        let roots = self.makeRoots(suffix: "reset")
        let sibling = self.tempDirectory.appendingPathComponent("sibling", isDirectory: true)

        for root in [roots.observer, roots.omi, roots.location, roots.importQueue, sibling] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("data".utf8).write(to: root.appendingPathComponent("item.dat"))
        }

        try OnThisPhoneUITestSeeder.reset(roots: roots, fileManager: .default)

        XCTAssertFalse(FileManager.default.fileExists(atPath: roots.observer.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: roots.omi.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: roots.location.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: roots.importQueue.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.appendingPathComponent("item.dat").path))
    }

    private func makeRoots(suffix: String) -> OnThisPhoneUITestSeeder.Roots {
        OnThisPhoneUITestSeeder.Roots(
            observer: self.tempDirectory.appendingPathComponent("\(suffix)-observer", isDirectory: true),
            omi: self.tempDirectory.appendingPathComponent("\(suffix)-omi", isDirectory: true),
            location: self.tempDirectory.appendingPathComponent("\(suffix)-location", isDirectory: true),
            importQueue: self.tempDirectory.appendingPathComponent("\(suffix)-import", isDirectory: true)
        )
    }

    private func audioFileCount(in root: URL) throws -> Int {
        try self.fileURLs(in: root).filter { $0.pathExtension == "m4a" }.count
    }

    private func collectTree(_ root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for fileURL in try self.fileURLs(in: root) {
            let relativePath = String(fileURL.path.dropFirst(root.path.count + 1))
            result[relativePath] = try Data(contentsOf: fileURL)
        }
        return result
    }

    private func fileURLs(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }
}
#endif
