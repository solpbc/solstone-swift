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

    func testRealKeychainStoreLifecycle() async throws {
        let (store, _) = makeRealKeychainStore()

        XCTAssertEqual(store.pairingGeneration, 0)
        XCTAssertEqual(store.accessMutationGeneration, 0)

        let pairing1 = makeSamplePairing(instanceID: "real-inst-1")
        try store.applyPairing(pairing1)

        XCTAssertEqual(store.pairingGeneration, 1)
        XCTAssertEqual(store.accessMutationGeneration, 1)
        XCTAssertEqual(try store.load()?.instanceID, "real-inst-1")

        // Same identity pairing always bumps generations on applyPairing
        try store.applyPairing(pairing1)
        XCTAssertEqual(store.pairingGeneration, 2)
        XCTAssertEqual(store.accessMutationGeneration, 2)

        let committed = try await store.commitReadyAccess(
            relayOrigin: "https://relay.example.com",
            deviceToken: "real-token",
            expiresAt: "2026-01-01T00:00:00Z",
            pairingGen: 2,
            mutationGen: 2
        )
        XCTAssertTrue(committed)
        XCTAssertEqual(store.accessMutationGeneration, 3)
        if case .enrolled(let token, _) = try store.load()?.relayEnrollment {
            XCTAssertEqual(token, "real-token")
        } else {
            XCTFail("Expected enrolled")
        }

        let disabled = try await store.disableRelayAccess(pairingGen: 2, mutationGen: 3)
        XCTAssertTrue(disabled)
        XCTAssertEqual(store.accessMutationGeneration, 4)
        XCTAssertEqual(try store.load()?.relayEnrollment, .unavailable)

        let revoked = try await store.revokeIfCurrentGeneration(pairingGen: 2, mutationGen: 4)
        XCTAssertTrue(revoked)
        XCTAssertNil(try store.load())
    }

    func testSaveFailureLeavesLiveRelayDisabledTrueAndBumpsMutationAndSetsFailedClear() async throws {
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
        do {
            _ = try await store.disableRelayAccess(pairingGen: pairGen, mutationGen: mutGen)
            XCTFail("Expected throw")
        } catch {
            // expected
        }

        // Overlay is set to true immediately even though disk save failed
        XCTAssertTrue(store.isLiveRelayDisabled)
        // Mutation generation IS bumped
        let newMutGen = mutGen + 1
        XCTAssertEqual(store.accessMutationGeneration, newMutGen)
        XCTAssertEqual(store.failedDurableClear, .uncommittedClear(pairingGen: pairGen, mutationGen: newMutGen))

        // Ready captured against old mutation fails CAS
        let oldReadyCommitted = try await store.commitReadyAccess(
            relayOrigin: "https://relay.example.com",
            deviceToken: "tok-old",
            expiresAt: nil,
            pairingGen: pairGen,
            mutationGen: mutGen
        )
        XCTAssertFalse(oldReadyCommitted)

        // Retry of durable clear with newMutGen succeeds when save stops throwing
        holder.shouldThrowOnSave = false
        let retrySucceeded = try await store.retryDurableClear(pairingGen: pairGen, mutationGen: newMutGen)
        XCTAssertTrue(retrySucceeded)
        XCTAssertNil(store.failedDurableClear)
        XCTAssertEqual(holder.stored?.relayEnrollment, .unavailable)
    }

    func testInterveningReadySupersedesFailedClearRetry() async throws {
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
        do {
            _ = try await store.disableRelayAccess(pairingGen: pairGen, mutationGen: mutGen)
            XCTFail("Expected throw")
        } catch {
            // expected
        }
        XCTAssertTrue(store.isLiveRelayDisabled)
        let failedClearMutGen = mutGen + 1
        XCTAssertEqual(store.accessMutationGeneration, failedClearMutGen)

        // Ready captured against the new disabled revision arrives and succeeds
        holder.shouldThrowOnSave = false
        let readyCommitted = try await store.commitReadyAccess(
            relayOrigin: "https://new-relay.example.com",
            deviceToken: "new-token",
            expiresAt: nil,
            pairingGen: pairGen,
            mutationGen: failedClearMutGen
        )
        XCTAssertTrue(readyCommitted)
        XCTAssertFalse(store.isLiveRelayDisabled)
        XCTAssertNil(store.failedDurableClear)
        XCTAssertEqual(store.accessMutationGeneration, failedClearMutGen + 1)

        // Stale retry against failedClearMutGen now fails CAS
        let staleRetrySucceeded = try await store.retryDurableClear(pairingGen: pairGen, mutationGen: failedClearMutGen)
        XCTAssertFalse(staleRetrySucceeded)
        if case .enrolled(let token, _) = holder.stored?.relayEnrollment {
            XCTAssertEqual(token, "new-token")
        } else {
            XCTFail("Expected new-token to remain intact")
        }
    }

    func testSameHomeApplyPairingBumpsGenerations() throws {
        let holder = StoredHolder()
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let pairing = makeSamplePairing(instanceID: "inst-1")
        try store.applyPairing(pairing)
        XCTAssertEqual(store.pairingGeneration, 1)
        XCTAssertEqual(store.accessMutationGeneration, 1)

        // Apply same pairing again
        try store.applyPairing(pairing)
        XCTAssertEqual(store.pairingGeneration, 2)
        XCTAssertEqual(store.accessMutationGeneration, 2)
    }

    func testRevokeIfCurrentGenerationCannotDeleteNewerReady() async throws {
        let holder = StoredHolder(makeSamplePairing(instanceID: "inst-1"))
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil }
        )

        let initialPairGen = store.pairingGeneration
        let initialMutGen = store.accessMutationGeneration

        // Ready commits and bumps mutationGen
        let committed = try await store.commitReadyAccess(
            relayOrigin: "https://relay.example.com",
            deviceToken: "tok-2",
            expiresAt: nil,
            pairingGen: initialPairGen,
            mutationGen: initialMutGen
        )
        XCTAssertTrue(committed)
        XCTAssertEqual(store.accessMutationGeneration, initialMutGen + 1)

        // Stale revoke attempt using initialMutGen fails CAS
        let staleRevoked = try await store.revokeIfCurrentGeneration(
            pairingGen: initialPairGen,
            mutationGen: initialMutGen
        )
        XCTAssertFalse(staleRevoked)
        XCTAssertNotNil(holder.stored)
    }

    func testReadySaveFailurePreservesUsableState() async throws {
        let sample = makeSamplePairing(instanceID: "inst-1")
        let holder = StoredHolder(sample)
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
        let committed = try await store.commitReadyAccess(
            relayOrigin: "https://relay.example.com",
            deviceToken: "tok-fail",
            expiresAt: nil,
            pairingGen: pairGen,
            mutationGen: mutGen
        )
        XCTAssertFalse(committed)
        XCTAssertEqual(store.accessMutationGeneration, mutGen)
        XCTAssertFalse(store.isLiveRelayDisabled)
        XCTAssertEqual(holder.stored?.instanceID, "inst-1")
    }
}

