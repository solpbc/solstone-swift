// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class OnThisPhoneLaunchMagicMomentGuardTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnThisPhoneLaunchMagicMomentGuardTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    func testLaunchPredicateMarksOnlyExistingNonUITestItemsThatHaveNotBeenSeen() {
        XCTAssertTrue(shouldMarkMagicMomentFirstSeenOnLaunch(
            magicMomentFirstSeen: false,
            hasExistingOnThisPhoneItems: true,
            isUITest: false
        ))
        XCTAssertFalse(shouldMarkMagicMomentFirstSeenOnLaunch(
            magicMomentFirstSeen: true,
            hasExistingOnThisPhoneItems: true,
            isUITest: false
        ))
        XCTAssertFalse(shouldMarkMagicMomentFirstSeenOnLaunch(
            magicMomentFirstSeen: false,
            hasExistingOnThisPhoneItems: false,
            isUITest: false
        ))
        XCTAssertFalse(shouldMarkMagicMomentFirstSeenOnLaunch(
            magicMomentFirstSeen: false,
            hasExistingOnThisPhoneItems: true,
            isUITest: true
        ))
    }

    @MainActor
    func testStoreProbeDetectsMobileSegmentDirectories() throws {
        let store = self.makeStore()
        try FileManager.default.createDirectory(
            at: store.segmentDirectoryURL(.pending, segmentID: UUID()),
            withIntermediateDirectories: true
        )

        XCTAssertTrue(OnThisPhoneLaunchMagicMomentStoreProbe.hasExistingOnThisPhoneItems(
            mobileSegmentStore: store,
            appGroupRootURL: self.tempDirectory
        ))
    }

    @MainActor
    func testStoreProbeDetectsShareLedgerEntries() throws {
        let store = self.makeStore()
        let importRoot = self.tempDirectory.appendingPathComponent("ImportQueue", isDirectory: true)
        try FileManager.default.createDirectory(at: importRoot, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: importRoot.appendingPathComponent("ledger.json", isDirectory: false))
        XCTAssertFalse(OnThisPhoneLaunchMagicMomentStoreProbe.hasExistingOnThisPhoneItems(
            mobileSegmentStore: store,
            appGroupRootURL: self.tempDirectory
        ))

        try Data(#"{"share-item":{}}"#.utf8).write(to: importRoot.appendingPathComponent("ledger.json", isDirectory: false))
        XCTAssertTrue(OnThisPhoneLaunchMagicMomentStoreProbe.hasExistingOnThisPhoneItems(
            mobileSegmentStore: store,
            appGroupRootURL: self.tempDirectory
        ))
    }

    @MainActor
    func testStoreProbeDetectsTransferSpoolEntriesWithoutCountingEmptyStateDirectories() throws {
        let store = self.makeStore()
        let transferRoot = self.tempDirectory.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        for directoryName in [
            TransferSpool.stagingDirectoryName,
            TransferSpool.queuedDirectoryName,
            TransferSpool.attentionDirectoryName,
        ] {
            try FileManager.default.createDirectory(
                at: transferRoot.appendingPathComponent(directoryName, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        XCTAssertFalse(OnThisPhoneLaunchMagicMomentStoreProbe.hasExistingOnThisPhoneItems(
            mobileSegmentStore: store,
            appGroupRootURL: self.tempDirectory
        ))

        try FileManager.default.createDirectory(
            at: transferRoot
                .appendingPathComponent(TransferSpool.queuedDirectoryName, isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(OnThisPhoneLaunchMagicMomentStoreProbe.hasExistingOnThisPhoneItems(
            mobileSegmentStore: store,
            appGroupRootURL: self.tempDirectory
        ))
    }

    @MainActor
    private func makeStore() -> MobileSegmentStore {
        MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent(MobileSegmentStore.directoryName, isDirectory: true))
    }
}
