// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest
import SPLTunnel
@testable import solstone_swift

private final class StoredHolder: @unchecked Sendable {
    var stored: StoredPairing?
    var shouldThrowOnSave = false
    init(_ stored: StoredPairing? = nil) {
        self.stored = stored
    }
}

private struct TestSaveError: Error {}

final class PairingCredentialStoreTests: XCTestCase {
    private var testKeychainStores: [SPLKeychainStore] = []

    override func tearDown() {
        for store in testKeychainStores {
            _ = try? store.delete()
        }
        testKeychainStores.removeAll()
        super.tearDown()
    }

    private func makeRealKeychainStore() -> (PairingCredentialStore, SPLKeychainStore) {
        let service = "app.solstone.swift.test.\(UUID().uuidString)"
        let keychain = SPLKeychainStore(
            policy: KeychainPolicy(
                service: service,
                account: "pairing",
                accessGroup: nil,
                useDataProtectionKeychain: false,
                accessibility: .afterFirstUnlock
            )
        )
        testKeychainStores.append(keychain)
        let store = PairingCredentialStore(
            loadPairing: { try keychain.load() },
            savePairing: { try keychain.save($0) },
            deletePairing: { try keychain.delete() }
        )
        return (store, keychain)
    }

    private func makeSamplePairing(
        instanceID: String = "test-instance",
        relayEnrollment: RelayEnrollment = .unavailable
    ) -> StoredPairing {
        StoredPairing(
            instanceID: instanceID,
            homeLabel: "Alice Journal",
            relayEndpoint: "https://relay.example.com",
            fingerprint: "0123456789abcdef",
            clientCertPEM: CertlessTrustFixtures.leafPEM,
            clientKeyPEM: "KEY",
            caChainPEM: CertlessTrustFixtures.caPEM,
            relayEnrollment: relayEnrollment,
            localEndpoints: [LocalEndpoint(host: "192.168.1.100", port: 7071, scope: "local")],
            pairedAt: Date()
        )
    }

    func testRealKeychainStoreLifecycle() throws {
        let (store, _) = makeRealKeychainStore()

        XCTAssertEqual(store.pairingGeneration, 0)
        XCTAssertEqual(store.accessMutationGeneration, 0)

        let pairing1 = makeSamplePairing(instanceID: "real-inst-1")
        try store.applyPairing(pairing1)

        XCTAssertEqual(store.pairingGeneration, 1)
        XCTAssertEqual(store.accessMutationGeneration, 1)
        XCTAssertEqual(try store.load()?.instanceID, "real-inst-1")

        // Same identity pairing does not bump generation
        try store.applyPairing(pairing1)
        XCTAssertEqual(store.pairingGeneration, 1)
        XCTAssertEqual(store.accessMutationGeneration, 1)

        let committed = try store.commitReadyAccess(
            relayOrigin: "https://relay.example.com",
            deviceToken: "real-token",
            expiresAt: "2026-01-01T00:00:00Z",
            pairingGen: 1,
            mutationGen: 1
        )
        XCTAssertTrue(committed)
        XCTAssertEqual(store.accessMutationGeneration, 2)
        if case .enrolled(let token, _) = try store.load()?.relayEnrollment {
            XCTAssertEqual(token, "real-token")
        } else {
            XCTFail("Expected enrolled")
        }

        let disabled = try store.disableRelayAccess(pairingGen: 1, mutationGen: 2)
        XCTAssertTrue(disabled)
        XCTAssertEqual(store.accessMutationGeneration, 3)
        XCTAssertEqual(try store.load()?.relayEnrollment, .unavailable)

        let revoked = try store.revokeIfCurrentGeneration(pairingGen: 1)
        XCTAssertTrue(revoked)
        XCTAssertNil(try store.load())
    }

    func testSaveFailureLeavesLiveRelayDisabledTrueAndFailsCAS() throws {
        let holder = StoredHolder(makeSamplePairing(
            instanceID: "inst-1",
            relayEnrollment: .enrolled(deviceToken: "tok-1", expiresAt: nil)
        ))
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: {
                if holder.shouldThrowOnSave {
                    throw TestSaveError()
                }
                holder.stored = $0
            },
            deletePairing: { holder.stored = nil }
        )

        let pairGen = store.pairingGeneration
        let mutGen = store.accessMutationGeneration

        holder.shouldThrowOnSave = true
        XCTAssertThrowsError(try store.disableRelayAccess(pairingGen: pairGen, mutationGen: mutGen))

        // Overlay is set to true immediately even though disk save failed
        XCTAssertTrue(store.isLiveRelayDisabled)
        // Mutation generation not bumped
        XCTAssertEqual(store.accessMutationGeneration, mutGen)

        // Retry succeeds when save stops throwing
        holder.shouldThrowOnSave = false
        let retrySucceeded = try store.disableRelayAccess(pairingGen: pairGen, mutationGen: mutGen)
        XCTAssertTrue(retrySucceeded)
        XCTAssertEqual(store.accessMutationGeneration, mutGen + 1)
        XCTAssertEqual(holder.stored?.relayEnrollment, .unavailable)
    }

    func testRetryOfDurableClearIgnoredIfInterveningReadyCommit() throws {
        let holder = StoredHolder(makeSamplePairing(
            instanceID: "inst-1",
            relayEnrollment: .enrolled(deviceToken: "tok-1", expiresAt: nil)
        ))
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: {
                if holder.shouldThrowOnSave {
                    throw TestSaveError()
                }
                holder.stored = $0
            },
            deletePairing: { holder.stored = nil }
        )

        let pairGen = store.pairingGeneration
        let failedClearMutGen = store.accessMutationGeneration

        // 1. Clear fails
        holder.shouldThrowOnSave = true
        XCTAssertThrowsError(try store.disableRelayAccess(pairingGen: pairGen, mutationGen: failedClearMutGen))
        XCTAssertTrue(store.isLiveRelayDisabled)

        // 2. Intervening ready commit arrives and succeeds
        holder.shouldThrowOnSave = false
        let readyCommitted = try store.commitReadyAccess(
            relayOrigin: "https://new-relay.example.com",
            deviceToken: "new-token",
            expiresAt: nil,
            pairingGen: pairGen,
            mutationGen: failedClearMutGen
        )
        XCTAssertTrue(readyCommitted)
        XCTAssertFalse(store.isLiveRelayDisabled)
        XCTAssertEqual(store.accessMutationGeneration, failedClearMutGen + 1)

        // 3. Stale retry with failedClearMutGen is ignored
        let staleRetrySucceeded = try store.disableRelayAccess(pairingGen: pairGen, mutationGen: failedClearMutGen)
        XCTAssertFalse(staleRetrySucceeded)
        if case .enrolled(let token, _) = holder.stored?.relayEnrollment {
            XCTAssertEqual(token, "new-token")
        } else {
            XCTFail("Expected new-token to remain intact")
        }
    }

    func testStaleRevokeLeavesDiskAlone() throws {
        let holder = StoredHolder(makeSamplePairing(instanceID: "inst-1"))
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let initialGen = store.pairingGeneration
        let staleRevoked = try store.revokeIfCurrentGeneration(pairingGen: initialGen + 99)
        XCTAssertFalse(staleRevoked)
        XCTAssertNotNil(holder.stored)
    }
}
