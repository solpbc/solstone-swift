// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel
import os

private let migrationCoordinatorLog = Logger(subsystem: "app.solstone.swift", category: "device-migration")

nonisolated enum DeviceMigrationRecoveryState: Equatable, Sendable {
    case preparing
    case offline
    case unsupported
    case storageUnavailable
    case keyRefused

    static func diagnosedFailure(_ error: Error) -> Self? {
        if error is CancellationError { return nil }
        if let storeError = error as? DeviceMigrationStoreError {
            switch storeError {
            case .keychain, .corruptRecord, .invalidPairing, .ownershipUnavailable:
                return .storageUnavailable
            }
        }
        if let controlError = error as? DeviceMigrationControlError {
            switch controlError {
            case .unexpectedStatus(let status) where status == 401 || status == 403:
                return .keyRefused
            case .unexpectedStatus(let status) where status == 404 || status == 405 || status == 426:
                return .unsupported
            case .unexpectedStatus:
                return nil
            case .invalidResponse, .responseTooLarge, .invalidHTTP, .identityChanged, .operationChanged, .keyBindingFailed:
                return nil
            }
        }
        if let tunnelError = error as? TunnelError {
            switch tunnelError {
            case .revoked, .tlsHandshakeFailed:
                return .keyRefused
            case .unreachable, .muxTeardown:
                return .offline
            case .unknown:
                return nil
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut:
                return .offline
            default:
                return nil
            }
        }
        return nil
    }
}

@MainActor
final class DeviceMigrationCoordinator {
    private let credentials: PairingCredentialStore
    private let confirmation: JournalSendConfirmationStore
    private let migrationStore: DeviceMigrationStore
    private let control: any MigrationControlExchanging
    private weak var appConfig: AppConfig?
    private let didRotateCredential: @MainActor @Sendable () -> Void

    init(
        credentials: PairingCredentialStore,
        confirmation: JournalSendConfirmationStore,
        appConfig: AppConfig? = nil,
        control: any MigrationControlExchanging = SPLMigrationControlExchange(),
        didRotateCredential: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.credentials = credentials
        self.confirmation = confirmation
        self.migrationStore = credentials.migrationStore
        self.appConfig = appConfig
        self.control = control
        self.didRotateCredential = didRotateCredential
    }

    func prepareForOrdinaryAdmission(
        pairing: StoredPairing,
        pairingGeneration: UInt64,
        mayContinue: @MainActor @Sendable () -> Bool
    ) async throws {
        guard mayContinue(), self.credentials.snapshot().pairingGeneration == pairingGeneration else {
            throw CancellationError()
        }
        guard let ownerID = self.credentials.snapshot().deviceOwnerID,
              try self.migrationStore.owns(ownerID: ownerID) else {
            throw DeviceMigrationStoreError.ownershipUnavailable
        }
        let identity = try DevicePairingIdentity.make(for: pairing)
        let classification = try self.migrationStore.classify(pairing: pairing, ownerID: ownerID)
        if !(try self.migrationStore.owns(ownerID: ownerID, pairing: pairing)) {
            guard classification == .sameDevice || classification == .migrationRecovery else {
                throw DeviceMigrationStoreError.ownershipUnavailable
            }
        }
        switch classification {
        case .noPairing:
            return
        case .firstAdoption:
            try self.migrationStore.adopt(pairing: pairing, includeFreshPairOffer: false)
        case .interruptedAdoption:
            try self.migrationStore.adopt(pairing: pairing, includeFreshPairOffer: false)
        case .sameDevice:
            try self.migrationStore.repairCommittedMigration(pairing: pairing)
            try self.credentials.recoverCommittedOwner(pairing: pairing, ownerID: ownerID)
            return
        case .journalChanged:
            throw DeviceMigrationStoreError.invalidPairing
        case .movedDevice:
            try await self.migrate(pairing: pairing, identity: identity, ownerID: ownerID, pairingGeneration: pairingGeneration, mayContinue: mayContinue)
        case .migrationRecovery:
            try await self.recover(pairing: pairing, identity: identity, ownerID: ownerID, pairingGeneration: pairingGeneration, mayContinue: mayContinue)
        }
    }

    func requiresMigrationPreparation(pairing: StoredPairing, ownerID: UUID?) throws -> Bool {
        switch try self.migrationStore.classify(pairing: pairing, ownerID: ownerID) {
        case .movedDevice, .migrationRecovery:
            return true
        case .noPairing, .firstAdoption, .interruptedAdoption, .sameDevice, .journalChanged:
            return false
        }
    }

