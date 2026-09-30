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
        XCTAssertEqual(key, "sha256:165b30a8336f6761c68a504de6d23c6d37e839920f1b87dacec3712c53bb516d")

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
