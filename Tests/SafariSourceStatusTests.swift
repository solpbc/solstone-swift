// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

final class SafariSourceStatusTests: XCTestCase {
    private func snapshot(contact: Bool = true, paused: Bool = false, full: Bool = false, confirmed: Bool = true, accepted: Bool = true) -> SafariBrowserSnapshot {
        SafariBrowserSnapshot(confirmed: confirmed, paused: paused, heldBytes: 0, queuedBytes: 0, lastAccepted: accepted ? Date() : nil,
            lastContact: contact ? Date() : nil, full: full)
    }

    func testTheSourceIsReadyToSetUpUntilSafarisExtensionAnswers() {
        XCTAssertEqual(SafariSourceStatus(snapshot: self.snapshot(contact: false)).sourceState, .readyToSetUp)
        XCTAssertEqual(SafariSourceStatus(snapshot: self.snapshot()).sourceState, .active)
    }

    func testSetUpLastsUntilTheFirstPageComesIn() {
        let waiting = self.snapshot(accepted: false)
        XCTAssertEqual(SafariSourceStatus(snapshot: waiting).sourceState, .readyToSetUp)
        XCTAssertTrue(SafariSetUpStep.isShown(snapshot: waiting))
        XCTAssertFalse(SafariSetUpStep.isShown(snapshot: self.snapshot()))
        XCTAssertFalse(SafariSetUpStep.isShown(snapshot: self.snapshot(paused: true, accepted: false)))
    }

    func testTheSwitchOrTheExtensionsHelloMovesSetUpOn() {
        let silent = self.snapshot(contact: false, accepted: false)
        XCTAssertEqual(SafariSetUpStep(snapshot: silent, extensionOn: nil), .turnOn)
        XCTAssertEqual(SafariSetUpStep(snapshot: silent, extensionOn: false), .turnOn)
        XCTAssertEqual(SafariSetUpStep(snapshot: silent, extensionOn: true), .addSite)
        XCTAssertEqual(SafariSetUpStep(snapshot: self.snapshot(accepted: false), extensionOn: nil), .addSite)
    }

    func testTheFirstSiteIsReadAsABareHost() {
        XCTAssertEqual(SafariFirstSite.host(from: " NYTimes.com "), "nytimes.com")
        XCTAssertEqual(SafariFirstSite.host(from: "https://www.nytimes.com/section?x=1"), "www.nytimes.com")
        XCTAssertNil(SafariFirstSite.host(from: "nytimes"))
        XCTAssertNil(SafariFirstSite.host(from: "not a site.com"))
        XCTAssertEqual(SafariFirstSite.urls(for: "nytimes.com").map(\.absoluteString),
                       ["x-safari-https://nytimes.com", "https://nytimes.com"])
    }

    func testPauseAndAFullStoreShowAsTheirOwnStates() {
        XCTAssertEqual(SafariSourceStatus(snapshot: self.snapshot(paused: true)).sourceState, .paused)
        let full = SafariSourceStatus(snapshot: self.snapshot(full: true))
        XCTAssertEqual(full.sourceState, .needsAttention)
        XCTAssertEqual(full.attention, SafariVocabulary.full)
        XCTAssertEqual(SafariSourceStatus(snapshot: nil).sourceState, .needsAttention)
    }

    func testWithoutAConfirmedJournalTheSourceIsOffAndSaysWhy() {
        let awaiting = safariSourceModel(snapshot: self.snapshot(confirmed: false), isJournalPaired: true)
        XCTAssertEqual(awaiting.state, .off)
        XCTAssertEqual(awaiting.subtext, SafariVocabulary.awaitingMark)
        let unpaired = safariSourceModel(snapshot: self.snapshot(confirmed: false), isJournalPaired: false)
        XCTAssertEqual(unpaired.subtext, SafariVocabulary.notPaired)
    }
}
