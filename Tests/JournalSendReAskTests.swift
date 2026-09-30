// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
import SwiftUI
import XCTest

nonisolated final class JournalSendReAskTests: XCTestCase {
    @MainActor
    func testHeldJournalReAskDecisionShouldPresent() {
        let emptyArgs: [String] = []

        // True case
        XCTAssertTrue(
            HeldJournalReAskDecision.shouldPresent(
                arguments: emptyArgs,
                scenePhase: .active,
                tunnelState: .connected(localPort: 7071, via: .lan),
                isPaired: true,
                journalSendConfirmed: false,
                presenceCount: 0,
                isShowingPairingSheet: false
            )
        )

        // False: background or inactive
        XCTAssertFalse(
            HeldJournalReAskDecision.shouldPresent(
                arguments: emptyArgs,
                scenePhase: .background,
                tunnelState: .connected(localPort: 7071, via: .lan),
                isPaired: true,
                journalSendConfirmed: false,
                presenceCount: 0,
                isShowingPairingSheet: false
            )
        )
        XCTAssertFalse(
            HeldJournalReAskDecision.shouldPresent(
                arguments: emptyArgs,
                scenePhase: .inactive,
                tunnelState: .connected(localPort: 7071, via: .lan),
                isPaired: true,
                journalSendConfirmed: false,
                presenceCount: 0,
                isShowingPairingSheet: false
            )
        )

        // False: tunnelState not connected
        XCTAssertFalse(
            HeldJournalReAskDecision.shouldPresent(
                arguments: emptyArgs,
                scenePhase: .active,
                tunnelState: .connecting,
                isPaired: true,
                journalSendConfirmed: false,
                presenceCount: 0,
                isShowingPairingSheet: false
            )
        )
        XCTAssertFalse(
            HeldJournalReAskDecision.shouldPresent(
                arguments: emptyArgs,
                scenePhase: .active,
                tunnelState: .waitingForHome,
                isPaired: true,
                journalSendConfirmed: false,
                presenceCount: 0,
                isShowingPairingSheet: false
            )
        )
        XCTAssertFalse(
            HeldJournalReAskDecision.shouldPresent(
                arguments: emptyArgs,
                scenePhase: .active,
                tunnelState: .disconnected,
                isPaired: true,
                journalSendConfirmed: false,
                presenceCount: 0,
                isShowingPairingSheet: false
            )
        )

        // False: not paired
        XCTAssertFalse(
            HeldJournalReAskDecision.shouldPresent(
                arguments: emptyArgs,
                scenePhase: .active,
                tunnelState: .connected(localPort: 7071, via: .lan),
                isPaired: false,
                journalSendConfirmed: false,
                presenceCount: 0,
                isShowingPairingSheet: false
            )
        )

        // False: already confirmed
        XCTAssertFalse(
            HeldJournalReAskDecision.shouldPresent(
                arguments: emptyArgs,
                scenePhase: .active,
                tunnelState: .connected(localPort: 7071, via: .lan),
                isPaired: true,
                journalSendConfirmed: true,
                presenceCount: 0,
                isShowingPairingSheet: false
            )
        )

        // False: presenceCount > 0
        XCTAssertFalse(
            HeldJournalReAskDecision.shouldPresent(
                arguments: emptyArgs,
                scenePhase: .active,
                tunnelState: .connected(localPort: 7071, via: .lan),
                isPaired: true,
                journalSendConfirmed: false,
                presenceCount: 1,
                isShowingPairingSheet: false
            )
        )

        // False: showing pairing sheet
        XCTAssertFalse(
            HeldJournalReAskDecision.shouldPresent(
                arguments: emptyArgs,
                scenePhase: .active,
                tunnelState: .connected(localPort: 7071, via: .lan),
                isPaired: true,
                journalSendConfirmed: false,
                presenceCount: 0,
                isShowingPairingSheet: true
            )
        )

        // False: test arguments
        for testArg in ["--ui-test", "--integration-test", "--integration-test-live"] {
            XCTAssertFalse(
                HeldJournalReAskDecision.shouldPresent(
                    arguments: [testArg],
                    scenePhase: .active,
                    tunnelState: .connected(localPort: 7071, via: .lan),
                    isPaired: true,
                    journalSendConfirmed: false,
                    presenceCount: 0,
                    isShowingPairingSheet: false
                )
            )
        }
    }

    @MainActor
    func testResolveConfirmationCancelledWithStartDeadlineWhenConnected() async {
        let task = Task { @MainActor in
            await resolveConfirmation(
                timeout: .seconds(10),
                step: .milliseconds(50),
                startDeadlineWhenConnected: true,
                connectedPort: { nil },
                fetchResult: { _ in .missingOrInvalid }
            )
        }
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, ConfirmOutcome.fallback(.cancelled))
    }

    func testPairFlowViewDefinesStartConfirmHeldJournal() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Pairing/PairFlowView.swift")
        let content = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(content.contains("func startConfirmHeldJournal()"))
    }
}
