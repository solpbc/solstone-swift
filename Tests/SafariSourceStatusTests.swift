// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

final class SafariSourceStatusTests: XCTestCase {
    private func snapshot(contact: Bool = true, full: Bool = false, confirmed: Bool = true, accepted: Bool = true) -> SafariBrowserSnapshot {
        SafariBrowserSnapshot(confirmed: confirmed, heldBytes: 0, queuedBytes: 0, lastAccepted: accepted ? Date() : nil,
            lastContact: contact ? Date() : nil, full: full)
    }

    @MainActor
    func testWaitingCountsSafariOnceAcrossAdoptionAndReadFailureStaysUnknown() {
        let first = UUID(), second = UUID()
        var local: SafariBrowserSnapshot? = self.snapshot()
        local?.pendingPeriodIDs = [first, second]
        let source = SafariSourceModel(load: {
            guard let local else { throw SafariBrowserError.storage }
            return local
        })
        let mirror = TransferStatusMirror()
        source.bindTransferMirror(mirror)
        XCTAssertEqual(source.waitingCount, 2)
        var browser = TransferSourceStatusSnapshot(queuedCount: 1, attentionCount: 0, inFlightCount: 0,
            deliveredCount: 0, droppedCount: 0, lastDeliveredAt: nil, lastErrorDetail: nil,
            recentErrorCount: 0, bytesPerSecond: 0)
        var transfer = TransferStatusSnapshot(counters: .empty, paused: false, policyPaused: false,
            backoffPendingCount: 0, soonestNextAttemptAt: nil, endpointHeld: false,
            lastEventSummary: nil, lastUpdatedAt: Date(), sources: ["browser": browser],
            aggregateBytesPerSecond: 0, heldItemIDs: [first])
        mirror.apply(snapshot: transfer)
        XCTAssertEqual(source.waitingCount, 2)
        local?.pendingPeriodIDs = []
        source.refresh()
        XCTAssertEqual(source.waitingCount, 1)
        browser.queuedCount = 0
        transfer.sources = ["browser": browser]
        transfer.heldItemIDs = []
        mirror.apply(snapshot: transfer)
        XCTAssertEqual(source.waitingCount, 0)
        XCTAssertTrue(source.waitingIsKnown)
        local = nil
        source.refresh()
        XCTAssertFalse(source.waitingIsKnown)
        for state in [HomeStatusPillState.caughtUp, .syncing] {
            let lead = StatusPaneLead.resolve(pillState: state, waitingTotal: 0,
                showsConnectionDetails: true, waitingIsKnown: source.waitingIsKnown)
            XCTAssertEqual(lead.lead, .headline(SourceVocabulary.connectedLabel))
        }
        local = self.snapshot()
        source.refresh()
        XCTAssertTrue(source.waitingIsKnown)
    }

    func testUnreadableSafariWithholdsPartialTotalInEveryConnectionState() {
        let states: [HomeStatusPillState] = [.caughtUp, .journalGap, .syncing, .connecting,
            .offline, .notPaired, .stalled, .awaitingMarkConfirmation]
        for state in states {
            for knownWaiting in [0, 2] {
                let presentation = StatusPaneLead.resolve(pillState: state, waitingTotal: knownWaiting,
                    showsConnectionDetails: true, waitingIsKnown: false)
                if case .count = presentation.lead {
                    XCTFail("Unknown Safari custody must not present a partial total in \(state)")
                }
            }
        }
    }

    func testFreshLocationUsesEnrollmentButDeniedSetupKeepsRecovery() {
        XCTAssertTrue(locationShowsEnrollment(state: .readyToSetUp, hasAttention: false))
        XCTAssertTrue(locationShowsEnrollment(state: .off, hasAttention: false))
        XCTAssertFalse(locationShowsEnrollment(state: .readyToSetUp, hasAttention: true))
        for state in [SourceState.active, .paused, .needsAttention, .enrolling] {
            XCTAssertFalse(locationShowsEnrollment(state: state, hasAttention: false))
        }
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
        XCTAssertFalse(SafariSetUpStep.isShown(snapshot: self.snapshot(full: true, accepted: false)))
    }

    func testTheSwitchOrTheExtensionsHelloMovesSetUpOn() {
        let silent = self.snapshot(contact: false, accepted: false)
        XCTAssertEqual(SafariSetUpStep(snapshot: silent, extensionOn: nil), .turnOn)
        XCTAssertEqual(SafariSetUpStep(snapshot: silent, extensionOn: false), .turnOn)
        XCTAssertEqual(SafariSetUpStep(snapshot: silent, extensionOn: true), .addSite)
        XCTAssertEqual(SafariSetUpStep(snapshot: self.snapshot(accepted: false), extensionOn: nil), .addSite)
        XCTAssertEqual(SafariSetUpStep(snapshot: self.snapshot(accepted: false), extensionOn: false), .turnOn)
    }

    func testTheFirstSiteIsReadAsABareHost() {
        XCTAssertEqual(SafariFirstSite.host(from: " NYTimes.com "), "nytimes.com")
        XCTAssertEqual(SafariFirstSite.host(from: "https://www.nytimes.com/section?x=1"), "www.nytimes.com")
        XCTAssertNil(SafariFirstSite.host(from: "nytimes"))
        XCTAssertNil(SafariFirstSite.host(from: "not a site.com"))
        XCTAssertEqual(SafariFirstSite.urls(for: "nytimes.com").map(\.absoluteString),
                       ["x-safari-https://nytimes.com", "https://nytimes.com"])
    }

    func testTurningTheExtensionOffInSettingsShowsAsOff() {
        let off = safariSourceModel(snapshot: self.snapshot(), extensionOn: false, isJournalPaired: true)
        XCTAssertEqual(off.state, .off)
        XCTAssertEqual(off.subtext, SafariVocabulary.extensionOff)
        XCTAssertEqual(SafariSourceStatus(snapshot: self.snapshot(), extensionOn: true).sourceState, .active)
        XCTAssertEqual(SafariSourceStatus(snapshot: self.snapshot(), extensionOn: nil).sourceState, .active)
    }

    func testAFullStoreShowsAsItsOwnState() {
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
