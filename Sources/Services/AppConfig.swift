// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import SPLTunnel
import os

private let appConfigLog = Logger(subsystem: "app.solstone.swift", category: "app-config")

@MainActor
@Observable
final class AppConfig {
    var host: String
    var port: Int
    var journalRoot: String
    var deviceID: String
    var isPaired: Bool
    var homeLabel: String
    var clientCertFingerprintHex: String
    var pairedAt: Date?
    var loopbackPort: Int?
    private var journalSendConfirmationValue: Bool
    var journalSendConfirmed: Bool {
        get { self.journalSendConfirmationValue && self.store.hasActiveOwner }
        set { self.journalSendConfirmationValue = newValue }
    }
    let journalVersion: JournalVersionMetadata

    @ObservationIgnored let store: PairingCredentialStore
    @ObservationIgnored let confirmationStore: JournalSendConfirmationStore
    @ObservationIgnored let deviceMigrationStore: DeviceMigrationStore
    @ObservationIgnored private let endpointCache: EndpointCache
    @ObservationIgnored private let appGroupMirror: AppGroupMirror
    @ObservationIgnored private let journalMarkStore: JournalMarkStore

    init(
        loadPairing: @escaping @Sendable () throws -> StoredPairing? = { try SPLRuntime.keychainStore.load() },
        savePairing: @escaping @Sendable (StoredPairing) throws -> Void = { try SPLRuntime.keychainStore.save($0) },
        deletePairing: @escaping @Sendable () throws -> Void = { try SPLRuntime.keychainStore.delete() },
        confirmationStore: JournalSendConfirmationStore? = nil,
        store: PairingCredentialStore? = nil,
        endpointCache: EndpointCache = .shared,
        appGroupMirror: AppGroupMirror = AppGroupMirror(),
        journalMarkStore: JournalMarkStore = JournalMarkStore(),
        journalVersion: JournalVersionMetadata = JournalVersionMetadata()
    ) {
        let effectiveConfirmationStore = confirmationStore ?? SPLRuntime.confirmationStore
        let effectiveStore = store ?? PairingCredentialStore(
            confirmationStore: effectiveConfirmationStore,
            migrationStore: SPLRuntime.deviceMigrationStore,
            loadPairing: loadPairing,
            savePairing: savePairing,
            deletePairing: deletePairing
        )
        self.store = effectiveStore
        self.confirmationStore = effectiveConfirmationStore
        self.deviceMigrationStore = effectiveStore.migrationStore
        self.endpointCache = endpointCache
        self.appGroupMirror = appGroupMirror
        self.journalMarkStore = journalMarkStore
        self.journalVersion = journalVersion
        self.host = ""
        self.port = 22
        self.journalRoot = ""
        self.deviceID = ""
        self.isPaired = false
        self.homeLabel = ""
        self.clientCertFingerprintHex = ""
        self.pairedAt = nil
        self.loopbackPort = nil
        self.journalSendConfirmationValue = false

        self.store.registerOnApplyPairing { [weak self] in
            self?.journalSendConfirmed = false
        }

        do {
            if let pairing = try self.store.load() {
                self.applyDerivedState(from: pairing)
            } else {
                self.journalVersion.clear()
                self.appGroupMirror.clearPairing()
            }
        } catch {
            appConfigLog.error("load stored pairing failed: \(String(describing: error), privacy: .public)")
            self.appGroupMirror.clearPairing()
        }

        do {
            let settleOutcome = try self.confirmationStore.settle(
                loadPairing: { try self.store.reloadPairingFromKeychain() },
                onRestoreSnapshot: { [weak self] restored in
                    self?.applyDerivedState(from: restored)
                }
            )
            self.journalSendConfirmed = settleOutcome.isConfirmed
        } catch {
            appConfigLog.error("confirmation settle failed on init: \(String(describing: error), privacy: .public)")
            self.journalSendConfirmed = false
        }
    }

