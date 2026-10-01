// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
import SwiftUI
import XCTest

nonisolated final class AwaitingMarkConfirmationTests: XCTestCase {
    private func makePairing() -> StoredPairing {
        StoredPairing(
            instanceID: "inst-awaiting",
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
    func testAppConfigAwaitingMarkConfirmationCases() throws {
        let pairing = self.makePairing()

        // 1. Matching record -> awaitingMarkConfirmation == false
        let confStoreMatching = JournalSendConfirmationStore.memory(initialMarker: true)
        try confStoreMatching.writeRecord(for: pairing)
        let credStoreMatching = PairingCredentialStore(
            confirmationStore: confStoreMatching,
            loadPairing: { pairing },
            savePairing: { _ in },
            deletePairing: {}
        )
        let configMatching = AppConfig(
            confirmationStore: confStoreMatching,
            store: credStoreMatching
        )
        XCTAssertTrue(configMatching.isPaired)
        XCTAssertTrue(configMatching.journalSendConfirmed)
        XCTAssertFalse(configMatching.awaitingMarkConfirmation)

        // 2. Marker + mismatched/nil record -> awaitingMarkConfirmation == true
        let confStoreMismatched = JournalSendConfirmationStore.memory(initialRecord: nil, initialMarker: true)
        let credStoreMismatched = PairingCredentialStore(
            confirmationStore: confStoreMismatched,
            loadPairing: { pairing },
            savePairing: { _ in },
            deletePairing: {}
        )
        let configMismatched = AppConfig(
            confirmationStore: confStoreMismatched,
            store: credStoreMismatched
        )
        XCTAssertTrue(configMismatched.isPaired)
        XCTAssertFalse(configMismatched.journalSendConfirmed)
        XCTAssertTrue(configMismatched.awaitingMarkConfirmation)

        // 3. Grandfathered (neither marker nor record) -> settles to confirmed -> awaitingMarkConfirmation == false
        let confStoreGrandfather = JournalSendConfirmationStore.memory(initialRecord: nil, initialMarker: false)
        let credStoreGrandfather = PairingCredentialStore(
            confirmationStore: confStoreGrandfather,
            loadPairing: { pairing },
            savePairing: { _ in },
            deletePairing: {}
        )
        let configGrandfather = AppConfig(
            confirmationStore: confStoreGrandfather,
            store: credStoreGrandfather
        )
        XCTAssertTrue(configGrandfather.isPaired)
        XCTAssertTrue(configGrandfather.journalSendConfirmed)
        XCTAssertFalse(configGrandfather.awaitingMarkConfirmation)

        // 4. Nil pairing -> awaitingMarkConfirmation == false
        let confStoreNil = JournalSendConfirmationStore.memory(initialRecord: nil, initialMarker: false)
        let credStoreNil = PairingCredentialStore(
            confirmationStore: confStoreNil,
            loadPairing: { nil },
            savePairing: { _ in },
            deletePairing: {}
        )
        let configNil = AppConfig(
            confirmationStore: confStoreNil,
            store: credStoreNil
        )
        XCTAssertFalse(configNil.isPaired)
        XCTAssertFalse(configNil.journalSendConfirmed)
        XCTAssertFalse(configNil.awaitingMarkConfirmation)

        // 5. failFirstRead: true -> initial settle fails -> awaitingMarkConfirmation == true -> retry settles -> false
        let confStoreFail = JournalSendConfirmationStore.memory(failFirstRead: true)
        let credStoreFail = PairingCredentialStore(
            confirmationStore: confStoreFail,
            loadPairing: { pairing },
            savePairing: { _ in },
            deletePairing: {}
        )
        let configFail = AppConfig(
            confirmationStore: confStoreFail,
            store: credStoreFail
        )
        XCTAssertTrue(configFail.isPaired)
        XCTAssertFalse(configFail.journalSendConfirmed)
        XCTAssertTrue(configFail.awaitingMarkConfirmation)

        let retrySucceeded = configFail.retrySettleIfNeeded()
        XCTAssertTrue(retrySucceeded)
        XCTAssertTrue(configFail.journalSendConfirmed)
        XCTAssertFalse(configFail.awaitingMarkConfirmation)
    }

    @MainActor
    func testPairFlowRequestsNextMintsUniqueIDs() {
        let req1 = PairFlowRequests.next(after: nil, start: .ceremony)
        XCTAssertEqual(req1.start, .ceremony)

        let req2 = PairFlowRequests.next(after: req1, start: .confirmHeldJournal)
        XCTAssertEqual(req2.start, .confirmHeldJournal)
        XCTAssertNotEqual(req1.id, req2.id)

        let req3 = PairFlowRequests.next(after: req2, start: .ceremony)
        XCTAssertNotEqual(req2.id, req3.id)
    }
}
