// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
import XCTest

/// Which key reaches which slot, and that the two marks each read as themselves. The words live
/// in the string catalog and are not pinned here.
nonisolated final class UnknownJournalNoticeTests: XCTestCase {
    private let address = UnknownJournalNotice.Place.address("192.168.4.63:7657")

    func testAPlaceTakesItsAddressFromADirectDialAndNoneFromTheRelay() {
        XCTAssertEqual(
            UnknownJournalNotice.Place(.lanDirect(host: "192.168.4.63", port: 7657)),
            self.address
        )
        XCTAssertEqual(
            UnknownJournalNotice.Place(.lanDirect(host: "fe80::1", port: 7657)),
            .address("[fe80::1]:7657")
        )
        XCTAssertEqual(
            UnknownJournalNotice.Place(.relay(endpoint: URL(string: "wss://relay.example.com")!)),
            .relay
        )
    }

    func testRowAndBodyKeysFollowThePlace() {
        XCTAssertEqual(UnknownJournalCopy.rowKey(self.address), "unknown_journal.row.direct")
        XCTAssertEqual(UnknownJournalCopy.rowKey(.relay), "unknown_journal.row.relay")
        XCTAssertEqual(UnknownJournalCopy.bodyKey(self.address), "unknown_journal.body.direct")
        XCTAssertEqual(UnknownJournalCopy.bodyKey(.relay), "unknown_journal.body.relay")
    }

    func testCaptionFollowsTheClaimNotThePlace() {
        XCTAssertEqual(UnknownJournalCopy.captionKey(.noIdentity), "unknown_journal.caption.no_identity")
        XCTAssertEqual(UnknownJournalCopy.captionKey(.deriving), "unknown_journal.caption.claimed")
        XCTAssertEqual(UnknownJournalCopy.captionKey(.mark(.uiTestSample)), "unknown_journal.caption.claimed")
        XCTAssertNil(UnknownJournalCopy.captionKey(.unavailable))
    }

    // Falsified by a key missing from the catalog, which would show the owner the key itself.
    func testEveryKeyResolvesInTheCatalog() {
        let keys = [
            UnknownJournalCopy.expandKey,
            UnknownJournalCopy.headingKey,
            UnknownJournalCopy.whatAnsweredKey,
            UnknownJournalCopy.yourJournalKey,
            UnknownJournalCopy.noIdentitySpokenKey,
            UnknownJournalCopy.rowKey(self.address),
            UnknownJournalCopy.rowKey(.relay),
            UnknownJournalCopy.bodyKey(self.address),
            UnknownJournalCopy.bodyKey(.relay),
            UnknownJournalCopy.captionKey(.noIdentity)!,
            UnknownJournalCopy.captionKey(.deriving)!,
        ] + UnknownJournalCopy.notPresentedWordKeys
        for key in keys {
            XCTAssertNotEqual(UnknownJournalCopy.localized(key), key, key)
        }
    }

    // Falsified by a slot left unfilled in a string the owner reads.
    func testTheAddressFillsItsSlotAndTheRelayStringsHaveNone() {
        for key in [UnknownJournalCopy.rowKey(self.address), UnknownJournalCopy.bodyKey(self.address)] {
            let text = UnknownJournalCopy.localized(key, place: self.address)
            XCTAssertTrue(text.contains("192.168.4.63:7657"), key)
            XCTAssertFalse(text.contains("{"), key)
        }
        for key in [UnknownJournalCopy.rowKey(.relay), UnknownJournalCopy.bodyKey(.relay)] {
            XCTAssertFalse(UnknownJournalCopy.localized(key, place: .relay).contains("{"), key)
        }
    }

    // Falsified by VoiceOver reading the no-identity slot as a mark, or a claimed mark without
    // saying it is only a claim.
    func testTheWhatAnsweredSlotSpeaksItsNameAndClaim() {
        XCTAssertEqual(
            UnknownJournalCopy.whatAnsweredSpokenValue(.noIdentity),
            UnknownJournalCopy.localized(UnknownJournalCopy.noIdentitySpokenKey)
        )
        let spoken = UnknownJournalCopy.whatAnsweredSpokenValue(.mark(.uiTestSample))
        XCTAssertTrue(spoken.contains(JournalMarkAccessibility.spokenValue(mark: .uiTestSample)))
        XCTAssertTrue(spoken.contains(UnknownJournalCopy.localized(UnknownJournalCopy.captionKey(.mark(.uiTestSample))!)))
        // A mark that couldn't be drawn is the peer's, so it doesn't speak as the owner's journal.
        XCTAssertFalse(UnknownJournalCopy.whatAnsweredSpokenValue(.unavailable).contains("your journal"))
    }

    // Falsified by routing a claim through the pairing's mark store: it would replace the owner's
    // own journal's mark, and outlive the restart that is meant to clear it.
    func testAClaimedMarkIsDerivedOnTheDeviceAndNeverKept() async throws {
        let suite = "unknown-journal-\(UUID().uuidString)"
        let store = JournalMarkStore(suiteName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let first = await JournalMarkDerivation.mark(forClaimedJournalID: "0190f3a2-7c4e-7d21-9b3f-5e8a1c2d4f60")
        let second = await JournalMarkDerivation.mark(forClaimedJournalID: "0190f3a2-7c4e-7d21-9b3f-5e8a1c2d4f61")

        XCTAssertNotNil(try XCTUnwrap(first).words.first)
        XCTAssertNotEqual(first, second)
        XCTAssertNil(store.load())
    }

    func testAJournalIDThatCannotBeDrawnHasNoMark() async {
        let mark = await JournalMarkDerivation.mark(forClaimedJournalID: "not-a-journal-id")
        XCTAssertNil(mark)
    }
}