    @discardableResult
    func retrySettleIfNeeded() -> Bool {
        guard !self.journalSendConfirmed else { return false }
        do {
            let settleOutcome = try self.confirmationStore.settle(
                loadPairing: { try self.store.reloadPairingFromKeychain() },
                onRestoreSnapshot: { [weak self] restored in
                    self?.applyDerivedState(from: restored)
                }
            )
            if settleOutcome.isConfirmed {
                self.journalSendConfirmed = true
                return true
            }
            return false
        } catch {
            appConfigLog.error("confirmation retry settle failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    func applyPairing(_ pairing: StoredPairing) throws {
        let newIdentity = journalVersionMetadataIdentity(for: pairing)
        let unchangedIdentity = newIdentity != nil && newIdentity == self.journalVersion.identity
        self.journalSendConfirmed = false
        do {
            try self.store.applyPairing(pairing)
        } catch {
            if self.store.snapshot().pairing?.fingerprint == pairing.fingerprint {
                if !unchangedIdentity { self.journalVersion.clear() }
                self.applyDerivedState(from: pairing)
            }
            throw error
        }
        if !unchangedIdentity {
            self.journalVersion.clear()
        }
        self.reflectCommittedPairing(pairing)
        appConfigLog.info("pairing applied for \(pairing.homeLabel, privacy: .public)")
    }

    func reflectCommittedPairing(_ pairing: StoredPairing) {
        guard self.store.snapshot().pairing?.fingerprint == pairing.fingerprint else { return }
        let newIdentity = journalVersionMetadataIdentity(for: pairing)
        if newIdentity != self.journalVersion.identity { self.journalVersion.clear() }
        self.journalSendConfirmed = false
        self.applyDerivedState(from: pairing)
        Task { await self.endpointCache.bootstrap(from: pairing) }
    }

    func applyMigratedPairing(_ pairing: StoredPairing) {
        self.applyDerivedState(from: pairing)
        self.journalSendConfirmed = self.confirmationStore.allowsSend(pairing: pairing)
        Task { await self.endpointCache.bootstrap(from: pairing) }
        appConfigLog.info("migrated pairing applied for \(pairing.homeLabel, privacy: .public)")
    }

    @discardableResult
    func clearPairing() -> Bool {
        do {
            if self.store.snapshot().pairing == nil {
                try self.store.clearPairing()
            } else {
                let lease = try self.store.beginPairingInvalidation()
                guard try self.store.clearPairing(invalidation: lease) else { return false }
            }
        } catch {
            appConfigLog.error("clear pairing keychain failed: \(String(describing: error), privacy: .public)")
            return false
        }

        self.finishPairingClear()
        return true
    }

    func beginPairingInvalidation(
        expectedOwnerID: UUID? = nil,
        expectedPairingGeneration: UInt64? = nil
    ) throws -> DeviceMigrationInvalidationLease {
        let lease = try self.store.beginPairingInvalidation(
            expectedOwnerID: expectedOwnerID,
            expectedPairingGeneration: expectedPairingGeneration
        )
        self.journalSendConfirmationValue = false
        return lease
    }

    @discardableResult
    func clearPairing(invalidation lease: DeviceMigrationInvalidationLease) -> Bool {
        do {
            guard try self.store.clearPairing(invalidation: lease) else { return false }
        } catch {
            appConfigLog.error("clear pairing cleanup failed: \(String(describing: error), privacy: .public)")
            return false
        }
        self.finishPairingClear()
        return true
    }

    private func finishPairingClear() {
        self.journalSendConfirmed = false
        self.journalVersion.clear()
        Task {
            await self.endpointCache.wipe()
        }
        self.host = ""
        self.port = 22
        self.journalRoot = ""
        self.deviceID = ""
        self.isPaired = false
        self.homeLabel = ""
        self.clientCertFingerprintHex = ""
        self.pairedAt = nil
        self.loopbackPort = nil
        self.appGroupMirror.clearPairing()
        // The mark is a property of the pairing, so unpairing is the one and only event that
        // clears it. ⛔ Nothing else may — see `JournalMarkStore`.
        self.journalMarkStore.clear()
        appConfigLog.info("pairing cleared")
    }

    func currentSessionKey() -> String? {
        nil
    }

    /// True when a pairing is stored and the owner has not confirmed the journal's mark.
    ///
    /// Accepted window: if `settle` throws before first unlock, `journalSendConfirmed` can
    /// read false while a later `allowsSend` would be true, until `retrySettleIfNeeded` on
    /// the next foreground. `ContentView.presentHeldJournalReAskIfNeeded` and `SolstoneSwiftApp`
    /// already call `retrySettleIfNeeded` on foreground and connect. This property does not
    /// exempt that window.
    var awaitingMarkConfirmation: Bool {
        self.isPaired && !self.journalSendConfirmed
    }

#if DEBUG
    func seedUITestPairing(
        host: String = "journal.local",
        port: Int = 22,
        journalRoot: String = "http://127.0.0.1:7071",
        deviceID: String = "ui-test-device",
        sessionKey: String? = nil,
        homeLabel: String = "ui-test-solstone",
        endpointPort: Int? = nil,
        relayEndpoint: String? = nil,
        confirmsSend: Bool = true
    ) {
        let endpointPort = endpointPort ?? Self.endpointPort(from: journalRoot)
            ?? Int(ProcessInfo.processInfo.environment["MOCK_PAIRING_PORT"] ?? "")
            ?? port
        let endpointHost = URL(string: journalRoot)?.host ?? host
        let pairing = StoredPairing(
            instanceID: "ui-test-instance",
            homeLabel: homeLabel,
            relayEndpoint: relayEndpoint ?? "wss://127.0.0.1:\(endpointPort)",
            fingerprint: Self.syntheticFingerprint,
            clientCertPEM: CertlessTrustConstants.leafPEM,
            clientKeyPEM: Self.syntheticPrivateKeyPEM,
            caChainPEM: CertlessTrustConstants.caPEM,
            relayEnrollment: .enrolled(deviceToken: sessionKey ?? "ui-test-device-token", expiresAt: nil),
            localEndpoints: [
                LocalEndpoint(host: endpointHost, port: endpointPort, scope: "")
            ],
            pairedAt: Date(timeIntervalSince1970: 1_776_144_000)
        )

        do {
            try self.applyPairing(pairing)
            // This DEBUG fixture represents an already paired shell. A prior
            // no-journal test can leave the same journal's adoption baseline;
            // reseeding it must not become a new owner replacement ceremony.
            try self.deviceMigrationStore.finishFreshPairing(pairing: pairing, includeFreshPairOffer: false)
        } catch {
            appConfigLog.error("ui-test pairing seed save failed: \(String(describing: error), privacy: .public)")
            self.applyDerivedState(from: pairing)
        }
        self.journalRoot = journalRoot
        self.host = host
        self.port = endpointPort
        self.loopbackPort = endpointPort
        self.deviceID = deviceID

        if confirmsSend {
            do {
                try self.confirmationStore.writeRecord(for: pairing)
                self.journalSendConfirmed = true
            } catch {
                appConfigLog.error("ui-test confirmation write failed: \(String(describing: error), privacy: .public)")
            }
        } else {
            self.journalSendConfirmed = false
        }
    }
#endif

    private func applyDerivedState(from pairing: StoredPairing) {
        self.journalVersion.setIdentity(journalVersionMetadataIdentity(for: pairing))
        let firstEndpoint = pairing.localEndpoints.first
        self.host = firstEndpoint?.host ?? URL(string: pairing.relayEndpoint)?.host ?? ""
        self.port = firstEndpoint?.port ?? URL(string: pairing.relayEndpoint)?.port ?? 443
        self.journalRoot = firstEndpoint.map { "http://127.0.0.1:\($0.port)" } ?? ""
        self.deviceID = pairing.instanceID
        self.isPaired = true
        self.homeLabel = pairing.homeLabel
        self.clientCertFingerprintHex = Self.normalizedFingerprint(pairing.fingerprint)
        self.pairedAt = pairing.pairedAt
        self.loopbackPort = firstEndpoint?.port
        self.appGroupMirror.writePairing(journalName: nil)
    }

    private static func normalizedFingerprint(_ fingerprint: String) -> String {
        let lower = fingerprint.lowercased()
        if lower.hasPrefix("sha256:") {
            return String(lower.dropFirst("sha256:".count))
        }
        return lower
    }

    func loadStoredPairing() -> StoredPairing? {
        do {
            return try self.store.load()
        } catch {
            appConfigLog.error("load stored pairing failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

#if DEBUG
    private static func endpointPort(from journalRoot: String) -> Int? {
        guard let url = URL(string: journalRoot) else { return nil }
        return url.port
    }

    private static let syntheticFingerprint = String(repeating: "a", count: 64)
    private static let syntheticPrivateKeyPEM = """
    -----BEGIN PRIVATE KEY-----
    MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgaaaaaaaaaaaaaaaaaaaa
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaahRANCAASaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    aaaaaaaaaaaaaaaaaaaaaaaaaaaa
    -----END PRIVATE KEY-----
    """
#endif
}
