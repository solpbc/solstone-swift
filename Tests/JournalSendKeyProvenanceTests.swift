// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
import XCTest

nonisolated final class JournalSendKeyProvenanceTests: XCTestCase {
    func testJournalSendConfirmationKeyDeterministicProvenance() {
        let pairing = StoredPairing(
            instanceID: "journal-send-confirmation-fixture",
            homeLabel: "test-home",
            relayEndpoint: "wss://relay.example.com",
            fingerprint: "sha256:\(String(repeating: "1", count: 64))",
            clientCertPEM: CertlessTrustConstants.leafPEM,
            clientKeyPEM: "test-key",
            caChainPEM: CertlessTrustConstants.caPEM,
            relayEnrollment: .unavailable,
            localEndpoints: [],
            pairedAt: Date(timeIntervalSince1970: 1_776_144_000)
        )

        let key = journalSendConfirmationKey(for: pairing)
        XCTAssertNotNil(key)
        // This fixture's id isn't its CA's journal id, so it has the key that holds it and asks again.
        // JournalSendPromptTests holds the unchanged key of a pairing whose id is.
        XCTAssertEqual(key, "sha256:0d480efec9128a32fff3a0f591662d3a222905e0575b7bed350d97d7290a21fa")

        // Verify repeatability
        let key2 = journalSendConfirmationKey(for: pairing)
        XCTAssertEqual(key, key2)

        // Verify that changing instanceID changes the key
        let pairingDiffInstance = StoredPairing(
            instanceID: "different-instance",
            homeLabel: "test-home",
            relayEndpoint: "wss://relay.example.com",
            fingerprint: "sha256:\(String(repeating: "1", count: 64))",
            clientCertPEM: CertlessTrustConstants.leafPEM,
            clientKeyPEM: "test-key",
            caChainPEM: CertlessTrustConstants.caPEM,
            relayEnrollment: .unavailable,
            localEndpoints: [],
            pairedAt: Date(timeIntervalSince1970: 1_776_144_000)
        )
        let keyDiffInstance = journalSendConfirmationKey(for: pairingDiffInstance)
        XCTAssertNotEqual(key, keyDiffInstance)

        // Verify that changing CA cert changes the key
        let pairingDiffCA = StoredPairing(
            instanceID: "journal-send-confirmation-fixture",
            homeLabel: "test-home",
            relayEndpoint: "wss://relay.example.com",
            fingerprint: "sha256:\(String(repeating: "1", count: 64))",
            clientCertPEM: CertlessTrustConstants.leafPEM,
            clientKeyPEM: "test-key",
            caChainPEM: CertlessTrustConstants.wrongCAPEM,
            relayEnrollment: .unavailable,
            localEndpoints: [],
            pairedAt: Date(timeIntervalSince1970: 1_776_144_000)
        )
        let keyDiffCA = journalSendConfirmationKey(for: pairingDiffCA)
        XCTAssertNotEqual(key, keyDiffCA)
    }
}
