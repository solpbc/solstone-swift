// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SPLMark
import SPLTunnel
@testable import solstone_swift
import XCTest

nonisolated final class JournalMarkDerivationTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: JournalMarkStore!

    override func setUp() {
        super.setUp()
        self.suiteName = "journal-mark-derivation-tests-\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: self.suiteName)
        self.store = JournalMarkStore(suiteName: self.suiteName)
    }

    override func tearDown() {
        self.defaults.removePersistentDomain(forName: self.suiteName)
        self.defaults = nil
        self.store = nil
        super.tearDown()
    }

    func testTheMarkIsTheOneFromThePinnedCAAndItCarriesTheSpokenColourNames() async throws {
        let expected = try markFromJournalID(CertChain.journalID(ofCAChainPEM: CertlessTrustFixtures.caPEM))

        let mark = await JournalMarkDerivation.mark(forCAChainPEM: CertlessTrustFixtures.caPEM, store: self.store)

        let derived = try XCTUnwrap(mark)
        XCTAssertEqual(derived.words, expected.words)
        XCTAssertEqual(derived.icon1.svg, expected.icon1.svg)
        XCTAssertEqual(derived.icon1.color.name, expected.icon1.color.name)
        XCTAssertEqual(derived.icon2.color.name, expected.icon2.color.name)
        XCTAssertEqual(derived.icon2.rot, expected.icon2.rot)
        XCTAssertTrue(JournalMarkAccessibility.spokenValue(mark: derived).hasPrefix("\(expected.icon1.color.name), \(expected.icon2.color.name), "))
    }

    func testAStoredPairingsServedCopyIsReplacedByTheMarkFromItsCA() async throws {
        self.defaults.set(try JSONEncoder().encode(JournalMark.uiTestSample), forKey: "solstone.journalMark.v1")

        let mark = await JournalMarkDerivation.mark(forCAChainPEM: CertlessTrustFixtures.caPEM, store: self.store)

        XCTAssertNotNil(mark)
        XCTAssertNotEqual(mark, JournalMark.uiTestSample)
        XCTAssertEqual(self.store.load(), mark)
    }

    func testItDerivesOnceAndKeepsIt() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let derive: @Sendable (String) async throws -> MarkRenderSpec = { journalID in
            calls.withLock { $0 += 1 }
            return try markFromJournalID(journalID)
        }

        let first = await JournalMarkDerivation.mark(forCAChainPEM: CertlessTrustFixtures.caPEM, store: self.store, derive: derive)
        let second = await JournalMarkDerivation.mark(forCAChainPEM: CertlessTrustFixtures.caPEM, store: self.store, derive: derive)

        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    func testAFailedDerivationIsNoMarkAndNothingIsKept() async {
        let mark = await JournalMarkDerivation.mark(
            forCAChainPEM: CertlessTrustFixtures.caPEM,
            store: self.store,
            derive: { _ in throw MarkError.hashFailed(code: -1) }
        )

        XCTAssertNil(mark)
        XCTAssertNil(self.store.load())
        XCTAssertEqual(JournalIdentity.select(isPaired: true, sendConfirmed: true, mark: mark), .unavailable)
    }

    func testAnUnreadableCAIsNoMark() async {
        let mark = await JournalMarkDerivation.mark(forCAChainPEM: "not a certificate", store: self.store)

        XCTAssertNil(mark)
    }
}