    private func migrate(
        pairing: StoredPairing,
        identity: DevicePairingIdentity,
        ownerID: UUID,
        pairingGeneration: UInt64,
        mayContinue: @MainActor @Sendable () -> Bool
    ) async throws {
        var marker = try self.migrationStore.loadMarker()
        if marker == nil || marker?.adoption != .migrating(identity) {
            marker = try self.migrationStore.beginMigrationMarker(for: identity)
        }
        guard let marker else { throw DeviceMigrationStoreError.corruptRecord }

        var pending = try self.migrationStore.loadPendingRekey(ownerID: ownerID)
        if pending == nil {
            let label = DeviceRegistrationDescriptor.currentDisplayName()
            let generated = try CryptoCSR.generate(deviceLabel: label)
            let operationID = UUID()
            var encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let request = MigrationRekeyRequest(
                operationID: operationID,
                csr: generated.csrPEM,
                deviceLabel: Self.prefix(label, maximumScalars: 80),
                clientLabel: Self.prefix(label, maximumScalars: 253)
            )
            let bytes = try encoder.encode(request)
            let candidate = PendingDeviceRekey(
                operationID: operationID,
                pairingOwnerID: ownerID,
                previousCID: pairing.fingerprint,
                csrPEM: generated.csrPEM,
                privateKeyPEM: generated.privateKeyPEM,
                requestBytes: bytes,
                responseBytes: nil
            )
            try self.migrationStore.savePendingRekey(candidate, ownerID: ownerID)
            pending = candidate
        }
        guard var operation = pending,
              operation.previousCID == pairing.fingerprint else {
            throw DeviceMigrationStoreError.corruptRecord
        }

        let priorConfirmation = self.priorSendWasConfirmed(pairing: pairing, identity: identity)
        if let responseBytes = operation.responseBytes {
            try self.commitResponse(
                responseBytes,
                operation: operation,
                oldPairing: pairing,
                marker: marker,
                priorConfirmation: priorConfirmation,
                ownerID: ownerID,
                pairingGeneration: pairingGeneration,
                mayContinue: mayContinue
            )
            return
        }

        guard self.mayContinue(ownerID: ownerID, pairingGeneration: pairingGeneration, mayContinue: mayContinue) else {
            throw CancellationError()
        }
        let candidates = TransportEndpoint.candidates(for: pairing)
        try await self.control.postRekey(
            pairing: pairing,
            candidates: candidates,
            body: operation.requestBytes,
            shouldContinue: { [weak self] in
                guard let self else { return false }
                return self.mayContinue(ownerID: ownerID, pairingGeneration: pairingGeneration, mayContinue: mayContinue)
            }
        ) { [weak self] responseBytes in
            guard let self else { throw CancellationError() }
            guard self.mayContinue(ownerID: ownerID, pairingGeneration: pairingGeneration, mayContinue: mayContinue) else {
                throw CancellationError()
            }
            operation.responseBytes = responseBytes
            try self.migrationStore.savePendingRekey(operation, ownerID: ownerID)
            try self.commitResponse(
                responseBytes,
                operation: operation,
                oldPairing: pairing,
                marker: marker,
                priorConfirmation: priorConfirmation,
                ownerID: ownerID,
                pairingGeneration: pairingGeneration,
                mayContinue: mayContinue
            )
        }
    }

    private nonisolated static func prefix(_ value: String, maximumScalars: Int) -> String {
        String(value.unicodeScalars.prefix(maximumScalars))
    }

    private func priorSendWasConfirmed(pairing: StoredPairing, identity: DevicePairingIdentity) -> Bool {
        if self.confirmation.allowsSend(pairing: pairing) { return true }
        guard let transaction = try? self.migrationStore.loadPortable(for: identity).transaction,
              transaction.currentCID == pairing.fingerprint,
              transaction.priorSendWasConfirmed,
              transaction.sameInstanceAndCA else { return false }
        return true
    }

