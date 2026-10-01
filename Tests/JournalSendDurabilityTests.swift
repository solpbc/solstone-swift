// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
@testable import SPLTunnel
import XCTest
import os

private final class DurabilityKeychainFake: @unchecked Sendable {
    private let lock = NSLock()
    var pairing: StoredPairing?
    var record: String?
    var marker: Bool = false
    var markerAttributes: [String: Any]?
    var failNextMarkerWrite = false
    var failNextRecordWrite = false
    var pairingSaveCount = 0

    init(pairing: StoredPairing? = nil, record: String? = nil, marker: Bool = false) {
        self.pairing = pairing
        self.record = record
        self.marker = marker
    }

    func readPairing() throws -> StoredPairing? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.pairing
    }

    func savePairing(_ pairing: StoredPairing) throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.pairingSaveCount += 1
        self.pairing = pairing
    }

    func deletePairing() throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.pairing = nil
    }

    func readRecord() throws -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.record
    }

    func writeRecord(_ key: String) throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.record = nil
        if self.failNextRecordWrite {
            self.failNextRecordWrite = false
            throw JournalSendConfirmationStoreError.secItemError(errSecIO)
        }
        self.record = key
    }

    func clearRecord() throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.record = nil
    }

    func readMarker() throws -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.marker
    }

    func writeMarker() throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.failNextMarkerWrite {
            self.failNextMarkerWrite = false
            throw JournalSendConfirmationStoreError.secItemError(errSecIO)
        }
        self.marker = true
        self.markerAttributes = JournalSendConfirmationStore.addAttributes(
            account: JournalSendConfirmationStore.settledAccount,
            valueData: Data("1".utf8)
        )
    }

    func clearMarker() throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.marker = false
        self.markerAttributes = nil
    }

    func makeConfirmationStore() -> JournalSendConfirmationStore {
        JournalSendConfirmationStore(
            loadRecord: { try self.readRecord() },
            saveRecord: { try self.writeRecord($0) },
            deleteRecord: { try self.clearRecord() },
            loadMarker: { try self.readMarker() },
            saveMarker: { try self.writeMarker() },
            deleteMarker: { try self.clearMarker() }
        )
    }

    func makeCredentialStore(confirmationStore: JournalSendConfirmationStore) -> PairingCredentialStore {
        PairingCredentialStore(
            confirmationStore: confirmationStore,
            loadPairing: { try self.readPairing() },
            savePairing: { try self.savePairing($0) },
            deletePairing: { try self.deletePairing() }
        )
    }
}

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
        let fake = DurabilityKeychainFake(pairing: pairing)
        let confirmation = fake.makeConfirmationStore()
        let store = fake.makeCredentialStore(confirmationStore: confirmation)
        try confirmation.writeRecord(for: pairing)

        let appConfig = AppConfig(confirmationStore: confirmation, store: store)
        XCTAssertTrue(appConfig.journalSendConfirmed)
        XCTAssertTrue(confirmation.allowsSend(pairing: pairing))
    }

    @MainActor
    func testHeldStaysHeldAcrossRebuildsAndSecondSettleDoesNotConfirm() async throws {
        let pairing = makePairing()
        // Marker is present (applied), but record is absent (held)
        let fake = DurabilityKeychainFake(pairing: pairing, marker: true)
        let confirmation1 = fake.makeConfirmationStore()
        let store1 = fake.makeCredentialStore(confirmationStore: confirmation1)

        let appConfig1 = AppConfig(confirmationStore: confirmation1, store: store1)
        XCTAssertFalse(appConfig1.journalSendConfirmed)
        XCTAssertFalse(confirmation1.allowsSend(pairing: pairing))

        // Second settle
        let retryResult = appConfig1.retrySettleIfNeeded()
        XCTAssertFalse(retryResult)
        XCTAssertFalse(appConfig1.journalSendConfirmed)

        // Rebuild 2
        let confirmation2 = fake.makeConfirmationStore()
        let store2 = fake.makeCredentialStore(confirmationStore: confirmation2)
        let appConfig2 = AppConfig(confirmationStore: confirmation2, store: store2)
        XCTAssertFalse(appConfig2.journalSendConfirmed)
        XCTAssertFalse(confirmation2.allowsSend(pairing: pairing))

        // Rebuild 3
        let confirmation3 = fake.makeConfirmationStore()
        let store3 = fake.makeCredentialStore(confirmationStore: confirmation3)
        let appConfig3 = AppConfig(confirmationStore: confirmation3, store: store3)
        XCTAssertFalse(appConfig3.journalSendConfirmed)
        XCTAssertFalse(confirmation3.allowsSend(pairing: pairing))

        // Resolver returns held
        let resolver = LoopbackTransferEndpointResolver(credentials: store3, confirmation: confirmation3)
        await resolver.update(activeLocalPort: 7071)
        let res = await resolver.resolve(TransferEndpointDescriptor(destinationKind: .observerIngest, path: "/app/devices/ingest"))
        if case .unavailable(let reason) = res {
            XCTAssertEqual(reason, "journal-send-held")
        } else {
            XCTFail("Expected .unavailable(journal-send-held), got \(res)")
        }
    }

    @MainActor
    func testConfirmedPairingStaysConfirmedAcrossRebuild() throws {
        let pairing = makePairing()
        guard let key = journalSendConfirmationKey(for: pairing) else {
            return XCTFail("Unable to derive confirmation key")
        }
        let fake = DurabilityKeychainFake(pairing: pairing, record: key, marker: true)

        let confirmation1 = fake.makeConfirmationStore()
        let store1 = fake.makeCredentialStore(confirmationStore: confirmation1)
        let appConfig1 = AppConfig(confirmationStore: confirmation1, store: store1)

        XCTAssertTrue(appConfig1.journalSendConfirmed)
        XCTAssertTrue(confirmation1.allowsSend(pairing: pairing))

        // Rebuild
        let confirmation2 = fake.makeConfirmationStore()
        let store2 = fake.makeCredentialStore(confirmationStore: confirmation2)
        let appConfig2 = AppConfig(confirmationStore: confirmation2, store: store2)

        XCTAssertTrue(appConfig2.journalSendConfirmed)
        XCTAssertTrue(confirmation2.allowsSend(pairing: pairing))
    }

    @MainActor
    func testMarkerWriteFailureOnFirstPairingLeavesUnconfirmed() throws {
        let pairing = makePairing()
        let fake = DurabilityKeychainFake()
        let confirmation = fake.makeConfirmationStore()
        let store = fake.makeCredentialStore(confirmationStore: confirmation)
        let appConfig = AppConfig(confirmationStore: confirmation, store: store)

        fake.failNextMarkerWrite = true
        XCTAssertThrowsError(try appConfig.applyPairing(pairing))
        XCTAssertEqual(fake.pairingSaveCount, 0)

        // Rebuild plus settle does not confirm
        let confirmation2 = fake.makeConfirmationStore()
        let store2 = fake.makeCredentialStore(confirmationStore: confirmation2)
        let appConfig2 = AppConfig(confirmationStore: confirmation2, store: store2)
        XCTAssertFalse(appConfig2.journalSendConfirmed)
    }

    @MainActor
    func testMarkerWriteFailureOnRePairLeavesPreviousPairingHeld() throws {
        let p1 = makePairing(id: "inst-1")
        let p2 = makePairing(id: "inst-2")
        let fake = DurabilityKeychainFake(pairing: p1, marker: true)

        let confirmation1 = fake.makeConfirmationStore()
        let store1 = fake.makeCredentialStore(confirmationStore: confirmation1)

        fake.failNextMarkerWrite = true
        XCTAssertThrowsError(try store1.applyPairing(p2))
        XCTAssertEqual(fake.pairing, p1)

        // Rebuild plus settle: held, not confirmed, allowsSend false
        let confirmation2 = fake.makeConfirmationStore()
        let store2 = fake.makeCredentialStore(confirmationStore: confirmation2)
        let appConfig2 = AppConfig(confirmationStore: confirmation2, store: store2)
        XCTAssertFalse(appConfig2.journalSendConfirmed)
        XCTAssertFalse(confirmation2.allowsSend(pairing: p1))
    }

    @MainActor
    func testStoreApplyPairingSucceedsThenAppConfigApplyPairingFailsMarkerWriteLeavesHeld() throws {
        let p1 = makePairing(id: "inst-1")
        let p2 = makePairing(id: "inst-2")
        let fake = DurabilityKeychainFake(pairing: p1, marker: true)

        let confirmation1 = fake.makeConfirmationStore()
        let store1 = fake.makeCredentialStore(confirmationStore: confirmation1)
        let appConfig1 = AppConfig(confirmationStore: confirmation1, store: store1)

        // First store.applyPairing of P2 succeeds
        try store1.applyPairing(p2)
        XCTAssertEqual(fake.pairing, p2)
        XCTAssertTrue(fake.marker)

        // Then AppConfig.applyPairing of P2 fails its marker write
        fake.failNextMarkerWrite = true
        XCTAssertThrowsError(try appConfig1.applyPairing(p2))
        XCTAssertEqual(fake.pairing, p2)
        XCTAssertTrue(fake.marker)

        // Rebuild plus settle: held, not grandfathered
        let confirmation2 = fake.makeConfirmationStore()
        let store2 = fake.makeCredentialStore(confirmationStore: confirmation2)
        let appConfig2 = AppConfig(confirmationStore: confirmation2, store: store2)
        XCTAssertFalse(appConfig2.journalSendConfirmed)
        XCTAssertFalse(confirmation2.allowsSend(pairing: p2))
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
        let policy = SPLRuntime.keychainPolicy
        XCTAssertEqual(attrs[kSecAttrAccessible as String] as? String, policy.accessibility.secAttrValue as String)
        let policyBaseQuery = policy.baseQuery()
        XCTAssertEqual(attrs[kSecAttrSynchronizable as String] as? Bool, policyBaseQuery[kSecAttrSynchronizable as String] as? Bool)
        XCTAssertEqual(attrs[kSecAttrService as String] as? String, "app.solstone.swift.journal-send")
        XCTAssertEqual(attrs[kSecAttrAccount as String] as? String, "confirmation")
        if let accessGroup = policy.accessGroup {
            XCTAssertEqual(attrs[kSecAttrAccessGroup as String] as? String, accessGroup)
        } else {
            XCTAssertNil(attrs[kSecAttrAccessGroup as String])
        }
    }
}
