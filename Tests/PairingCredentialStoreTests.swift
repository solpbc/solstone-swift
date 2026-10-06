// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest
import SPLTunnel
@testable import solstone_swift

private final class StoredHolder: @unchecked Sendable {
    var stored: StoredPairing?
    var shouldThrowOnSave = false
    var shouldThrowOnLoad = false
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
            confirmationStore: JournalSendConfirmationStore.memory(),
            loadPairing: { try keychain.load() },
            savePairing: { try keychain.save($0) },
            deletePairing: { try keychain.delete() }
        )
        return (store, keychain)
    }

    private func makeStore(
        holder: StoredHolder,
        confirmationStore: JournalSendConfirmationStore = JournalSendConfirmationStore.memory(),
        migrationStore: DeviceMigrationStore = .memory(),
        deletePushKey: (@Sendable () throws -> Void)? = nil
    ) -> PairingCredentialStore {
        PairingCredentialStore(
            confirmationStore: confirmationStore,
            migrationStore: migrationStore,
            loadPairing: {
                if holder.shouldThrowOnLoad { throw TestSaveError() }
                return holder.stored
            },
            savePairing: {
                if holder.shouldThrowOnSave {
                    throw TestSaveError()
                }
                holder.stored = $0
            },
            deletePairing: { holder.stored = nil },
            deletePushKey: deletePushKey ?? {}
        )
    }

    func testUnlockReloadRecoversUnchangedDurableOwnerAndFailsClosedWhileStorageUnavailable() throws {
        let pairing = self.makeSamplePairing()
        let holder = StoredHolder(pairing)
        let persistence = MigrationTestPersistence()
        let migration = DeviceMigrationStore(persistence: persistence)
        let ownerID = try migration.claimExistingPairing(pairing)
        holder.shouldThrowOnLoad = true
        let store = self.makeStore(holder: holder, migrationStore: migration)
        XCTAssertNil(store.snapshot().pairing)
        XCTAssertNil(store.snapshot().deviceOwnerID)
        holder.shouldThrowOnLoad = false
        persistence.setReadFailure(true)
        XCTAssertThrowsError(try store.reloadPairingFromKeychain())
        XCTAssertNil(store.snapshot().pairing)
        XCTAssertNil(store.snapshot().deviceOwnerID)
        persistence.setReadFailure(false)
        XCTAssertEqual(try store.reloadPairingFromKeychain(), pairing)
        XCTAssertEqual(store.snapshot().deviceOwnerID, ownerID)
        XCTAssertEqual(try migration.claimExistingPairing(pairing), ownerID)
        XCTAssertTrue(try migration.owns(ownerID: ownerID, pairing: pairing))
        XCTAssertEqual(holder.stored, pairing)
    }

    private func makeSamplePairing(
        instanceID: String = "test-instance",
        fingerprint: String = "0123456789abcdef",
        relayEnrollment: RelayEnrollment = .unavailable
    ) -> StoredPairing {
        StoredPairing(
            instanceID: instanceID,
            homeLabel: "Alice Journal",
            relayEndpoint: "https://relay.example.com",
            fingerprint: fingerprint,
            clientCertPEM: CertlessTrustFixtures.leafPEM,
            clientKeyPEM: "KEY",
            caChainPEM: CertlessTrustFixtures.caPEM,
            relayEnrollment: relayEnrollment,
            localEndpoints: [LocalEndpoint(host: "192.168.1.100", port: 7071, scope: "local")],
            pairedAt: Date(timeIntervalSince1970: 1_700_000_000)
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
            expiresAt: "2036-01-01T00:00:00Z",
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
    @MainActor
    func testQueuedStaleSaveAndDeleteCannotChangeReplacementKeychain() async throws {
        let (_, keychain) = makeRealKeychainStore()
        let original = makeSamplePairing(instanceID: "original")
        let replacement = makeSamplePairing(instanceID: "replacement")
        try keychain.save(original)
        let entered = expectation(description: "replacement save entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let store = PairingCredentialStore(
            loadPairing: { try keychain.load() },
            savePairing: { pairing in
                if pairing.instanceID == "replacement" {
                    entered.fulfill()
                    guard release.wait(timeout: .now() + 5) == .success else { throw TestSaveError() }
                }
                try keychain.save(pairing)
            },
            deletePairing: { try keychain.delete() }
        )
        let apply = Task.detached { try store.applyPairing(replacement) }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(store.snapshot().pairing, original)
        let ready = Task {
            try await store.commitReadyAccess(relayOrigin: "https://relay.example.com", deviceToken: "stale",
                expiresAt: nil, pairingGen: 0, mutationGen: 0)
        }
        let revoke = Task { try await store.revokeIfCurrentGeneration(pairingGen: 0, mutationGen: 0) }
        try await Task.sleep(for: .milliseconds(50))
        release.signal()
        try await apply.value
        let didSave = try await ready.value
        let didDelete = try await revoke.value
        XCTAssertFalse(didSave)
        XCTAssertFalse(didDelete)
        XCTAssertEqual(try keychain.load(), replacement)
        XCTAssertEqual(store.snapshot().pairing, replacement)
    }

    @MainActor
    func testCancelledQueuedReadyCannotWriteKeychainAfterOwnedSaveFinishes() async throws {
        let (_, keychain) = makeRealKeychainStore()
        try keychain.save(makeSamplePairing())
        let entered = expectation(description: "first save entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let store = PairingCredentialStore(
            loadPairing: { try keychain.load() },
            savePairing: { pairing in
                if case .enrolled("first", _) = pairing.relayEnrollment {
                    entered.fulfill()
                    guard release.wait(timeout: .now() + 5) == .success else { throw TestSaveError() }
                }
                try keychain.save(pairing)
            },
            deletePairing: { try keychain.delete() }
        )
        let first = Task {
            try await store.commitReadyAccess(relayOrigin: "https://relay.example.com", deviceToken: "first",
                expiresAt: nil, pairingGen: 0, mutationGen: 0)
        }
        await fulfillment(of: [entered], timeout: 2)
        let cancelled = Task {
            try await store.commitReadyAccess(relayOrigin: "https://relay.example.com", deviceToken: "cancelled",
                expiresAt: nil, pairingGen: 0, mutationGen: 0)
        }
        try await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()
        release.signal()
        let firstResult = try await first.value
        let cancelledResult = try await cancelled.value
        XCTAssertTrue(firstResult)
        XCTAssertFalse(cancelledResult)
        XCTAssertEqual(try keychain.load()?.relayEnrollment, .enrolled(deviceToken: "first", expiresAt: nil))
        XCTAssertEqual(store.snapshot().pairing, try keychain.load())
    }

    @MainActor
    func testReadyExpiryIsCheckedAfterWaitingForClearRetryOwner() async throws {
        let (_, keychain) = makeRealKeychainStore()
        try keychain.save(makeSamplePairing(relayEnrollment: .enrolled(deviceToken: "old", expiresAt: nil)))
        let entered = expectation(description: "retry save entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let saveCount = StoreTestCounter()
        let store = PairingCredentialStore(
            loadPairing: { try keychain.load() },
            savePairing: { pairing in
                let count = saveCount.next()
                if count == 1 { throw TestSaveError() }
                if count == 2 {
                    entered.fulfill()
                    guard release.wait(timeout: .now() + 5) == .success else { throw TestSaveError() }
                }
                try keychain.save(pairing)
            },
            deletePairing: { try keychain.delete() }
        )
        do {
            _ = try await store.disableRelayAccess(pairingGen: 0, mutationGen: 0)
            XCTFail("clear should fail")
        } catch {}
        let retry = Task { try await store.retryDurableClear(pairingGen: 0, mutationGen: 1) }
        await fulfillment(of: [entered], timeout: 2)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiry = formatter.string(from: Date().addingTimeInterval(0.15))
        let ready = Task {
            try await store.commitReadyAccess(relayOrigin: "https://relay.example.com", deviceToken: "expired",
                expiresAt: expiry, pairingGen: 0, mutationGen: 1)
        }
        try await Task.sleep(for: .milliseconds(250))
        release.signal()
        let retried = try await retry.value
        let committed = try await ready.value
        XCTAssertTrue(retried)
        XCTAssertFalse(committed)
        XCTAssertEqual(saveCount.value, 2)
        XCTAssertEqual(try keychain.load()?.relayEnrollment, .unavailable)
        XCTAssertTrue(store.isLiveRelayDisabled)
    }

    func testAcceptedRefreshAdvancesRevisionAndRejectsOlderReadyAndRevoke() async throws {
        let (store, keychain) = makeRealKeychainStore()
        let pairing = makeSamplePairing()
        try store.applyPairing(pairing)
        let updated = makeSamplePairing(relayEnrollment: .enrolled(deviceToken: "refreshed", expiresAt: nil))
        let refreshed = try await store.persistRefreshedPairing(updated, pairingGen: 1, mutationGen: 1)
        XCTAssertTrue(refreshed)
        XCTAssertEqual(store.accessMutationGeneration, 2)
        let ready = try await store.commitReadyAccess(relayOrigin: "https://relay.example.com", deviceToken: "old",
            expiresAt: nil, pairingGen: 1, mutationGen: 1)
        let revoked = try await store.revokeIfCurrentGeneration(pairingGen: 1, mutationGen: 1)
        XCTAssertFalse(ready)
        XCTAssertFalse(revoked)
        XCTAssertEqual(try keychain.load(), updated)
    }

    func testDeletePushKeyCalledOnClearPairing() throws {
        let holder = StoredHolder(makeSamplePairing())
        let deletePushKeyCount = StoreTestCounter()
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil },
            deletePushKey: { _ = deletePushKeyCount.next() }
        )

        try store.clearPairing()
        XCTAssertEqual(deletePushKeyCount.value, 1)
        XCTAssertNil(holder.stored)
    }

    func testDeletePushKeyCalledOnFingerprintChange() throws {
        let holder = StoredHolder(makeSamplePairing(instanceID: "inst-1"))
        let deletePushKeyCount = StoreTestCounter()
        let store = PairingCredentialStore(
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil },
            deletePushKey: { _ = deletePushKeyCount.next() }
        )

        var pairing2 = makeSamplePairing(instanceID: "inst-2")
        pairing2 = StoredPairing(
            instanceID: pairing2.instanceID,
            homeLabel: pairing2.homeLabel,
            relayEndpoint: pairing2.relayEndpoint,
            fingerprint: "different-fingerprint",
            clientCertPEM: pairing2.clientCertPEM,
            clientKeyPEM: pairing2.clientKeyPEM,
            caChainPEM: pairing2.caChainPEM,
            relayEnrollment: pairing2.relayEnrollment,
            localEndpoints: pairing2.localEndpoints,
            pairedAt: pairing2.pairedAt
        )

        try store.applyPairing(pairing2)
        XCTAssertEqual(deletePushKeyCount.value, 1)
    }

    func testDeletePushKeyNotCalledOnSameFingerprint() throws {
        let pairing = makeSamplePairing(instanceID: "inst-1")
        let holder = StoredHolder(pairing)
        let deletePushKeyCount = StoreTestCounter()
        let store = PairingCredentialStore(
            confirmationStore: JournalSendConfirmationStore.memory(),
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil },
            deletePushKey: { _ = deletePushKeyCount.next() }
        )

        try store.applyPairing(pairing)
        XCTAssertEqual(deletePushKeyCount.value, 0)
    }

    func testPairingFlowLeasePreventsLateResponseFromReplacingNewFlow() throws {
        let holder = StoredHolder(nil)
        let store = makeStore(holder: holder)
        let oldResponse = makeSamplePairing(instanceID: "old-flow")
        let newerResponse = makeSamplePairing(instanceID: "new-flow")

        let oldLease = try store.beginPairingFlow()
        let currentLease = try store.beginPairingFlow()
        XCTAssertThrowsError(try store.applyPairing(oldResponse, ifPairingFlowLease: oldLease))
        XCTAssertNil(holder.stored)

        try store.applyPairing(newerResponse, ifPairingFlowLease: currentLease)
        XCTAssertEqual(holder.stored?.instanceID, "new-flow")
    }

    func testPairingFlowLeaseRemainsOwnedAfterItsCommitUntilAnotherFlowStarts() throws {
        let holder = StoredHolder(nil)
        let store = makeStore(holder: holder)
        let lease = try store.beginPairingFlow()

        try store.applyPairing(
            makeSamplePairing(instanceID: "committed-flow", fingerprint: "committed-cid"),
            ifPairingFlowLease: lease
        )
        XCTAssertTrue(try store.migrationStore.ownsPairingFlowLease(lease))

        let nextLease = try store.beginPairingFlow()
        XCTAssertFalse(try store.migrationStore.ownsPairingFlowLease(lease))
        XCTAssertTrue(try store.migrationStore.ownsPairingFlowLease(nextLease))
    }

    func testPairingInvalidationCompareAndSetRejectsReplacedCredentialOwner() throws {
        let holder = StoredHolder(nil)
        let store = makeStore(holder: holder)
        try store.applyPairing(makeSamplePairing(instanceID: "same-journal", fingerprint: "old-cid"))
        let old = store.snapshot()
        let oldOwner = try XCTUnwrap(old.deviceOwnerID)
        try store.applyPairing(makeSamplePairing(instanceID: "same-journal", fingerprint: "fresh-cid"))
        let fresh = store.snapshot()

        XCTAssertThrowsError(try store.beginPairingInvalidation(
            expectedOwnerID: oldOwner,
            expectedPairingGeneration: old.pairingGeneration
        ))
        XCTAssertEqual(fresh, store.snapshot())
        XCTAssertEqual(store.snapshot().pairing?.fingerprint, "fresh-cid")
        XCTAssertTrue(store.hasActiveOwner)
    }

    func testCancelledPairingFlowDoesNotDurablyApplyResponse() throws {
        let holder = StoredHolder(nil)
        let store = makeStore(holder: holder)
        let lease = try store.beginPairingFlow()

        XCTAssertThrowsError(try store.applyPairing(
            makeSamplePairing(instanceID: "cancelled-flow"),
            ifPairingFlowLease: lease,
            shouldCommit: { false }
        ))
        XCTAssertNil(holder.stored)
        XCTAssertNil(store.snapshot().deviceOwnerID)
    }

    func testApplyPairingWithNoStoredPairingCallsDeletePushKey() throws {
        let holder = StoredHolder(nil)
        let deletePushKeyCount = StoreTestCounter()
        let store = PairingCredentialStore(
            confirmationStore: JournalSendConfirmationStore.memory(),
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil },
            deletePushKey: { _ = deletePushKeyCount.next() }
        )

        let pairing = makeSamplePairing(instanceID: "inst-1")
        try store.applyPairing(pairing)
        XCTAssertEqual(deletePushKeyCount.value, 1)
    }

    func testThrownDeletePushKeyKeepsInvalidationFencedUntilColdCleanupRetry() throws {
        let holder = StoredHolder(makeSamplePairing())
        let migration = DeviceMigrationStore.memory()
        let deletePushKeyCount = StoreTestCounter()
        let deletePushKey: @Sendable () throws -> Void = {
            if deletePushKeyCount.next() == 1 { throw NSError(domain: "TestError", code: -1) }
        }
        let store = PairingCredentialStore(
            confirmationStore: JournalSendConfirmationStore.memory(),
            migrationStore: migration,
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil },
            deletePushKey: deletePushKey
        )

        XCTAssertThrowsError(try store.clearPairing())
        XCTAssertNil(holder.stored)
        XCTAssertFalse(store.hasActiveOwner)
        XCTAssertNotNil(try migration.resumeInvalidation())
        let recovered = PairingCredentialStore(
            confirmationStore: JournalSendConfirmationStore.memory(),
            migrationStore: migration,
            loadPairing: { holder.stored },
            savePairing: { holder.stored = $0 },
            deletePairing: { holder.stored = nil },
            deletePushKey: deletePushKey
        )
        XCTAssertNil(recovered.snapshot().pairing)
        try recovered.clearPairing()
        XCTAssertNil(try migration.resumeInvalidation())
        XCTAssertNil(recovered.snapshot().pairing)
        XCTAssertFalse(recovered.hasActiveOwner)
    }

    func testPersistRefreshedPairingAndCommitReadyAccessKeepConfirmationRecord() async throws {
        let holder = StoredHolder()
        let confirmation = JournalSendConfirmationStore.memory()
        let store = makeStore(holder: holder, confirmationStore: confirmation)
        let pairing = makeSamplePairing()
        try store.applyPairing(pairing)
        try confirmation.writeRecord(for: pairing)
        XCTAssertTrue(confirmation.allowsSend(pairing: pairing))

        let refreshed = makeSamplePairing(relayEnrollment: .enrolled(deviceToken: "refreshed-tok", expiresAt: nil))
        let okRefresh = try await store.persistRefreshedPairing(refreshed, pairingGen: 1, mutationGen: 1)
        XCTAssertTrue(okRefresh)
        XCTAssertTrue(confirmation.allowsSend(pairing: refreshed))

        let okReady = try await store.commitReadyAccess(
            relayOrigin: "https://relay.example.com",
            deviceToken: "ready-tok",
            expiresAt: nil,
            pairingGen: 1,
            mutationGen: 2
        )
        XCTAssertTrue(okReady)
        XCTAssertTrue(confirmation.allowsSend(pairing: store.snapshot().pairing))
    }

    func testClearPairingAndRevokeIfCurrentGenerationDeleteConfirmationRecordAndLeaveMarker() async throws {
        let holder = StoredHolder()
        let confirmation = JournalSendConfirmationStore.memory()
        let store = makeStore(holder: holder, confirmationStore: confirmation)
        let pairing = makeSamplePairing()
        try store.applyPairing(pairing)
        try confirmation.writeRecord(for: pairing)
        XCTAssertTrue(confirmation.allowsSend(pairing: pairing))

        // Revoke deletes the record
        let okRevoke = try await store.revokeIfCurrentGeneration(pairingGen: 1, mutationGen: 1)
        XCTAssertTrue(okRevoke)
        XCTAssertFalse(confirmation.allowsSend(pairing: pairing))

        // Re-apply and confirm
        try store.applyPairing(pairing)
        try confirmation.writeRecord(for: pairing)
        XCTAssertTrue(confirmation.allowsSend(pairing: pairing))

        // Clear pairing deletes the record
        try store.clearPairing()
        XCTAssertFalse(confirmation.allowsSend(pairing: pairing))
    }
}


private final class StoreTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
    var value: Int { lock.withLock { count } }
}
