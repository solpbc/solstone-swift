// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class IngestPrefixMigrationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        self.suiteName = "IngestPrefixMigrationTests.\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: self.suiteName)
        self.defaults.removePersistentDomain(forName: self.suiteName)
    }

    override func tearDown() {
        self.defaults.removePersistentDomain(forName: self.suiteName)
        self.defaults = nil
        self.suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testLegacyValueMigratesAndSecondRunIsIdempotent() {
        let store = IngestPrefixStore(defaults: self.defaults)
        var legacyObserver: String? = "legacy-observer"
        var deleteCount = 0
        let streams: [SolstoneSwiftApp.LegacyIngestPrefixStream] = [
            (.observer, "observer",
             { legacyObserver },
             {
                 deleteCount += 1
                 legacyObserver = nil
             }),
        ]

        SolstoneSwiftApp.migrateLegacyIngestPrefixes(store: store, streams: streams)

        XCTAssertEqual(store.load(.observer), "legacy-observer")
        XCTAssertNil(legacyObserver)
        XCTAssertEqual(deleteCount, 1)

        SolstoneSwiftApp.migrateLegacyIngestPrefixes(store: store, streams: streams)

        XCTAssertEqual(store.load(.observer), "legacy-observer")
        XCTAssertNil(legacyObserver)
        XCTAssertEqual(deleteCount, 1)
    }

    @MainActor
    func testConflictKeepsDefaultsAndStillAttemptsDelete() {
        let store = IngestPrefixStore(defaults: self.defaults)
        store.save("prefix-a", for: .observer)
        var legacyObserver: String? = "prefix-b"
        var deleteInvoked = false
        let streams: [SolstoneSwiftApp.LegacyIngestPrefixStream] = [
            (.observer, "observer",
             { legacyObserver },
             {
                 deleteInvoked = true
                 legacyObserver = nil
             }),
        ]

        SolstoneSwiftApp.migrateLegacyIngestPrefixes(store: store, streams: streams)

        XCTAssertEqual(store.load(.observer), "prefix-a")
        XCTAssertNil(legacyObserver)
        XCTAssertTrue(deleteInvoked)
    }

    @MainActor
    func testFailedLegacyDeleteLeavesDefaultsAndRetriesLater() {
        let store = IngestPrefixStore(defaults: self.defaults)
        var legacyObserver: String? = "legacy-observer"
        var deleteCount = 0
        let streams: [SolstoneSwiftApp.LegacyIngestPrefixStream] = [
            (.observer, "observer",
             { legacyObserver },
             {
                 deleteCount += 1
                 throw IngestPrefixMigrationTestError.deleteFailed
             }),
        ]

        SolstoneSwiftApp.migrateLegacyIngestPrefixes(store: store, streams: streams)

        XCTAssertEqual(store.load(.observer), "legacy-observer")
        XCTAssertEqual(legacyObserver, "legacy-observer")
        XCTAssertEqual(deleteCount, 1)

        SolstoneSwiftApp.migrateLegacyIngestPrefixes(store: store, streams: streams)

        XCTAssertEqual(store.load(.observer), "legacy-observer")
        XCTAssertEqual(legacyObserver, "legacy-observer")
        XCTAssertEqual(deleteCount, 2)
    }

    @MainActor
    func testDefaultsUnavailableDoesNotDeleteLegacyValue() {
        let store = IngestPrefixStore(defaults: nil)
        var legacyObserver: String? = "legacy-observer"
        var legacyOmi: String? = "legacy-omi"
        var legacyWatch: String? = "legacy-watch"
        var observerDeleteInvoked = false
        var omiDeleteInvoked = false
        var watchDeleteInvoked = false
        let streams: [SolstoneSwiftApp.LegacyIngestPrefixStream] = [
            (.observer, "observer",
             { legacyObserver },
             {
                 observerDeleteInvoked = true
                 legacyObserver = nil
             }),
            (.omi, "omi",
             { legacyOmi },
             {
                 omiDeleteInvoked = true
                 legacyOmi = nil
             }),
            (.watch, "watch",
             { legacyWatch },
             {
                 watchDeleteInvoked = true
                 legacyWatch = nil
             }),
        ]

        SolstoneSwiftApp.migrateLegacyIngestPrefixes(store: store, streams: streams)

        XCTAssertNil(store.load(.observer))
        XCTAssertNil(store.load(.omi))
        XCTAssertNil(store.load(.watch))
        XCTAssertEqual(legacyObserver, "legacy-observer")
        XCTAssertEqual(legacyOmi, "legacy-omi")
        XCTAssertEqual(legacyWatch, "legacy-watch")
        XCTAssertFalse(observerDeleteInvoked)
        XCTAssertFalse(omiDeleteInvoked)
        XCTAssertFalse(watchDeleteInvoked)
    }

    @MainActor
    func testLegacyLoadFailureDoesNotBlockOtherStreams() {
        let store = IngestPrefixStore(defaults: self.defaults)
        var legacyObserver: String? = "legacy-observer"
        var legacyWatch: String? = "legacy-watch"
        var observerDeleteCount = 0
        var watchDeleteCount = 0
        let streams: [SolstoneSwiftApp.LegacyIngestPrefixStream] = [
            (.observer, "observer",
             { legacyObserver },
             {
                 observerDeleteCount += 1
                 legacyObserver = nil
             }),
            (.omi, "omi",
             { throw IngestPrefixMigrationTestError.loadFailed },
             { XCTFail("omi delete should not run when load fails") }),
            (.watch, "watch",
             { legacyWatch },
             {
                 watchDeleteCount += 1
                 legacyWatch = nil
             }),
        ]

        SolstoneSwiftApp.migrateLegacyIngestPrefixes(store: store, streams: streams)

        XCTAssertEqual(store.load(.observer), "legacy-observer")
        XCTAssertNil(store.load(.omi))
        XCTAssertEqual(store.load(.watch), "legacy-watch")
        XCTAssertNil(legacyObserver)
        XCTAssertNil(legacyWatch)
        XCTAssertEqual(observerDeleteCount, 1)
        XCTAssertEqual(watchDeleteCount, 1)
    }

    @MainActor
    func testLegacyDeleteFailureDoesNotBlockOtherStreams() {
        let store = IngestPrefixStore(defaults: self.defaults)
        var legacyObserver: String? = "legacy-observer"
        var legacyOmi: String? = "legacy-omi"
        var legacyWatch: String? = "legacy-watch"
        var observerDeleteCount = 0
        var omiDeleteCount = 0
        var watchDeleteCount = 0
        let streams: [SolstoneSwiftApp.LegacyIngestPrefixStream] = [
            (.observer, "observer",
             { legacyObserver },
             {
                 observerDeleteCount += 1
                 throw IngestPrefixMigrationTestError.deleteFailed
             }),
            (.omi, "omi",
             { legacyOmi },
             {
                 omiDeleteCount += 1
                 legacyOmi = nil
             }),
            (.watch, "watch",
             { legacyWatch },
             {
                 watchDeleteCount += 1
                 legacyWatch = nil
             }),
        ]

        SolstoneSwiftApp.migrateLegacyIngestPrefixes(store: store, streams: streams)

        XCTAssertEqual(store.load(.observer), "legacy-observer")
        XCTAssertEqual(store.load(.omi), "legacy-omi")
        XCTAssertEqual(store.load(.watch), "legacy-watch")
        XCTAssertEqual(legacyObserver, "legacy-observer")
        XCTAssertNil(legacyOmi)
        XCTAssertNil(legacyWatch)
        XCTAssertEqual(observerDeleteCount, 1)
        XCTAssertEqual(omiDeleteCount, 1)
        XCTAssertEqual(watchDeleteCount, 1)
    }
}

private enum IngestPrefixMigrationTestError: Error {
    case loadFailed
    case deleteFailed
}