    private func recover(
        pairing: StoredPairing,
        identity: DevicePairingIdentity,
        ownerID: UUID,
        pairingGeneration: UInt64,
        mayContinue: @MainActor @Sendable () -> Bool
    ) async throws {
        guard self.mayContinue(ownerID: ownerID, pairingGeneration: pairingGeneration, mayContinue: mayContinue) else {
            throw DeviceMigrationStoreError.corruptRecord
        }
        let marker = try self.migrationStore.loadMarker() ?? self.migrationStore.beginMigrationMarker(for: identity)
        let portable = try self.migrationStore.loadPortable(for: identity)
        if pairing.fingerprint == portable.transaction?.currentCID {
            guard let transaction = portable.transaction else { throw DeviceMigrationStoreError.corruptRecord }
            let storedMarkerFingerprint = portable.stagedBaseline?.deviceMarkerFingerprint
                ?? portable.baseline?.deviceMarkerFingerprint
            let markerWasRestored = storedMarkerFingerprint != marker.fingerprint
            if transaction.priorSendWasConfirmed && transaction.sameInstanceAndCA {
                try self.confirmation.writeRecord(for: pairing)
            }
            try self.credentials.commitMigratedPairing(pairing) {
                try self.migrationStore.finishMigration(pairing: pairing, marker: marker)
            }
            if markerWasRestored {
                try self.migrationStore.adoptRecoveredMigrationOnCurrentDevice(pairing: pairing, marker: marker)
            }
            self.appConfig?.applyMigratedPairing(pairing)
            self.didRotateCredential()
            return
        }

        guard var operation = try self.migrationStore.loadPendingRekey(ownerID: ownerID) else {
            throw DeviceMigrationStoreError.corruptRecord
        }

        if let responseBytes = operation.responseBytes {
            let priorConfirmation = portable.transaction?.priorSendWasConfirmed
                ?? self.confirmation.allowsSend(pairing: pairing)
            try self.commitResponse(
                responseBytes,
                operation: operation,
                oldPairing: pairing,
                marker: marker,
                priorConfirmation: priorConfirmation,
                ownerID: ownerID,
                pairingGeneration: pairingGeneration,
                mayContinue: mayContinue
            )
            return
        }

        operation.responseBytes = nil
        let candidates = TransportEndpoint.candidates(for: pairing)
        try await self.control.postRekey(
            pairing: pairing,
            candidates: candidates,
            body: operation.requestBytes,
            shouldContinue: { [weak self] in
                guard let self else { return false }
                return self.mayContinue(ownerID: ownerID, pairingGeneration: pairingGeneration, mayContinue: mayContinue)
            }
        ) { [weak self] responseBytes in
            guard let self,
                  self.mayContinue(ownerID: ownerID, pairingGeneration: pairingGeneration, mayContinue: mayContinue) else {
                throw CancellationError()
            }
            operation.responseBytes = responseBytes
            try self.migrationStore.savePendingRekey(operation, ownerID: ownerID)
            let priorConfirmation = (try self.migrationStore.loadPortable(for: identity).transaction?.priorSendWasConfirmed)
                ?? self.confirmation.allowsSend(pairing: pairing)
            try self.commitResponse(
                responseBytes,
                operation: operation,
                oldPairing: pairing,
                marker: marker,
                priorConfirmation: priorConfirmation,
                ownerID: ownerID,
                pairingGeneration: pairingGeneration,
                mayContinue: mayContinue
            )
        }
    }

    private func commitResponse(
        _ responseBytes: Data,
        operation: PendingDeviceRekey,
        oldPairing: StoredPairing,
        marker: DeviceMigrationMarker,
        priorConfirmation: Bool,
        ownerID: UUID,
        pairingGeneration: UInt64,
        mayContinue: @MainActor @Sendable () -> Bool
    ) throws {
        guard self.mayContinue(ownerID: ownerID, pairingGeneration: pairingGeneration, mayContinue: mayContinue) else {
            throw CancellationError()
        }
        let result = try DeviceMigrationPairingValidator.validate(
            responseData: responseBytes,
            expectedOperationID: operation.operationID,
            expectedPreviousCID: operation.previousCID,
            oldPairing: oldPairing,
            privateKeyPEM: operation.privateKeyPEM,
            relayEndpoint: oldPairing.relayEndpoint
        )
        try self.migrationStore.stageMigration(
            from: oldPairing,
            to: result.pairing,
            marker: marker,
            priorSendWasConfirmed: priorConfirmation,
            pairingOwnerID: ownerID
        )
        if priorConfirmation && result.sameInstanceAndCA {
            try self.confirmation.writeRecord(for: result.pairing)
        }
        try self.credentials.commitMigratedPairing(result.pairing) {
            try self.migrationStore.finishMigration(pairing: result.pairing, marker: marker)
        }
        self.appConfig?.applyMigratedPairing(result.pairing)
        self.didRotateCredential()
        migrationCoordinatorLog.info("device credential migration committed")
    }

    private func mayContinue(
        ownerID: UUID,
        pairingGeneration: UInt64,
        mayContinue: @MainActor @Sendable () -> Bool
    ) -> Bool {
        guard mayContinue() else { return false }
        let snapshot = self.credentials.snapshot()
        guard snapshot.pairingGeneration == pairingGeneration,
              snapshot.deviceOwnerID == ownerID else { return false }
        return (try? self.migrationStore.owns(ownerID: ownerID)) == true
    }
}
