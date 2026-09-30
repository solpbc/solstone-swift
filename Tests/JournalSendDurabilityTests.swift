// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
import XCTest

nonisolated final class JournalSendDurabilityTests: XCTestCase {
    private func makePairing(id: String = "inst-1") -> StoredPairing {
        StoredPairing(
            instanceID: id,
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
    func testConfirmedSurvivesNewStoreAndAppConfigAfterUserDefaultsWipe() throws {
        let suiteName = "test.durability.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("dummy", forKey: "k")
        defaults.removePersistentDomain(forName: suiteName)

        let pairing = makePairing()
        let confirmation = JournalSendConfirmationStore.memory()
        let store = PairingCredentialStore(
            confirmationStore: confirmation,
            loadPairing: { pairing },
            savePairing: { _ in },
            deletePairing: {}
        )
        try confirmation.writeRecord(for: pairing)

        let appConfig = AppConfig(confirmationStore: confirmation, store: store)
        XCTAssertTrue(appConfig.journalSendConfirmed)
        XCTAssertTrue(confirmation.allowsSend(pairing: pairing))
    }

    @MainActor
    func testHeldStaysHeldAcrossRebuildsAndSecondSettleDoesNotConfirm() async throws {
        let pairing = makePairing()
        // Marker is present (applied), but record is absent (held)
        let confirmation = JournalSendConfirmationStore.memory(initialMarker: true)
        let store = PairingCredentialStore(
            confirmationStore: confirmation,
            loadPairing: { pairing },
            savePairing: { _ in },
            deletePairing: {}
        )

        let appConfig = AppConfig(confirmationStore: confirmation, store: store)
        XCTAssertFalse(appConfig.journalSendConfirmed)

        // Second settle
        let retryResult = appConfig.retrySettleIfNeeded()
        XCTAssertFalse(retryResult)
        XCTAssertFalse(appConfig.journalSendConfirmed)

        // Resolver returns held
        let resolver = LoopbackTransferEndpointResolver(credentials: store, confirmation: confirmation)
        await resolver.update(activeLocalPort: 7071)
        let res = await resolver.resolve(TransferEndpointDescriptor(destinationKind: .observerIngest, path: "/app/devices/ingest"))
        if case .unavailable(let reason) = res {
            XCTAssertEqual(reason, "journal-send-held")
        } else {
            XCTFail("Expected .unavailable(journal-send-held), got \(res)")
        }
    }

    func testAbsentRecordThrowingReadAndUnderivableCertResolveHeld() async throws {
        let pairing = makePairing()

        // 1. Absent record
        let confAbsent = JournalSendConfirmationStore.memory()
        let storeAbsent = PairingCredentialStore(
            confirmationStore: confAbsent,
            loadPairing: { pairing },
            savePairing: { _ in },
            deletePairing: {}
        )
        let resolverAbsent = LoopbackTransferEndpointResolver(credentials: storeAbsent, confirmation: confAbsent)
        await resolverAbsent.update(activeLocalPort: 7071)
        let resAbsent = await resolverAbsent.resolve(TransferEndpointDescriptor(destinationKind: .observerIngest, path: "/app/devices/ingest"))
        if case .unavailable(let reason) = resAbsent {
            XCTAssertEqual(reason, "journal-send-held")
        } else {
            XCTFail("Expected unavailable(journal-send-held)")
        }

        // 2. Throwing read
        let confThrowing = JournalSendConfirmationStore.memory(failFirstRead: true)
        let storeThrowing = PairingCredentialStore(
            confirmationStore: confThrowing,
            loadPairing: { pairing },
            savePairing: { _ in },
            deletePairing: {}
        )
        let resolverThrowing = LoopbackTransferEndpointResolver(credentials: storeThrowing, confirmation: confThrowing)
        await resolverThrowing.update(activeLocalPort: 7071)
        let resThrowing = await resolverThrowing.resolve(TransferEndpointDescriptor(destinationKind: .observerIngest, path: "/app/devices/ingest"))
        if case .unavailable(let reason) = resThrowing {
            XCTAssertEqual(reason, "journal-send-held")
        } else {
            XCTFail("Expected unavailable(journal-send-held)")
        }

        // 3. Underivable cert (bad PEM)
        let badPairing = StoredPairing(
            instanceID: "inst-bad",
            homeLabel: "Home",
            relayEndpoint: "wss://relay.example.com",
            fingerprint: "sha256:\(String(repeating: "a", count: 64))",
            clientCertPEM: "NOT-A-CERT",
            clientKeyPEM: "key",
            caChainPEM: "NOT-A-CA",
            relayEnrollment: .unavailable,
            localEndpoints: [],
            pairedAt: Date()
        )
        let confBad = JournalSendConfirmationStore.memory()
        let storeBad = PairingCredentialStore(
            confirmationStore: confBad,
            loadPairing: { badPairing },
            savePairing: { _ in },
            deletePairing: {}
        )
        let resolverBad = LoopbackTransferEndpointResolver(credentials: storeBad, confirmation: confBad)
        await resolverBad.update(activeLocalPort: 7071)
        let resBad = await resolverBad.resolve(TransferEndpointDescriptor(destinationKind: .observerIngest, path: "/app/devices/ingest"))
        if case .unavailable(let reason) = resBad {
            XCTAssertEqual(reason, "journal-send-held")
        } else {
            XCTFail("Expected unavailable(journal-send-held)")
        }
    }

    func testConfirmationStoreKeychainAttributesAndPolicy() {
        XCTAssertEqual(JournalSendConfirmationStore.service, "app.solstone.swift.journal-send")
        XCTAssertEqual(JournalSendConfirmationStore.confirmationAccount, "confirmation")
        XCTAssertEqual(JournalSendConfirmationStore.settledAccount, "settled")

        let attrs = JournalSendConfirmationStore.addAttributes(account: "confirmation", valueData: Data([1, 2, 3]))
        XCTAssertEqual(attrs[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlock as String)
        XCTAssertEqual(attrs[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(attrs[kSecAttrService as String] as? String, "app.solstone.swift.journal-send")
        XCTAssertEqual(attrs[kSecAttrAccount as String] as? String, "confirmation")
    }
}
