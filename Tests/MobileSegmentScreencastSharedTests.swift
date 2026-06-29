// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class MobileSegmentScreencastSharedTests: XCTestCase {
    func testRelativePaths() throws {
        let segmentID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let sessionID = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))

        XCTAssertEqual(
            MobileSegmentScreencastPaths.activeSegmentRelativeDirectory(segmentID: segmentID),
            "MobileSegment/active/11111111-1111-1111-1111-111111111111"
        )
        XCTAssertEqual(
            MobileSegmentScreencastPaths.screenRelativePath(segmentID: segmentID),
            "MobileSegment/active/11111111-1111-1111-1111-111111111111/screen.mp4"
        )
        XCTAssertEqual(
            MobileSegmentScreencastPaths.screenPartRelativePath(segmentID: segmentID),
            "MobileSegment/active/11111111-1111-1111-1111-111111111111/screen.mp4.part"
        )
        XCTAssertEqual(
            MobileSegmentScreencastPaths.screenLivenessRelativePath(segmentID: segmentID),
            "MobileSegment/active/11111111-1111-1111-1111-111111111111/screen.live.json"
        )
        XCTAssertEqual(
            MobileSegmentScreencastPaths.screenDiagnosticRelativePath(segmentID: segmentID),
            "MobileSegment/active/11111111-1111-1111-1111-111111111111/screen.failed.json"
        )
        XCTAssertEqual(
            MobileSegmentScreencastPaths.handoffRelativePath(),
            "MobileSegment/screencast/handoff/current.json"
        )
        XCTAssertEqual(
            MobileSegmentScreencastPaths.continuationLeaseRelativePath(fromSegmentID: segmentID),
            "MobileSegment/screencast/leases/11111111-1111-1111-1111-111111111111.json"
        )
        XCTAssertEqual(
            MobileSegmentScreencastPaths.runtimeRelativePath(),
            "MobileSegment/screencast/runtime/current.json"
        )
        XCTAssertEqual(
            MobileSegmentScreencastPaths.runtimeDiagnosticRelativePath(sessionID: sessionID),
            "MobileSegment/screencast/runtime/diagnostics/22222222-2222-2222-2222-222222222222.failed.json"
        )

        let root = URL(fileURLWithPath: "/tmp/app-group", isDirectory: true)
        XCTAssertEqual(
            MobileSegmentScreencastPaths.url(
                root: root,
                relativePath: MobileSegmentScreencastPaths.screenRelativePath(segmentID: segmentID)
            ).path,
            "/tmp/app-group/MobileSegment/active/11111111-1111-1111-1111-111111111111/screen.mp4"
        )
    }

    func testRejectsUnsafeRelativePaths() throws {
        XCTAssertNoThrow(try MobileSegmentScreencastPaths.validateRelativePath("MobileSegment/active/id/screen.mp4"))
        XCTAssertThrowsError(try MobileSegmentScreencastPaths.validateRelativePath(""))
        XCTAssertThrowsError(try MobileSegmentScreencastPaths.validateRelativePath("/MobileSegment/active/id/screen.mp4"))
        XCTAssertThrowsError(try MobileSegmentScreencastPaths.validateRelativePath("MobileSegment//active/id/screen.mp4"))
        XCTAssertThrowsError(try MobileSegmentScreencastPaths.validateRelativePath("MobileSegment/active/../screen.mp4"))
        XCTAssertThrowsError(try MobileSegmentScreencastPaths.validateRelativePath("Other/active/id/screen.mp4"))
    }

    func testHandoffRoundTrip() throws {
        let record = try self.makeHandoff(revision: 7)
        let tempDirectory = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let url = tempDirectory.appendingPathComponent("handoff.json", isDirectory: false)

        try MobileSegmentScreencastJSONStore.write(record, to: url)
        let decoded = try MobileSegmentScreencastJSONStore.read(
            MobileSegmentScreencastHandoffRecord.self,
            from: url
        )

        XCTAssertEqual(decoded, record)
    }

    func testAtomicWriteLeavesNoPartialTarget() throws {
        let tempDirectory = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let url = tempDirectory.appendingPathComponent("handoff/current.json", isDirectory: false)
        let first = try self.makeHandoff(revision: 1)
        let second = try self.makeHandoff(revision: 2)

        try MobileSegmentScreencastJSONStore.write(first, to: url)
        try MobileSegmentScreencastJSONStore.write(second, to: url)

        let decoded = try MobileSegmentScreencastJSONStore.read(
            MobileSegmentScreencastHandoffRecord.self,
            from: url
        )
        XCTAssertEqual(decoded.revision, 2)
        let siblings = try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(siblings.map(\.lastPathComponent), ["current.json"])
    }

    func testAtomicFinalizeNoPartialTarget() throws {
        let tempDirectory = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let partURL = tempDirectory.appendingPathComponent("screen.mp4.part", isDirectory: false)
        let finalURL = tempDirectory.appendingPathComponent("screen.mp4", isDirectory: false)
        try Data("final-video".utf8).write(to: partURL)

        try MobileSegmentScreencastJSONStore.finalizePart(partURL: partURL, finalURL: finalURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: partURL.path))
        XCTAssertEqual(try Data(contentsOf: finalURL), Data("final-video".utf8))
    }

    @MainActor
    func testStoreUsesSharedScreenPathHelper() {
        let root = URL(fileURLWithPath: "/tmp/MobileSegment", isDirectory: true)
        let store = MobileSegmentStore(rootURL: root)
        let segmentID = UUID()
        let directory = store.segmentDirectoryURL(.active, segmentID: segmentID)

        XCTAssertEqual(
            store.screenURL(in: directory),
            MobileSegmentScreencastPaths.screenURL(inSegmentDirectory: directory)
        )
        XCTAssertEqual(
            store.screenPartURL(in: directory),
            MobileSegmentScreencastPaths.screenPartURL(inSegmentDirectory: directory)
        )
    }

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileSegmentScreencastSharedTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeHandoff(revision: Int64) throws -> MobileSegmentScreencastHandoffRecord {
        let segmentID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let sessionID = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let eventID = try XCTUnwrap(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        let now = Date(timeIntervalSince1970: 1_780_480_800)
        return MobileSegmentScreencastHandoffRecord(
            revision: revision,
            eventID: eventID,
            sessionID: sessionID,
            segmentID: segmentID,
            sourceSetVersion: 4,
            sourceSet: [.audio, .screencast],
            startedAt: now,
            segmentDirectoryRelativePath: MobileSegmentScreencastPaths.activeSegmentRelativeDirectory(segmentID: segmentID),
            screenPartRelativePath: MobileSegmentScreencastPaths.screenPartRelativePath(segmentID: segmentID),
            screenFinalRelativePath: MobileSegmentScreencastPaths.screenRelativePath(segmentID: segmentID),
            desiredState: .writing,
            rolloverAfter: now.addingTimeInterval(300),
            lastHostUpdateAt: now
        )
    }
}
