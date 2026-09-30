// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
import XCTest

nonisolated final class JournalSendJournalTests: XCTestCase {
    func testJournalWebPresentationConnectionLostMessage() {
        XCTAssertEqual(
            JournalWebPresentation.connectionLostMessage,
            "lost the connection to your journal. keep the solstone app open and try again."
        )
    }

    func testShouldLoadWebViewRequiresConfirmationAndURL() {
        let testURL = URL(string: "http://127.0.0.1:7071/")!

        // True: confirmed and non-nil URL
        XCTAssertTrue(InAppJournalPresentation.shouldLoadWebView(journalSendConfirmed: true, resolvedURL: testURL))

        // False: unconfirmed even with non-nil URL
        XCTAssertFalse(InAppJournalPresentation.shouldLoadWebView(journalSendConfirmed: false, resolvedURL: testURL))

        // False: confirmed but nil URL
        XCTAssertFalse(InAppJournalPresentation.shouldLoadWebView(journalSendConfirmed: true, resolvedURL: nil))

        // False: unconfirmed and nil URL
        XCTAssertFalse(InAppJournalPresentation.shouldLoadWebView(journalSendConfirmed: false, resolvedURL: nil))
    }

    @MainActor
    func testAppConfigConfirmationTransitionsForJournalWebView() throws {
        let pairing = StoredPairing(
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

        // Held: web view should not load
        XCTAssertFalse(appConfig.journalSendConfirmed)
        let url = URL(string: "http://127.0.0.1:7071/")!
        XCTAssertFalse(InAppJournalPresentation.shouldLoadWebView(journalSendConfirmed: appConfig.journalSendConfirmed, resolvedURL: url))

        // Confirm
        try confirmationStore.writeRecord(for: pairing)
        appConfig.journalSendConfirmed = true

        // Confirmed: web view loads
        XCTAssertTrue(InAppJournalPresentation.shouldLoadWebView(journalSendConfirmed: appConfig.journalSendConfirmed, resolvedURL: url))
    }
}
