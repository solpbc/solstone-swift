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
    var serverVersion: String
    var isPaired: Bool
    var homeLabel: String
    var caFingerprintHex: String
    var pairedAt: Date?
    var loopbackPort: Int?

    @ObservationIgnored private let loadPairing: @Sendable () throws -> StoredPairing?
    @ObservationIgnored private let savePairing: @Sendable (StoredPairing) throws -> Void
    @ObservationIgnored private let deletePairing: @Sendable () throws -> Void
    @ObservationIgnored private let endpointCache: EndpointCache

    init(
        loadPairing: @escaping @Sendable () throws -> StoredPairing? = { try SPLKeychain.load() },
        savePairing: @escaping @Sendable (StoredPairing) throws -> Void = { try SPLKeychain.save($0) },
        deletePairing: @escaping @Sendable () throws -> Void = { try SPLKeychain.delete() },
        endpointCache: EndpointCache = EndpointCache()
    ) {
        self.loadPairing = loadPairing
        self.savePairing = savePairing
        self.deletePairing = deletePairing
        self.endpointCache = endpointCache
        self.host = ""
        self.port = 22
        self.journalRoot = ""
        self.ownerIdentity = ""
        self.deviceID = ""
        self.serverVersion = ""
        self.isPaired = false
        self.homeLabel = ""
        self.caFingerprintHex = ""
        self.pairedAt = nil
        self.loopbackPort = nil

        do {
            if let pairing = try loadPairing() {
                self.applyDerivedState(from: pairing)
            }
        } catch {
            appConfigLog.error("load stored pairing failed: \(String(describing: error), privacy: .public)")
        }
    }

    func applyPairing(_ pairing: StoredPairing) throws {
        try self.savePairing(pairing)
        self.applyDerivedState(from: pairing)
        Task {
            await self.endpointCache.bootstrap(from: pairing)
        }
        appConfigLog.info("pairing applied for \(pairing.homeLabel, privacy: .public)")
    }

    func clearPairing() {
        do {
            try self.deletePairing()
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
        self.serverVersion = ""
        self.isPaired = false
        self.homeLabel = ""
        self.caFingerprintHex = ""
        self.pairedAt = nil
        self.loopbackPort = nil
        appConfigLog.info("pairing cleared")
    }

    func currentSessionKey() -> String? {
        nil
    }

    func seedUITestPairing(
        host: String = "journal.local",
        port: Int = 22,
        journalRoot: String = "http://127.0.0.1:7071",
        deviceID: String = "ui-test-device",
        sessionKey: String? = nil
    ) {
        let endpointPort = Self.endpointPort(from: journalRoot)
            ?? Int(ProcessInfo.processInfo.environment["MOCK_PAIRING_PORT"] ?? "")
            ?? port
        let endpointHost = URL(string: journalRoot)?.host ?? host
        let pairing = StoredPairing(
            instanceID: "ui-test-instance",
            homeLabel: "ui-test-solstone",
            relayEndpoint: "ws://127.0.0.1:\(endpointPort)",
            fingerprint: Self.syntheticFingerprint,
            clientCertPEM: Self.syntheticCertificatePEM,
            clientKeyPEM: Self.syntheticPrivateKeyPEM,
            caChainPEM: Self.syntheticCertificatePEM,
            deviceToken: sessionKey ?? "ui-test-device-token",
            localEndpoints: [
                LocalEndpoint(host: endpointHost, port: endpointPort, scope: "")
            ],
            pairedAt: Date(timeIntervalSince1970: 1_776_144_000)
        )

        do {
            try self.applyPairing(pairing)
        } catch {
            appConfigLog.error("ui-test pairing seed save failed: \(String(describing: error), privacy: .public)")
            self.applyDerivedState(from: pairing)
        }
        self.journalRoot = journalRoot
        self.host = host
        self.port = endpointPort
        self.loopbackPort = endpointPort
        self.deviceID = deviceID
        self.serverVersion = "ui-test"
    }

    private func applyDerivedState(from pairing: StoredPairing) {
        let firstEndpoint = pairing.localEndpoints.first
        self.host = firstEndpoint?.host ?? URL(string: pairing.relayEndpoint)?.host ?? ""
        self.port = firstEndpoint?.port ?? URL(string: pairing.relayEndpoint)?.port ?? 443
        self.journalRoot = firstEndpoint.map { "http://127.0.0.1:\($0.port)" } ?? ""
        self.ownerIdentity = pairing.homeLabel
        self.deviceID = pairing.instanceID
        self.serverVersion = ""
        self.isPaired = true
        self.homeLabel = pairing.homeLabel
        self.caFingerprintHex = Self.normalizedFingerprint(pairing.fingerprint)
        self.pairedAt = pairing.pairedAt
        self.loopbackPort = firstEndpoint?.port
    }

    private static func normalizedFingerprint(_ fingerprint: String) -> String {
        let lower = fingerprint.lowercased()
        if lower.hasPrefix("sha256:") {
            return String(lower.dropFirst("sha256:".count))
        }
        return lower
    }

    private static func endpointPort(from journalRoot: String) -> Int? {
        guard let url = URL(string: journalRoot) else { return nil }
        return url.port
    }

    private static let syntheticFingerprint = String(repeating: "a", count: 64)
    private static let syntheticCertificatePEM = """
    -----BEGIN CERTIFICATE-----
    MIIBsjCCAVigAwIBAgIJAO0AAAAAAAAAMAoGCCqGSM49BAMCMBcxFTATBgNVBAMM
    DHVpLXRlc3QtY2VydDAeFw0yNjAxMDEwMDAwMDBaFw0yNzAxMDEwMDAwMDBaMBcx
    FTATBgNVBAMMDHVpLXRlc3QtY2VydDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IA
    BAaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaajUzBRMB0G
    A1UdDgQWBBSaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaAfBgNVHSMEGDAWgBSa
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaAPBgNVHRMBAf8EBTADAQH/MAoGCCqG
    SM49BAMCA0gAMEUCIQDaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaIgIgDaaa
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=
    -----END CERTIFICATE-----
    """
    private static let syntheticPrivateKeyPEM = """
    -----BEGIN PRIVATE KEY-----
    MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgaaaaaaaaaaaaaaaaaaaa
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaahRANCAASaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    aaaaaaaaaaaaaaaaaaaaaaaaaaaa
    -----END PRIVATE KEY-----
    """
}
