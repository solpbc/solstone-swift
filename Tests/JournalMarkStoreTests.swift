// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

/// The mark is a property of the pairing, not of the connection.
///
/// Founder, 2026-09-01: the mark *"shouldn't wait for a connection, we should know that
/// absolutely on app start and render it from our stored value… it needs to render the first
/// time it syncs but once device is paired it should be an absolute."*
nonisolated final class JournalMarkStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: JournalMarkStore!

    override func setUp() {
        super.setUp()
        self.suiteName = "journal-mark-store-tests-\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: self.suiteName)
        self.store = JournalMarkStore(suiteName: self.suiteName)
    }

    override func tearDown() {
        self.defaults.removePersistentDomain(forName: self.suiteName)
        self.defaults = nil
        self.store = nil
        super.tearDown()
    }

    func testNothingIsStoredBeforeTheFirstSync() {
        XCTAssertNil(self.store.load())
    }

    func testTheMarkSurvivesASaveAndReloadIntact() {
        self.store.save(.uiTestSample)

        let loaded = self.store.load()
        XCTAssertEqual(loaded, JournalMark.uiTestSample)
        // The words are what the owner actually reads, so assert them rather than only
        // trusting `Equatable` over a round trip.
        XCTAssertEqual(loaded?.words, JournalMark.uiTestSample.words)
        XCTAssertEqual(loaded?.icon1.color.hex, JournalMark.uiTestSample.icon1.color.hex)
    }

    /// A second reader gets the mark without anything having connected — this is the whole
    /// point. The shipped bug derived the mark only from a live tunnel and assigned `nil`
    /// when there was none, so every launch showed the generic mark until sync came up.
    func testAFreshStoreOverTheSameDefaultsSeesTheMarkWithNoConnection() {
        self.store.save(.uiTestSample)

        let coldStart = JournalMarkStore(suiteName: self.suiteName)
        XCTAssertEqual(coldStart.load(), JournalMark.uiTestSample)
    }

    func testUnpairingIsWhatClearsIt() {
        self.store.save(.uiTestSample)
        XCTAssertNotNil(self.store.load())

        self.store.clear()
        XCTAssertNil(self.store.load())
    }

    /// A malformed blob resolves to "no mark yet" rather than rendering something broken, and
    /// clears itself so it cannot fail again on every subsequent launch.
    func testAnUnreadableStoredValueIsDiscardedRatherThanRendered() {
        self.defaults.set(Data("not a mark".utf8), forKey: "solstone.journalMark.v1")

        XCTAssertNil(self.store.load())
        XCTAssertNil(self.defaults.data(forKey: "solstone.journalMark.v1"))
    }

    /// A structurally-valid blob that is not a *valid mark* is also refused — `load()` runs the
    /// same validation the network path does, so a schema drift cannot put a broken mark on
    /// screen just because it decoded.
    func testAStoredMarkStillHasToPassMarkValidation() throws {
        let invalid = """
        {"icon1":{"name":"a","color":{"hex":"#zzzzzz"},"rot":0,"svg":"<path d=\\"M0 0\\"/>"},\
        "icon2":{"name":"b","color":{"hex":"#E8913A"},"rot":45,"svg":"<path d=\\"M0 0\\"/>"},\
        "words":["one","two"]}
        """
        self.defaults.set(Data(invalid.utf8), forKey: "solstone.journalMark.v1")

        XCTAssertNil(self.store.load())
    }
}
