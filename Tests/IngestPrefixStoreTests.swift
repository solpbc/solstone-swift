// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class IngestPrefixStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        self.suiteName = "IngestPrefixStoreTests.\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: self.suiteName)
        self.defaults.removePersistentDomain(forName: self.suiteName)
        try self.clearLegacyKeychainPrefixes()
        try self.assertNoLegacyKeychainPrefixes()
    }

    override func tearDownWithError() throws {
        try? self.clearLegacyKeychainPrefixes()
        self.defaults.removePersistentDomain(forName: self.suiteName)
        self.defaults = nil
        self.suiteName = nil
        try super.tearDownWithError()
    }

    func testRoundTripAndStreamIsolation() {
        let store = IngestPrefixStore(defaults: self.defaults)

        store.save("omi-prefix", for: .omi)

        XCTAssertNil(store.load(.observer))
        XCTAssertEqual(store.load(.omi), "omi-prefix")
        XCTAssertNil(store.load(.watch))

        store.save("observer-prefix", for: .observer)
        store.save("watch-prefix", for: .watch)

        XCTAssertEqual(store.load(.observer), "observer-prefix")
        XCTAssertEqual(store.load(.omi), "omi-prefix")
        XCTAssertEqual(store.load(.watch), "watch-prefix")

        store.clear(.observer)
        store.clear(.omi)
        store.clear(.watch)

        XCTAssertNil(store.load(.observer))
        XCTAssertNil(store.load(.omi))
        XCTAssertNil(store.load(.watch))
    }

    func testKeyNamespacing() {
        let store = IngestPrefixStore(defaults: self.defaults)

        store.save("observer-prefix", for: .observer)
        store.save("omi-prefix", for: .omi)
        store.save("watch-prefix", for: .watch)

        XCTAssertEqual(self.defaults.string(forKey: "ingestPrefix.observer"), "observer-prefix")
        XCTAssertEqual(self.defaults.string(forKey: "ingestPrefix.omi"), "omi-prefix")
        XCTAssertEqual(self.defaults.string(forKey: "ingestPrefix.watch"), "watch-prefix")
    }

    func testNilDefaultsNoOp() {
        let store = IngestPrefixStore(defaults: nil)

        store.save("observer-prefix", for: .observer)
        store.save("omi-prefix", for: .omi)
        store.save("watch-prefix", for: .watch)

        XCTAssertNil(store.load(.observer))
        XCTAssertNil(store.load(.omi))
        XCTAssertNil(store.load(.watch))

        store.clear(.observer)
        store.clear(.omi)
        store.clear(.watch)

        XCTAssertNil(store.load(.observer))
        XCTAssertNil(store.load(.omi))
        XCTAssertNil(store.load(.watch))
    }

    func testStoreDoesNotTouchKeychain() throws {
        let store = IngestPrefixStore(defaults: self.defaults)

        XCTAssertNil(try ObserverKeychain.legacyLoadObserverIngestPrefix())
        XCTAssertNil(try ObserverKeychain.legacyLoadOmiIngestPrefix())
        XCTAssertNil(try ObserverKeychain.legacyLoadWatchIngestPrefix())

        store.save("observer-prefix", for: .observer)
        store.save("omi-prefix", for: .omi)
        store.save("watch-prefix", for: .watch)

        XCTAssertEqual(store.load(.observer), "observer-prefix")
        XCTAssertEqual(store.load(.omi), "omi-prefix")
        XCTAssertEqual(store.load(.watch), "watch-prefix")
        try self.assertNoLegacyKeychainPrefixes()

        store.clear(.observer)
        store.clear(.omi)
        store.clear(.watch)

        try self.assertNoLegacyKeychainPrefixes()
    }

    private func clearLegacyKeychainPrefixes() throws {
        try ObserverKeychain.legacyDeleteObserverIngestPrefix()
        try ObserverKeychain.legacyDeleteOmiIngestPrefix()
        try ObserverKeychain.legacyDeleteWatchIngestPrefix()
    }

    private func assertNoLegacyKeychainPrefixes(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertNil(try ObserverKeychain.legacyLoadObserverIngestPrefix(), file: file, line: line)
        XCTAssertNil(try ObserverKeychain.legacyLoadOmiIngestPrefix(), file: file, line: line)
        XCTAssertNil(try ObserverKeychain.legacyLoadWatchIngestPrefix(), file: file, line: line)
    }
}
