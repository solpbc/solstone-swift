// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel
import os

#if DEBUG && targetEnvironment(simulator)
private let log = Logger(subsystem: "app.solstone.swift", category: "integration-gate-pairing")

struct IntegrationGatePairingSnapshot: Sendable, Equatable {
    var instanceID: String
    var fingerprintSHA256Hex: String
    var pairedAtUnixMillis: Int64
    var relayEnrollmentPresent: Bool
    var relayEndpoint: String

    var resultSnapshot: IntegrationGateResultPairingSnapshot {
        IntegrationGateResultPairingSnapshot(
            instanceID: instanceID,
            fingerprintSHA256Hex: fingerprintSHA256Hex,
            pairedAtUnixMillis: pairedAtUnixMillis,
            relayEnrollmentPresent: relayEnrollmentPresent,
            relayEndpoint: relayEndpoint
        )
    }
}

struct IntegrationGatePairingSnapshotLoader: Sendable {
    // Exactly one pairing is structural: SPLRuntime.keychainPolicy fixes one service/account,
    // and Tests/SPLRuntimeTests.swift asserts that production contract. Do not enumerate.
    func loadValidatedPairing(
        for manifest: IntegrationGateManifest,
        keychainStore: SPLKeychainStore = SPLRuntime.keychainStore
    ) throws -> (StoredPairing, IntegrationGatePairingSnapshot) {
        guard let pairing = try keychainStore.load() else {
            throw IntegrationGateValidationError(.zeroPairing)
        }
        let snapshot = try self.validatedSnapshot(pairing: pairing, manifest: manifest)
        return (pairing, snapshot)
    }

    func revalidate(
        original: IntegrationGatePairingSnapshot,
        manifest: IntegrationGateManifest,
        keychainStore: SPLKeychainStore = SPLRuntime.keychainStore
    ) throws -> StoredPairing {
        guard let pairing = try keychainStore.load() else {
            throw IntegrationGateValidationError(.zeroPairing)
        }
        let snapshot = try self.snapshot(pairing: pairing)
        guard snapshot == original else {
            throw IntegrationGateValidationError(.changedPairing)
        }
        try self.validate(snapshot: snapshot, pairing: pairing, manifest: manifest)
        return pairing
    }

    func validatedSnapshot(pairing: StoredPairing, manifest: IntegrationGateManifest) throws -> IntegrationGatePairingSnapshot {
        let snapshot = try self.snapshot(pairing: pairing)
        try self.validate(snapshot: snapshot, pairing: pairing, manifest: manifest)
        return snapshot
    }

    func relayOnlyPairingCopy(from pairing: StoredPairing) -> StoredPairing {
        StoredPairing(
            instanceID: pairing.instanceID,
            homeLabel: pairing.homeLabel,
            relayEndpoint: pairing.relayEndpoint,
            fingerprint: pairing.fingerprint,
            clientCertPEM: pairing.clientCertPEM,
            clientKeyPEM: pairing.clientKeyPEM,
            caChainPEM: pairing.caChainPEM,
            relayEnrollment: pairing.relayEnrollment,
            localEndpoints: [],
            pairedAt: pairing.pairedAt
        )
    }

    private func snapshot(pairing: StoredPairing) throws -> IntegrationGatePairingSnapshot {
        let relayEnrollmentPresent: Bool
        switch pairing.relayEnrollment {
        case .enrolled(let deviceToken, _):
            relayEnrollmentPresent = !deviceToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .unavailable:
            relayEnrollmentPresent = false
        }
        return IntegrationGatePairingSnapshot(
            instanceID: pairing.instanceID,
            fingerprintSHA256Hex: pairing.fingerprint,
            pairedAtUnixMillis: Int64(pairing.pairedAt.timeIntervalSince1970 * 1_000),
            relayEnrollmentPresent: relayEnrollmentPresent,
            relayEndpoint: pairing.relayEndpoint
        )
    }

    private func validate(
        snapshot: IntegrationGatePairingSnapshot,
        pairing: StoredPairing,
        manifest: IntegrationGateManifest
    ) throws {
        guard snapshot.instanceID == manifest.expectedPairing.instanceID,
              snapshot.fingerprintSHA256Hex == manifest.expectedPairing.fingerprintSHA256Hex
        else {
            throw IntegrationGateValidationError(.foreignPairing)
        }
        guard snapshot.pairedAtUnixMillis >= manifest.expectedPairing.pairedAtNotBeforeUnixMillis else {
            throw IntegrationGateValidationError(.stalePairing)
        }
        guard snapshot.relayEnrollmentPresent else {
            throw IntegrationGateValidationError(.absentRelayEnrollment)
        }
        // go.solstone.app is the applink host. The SPL relay endpoint compared here is link.solstone.app.
        guard pairing.relayEndpoint == IntegrationGateConstants.relayEndpoint else {
            throw IntegrationGateValidationError(.wrongRelayEndpoint)
        }
    }
}
#endif
