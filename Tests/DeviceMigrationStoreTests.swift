// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation
import SPLTunnel
import XCTest
import os
@testable import solstone_swift

enum MigrationPersistenceTestError: Error {
    case read
    case write
}

final class MigrationPortableBacking: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: Data] = [:]

    func read(_ account: String) -> Data? { self.lock.withLock { self.records[account] } }
    func write(_ data: Data, account: String) { self.lock.withLock { self.records[account] = data } }
    func delete(_ account: String) { self.lock.withLock { self.records.removeValue(forKey: account) } }
}

final class MigrationTestPersistence: DeviceMigrationPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var device: [String: Data] = [:]
    private var mutationCount = 0
    private var failedMutation: Int?
    private var failReads = false
    private let portableBacking: MigrationPortableBacking

    init(portableBacking: MigrationPortableBacking = MigrationPortableBacking()) {
        self.portableBacking = portableBacking
    }

    func readDeviceRecord(account: String) throws -> Data? {
        try self.lock.withLock {
            if self.failReads { throw MigrationPersistenceTestError.read }
            return self.device[account]
        }
    }

    func writeDeviceRecord(_ data: Data, account: String) throws {
        try self.lock.withLock {
            try self.beforeMutation()
            self.device[account] = data
        }
    }

    func deleteDeviceRecord(account: String) throws {
        try self.lock.withLock {
            try self.beforeMutation()
            self.device.removeValue(forKey: account)
        }
    }

    func readPortableRecord(account: String) throws -> Data? {
        try self.lock.withLock {
            if self.failReads { throw MigrationPersistenceTestError.read }
            return self.portableBacking.read(account)
        }
    }

    func writePortableRecord(_ data: Data, account: String) throws {
        try self.lock.withLock {
            try self.beforeMutation()
            self.portableBacking.write(data, account: account)
        }
    }

    func deletePortableRecord(account: String) throws {
        try self.lock.withLock {
            try self.beforeMutation()
            self.portableBacking.delete(account)
        }
    }

    func failMutation(after successfulMutations: Int) {
        self.lock.withLock {
            self.failedMutation = self.mutationCount + successfulMutations + 1
        }
    }

    func allowMutations() {
        self.lock.withLock { self.failedMutation = nil }
    }

    func setReadFailure(_ fail: Bool) {
        self.lock.withLock { self.failReads = fail }
    }

    func rawPortable(account: String) -> Data? {
        self.lock.withLock { self.portableBacking.read(account) }
    }

    func rawDevice(account: String) -> Data? {
        self.lock.withLock { self.device[account] }
    }

    func replaceDevice(account: String, with data: Data?) {
        self.lock.withLock { self.device[account] = data }
    }

    func replacePortable(account: String, with data: Data?) {
        self.lock.withLock {
            if let data { self.portableBacking.write(data, account: account) }
            else { self.portableBacking.delete(account) }
        }
    }

    private func beforeMutation() throws {
        self.mutationCount += 1
        if self.failedMutation == self.mutationCount { throw MigrationPersistenceTestError.write }
    }
}

private enum MigrationAttemptTestError: Error {
    case unavailable
}

@MainActor
private final class MigrationAttemptRecorder: MigrationControlExchanging {
    private(set) var requestBodies: [Data] = []

    func postRekey(
        pairing: StoredPairing,
        candidates: [TransportEndpoint],
        body: Data,
        shouldContinue: @MainActor @Sendable () -> Bool,
        afterResponse: @MainActor @Sendable (Data) async throws -> Void
    ) async throws {
        guard shouldContinue() else { throw CancellationError() }
        self.requestBodies.append(body)
        throw MigrationAttemptTestError.unavailable
    }
}

final class DeviceMigrationStoreTests: XCTestCase {
    func testNoPairingFirstAdoptionInterruptedAdoptionAndMovedHardware() throws {
        let persistence = MigrationTestPersistence()
        let migration = DeviceMigrationStore(persistence: persistence)
        XCTAssertEqual(try migration.classify(pairing: nil), .noPairing)

        let pairing = Self.pairing(cidByte: "a")
        XCTAssertEqual(try migration.classify(pairing: pairing), .firstAdoption)
        let marker = try migration.prepareAdoption(pairing: pairing, includeFreshPairOffer: false)
        XCTAssertEqual(try migration.classify(pairing: pairing), .interruptedAdoption)
        try migration.finishAdoption(pairing: pairing, marker: marker)
        XCTAssertEqual(try migration.classify(pairing: pairing), .sameDevice)

        let portableIdentity = try DevicePairingIdentity.make(for: pairing)
        let restoredMarker = DeviceMigrationMarker.fresh()
        try migration.saveMarker(restoredMarker)
        XCTAssertEqual(try migration.classify(pairing: pairing), .movedDevice)
        XCTAssertNotEqual(restoredMarker.fingerprint, try XCTUnwrap(migration.loadPortable(for: portableIdentity).baseline).deviceMarkerFingerprint)

        persistence.replaceDevice(account: DeviceMigrationStore.deviceMarkerAccount, with: nil)
        XCTAssertEqual(try migration.classify(pairing: pairing), .movedDevice)
    }

    func testMissingUnavailableAndCorruptRecordsStayDistinctAndFailClosed() throws {
        let persistence = MigrationTestPersistence()
        let migration = DeviceMigrationStore(persistence: persistence)
        let pairing = Self.pairing(cidByte: "b")
        XCTAssertEqual(try migration.classify(pairing: pairing), .firstAdoption)

        persistence.setReadFailure(true)
        XCTAssertThrowsError(try migration.classify(pairing: pairing))
        persistence.setReadFailure(false)

        let identity = try DevicePairingIdentity.make(for: pairing)
        persistence.replacePortable(account: identity.account, with: Data("{corrupt".utf8))
        XCTAssertThrowsError(try migration.classify(pairing: pairing)) { error in
            XCTAssertEqual(error as? DeviceMigrationStoreError, .corruptRecord)
        }

        persistence.replacePortable(account: identity.account, with: nil)
        persistence.replaceDevice(account: DeviceMigrationStore.deviceMarkerAccount, with: Data("{corrupt".utf8))
        XCTAssertThrowsError(try migration.classify(pairing: pairing)) { error in
            XCTAssertEqual(error as? DeviceMigrationStoreError, .corruptRecord)
        }
    }

