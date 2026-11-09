// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Foundation
@testable import solstone_swift
import SPLTunnel
import XCTest

nonisolated final class JournalSendPromptTests: XCTestCase {
    private func makePairing() -> StoredPairing {
        StoredPairing(
            instanceID: "inst-1",
            homeLabel: "Home",
            relayEndpoint: "wss://relay.example.com",
            fingerprint: "sha256:\(String(repeating: "a", count: 64))",
            clientCertPEM: CertlessTrustConstants.leafPEM,
            clientKeyPEM: "key",
            caChainPEM: CertlessTrustConstants.caPEM,
            relayEnrollment: .unavailable,
            localEndpoints: [LocalEndpoint(host: "127.0.0.1", port: 7071, scope: "")],
            pairedAt: Date()
        )
    }

    @MainActor
    func testPairFlowPresenceIncrementAndDecrement() {
        let presence = PairFlowPresence()
        XCTAssertEqual(presence.count, 0)
        XCTAssertFalse(presence.isPresent)

        presence.increment()
        XCTAssertEqual(presence.count, 1)
        XCTAssertTrue(presence.isPresent)

        presence.increment()
        XCTAssertEqual(presence.count, 2)
        XCTAssertTrue(presence.isPresent)

        presence.decrement()
        XCTAssertEqual(presence.count, 1)
        XCTAssertTrue(presence.isPresent)

        presence.decrement()
        XCTAssertEqual(presence.count, 0)
        XCTAssertFalse(presence.isPresent)

        // Decrement does not go below 0
        presence.decrement()
        XCTAssertEqual(presence.count, 0)
        XCTAssertFalse(presence.isPresent)
    }

    func testPairFlowStartModes() {
        let ceremony: PairFlowView.PairFlowStart = .ceremony
        let confirmHeld: PairFlowView.PairFlowStart = .confirmHeldJournal
        XCTAssertNotEqual(ceremony, confirmHeld)
    }

    @MainActor
    func testCompleteJournalSendAuthorizesAndSetsAllowsSend() throws {
        let pairing = self.makePairing()
        let confirmationStore = JournalSendConfirmationStore.memory()
        let credentialStore = PairingCredentialStore(
            confirmationStore: confirmationStore,
            loadPairing: { pairing },
            savePairing: { _ in },
            deletePairing: {}
        )
        let appConfig = AppConfig(
            confirmationStore: confirmationStore,
            store: credentialStore
        )
        try appConfig.applyPairing(pairing)
        XCTAssertFalse(appConfig.journalSendConfirmed)

        let release = JournalSendRelease(
            credentialStore: credentialStore,
            confirmationStore: confirmationStore,
            transferEngine: TransferEngine(spool: TransferSpool(rootURL: FileManager.default.temporaryDirectory), transport: TransferTransport(), endpointResolver: LoopbackTransferEndpointResolver(credentials: credentialStore, confirmation: confirmationStore)),
            foregroundDrainGate: ForegroundDrainGate(drive: {})
        )

        let gate = PairFlowCompletionGate()
        var completed = false
        let success = completeJournalSend(
            release: release,
            appConfig: appConfig,
            gate: gate,
            onComplete: { completed = true }
        )

        XCTAssertTrue(success)
        XCTAssertTrue(completed)
        XCTAssertTrue(appConfig.journalSendConfirmed)
        XCTAssertTrue(confirmationStore.allowsSend(pairing: pairing))
    }

    func testPairFlowViewButtonsDoNotUseTryQuestionMark() throws {
        let viewURL = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("Sources/Pairing/PairFlowView.swift")
        let text = try String(contentsOf: viewURL, encoding: .utf8)

        let confirmBlock = try XCTUnwrap(text.range(of: "Button(SourceVocabulary.journalMarkConfirmButton)"))
        let confirmSection = text[confirmBlock.lowerBound...]
        let confirmEnd = try XCTUnwrap(confirmSection.range(of: ".buttonStyle(BrandProminentButtonStyle())"))
        let confirmButtonBody = confirmSection[..<confirmEnd.lowerBound]

        XCTAssertFalse(confirmButtonBody.contains("try?"))
        XCTAssertTrue(confirmButtonBody.contains("recordAnswer"))

        let couldNotVerifyBlock = try XCTUnwrap(text.range(of: "Button(SourceVocabulary.journalMarkCouldNotVerifyContinue)"))
        let couldNotVerifySection = text[couldNotVerifyBlock.lowerBound...]
        let couldNotVerifyEnd = try XCTUnwrap(couldNotVerifySection.range(of: ".buttonStyle(BrandProminentButtonStyle())"))
        let couldNotVerifyBody = couldNotVerifySection[..<couldNotVerifyEnd.lowerBound]

        XCTAssertFalse(couldNotVerifyBody.contains("try?"))
        XCTAssertTrue(couldNotVerifyBody.contains("recordAnswer"))

        let recordBlock = try XCTUnwrap(text.range(of: "private func recordAnswer()"))
        XCTAssertTrue(text[recordBlock.lowerBound...].contains("completeJournalSend"))
    }

    @MainActor
    func testFailNextRecordWriteDoesNotLatchGateAndSubsequentAttemptSucceeds() throws {
        let pairing = self.makePairing()
        let confirmationStore = JournalSendConfirmationStore.memory()
        let credentialStore = PairingCredentialStore(
            confirmationStore: confirmationStore,
            loadPairing: { pairing },
            savePairing: { _ in },
            deletePairing: {}
        )
        let appConfig = AppConfig(
            confirmationStore: confirmationStore,
            store: credentialStore
        )
        try appConfig.applyPairing(pairing)

        let release = JournalSendRelease(
            credentialStore: credentialStore,
            confirmationStore: confirmationStore,
            transferEngine: TransferEngine(spool: TransferSpool(rootURL: FileManager.default.temporaryDirectory), transport: TransferTransport(), endpointResolver: LoopbackTransferEndpointResolver(credentials: credentialStore, confirmation: confirmationStore)),
            foregroundDrainGate: ForegroundDrainGate(drive: {})
        )

        // Prime the failure right before the first attempt
        confirmationStore.failNextRecordWrite()

        // First attempt throws from authorize, completeJournalSend returns false
        let gate = PairFlowCompletionGate()
        var completedCount = 0
        let firstSuccess = completeJournalSend(
            release: release,
            appConfig: appConfig,
            gate: gate,
            onComplete: { completedCount += 1 }
        )

        XCTAssertFalse(firstSuccess)
        XCTAssertEqual(completedCount, 0)
        XCTAssertFalse(appConfig.journalSendConfirmed)
        XCTAssertFalse(confirmationStore.allowsSend(pairing: pairing))

        // Direct authorize throws confirmFailed with stable description
        XCTAssertEqual(JournalSendConfirmationStoreError.confirmFailed.description, "journal-send-confirm-failed")

        // Second attempt succeeds and calls onComplete once (proves gate did not latch)
        let secondSuccess = completeJournalSend(
            release: release,
            appConfig: appConfig,
            gate: gate,
            onComplete: { completedCount += 1 }
        )

        XCTAssertTrue(secondSuccess)
        XCTAssertEqual(completedCount, 1)
        XCTAssertTrue(appConfig.journalSendConfirmed)
        XCTAssertTrue(confirmationStore.allowsSend(pairing: pairing))
    }

    func testAStoredPairingWhoseIDIsNotItsCAsGetsItsOwnKey() throws {
        let unbound = self.makePairing()
        XCTAssertFalse(pairingIsBoundToItsCA(unbound))
        let bound = StoredPairing(
            instanceID: try CertChain.journalID(ofCAChainPEM: CertlessTrustConstants.caPEM),
            homeLabel: unbound.homeLabel,
            relayEndpoint: unbound.relayEndpoint,
            fingerprint: unbound.fingerprint,
            clientCertPEM: unbound.clientCertPEM,
            clientKeyPEM: unbound.clientKeyPEM,
            caChainPEM: unbound.caChainPEM,
            relayEnrollment: unbound.relayEnrollment,
            localEndpoints: unbound.localEndpoints,
            pairedAt: unbound.pairedAt
        )
        XCTAssertTrue(pairingIsBoundToItsCA(bound))

        // An answer from before this check, under the key every pairing used then.
        func opaque(_ parts: [String]) -> String {
            "sha256:" + SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let earlierKey = { (pairing: StoredPairing) -> String in
            let ca = try! CertChain.certificates(fromPEM: pairing.caChainPEM)
            let leaf = try! XCTUnwrap(CertChain.certificates(fromPEM: pairing.clientCertPEM).first)
            return opaque([
                "journal-send-confirmation-v1",
                pairing.instanceID,
                opaque(["journal-version-ca-chain-v1"] + ca.map(CertChain.sha256Fingerprint(of:))),
                CertChain.sha256Fingerprint(of: leaf)
            ])
        }
        XCTAssertEqual(journalSendConfirmationKey(for: bound), earlierKey(bound), "a bound pairing keeps its answer")
        XCTAssertNotEqual(journalSendConfirmationKey(for: unbound), earlierKey(unbound), "an unbound pairing is asked again")

        // Held on start, whatever was answered before; a new answer is kept.
        let store = JournalSendConfirmationStore.memory()
        try store.grandfather(key: earlierKey(unbound))
        XCTAssertFalse(store.allowsSend(pairing: unbound))
        try store.writeRecord(for: unbound)
        XCTAssertTrue(store.allowsSend(pairing: unbound))
    }

    func testAnUnboundPairingWithNoAnswerIsNotSettledAsConfirmed() throws {
        let store = JournalSendConfirmationStore.memory()
        let outcome = try store.settle(loadPairing: { self.makePairing() })
        XCTAssertFalse(outcome.isConfirmed)
        XCTAssertFalse(outcome.isGrandfathered)
    }

    @MainActor
    func testAFailedSaveReportsItselfAndDoesNotComplete() throws {
        let pairing = self.makePairing()
        let confirmationStore = JournalSendConfirmationStore.memory()
        let credentialStore = PairingCredentialStore(
            confirmationStore: confirmationStore,
            loadPairing: { pairing },
            savePairing: { _ in },
            deletePairing: {}
        )
        let appConfig = AppConfig(
            confirmationStore: confirmationStore,
            store: credentialStore
        )
        try appConfig.applyPairing(pairing)

        let release = JournalSendRelease(
            credentialStore: credentialStore,
            confirmationStore: confirmationStore,
            transferEngine: TransferEngine(
                spool: TransferSpool(rootURL: FileManager.default.temporaryDirectory),
                transport: TransferTransport(),
                endpointResolver: LoopbackTransferEndpointResolver(credentials: credentialStore, confirmation: confirmationStore)
            ),
            foregroundDrainGate: ForegroundDrainGate(drive: {})
        )

        confirmationStore.failNextRecordWrite()

        let gate = PairFlowCompletionGate()
        var completed = false
        let didComplete = completeJournalSend(
            release: release,
            appConfig: appConfig,
            gate: gate,
            onComplete: { completed = true }
        )

        XCTAssertFalse(didComplete)
        XCTAssertFalse(completed)
        XCTAssertFalse(appConfig.journalSendConfirmed)
    }
}
