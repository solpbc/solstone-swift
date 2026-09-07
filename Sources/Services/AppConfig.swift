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
    var ownerIdentity: String
    var deviceID: String
    var isPaired: Bool
    var homeLabel: String
    var caFingerprintHex: String
    var pairedAt: Date?
    var loopbackPort: Int?
    let journalVersion: JournalVersionMetadata

    @ObservationIgnored let store: PairingCredentialStore
    @ObservationIgnored private let endpointCache: EndpointCache
    @ObservationIgnored private let appGroupMirror: AppGroupMirror
    @ObservationIgnored private let journalMarkStore: JournalMarkStore

    init(
        loadPairing: @escaping @Sendable () throws -> StoredPairing? = { try SPLRuntime.keychainStore.load() },
        savePairing: @escaping @Sendable (StoredPairing) throws -> Void = { try SPLRuntime.keychainStore.save($0) },
        deletePairing: @escaping @Sendable () throws -> Void = { try SPLRuntime.keychainStore.delete() },
        store: PairingCredentialStore? = nil,
        endpointCache: EndpointCache = EndpointCache(),
        appGroupMirror: AppGroupMirror = AppGroupMirror(),
        journalMarkStore: JournalMarkStore = JournalMarkStore(),
        journalVersion: JournalVersionMetadata = JournalVersionMetadata()
    ) {
        let effectiveStore = store ?? PairingCredentialStore(
            loadPairing: loadPairing,
            savePairing: savePairing,
            deletePairing: deletePairing
        )
        self.store = effectiveStore
        self.endpointCache = endpointCache
        self.appGroupMirror = appGroupMirror
        self.journalMarkStore = journalMarkStore
        self.journalVersion = journalVersion
        self.host = ""
        self.port = 22
        self.journalRoot = ""
        self.ownerIdentity = ""
        self.deviceID = ""
        self.isPaired = false
        self.homeLabel = ""
        self.caFingerprintHex = ""
        self.pairedAt = nil
        self.loopbackPort = nil

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
    }

    func applyPairing(_ pairing: StoredPairing) throws {
        let newIdentity = journalVersionMetadataIdentity(for: pairing)
        let unchangedIdentity = newIdentity != nil && newIdentity == self.journalVersion.identity
        try self.store.applyPairing(pairing)
        if !unchangedIdentity {
            self.journalVersion.clear()
        }
        self.applyDerivedState(from: pairing)
        Task {
            await self.endpointCache.bootstrap(from: pairing)
        }
        appConfigLog.info("pairing applied for \(pairing.homeLabel, privacy: .public)")
    }

    func clearPairing() {
        self.journalVersion.clear()
        do {
            try self.store.clearPairing()
        } catch {
            appConfigLog.error("clear pairing keychain failed: \(String(describing: error), privacy: .public)")
        }

        Task {
            await self.endpointCache.wipe()
        }
        self.host = ""
        self.port = 22
        self.journalRoot = ""
        self.ownerIdentity = ""
        self.deviceID = ""
        self.isPaired = false
        self.homeLabel = ""
        self.caFingerprintHex = ""
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

#if DEBUG
    func seedUITestPairing(
        host: String = "journal.local",
        port: Int = 22,
        journalRoot: String = "http://127.0.0.1:7071",
        ownerIdentity: String = "Jeremiah",
        deviceID: String = "test-device-id",
        sessionKey: String? = nil,
        isPaired: Bool = true,
        homeLabel: String = "Jeremiah's Journal",
        caFingerprintHex: String = "feedfacecafebeef0123456789abcdef0123456789abcdef0123456789abcdef",
        pairedAt: Date = Date(),
        endpointPort: Int = 7071,
        relayEndpoint: String = "https://relay.example.com",
        clientCertPEM: String = "CERT",
        clientKeyPEM: String = "KEY",
        caChainPEM: String = "CA",
        deviceToken: String = "token"
    ) {
        let pairing = StoredPairing(
            instanceID: deviceID,
            homeLabel: homeLabel,
            relayEndpoint: relayEndpoint,
            fingerprint: caFingerprintHex,
            clientCertPEM: clientCertPEM,
            clientKeyPEM: clientKeyPEM,
            caChainPEM: caChainPEM,
            relayEnrollment: .enrolled(deviceToken: deviceToken, expiresAt: nil),
            localEndpoints: [LocalEndpoint(host: host, port: endpointPort, scope: "local")],
            pairedAt: pairedAt
        )
        try? self.applyPairing(pairing)
        self.isPaired = isPaired
        self.journalRoot = journalRoot
        self.ownerIdentity = ownerIdentity
        self.homeLabel = homeLabel
        self.caFingerprintHex = caFingerprintHex
        self.pairedAt = pairedAt
        self.host = host
        self.port = endpointPort
        self.loopbackPort = endpointPort
        self.deviceID = deviceID
    }
#endif

    private func applyDerivedState(from pairing: StoredPairing) {
        self.journalVersion.setIdentity(journalVersionMetadataIdentity(for: pairing))
        let firstEndpoint = pairing.localEndpoints.first
        self.host = firstEndpoint?.host ?? URL(string: pairing.relayEndpoint)?.host ?? ""
        self.port = firstEndpoint?.port ?? URL(string: pairing.relayEndpoint)?.port ?? 443
        self.journalRoot = firstEndpoint.map { "http://127.0.0.1:\($0.port)" } ?? ""
        self.ownerIdentity = pairing.homeLabel
        self.deviceID = pairing.instanceID
        self.isPaired = true
        self.homeLabel = pairing.homeLabel
        self.caFingerprintHex = Self.normalizedFingerprint(pairing.fingerprint)
        self.pairedAt = pairing.pairedAt
        self.loopbackPort = firstEndpoint?.port
        self.appGroupMirror.writePairing(journalName: pairing.homeLabel)
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
}