    func testInterruptedFirstAdoptionRetriesEveryDurableBoundaryOnSameDevice() throws {
        for failureOffset in 0..<4 {
            let persistence = MigrationTestPersistence()
            let migration = DeviceMigrationStore(persistence: persistence)
            let pairing = Self.pairing(cidByte: "6")
            persistence.failMutation(after: failureOffset)
            XCTAssertThrowsError(try migration.adopt(pairing: pairing, includeFreshPairOffer: false))
            persistence.allowMutations()

            XCTAssertTrue([.firstAdoption, .interruptedAdoption].contains(try migration.classify(pairing: pairing)))
            let marker = try migration.adopt(pairing: pairing, includeFreshPairOffer: false)
            XCTAssertEqual(try migration.classify(pairing: pairing), .sameDevice)
            XCTAssertEqual(try migration.loadPortable(for: DevicePairingIdentity.make(for: pairing)).baseline?.deviceMarkerFingerprint, marker.fingerprint)
        }
    }

    func testPendingCandidateAndExactRequestRemainDeviceOnly() throws {
        let persistence = MigrationTestPersistence()
        let migration = DeviceMigrationStore(persistence: persistence)
        let oldPairing = Self.pairing(cidByte: "c")
        let newPairing = Self.pairing(cidByte: "d")
        let marker = try migration.adopt(pairing: oldPairing, includeFreshPairOffer: false)
        let ownerID = try migration.claimExistingPairing(oldPairing)
        let migratingMarker = try migration.beginMigrationMarker(for: DevicePairingIdentity.make(for: oldPairing))
        XCTAssertEqual(marker.value, migratingMarker.value)

        let operationID = UUID()
        let request = Data(#"{"operation_id":"exact-request"}"#.utf8)
        let pending = PendingDeviceRekey(
            operationID: operationID,
            pairingOwnerID: ownerID,
            previousCID: oldPairing.fingerprint,
            csrPEM: "private csr material",
            privateKeyPEM: "private key material",
            requestBytes: request,
            responseBytes: nil
        )
        try migration.savePendingRekey(pending, ownerID: ownerID)
        try migration.stageMigration(
            from: oldPairing,
            to: newPairing,
            marker: migratingMarker,
            priorSendWasConfirmed: false,
            pairingOwnerID: ownerID
        )

        XCTAssertEqual(try migration.loadPendingRekey(ownerID: ownerID), pending)
        let identity = try DevicePairingIdentity.make(for: oldPairing)
        let portable = try XCTUnwrap(persistence.rawPortable(account: identity.account))
        let portableText = String(decoding: portable, as: UTF8.self)
        XCTAssertFalse(portableText.contains(operationID.uuidString))
        XCTAssertFalse(portableText.contains("private csr material"))
        XCTAssertFalse(portableText.contains("private key material"))
        XCTAssertFalse(portableText.contains(String(decoding: request, as: UTF8.self)))

        let firstCandidate = try CryptoCSR.generate(deviceLabel: "phone")
        let secondCandidate = try CryptoCSR.generate(deviceLabel: "phone")
        XCTAssertNotEqual(firstCandidate.privateKeyPEM, secondCandidate.privateKeyPEM)
        let firstOperationID = UUID()
        let secondOperationID = UUID()
        XCTAssertNotEqual(firstOperationID, secondOperationID)
    }

    @MainActor
    func testUnchangedPairingReplaysExactPostAndSecondRestoredDeviceCreatesNewCandidate() async throws {
        let portableBacking = MigrationPortableBacking()
        let pairing = Self.pairing(cidByte: "5")
        let firstMigrationStore = DeviceMigrationStore(
            persistence: MigrationTestPersistence(portableBacking: portableBacking)
        )
        _ = try firstMigrationStore.adopt(pairing: pairing, includeFreshPairOffer: false)
        let firstConfirmation = JournalSendConfirmationStore.memory()
        let firstCredentials = PairingCredentialStore(
            confirmationStore: firstConfirmation,
            migrationStore: firstMigrationStore,
            loadPairing: { pairing }
        )
        var movedMarker = DeviceMigrationMarker.fresh()
        movedMarker.adoption = .adopted(try DevicePairingIdentity.make(for: pairing))
        try firstMigrationStore.saveMarker(movedMarker)

        let firstControl = MigrationAttemptRecorder()
        let firstCoordinator = DeviceMigrationCoordinator(
            credentials: firstCredentials,
            confirmation: firstConfirmation,
            control: firstControl
        )
        let firstGeneration = firstCredentials.snapshot().pairingGeneration
        for _ in 0..<2 {
            do {
                try await firstCoordinator.prepareForOrdinaryAdmission(
                    pairing: pairing,
                    pairingGeneration: firstGeneration,
                    mayContinue: { firstCredentials.snapshot().pairingGeneration == firstGeneration }
                )
                XCTFail("expected migration control to remain unavailable")
            } catch is CancellationError {
                XCTFail("unexpected migration cancellation")
            } catch {
                // The pending request remains available for exact replay.
            }
        }
        let firstOwnerID = try XCTUnwrap(firstCredentials.snapshot().deviceOwnerID)
        let firstPending = try XCTUnwrap(firstMigrationStore.loadPendingRekey(ownerID: firstOwnerID))
        XCTAssertEqual(firstControl.requestBodies.count, 2)
        XCTAssertEqual(firstControl.requestBodies[0], firstControl.requestBodies[1])
        XCTAssertEqual(firstPending.requestBytes, firstControl.requestBodies[0])

        let secondMigrationStore = DeviceMigrationStore(
            persistence: MigrationTestPersistence(portableBacking: portableBacking)
        )
        let secondConfirmation = JournalSendConfirmationStore.memory()
        let secondCredentials = PairingCredentialStore(
            confirmationStore: secondConfirmation,
            migrationStore: secondMigrationStore,
            loadPairing: { pairing }
        )
        let secondControl = MigrationAttemptRecorder()
        let secondCoordinator = DeviceMigrationCoordinator(
            credentials: secondCredentials,
            confirmation: secondConfirmation,
            control: secondControl
        )
        let secondGeneration = secondCredentials.snapshot().pairingGeneration
        do {
            try await secondCoordinator.prepareForOrdinaryAdmission(
                pairing: pairing,
                pairingGeneration: secondGeneration,
                mayContinue: { secondCredentials.snapshot().pairingGeneration == secondGeneration }
            )
            XCTFail("expected restored-device migration control to remain unavailable")
        } catch is CancellationError {
            XCTFail("unexpected restored-device migration cancellation")
        } catch {
            // The second hardware has its own device-only candidate.
        }
        let secondOwnerID = try XCTUnwrap(secondCredentials.snapshot().deviceOwnerID)
        let secondPending = try XCTUnwrap(secondMigrationStore.loadPendingRekey(ownerID: secondOwnerID))
        XCTAssertNotEqual(firstPending.operationID, secondPending.operationID)
        XCTAssertNotEqual(firstPending.privateKeyPEM, secondPending.privateKeyPEM)
        XCTAssertNotEqual(firstPending.requestBytes, secondPending.requestBytes)
        XCTAssertEqual(secondControl.requestBodies, [secondPending.requestBytes])

        let identity = try DevicePairingIdentity.make(for: pairing)
        let portable = try secondMigrationStore.loadPortable(for: identity)
        let portableText = String(decoding: try JSONEncoder().encode(portable), as: UTF8.self)
        XCTAssertFalse(portableText.contains(firstPending.operationID.uuidString))
        XCTAssertFalse(portableText.contains(secondPending.operationID.uuidString))
    }

    func testMigrationCommitRetriesEveryDurableBoundaryWithoutLosingOldBaseline() throws {
        for failureOffset in 0..<7 {
            let persistence = MigrationTestPersistence()
            let migration = DeviceMigrationStore(persistence: persistence)
            let oldPairing = Self.pairing(cidByte: "e")
            let newPairing = Self.pairing(cidByte: "f")
            _ = try migration.adopt(pairing: oldPairing, includeFreshPairOffer: false)
            let ownerID = try migration.claimExistingPairing(oldPairing)
            let identity = try DevicePairingIdentity.make(for: oldPairing)
            let marker = try migration.beginMigrationMarker(for: identity)
            let operationID = UUID()
            try migration.savePendingRekey(PendingDeviceRekey(
                operationID: operationID,
                pairingOwnerID: ownerID,
                previousCID: oldPairing.fingerprint,
                csrPEM: "csr",
                privateKeyPEM: "key",
                requestBytes: Data("request".utf8),
                responseBytes: Data("response".utf8)
            ), ownerID: ownerID)
            try migration.stageMigration(
                from: oldPairing,
                to: newPairing,
                marker: marker,
                priorSendWasConfirmed: true,
                pairingOwnerID: ownerID
            )
            let oldBaseline = try XCTUnwrap(migration.loadPortable(for: identity).baseline)
            let holder = PairingSnapshotHolder(oldPairing)
            let credentials = PairingCredentialStore(
                confirmationStore: .memory(),
                migrationStore: migration,
                loadPairing: { holder.pairing },
                savePairing: { holder.pairing = $0 }
            )
            persistence.failMutation(after: failureOffset)

            XCTAssertThrowsError(try credentials.commitMigratedPairing(newPairing) {
                try migration.finishMigration(pairing: newPairing, marker: marker)
            }, "failure boundary \(failureOffset)")
            XCTAssertEqual(credentials.snapshot().pairingGeneration, 0)
            let afterFailure = try migration.loadPortable(for: identity)
            if failureOffset < 5 {
                XCTAssertEqual(afterFailure.baseline, oldBaseline)
            } else {
                XCTAssertEqual(afterFailure.baseline?.cid, newPairing.fingerprint)
            }

            persistence.allowMutations()
            let reconstructedMigration = DeviceMigrationStore(persistence: persistence)
            let reconstructedCredentials = PairingCredentialStore(
                confirmationStore: .memory(),
                migrationStore: reconstructedMigration,
                loadPairing: { holder.pairing },
                savePairing: { holder.pairing = $0 }
            )
            let recoveredOwnerID = try XCTUnwrap(reconstructedCredentials.snapshot().deviceOwnerID)
            let recoveredClassification = try reconstructedMigration.classify(
                pairing: holder.pairing,
                ownerID: recoveredOwnerID
            )
            XCTAssertTrue(
                [.migrationRecovery, .sameDevice].contains(recoveredClassification),
                "failure boundary \(failureOffset) must remain recoverable after reconstruction"
            )
            try reconstructedCredentials.commitMigratedPairing(newPairing) {
                try reconstructedMigration.finishMigration(pairing: newPairing, marker: marker)
            }

            let portable = try reconstructedMigration.loadPortable(for: identity)
            XCTAssertEqual(portable.baseline?.cid, newPairing.fingerprint)
            XCTAssertEqual(portable.transaction?.phase, .credentialCommitted)
            XCTAssertEqual(portable.transaction?.rekeyOperationID, operationID)
            XCTAssertNil(try reconstructedMigration.loadPendingRekey(ownerID: recoveredOwnerID))
            XCTAssertEqual(reconstructedCredentials.snapshot().pairing?.fingerprint, newPairing.fingerprint)
            XCTAssertEqual(reconstructedCredentials.snapshot().pairingGeneration, 1)
        }
    }

    @MainActor
    func testSameHardwareResumesCandidateButRestoredHardwareCreatesDistinctOperation() async throws {
        let portableBacking = MigrationPortableBacking()
        let firstPersistence = MigrationTestPersistence(portableBacking: portableBacking)
        let firstMigration = DeviceMigrationStore(persistence: firstPersistence)
        let oldPairing = Self.pairing(cidByte: "1")
        let candidate = Self.pairing(cidByte: "2")
        _ = try firstMigration.adopt(pairing: oldPairing, includeFreshPairOffer: false)
        let originalOwner = try firstMigration.claimExistingPairing(oldPairing)
        let identity = try DevicePairingIdentity.make(for: oldPairing)
        let marker = try firstMigration.beginMigrationMarker(for: identity)
        let operationID = UUID()
        try firstMigration.savePendingRekey(PendingDeviceRekey(
            operationID: operationID,
            pairingOwnerID: originalOwner,
            previousCID: oldPairing.fingerprint,
            csrPEM: "csr",
            privateKeyPEM: "device-only key",
            requestBytes: Data("exact request".utf8),
            responseBytes: Data("validated response".utf8)
        ), ownerID: originalOwner)
        try firstMigration.stageMigration(
            from: oldPairing,
            to: candidate,
            marker: marker,
            priorSendWasConfirmed: false,
            pairingOwnerID: originalOwner
        )

        let holder = PairingSnapshotHolder(oldPairing)
        let firstCredentials = PairingCredentialStore(
            confirmationStore: .memory(),
            migrationStore: firstMigration,
            loadPairing: { holder.pairing },
            savePairing: { holder.pairing = $0 }
        )
        XCTAssertThrowsError(try firstCredentials.commitMigratedPairing(candidate) {
            throw MigrationPersistenceTestError.write
        })
        XCTAssertEqual(holder.pairing, candidate)
        XCTAssertEqual(try firstMigration.loadPortable(for: identity).transaction?.rekeyOperationID, operationID)

        let portableBeforeRestore = try XCTUnwrap(portableBacking.read(identity.account))
        let restoredBacking = MigrationPortableBacking()
        restoredBacking.write(portableBeforeRestore, account: identity.account)

        let sameHardwareMigration = DeviceMigrationStore(persistence: firstPersistence)
        let confirmation = JournalSendConfirmationStore.memory()
        let sameHardwareCredentials = PairingCredentialStore(
            confirmationStore: confirmation,
            migrationStore: sameHardwareMigration,
            loadPairing: { holder.pairing },
            savePairing: { holder.pairing = $0 }
        )
        let sameHardwareOwner = try XCTUnwrap(sameHardwareCredentials.snapshot().deviceOwnerID)
        XCTAssertEqual(sameHardwareOwner, originalOwner)
        XCTAssertEqual(
            try sameHardwareMigration.classify(pairing: candidate, ownerID: sameHardwareOwner),
            .migrationRecovery
        )
        let noNetworkAttempt = MigrationAttemptRecorder()
        let sameHardwareCoordinator = DeviceMigrationCoordinator(
            credentials: sameHardwareCredentials,
            confirmation: confirmation,
            control: noNetworkAttempt
        )
        try await sameHardwareCoordinator.prepareForOrdinaryAdmission(
            pairing: candidate,
            pairingGeneration: 0,
            mayContinue: { true }
        )
        XCTAssertTrue(noNetworkAttempt.requestBodies.isEmpty)
        XCTAssertNil(try sameHardwareMigration.loadPendingRekey(ownerID: originalOwner))
        XCTAssertTrue(sameHardwareCredentials.hasActiveOwner)

        let restoredPersistence = MigrationTestPersistence(portableBacking: restoredBacking)
        let restoredMigration = DeviceMigrationStore(persistence: restoredPersistence)
        let restoredCredentials = PairingCredentialStore(
            confirmationStore: .memory(),
            migrationStore: restoredMigration,
            loadPairing: { holder.pairing },
            savePairing: { holder.pairing = $0 }
        )
        let restoredOwner = try XCTUnwrap(restoredCredentials.snapshot().deviceOwnerID)
        XCTAssertNotEqual(restoredOwner, originalOwner)
        XCTAssertEqual(
            try restoredMigration.classify(pairing: candidate, ownerID: restoredOwner),
            .movedDevice
        )
        let freshAttempt = MigrationAttemptRecorder()
        let restoredCoordinator = DeviceMigrationCoordinator(
            credentials: restoredCredentials,
            confirmation: .memory(),
            control: freshAttempt
        )
        do {
            try await restoredCoordinator.prepareForOrdinaryAdmission(
                pairing: candidate,
                pairingGeneration: 0,
                mayContinue: { true }
            )
            XCTFail("the control attempt should remain offline")
        } catch {}

        let freshCandidate = try XCTUnwrap(try restoredMigration.loadPendingRekey(ownerID: restoredOwner))
        XCTAssertNotEqual(freshCandidate.operationID, operationID)
        XCTAssertNotEqual(freshCandidate.privateKeyPEM, "device-only key")
        XCTAssertEqual(freshAttempt.requestBodies, [freshCandidate.requestBytes])
        let carriedTransaction = try XCTUnwrap(try restoredMigration.loadPortable(for: identity).transaction)
        XCTAssertEqual(carriedTransaction.rekeyOperationID, operationID)
        XCTAssertEqual(carriedTransaction.pairingOwnerID, originalOwner)
        XCTAssertNotEqual(carriedTransaction.pairingOwnerID, restoredOwner)
    }

    @MainActor
    func testRestoredPartialCandidateRecoversItsOwnCommittedPhaseAfterAnotherInterruption() async throws {
        let original = Self.pairing(cidByte: "a")
        let carriedCandidate = Self.pairing(cidByte: "b")
        let freshCandidate = Self.pairing(cidByte: "c")
        let backing = MigrationPortableBacking()
        let firstPersistence = MigrationTestPersistence(portableBacking: backing)
        let firstStore = DeviceMigrationStore(persistence: firstPersistence)
        _ = try firstStore.adopt(pairing: original, includeFreshPairOffer: false)
        let firstOwner = try firstStore.claimExistingPairing(original)
        let identity = try DevicePairingIdentity.make(for: original)
        let firstMarker = try firstStore.beginMigrationMarker(for: identity)
        let firstOperation = UUID()
        try firstStore.savePendingRekey(PendingDeviceRekey(
            operationID: firstOperation, pairingOwnerID: firstOwner,
            previousCID: original.fingerprint, csrPEM: "first csr", privateKeyPEM: "first local key",
            requestBytes: Data("first request".utf8), responseBytes: Data("first response".utf8)
        ), ownerID: firstOwner)
        try firstStore.stageMigration(from: original, to: carriedCandidate, marker: firstMarker,
                                      priorSendWasConfirmed: false, pairingOwnerID: firstOwner)

        // Only portable records and the partially saved credential move. The
        // first device's owner, marker and staged key are absent on this device.
        let persistence = MigrationTestPersistence(portableBacking: backing)
        let store = DeviceMigrationStore(persistence: persistence)
        let holder = PairingSnapshotHolder(carriedCandidate)
        let credentials = PairingCredentialStore(
            confirmationStore: .memory(), migrationStore: store,
            loadPairing: { holder.pairing }, savePairing: { holder.pairing = $0 }
        )
        let owner = try XCTUnwrap(credentials.snapshot().deviceOwnerID)
        XCTAssertNotEqual(owner, firstOwner)
        XCTAssertEqual(try store.classify(pairing: carriedCandidate, ownerID: owner), .movedDevice)
        let marker = try store.beginMigrationMarker(for: identity)
        let operation = UUID()
        let exactRequest = Data("second device exact request".utf8)
        try store.savePendingRekey(PendingDeviceRekey(
            operationID: operation, pairingOwnerID: owner,
            previousCID: carriedCandidate.fingerprint, csrPEM: "second csr", privateKeyPEM: "second local key",
            requestBytes: exactRequest, responseBytes: Data("second response".utf8)
        ), ownerID: owner)
        try store.stageMigration(from: carriedCandidate, to: freshCandidate, marker: marker,
                                 priorSendWasConfirmed: false, pairingOwnerID: owner)
        persistence.failMutation(after: 3)
        XCTAssertThrowsError(try credentials.commitMigratedPairing(freshCandidate) {
            try store.finishMigration(pairing: freshCandidate, marker: marker)
        })
        let interrupted = try store.loadPortable(for: identity)
        XCTAssertEqual(interrupted.transaction?.phase, .credentialCommitted)
        XCTAssertEqual(interrupted.baseline?.cid, original.fingerprint)
        XCTAssertEqual(holder.pairing, freshCandidate)
        persistence.allowMutations()

        let recovered = DeviceMigrationStore(persistence: persistence)
        let confirmation = JournalSendConfirmationStore.memory()
        let coldCredentials = PairingCredentialStore(
            confirmationStore: confirmation, migrationStore: recovered,
            loadPairing: { holder.pairing }, savePairing: { holder.pairing = $0 }
        )
        XCTAssertEqual(coldCredentials.snapshot().deviceOwnerID, owner)
        XCTAssertEqual(try recovered.loadPendingRekey(ownerID: owner)?.operationID, operation)
        XCTAssertEqual(try recovered.loadPendingRekey(ownerID: owner)?.requestBytes, exactRequest)
        let control = MigrationAttemptRecorder()
        let coordinator = DeviceMigrationCoordinator(credentials: coldCredentials, confirmation: confirmation, control: control)
        try await coordinator.prepareForOrdinaryAdmission(pairing: freshCandidate, pairingGeneration: 0, mayContinue: { true })
        XCTAssertTrue(control.requestBodies.isEmpty)
        XCTAssertTrue(try recovered.owns(ownerID: owner, pairing: freshCandidate))
        XCTAssertEqual(try recovered.loadPortable(for: identity).baseline?.cid, freshCandidate.fingerprint)
        XCTAssertEqual(try recovered.loadPortable(for: identity).transaction?.rekeyOperationID, operation)
        XCTAssertNotEqual(operation, firstOperation)
        XCTAssertNil(try recovered.loadPendingRekey(ownerID: owner))
    }

    @MainActor
    func testGenerationAdvancesOnlyAfterCandidateCleanupRetry() throws {
        let persistence = MigrationTestPersistence()
        let migration = DeviceMigrationStore(persistence: persistence)
        let oldPairing = Self.pairing(cidByte: "c")
        let newPairing = Self.pairing(cidByte: "d")
        _ = try migration.adopt(pairing: oldPairing, includeFreshPairOffer: false)
        let ownerID = try migration.claimExistingPairing(oldPairing)
        let identity = try DevicePairingIdentity.make(for: oldPairing)
        let marker = try migration.beginMigrationMarker(for: identity)
        let operationID = UUID()
        try migration.savePendingRekey(PendingDeviceRekey(
            operationID: operationID,
            pairingOwnerID: ownerID,
            previousCID: oldPairing.fingerprint,
            csrPEM: "csr",
            privateKeyPEM: "key",
            requestBytes: Data("request".utf8),
            responseBytes: Data("response".utf8)
        ), ownerID: ownerID)
        try migration.stageMigration(
            from: oldPairing,
            to: newPairing,
            marker: marker,
            priorSendWasConfirmed: false,
            pairingOwnerID: ownerID
        )
        let holder = PairingSnapshotHolder(oldPairing)
        let credentials = PairingCredentialStore(
            confirmationStore: .memory(),
            migrationStore: migration,
            loadPairing: { holder.pairing },
            savePairing: { holder.pairing = $0 }
        )
        persistence.failMutation(after: 6)

        XCTAssertThrowsError(try credentials.commitMigratedPairing(newPairing) {
            try migration.finishMigration(pairing: newPairing, marker: marker)
        })
        XCTAssertEqual(credentials.snapshot().pairingGeneration, 0)
        XCTAssertNotNil(try migration.loadPendingRekey(ownerID: ownerID))

        persistence.allowMutations()
        try migration.repairCommittedMigration(pairing: newPairing)
        try credentials.recoverCommittedOwner(pairing: newPairing, ownerID: ownerID)

        XCTAssertEqual(credentials.snapshot().pairingGeneration, 1)
        XCTAssertTrue(credentials.hasActiveOwner)
        XCTAssertNil(try migration.loadPendingRekey(ownerID: ownerID))
        XCTAssertEqual(try migration.loadPortable(for: identity).transaction?.rekeyOperationID, operationID)
    }

    @MainActor
    func testClearDeletesCandidateOnlyWhenPreparedMigrationProvesOwnerLineage() throws {
        let persistence = MigrationTestPersistence()
        let migration = DeviceMigrationStore(persistence: persistence)
        let oldPairing = Self.pairing(cidByte: "8")
        let candidatePairing = Self.pairing(cidByte: "9")
        _ = try migration.adopt(pairing: oldPairing, includeFreshPairOffer: false)
        let ownerID = try migration.claimExistingPairing(oldPairing)
        let identity = try DevicePairingIdentity.make(for: oldPairing)
        let migratingMarker = try migration.beginMigrationMarker(for: identity)
        try migration.savePendingRekey(PendingDeviceRekey(
            operationID: UUID(),
            pairingOwnerID: ownerID,
            previousCID: oldPairing.fingerprint,
            csrPEM: "candidate csr",
            privateKeyPEM: "candidate key",
            requestBytes: Data("exact request".utf8),
            responseBytes: Data("validated response".utf8)
        ), ownerID: ownerID)
        try migration.stageMigration(
            from: oldPairing,
            to: candidatePairing,
            marker: migratingMarker,
            priorSendWasConfirmed: false,
            pairingOwnerID: ownerID
        )
        let holder = PairingSnapshotHolder(oldPairing)
        let confirmation = JournalSendConfirmationStore.memory()
        let credentials = PairingCredentialStore(
            confirmationStore: confirmation,
            migrationStore: migration,
            loadPairing: { holder.pairing },
            savePairing: { holder.pairing = $0 },
            deletePairing: { holder.pairing = nil }
        )

        XCTAssertThrowsError(try credentials.commitMigratedPairing(candidatePairing) {
            throw MigrationPersistenceTestError.write
        })
        XCTAssertEqual(holder.pairing, candidatePairing)
        XCTAssertEqual(try migration.classify(pairing: candidatePairing, ownerID: ownerID), .migrationRecovery)

        let reconstructedMigration = DeviceMigrationStore(persistence: persistence)
        let reconstructedCredentials = PairingCredentialStore(
            confirmationStore: confirmation,
            migrationStore: reconstructedMigration,
            loadPairing: { holder.pairing },
            savePairing: { holder.pairing = $0 },
            deletePairing: { holder.pairing = nil }
        )
        try reconstructedCredentials.clearPairing()
        XCTAssertNil(holder.pairing)
        XCTAssertNil(reconstructedCredentials.snapshot().pairing)
        XCTAssertNil(try reconstructedMigration.loadPendingRekey(ownerID: ownerID))
        XCTAssertNil(try reconstructedMigration.loadPortable(for: identity).transaction)
        XCTAssertEqual(try reconstructedMigration.classify(pairing: nil), .noPairing)
    }

    @MainActor
    func testClearRefusesUnrelatedSameJournalCredentialAndPreservesRecoveryRecords() throws {
        let persistence = MigrationTestPersistence()
        let migration = DeviceMigrationStore(persistence: persistence)
        let original = Self.pairing(cidByte: "a")
        let unrelated = Self.pairing(cidByte: "b")
        _ = try migration.adopt(pairing: original, includeFreshPairOffer: false)
        _ = try migration.claimExistingPairing(original)
        let holder = PairingSnapshotHolder(unrelated)
        let credentials = PairingCredentialStore(
            confirmationStore: .memory(),
            migrationStore: migration,
            loadPairing: { holder.pairing },
            savePairing: { holder.pairing = $0 },
            deletePairing: { holder.pairing = nil }
        )

        XCTAssertThrowsError(try credentials.clearPairing())
        XCTAssertEqual(holder.pairing, unrelated)
        XCTAssertEqual(try migration.loadPortable(for: DevicePairingIdentity.make(for: original)).baseline?.cid, original.fingerprint)
    }

    @MainActor
    func testInvalidationLeaseCannotClearFreshSameJournalPairingAcrossReconstruction() throws {
        let persistence = MigrationTestPersistence()
        let migration = DeviceMigrationStore(persistence: persistence)
        let confirmation = JournalSendConfirmationStore.memory()
        let original = Self.pairing(cidByte: "1")
        let fresh = Self.pairing(cidByte: "2")
        let holder = PairingSnapshotHolder(nil)
        let credentials = PairingCredentialStore(
            confirmationStore: confirmation,
            migrationStore: migration,
            loadPairing: { holder.pairing },
            savePairing: { holder.pairing = $0 },
            deletePairing: { holder.pairing = nil }
        )

        try credentials.applyPairing(original)
        let invalidation = try credentials.beginPairingInvalidation()
        try credentials.applyPairing(fresh)

        XCTAssertFalse(try credentials.clearPairing(invalidation: invalidation))
        XCTAssertEqual(holder.pairing, fresh)
        XCTAssertTrue(credentials.hasActiveOwner)
        XCTAssertFalse(confirmation.allowsSend(pairing: fresh))

        let identity = try DevicePairingIdentity.make(for: fresh)
        let offer = try XCTUnwrap(migration.loadPortable(for: identity).replacementOffer)
        XCTAssertEqual(offer.pairingFingerprint, fresh.fingerprint)
        XCTAssertEqual(offer.pairingOwnerID, credentials.snapshot().deviceOwnerID)
        XCTAssertEqual(offer.state, .awaitingMarkConfirmation)

        let reconstructed = PairingCredentialStore(
            confirmationStore: confirmation,
            migrationStore: migration,
            loadPairing: { holder.pairing },
            savePairing: { holder.pairing = $0 },
            deletePairing: { holder.pairing = nil }
        )
        XCTAssertEqual(reconstructed.snapshot().pairing, fresh)
        XCTAssertTrue(reconstructed.hasActiveOwner)
        XCTAssertEqual(try migration.loadPortable(for: identity).replacementOffer, offer)
    }

    @MainActor
    func testFreshSameJournalPairingCreatesOfferAfterPriorOfferWasDismissed() throws {
        let migration = DeviceMigrationStore.memory()
        let confirmation = JournalSendConfirmationStore.memory()
        let original = Self.pairing(cidByte: "5")
        let fresh = Self.pairing(cidByte: "6")
        _ = try migration.adopt(pairing: original, includeFreshPairOffer: true)
        let originalOwnerID = try migration.claimExistingPairing(original)
        let identity = try DevicePairingIdentity.make(for: original)
        let oldOffer = try XCTUnwrap(migration.loadPortable(for: identity).replacementOffer)
        try migration.updateReplacementOffer(
            identity: identity,
            ownerID: originalOwnerID,
            operationID: oldOffer.operationID
        ) {
            $0.state = .dismissed
        }

        let holder = PairingSnapshotHolder(original)
        let credentials = PairingCredentialStore(
            confirmationStore: confirmation,
            migrationStore: migration,
            loadPairing: { holder.pairing },
            savePairing: { holder.pairing = $0 },
            deletePairing: { holder.pairing = nil }
        )
        try credentials.applyPairing(fresh)

        let newOffer = try XCTUnwrap(migration.loadPortable(for: identity).replacementOffer)
        XCTAssertNotEqual(newOffer.operationID, oldOffer.operationID)
        XCTAssertEqual(newOffer.pairingOwnerID, credentials.snapshot().deviceOwnerID)
        XCTAssertEqual(newOffer.pairingFingerprint, fresh.fingerprint)
        XCTAssertEqual(newOffer.state, .awaitingMarkConfirmation)
    }

    @MainActor
    func testFailedInvalidationWritePreservesCurrentCredentialOwner() throws {
        let persistence = MigrationTestPersistence()
        let migration = DeviceMigrationStore(persistence: persistence)
        let pairing = Self.pairing(cidByte: "3")
        let holder = PairingSnapshotHolder(nil)
        let credentials = PairingCredentialStore(
            confirmationStore: .memory(),
            migrationStore: migration,
            loadPairing: { holder.pairing },
            savePairing: { holder.pairing = $0 },
            deletePairing: { holder.pairing = nil }
        )
        try credentials.applyPairing(pairing)
        let before = credentials.snapshot()
        persistence.failMutation(after: 0)

        XCTAssertThrowsError(try credentials.beginPairingInvalidation())
        XCTAssertEqual(credentials.snapshot().pairing, pairing)
        XCTAssertEqual(credentials.snapshot().deviceOwnerID, before.deviceOwnerID)
        XCTAssertEqual(credentials.snapshot().pairingGeneration, before.pairingGeneration)
        XCTAssertEqual(holder.pairing, pairing)
        XCTAssertTrue(credentials.hasActiveOwner)
    }

    @MainActor
    func testDirectClearNotifiesAdmissionOnlyAfterDurableInvalidation() throws {
        let persistence = MigrationTestPersistence()
        let migration = DeviceMigrationStore(persistence: persistence)
        let pairing = Self.pairing(cidByte: "4")
        let holder = PairingSnapshotHolder(nil)
        let credentials = PairingCredentialStore(
            confirmationStore: .memory(),
            migrationStore: migration,
            loadPairing: { holder.pairing },
            savePairing: { holder.pairing = $0 },
            deletePairing: { holder.pairing = nil }
        )
        let invalidationCount = OSAllocatedUnfairLock(initialState: 0)
        credentials.registerOnCredentialInvalidation { invalidationCount.withLock { $0 += 1 } }
        try credentials.applyPairing(pairing)

        persistence.failMutation(after: 0)
        XCTAssertThrowsError(try credentials.clearPairing())
        XCTAssertEqual(invalidationCount.withLock { $0 }, 0)
        XCTAssertEqual(credentials.snapshot().pairing, pairing)
        XCTAssertTrue(credentials.hasActiveOwner)

        persistence.allowMutations()
        try credentials.clearPairing()
        XCTAssertEqual(invalidationCount.withLock { $0 }, 1)
        XCTAssertNil(credentials.snapshot().pairing)
        XCTAssertNil(holder.pairing)
    }

    @MainActor
    func testRevocationFencesAdmissionBeforeCredentialDeletion() async throws {
        let persistence = MigrationTestPersistence()
        let migration = DeviceMigrationStore(persistence: persistence)
        let pairing = Self.pairing(cidByte: "7")
        let holder = PairingSnapshotHolder(nil)
        let invalidationCount = OSAllocatedUnfairLock(initialState: 0)
        let deletionSawInvalidation = OSAllocatedUnfairLock(initialState: false)
        let credentials = PairingCredentialStore(
            confirmationStore: .memory(),
            migrationStore: migration,
            loadPairing: { holder.pairing },
            savePairing: { holder.pairing = $0 },
            deletePairing: {
                deletionSawInvalidation.withLock { $0 = invalidationCount.withLock { $0 == 1 } }
                holder.pairing = nil
            }
        )
        credentials.registerOnCredentialInvalidation { invalidationCount.withLock { $0 += 1 } }
        try credentials.applyPairing(pairing)
        let snapshot = credentials.snapshot()

        persistence.failMutation(after: 0)
        do {
            _ = try await credentials.revokeIfCurrentGeneration(
                pairingGen: snapshot.pairingGeneration,
                mutationGen: snapshot.accessMutationGeneration
            )
            XCTFail("failed durable invalidation must stop revocation")
        } catch {
            // Pairing and admission ownership remain unchanged until invalidation persists.
        }
        XCTAssertEqual(invalidationCount.withLock { $0 }, 0)
        XCTAssertEqual(holder.pairing, pairing)
        XCTAssertTrue(credentials.hasActiveOwner)

        persistence.allowMutations()
        let revoked = try await credentials.revokeIfCurrentGeneration(
            pairingGen: snapshot.pairingGeneration,
            mutationGen: snapshot.accessMutationGeneration
        )
        XCTAssertTrue(revoked)
        XCTAssertEqual(invalidationCount.withLock { $0 }, 1)
        XCTAssertTrue(deletionSawInvalidation.withLock { $0 })
        XCTAssertNil(holder.pairing)
        XCTAssertNil(credentials.snapshot().pairing)
    }

    @MainActor
    func testApplyPairingWithoutLocalBaselineEnrollsFreshPairOffer() throws {
        let migration = DeviceMigrationStore.memory()
        let confirmation = JournalSendConfirmationStore.memory()
        let pairing = Self.pairing(cidByte: "a")
        let holder = PairingSnapshotHolder(nil)
        let credentials = PairingCredentialStore(
            confirmationStore: confirmation,
            migrationStore: migration,
            loadPairing: { holder.pairing },
            savePairing: { holder.pairing = $0 },
            deletePairing: { holder.pairing = nil }
        )
        try credentials.applyPairing(pairing)

        let identity = try DevicePairingIdentity.make(for: pairing)
        let offer = try XCTUnwrap(migration.loadPortable(for: identity).replacementOffer)
        XCTAssertEqual(offer.pairingFingerprint, pairing.fingerprint)
        XCTAssertEqual(offer.pairingOwnerID, credentials.snapshot().deviceOwnerID)
        XCTAssertEqual(offer.state, .awaitingMarkConfirmation)
        XCTAssertNil(offer.targetCID)
        XCTAssertNil(offer.requestBytes)
        XCTAssertNil(offer.presentationShown)
    }

    @MainActor
    func testApplyPairingWithDifferentIdentityEnrollsFreshPairOfferOnNewIdentity() throws {
        let migration = DeviceMigrationStore.memory()
        let confirmation = JournalSendConfirmationStore.memory()
        let firstPairing = Self.pairing(cidByte: "b")
        var secondPairing = Self.pairing(cidByte: "c")
        secondPairing = StoredPairing(
            instanceID: "different-journal-instance",
            homeLabel: secondPairing.homeLabel,
            relayEndpoint: secondPairing.relayEndpoint,
            fingerprint: secondPairing.fingerprint,
            clientCertPEM: secondPairing.clientCertPEM,
            clientKeyPEM: secondPairing.clientKeyPEM,
            caChainPEM: secondPairing.caChainPEM,
            relayEnrollment: secondPairing.relayEnrollment,
            localEndpoints: secondPairing.localEndpoints,
            pairedAt: secondPairing.pairedAt
        )
        let holder = PairingSnapshotHolder(nil)
        let credentials = PairingCredentialStore(
            confirmationStore: confirmation,
            migrationStore: migration,
            loadPairing: { holder.pairing },
            savePairing: { holder.pairing = $0 },
            deletePairing: { holder.pairing = nil }
        )
        try credentials.applyPairing(firstPairing)
        let firstIdentity = try DevicePairingIdentity.make(for: firstPairing)
        let firstOffer = try XCTUnwrap(migration.loadPortable(for: firstIdentity).replacementOffer)

        try credentials.applyPairing(secondPairing)
        let secondIdentity = try DevicePairingIdentity.make(for: secondPairing)
        let secondOffer = try XCTUnwrap(migration.loadPortable(for: secondIdentity).replacementOffer)
        XCTAssertNotEqual(firstIdentity, secondIdentity)
        XCTAssertEqual(secondOffer.pairingFingerprint, secondPairing.fingerprint)
        XCTAssertEqual(secondOffer.pairingOwnerID, credentials.snapshot().deviceOwnerID)
        XCTAssertEqual(secondOffer.state, .awaitingMarkConfirmation)
        XCTAssertNil(secondOffer.targetCID)
        XCTAssertNil(secondOffer.requestBytes)
        XCTAssertNil(try migration.loadPortable(for: firstIdentity).replacementOffer)
    }

    @MainActor
    func testApplyPairingSameCredentialDoesNotReplaceExistingOffer() throws {
        let migration = DeviceMigrationStore.memory()
        let confirmation = JournalSendConfirmationStore.memory()
        let pairing = Self.pairing(cidByte: "d")
        let holder = PairingSnapshotHolder(nil)
        let credentials = PairingCredentialStore(
            confirmationStore: confirmation,
            migrationStore: migration,
            loadPairing: { holder.pairing },
            savePairing: { holder.pairing = $0 },
            deletePairing: { holder.pairing = nil }
        )
        try credentials.applyPairing(pairing)
        let identity = try DevicePairingIdentity.make(for: pairing)
        let firstOffer = try XCTUnwrap(migration.loadPortable(for: identity).replacementOffer)

        try credentials.applyPairing(pairing)
        let secondOffer = try XCTUnwrap(migration.loadPortable(for: identity).replacementOffer)
        XCTAssertEqual(firstOffer.operationID, secondOffer.operationID)
        XCTAssertEqual(firstOffer.pairingOwnerID, secondOffer.pairingOwnerID)
        XCTAssertEqual(firstOffer.pairingFingerprint, secondOffer.pairingFingerprint)
        XCTAssertEqual(firstOffer.state, secondOffer.state)
    }

    @MainActor
    func testPersistRefreshedPairingAndCommitReadyAccessDoNotAlterReplacementOffer() async throws {
        let migration = DeviceMigrationStore.memory()
        let confirmation = JournalSendConfirmationStore.memory()
        let pairing = Self.pairing(cidByte: "e")
        let holder = PairingSnapshotHolder(nil)
        let credentials = PairingCredentialStore(
            confirmationStore: confirmation,
            migrationStore: migration,
            loadPairing: { holder.pairing },
            savePairing: { holder.pairing = $0 },
            deletePairing: { holder.pairing = nil }
        )
        try credentials.applyPairing(pairing)
        let identity = try DevicePairingIdentity.make(for: pairing)
        let initialOffer = try XCTUnwrap(migration.loadPortable(for: identity).replacementOffer)

        let snap1 = credentials.snapshot()
        let expiresAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let committed = try await credentials.commitReadyAccess(
            relayOrigin: "https://relay-updated.example.invalid",
            deviceToken: "token-abc",
            expiresAt: expiresAt,
            pairingGen: snap1.pairingGeneration,
            mutationGen: snap1.accessMutationGeneration
        )
        XCTAssertTrue(committed)
        let offerAfterAccess = try XCTUnwrap(migration.loadPortable(for: identity).replacementOffer)
        XCTAssertEqual(offerAfterAccess, initialOffer)

        let currentPairing = try XCTUnwrap(credentials.load())
        let updatedPairing = StoredPairing(
            instanceID: currentPairing.instanceID,
            homeLabel: currentPairing.homeLabel,
            relayEndpoint: "https://relay-refreshed.example.invalid",
            fingerprint: currentPairing.fingerprint,
            clientCertPEM: currentPairing.clientCertPEM,
            clientKeyPEM: currentPairing.clientKeyPEM,
            caChainPEM: currentPairing.caChainPEM,
            relayEnrollment: .enrolled(deviceToken: "token-def", expiresAt: expiresAt),
            localEndpoints: currentPairing.localEndpoints,
            pairedAt: currentPairing.pairedAt
        )
        let snap2 = credentials.snapshot()
        let refreshed = try await credentials.persistRefreshedPairing(
            updatedPairing,
            pairingGen: snap2.pairingGeneration,
            mutationGen: snap2.accessMutationGeneration
        )
        XCTAssertTrue(refreshed)
        let offerAfterRefresh = try XCTUnwrap(migration.loadPortable(for: identity).replacementOffer)
        XCTAssertEqual(offerAfterRefresh, initialOffer)
    }

    @MainActor
    func testAdoptWithoutFreshPairOfferLeavesNoOffer() throws {
        let migration = DeviceMigrationStore.memory()
        let pairing = Self.pairing(cidByte: "f")
        _ = try migration.adopt(pairing: pairing, includeFreshPairOffer: false)
        let identity = try DevicePairingIdentity.make(for: pairing)
        XCTAssertNil(try migration.loadPortable(for: identity).replacementOffer)
    }

    private static func pairing(cidByte: String) -> StoredPairing {
        StoredPairing(
            instanceID: "migration-test-instance",
            homeLabel: "test journal",
            relayEndpoint: "https://relay.example.invalid",
            fingerprint: "sha256:" + String(repeating: cidByte, count: 64),
            clientCertPEM: CertlessTrustFixtures.leafPEM,
            clientKeyPEM: "unused key",
            caChainPEM: CertlessTrustFixtures.caPEM,
            relayEnrollment: .unavailable,
            localEndpoints: [],
            pairedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

private final class PairingSnapshotHolder: @unchecked Sendable {
    var pairing: StoredPairing?
    init(_ pairing: StoredPairing?) { self.pairing = pairing }
}

final class DeviceMigrationContractFixtureTests: XCTestCase {
    func testAllSuppliedContractFixtureHashesAndCanonicalPairingShape() throws {
        let expected: [(String, String)] = [
            ("DeviceMigration/v1.schema.json", "5ea0ce5bf0bc5f07233f05dda3334ccea3bf173363fcd4fd4cdcd9479130a373"),
            ("DeviceMigration/v1.vectors.json", "3ba1bb508a0cd5756626c6246bfbff77573c54538db60c8e7f938e38b306ef9c"),
            ("LinkedDeviceIngest/manifest.json", "86d4358916a0303c29a8e61c6d1e48ef1939d0b5a2f042ae617958b9d0c1a5a8"),
            ("LinkedDeviceIngest/projection.openapi.json", "db75a94ab97e83c56603e44d9313db86a94a2d9c4a920deaf090fe0f3358b8b0"),
            ("LinkedDeviceIngest/vectors.json", "7c61c1238184e1440110801478daf714aba05b2472338bd98c12cd508b303d0f"),
            ("LinkedDeviceIngest/wire-behavior.json", "035e59297af21da998984910b4aa6a850d7e2e1225c79019045381bf3e17e708"),
        ]
        let root = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
        for (path, hash) in expected {
            let bundledPath = path.hasPrefix("LinkedDeviceIngest/")
                ? path : URL(fileURLWithPath: path).lastPathComponent
            let data = try Data(contentsOf: root.appendingPathComponent(bundledPath))
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(actual, hash, path)
        }

        let vectorsURL = root.appendingPathComponent("v1.vectors.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: vectorsURL)) as? [String: Any])
        let vectors = try XCTUnwrap(json["vectors"] as? [String: Any])
        let request = try XCTUnwrap(vectors["rekey_request"] as? [String: Any])
        XCTAssertEqual(request["platform"] as? String, "ios")
        let response = try XCTUnwrap(vectors["rekey_created_201"] as? [String: Any])
        let body = try XCTUnwrap(response["body"] as? [String: Any])
        let pairing = try XCTUnwrap(body["pairing"] as? [String: Any])
        XCTAssertEqual(Set(pairing.keys), Set([
            "client_cert", "ca_chain", "instance_id", "home_label", "fingerprint",
            "home_attestation", "local_endpoints", "relay_access",
        ]))
        let noNetwork = try XCTUnwrap(vectors["rekey_without_network_metadata"] as? [String: Any])
        let noNetworkBody = try XCTUnwrap(noNetwork["body"] as? [String: Any])
        let noNetworkPairing = try XCTUnwrap(noNetworkBody["pairing"] as? [String: Any])
        XCTAssertEqual(Set(noNetworkPairing.keys), Set([
            "client_cert", "ca_chain", "instance_id", "home_label", "fingerprint", "home_attestation",
        ]))
        XCTAssertNil(noNetworkPairing["local_endpoints"])
        XCTAssertNil(noNetworkPairing["relay_access"])
    }
}
