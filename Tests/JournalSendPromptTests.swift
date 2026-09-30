// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

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
        let confirmEnd = try XCTUnwrap(confirmSection.range(of: ".buttonStyle(.borderedProminent)"))
        let confirmButtonBody = confirmSection[..<confirmEnd.lowerBound]

        XCTAssertFalse(confirmButtonBody.contains("try?"))
        XCTAssertTrue(confirmButtonBody.contains("completeJournalSend"))

        let couldNotVerifyBlock = try XCTUnwrap(text.range(of: "Button(SourceVocabulary.journalMarkCouldNotVerifyContinue)"))
        let couldNotVerifySection = text[couldNotVerifyBlock.lowerBound...]
        let couldNotVerifyEnd = try XCTUnwrap(couldNotVerifySection.range(of: ".buttonStyle(.borderedProminent)"))
        let couldNotVerifyBody = couldNotVerifySection[..<couldNotVerifyEnd.lowerBound]

        XCTAssertFalse(couldNotVerifyBody.contains("try?"))
        XCTAssertTrue(couldNotVerifyBody.contains("completeJournalSend"))
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
}
