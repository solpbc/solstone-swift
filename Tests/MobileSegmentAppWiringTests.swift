// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class MobileSegmentAppWiringTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileSegmentAppWiringTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    func testOmiWatchShareStorageStaysSeparateFromMobileSegmentEngine() async throws {
        XCTAssertEqual(ObserverAudioTransferSource.mobileSegment, "mobile-segment")
        XCTAssertEqual(ObserverAudioTransferSource.omi, "omi-audio")
        XCTAssertEqual(ObserverAudioTransferSource.watch, "watch-audio")
        XCTAssertEqual(ObserverAudioTransferSource.share, "share")
        XCTAssertEqual(OmiSegmentWriter.cacheDirectoryName, "OmiObserver")
        XCTAssertEqual(WatchTransferSpoolMigrator.legacyCacheDirectoryName, "WatchObserver")
        XCTAssertEqual(ImporterServerURL.savePath, "/app/import/api/save")
        XCTAssertEqual(ImporterServerURL.startPath, "/app/import/api/start")

        XCTAssertEqual(OnThisPhoneAudioSource(sourceType: "omi-audio"), .omi)
        XCTAssertEqual(OnThisPhoneAudioSource(sourceType: "watch-audio"), .watch)

        let watchRoot = self.tempDirectory.appendingPathComponent("WatchObserver", isDirectory: true)

        let mobileTransportRoot = self.tempDirectory.appendingPathComponent("Observer", isDirectory: true)
        let appGroupMobileSegmentRoot = self.tempDirectory
            .appendingPathComponent("AppGroup", isDirectory: true)
            .appendingPathComponent("MobileSegment", isDirectory: true)
        let mobileSegmentStore = MobileSegmentStore(rootURL: appGroupMobileSegmentRoot)
        let mobileSegmentUploader = MobileSegmentUploader(
            store: mobileSegmentStore,
            clock: MockObserverClock()
        )
        let engine = MobileSegmentEngine(uploader: mobileSegmentUploader, clock: MockObserverClock())
        _ = engine

        let omiRoot = self.tempDirectory.appendingPathComponent("OmiObserver", isDirectory: true)
        let importRoot = self.tempDirectory.appendingPathComponent("ImportQueue", isDirectory: true)
        let shareImportStore = ShareImportStore(cacheRootURL: importRoot)
        XCTAssertEqual(mobileSegmentStore.rootURL, appGroupMobileSegmentRoot)
        XCTAssertNotEqual(mobileSegmentStore.rootURL, mobileTransportRoot)
        XCTAssertNotEqual(mobileSegmentStore.rootURL, omiRoot)
        XCTAssertNotEqual(mobileSegmentStore.rootURL, watchRoot)
        XCTAssertNotEqual(mobileSegmentStore.rootURL, importRoot)
        XCTAssertEqual(mobileSegmentUploader.pendingCount, 0)
        XCTAssertEqual(shareImportStore.pendingCount, 0)
    }
}
