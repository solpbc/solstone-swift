// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Foundation
import Observation
import SPLTunnel

/// Connection freshness is memory-only; a saved observation is always last known on launch.
@MainActor
@Observable
final class JournalVersionMetadata {
    nonisolated struct Record: Codable {
        let identity: String
        let version: String
        let name: String?

        init(identity: String, version: String, name: String? = nil) {
            self.identity = identity
            self.version = version
            self.name = name
        }
    }

    private(set) var version: String?
    private(set) var name: String?
    private(set) var isCurrent = false
    var displayValue: String {
        guard let version else { return "unknown" }
        return isCurrent ? version : "\(version) (last known)"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetch: @Sendable (Int) async -> String?
    @ObservationIgnored private(set) var identity: String?
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var activePort: Int?
    @ObservationIgnored private var task: Task<Void, Never>?
    private static let storageKey = "journalVersionMetadata"

    init(
        defaults: UserDefaults = .standard,
        fetch: @escaping @Sendable (Int) async -> String? = { await AuthenticatedHomeClient().fetchStatus(localPort: $0) }
    ) {
        self.defaults = defaults
        self.fetch = fetch
    }

    func setIdentity(_ value: String?) {
        defer { onChange?() }
        guard identity != value else {
            if value == nil { clear() }
            return
        }
        disconnected()
        identity = value
        version = nil
        name = nil
        if let value, let data = defaults.data(forKey: Self.storageKey),
           let record = try? JSONDecoder().decode(Record.self, from: data),
           record.identity == value, let saved = sanitizedJournalVersion(record.version) {
            version = saved
            name = sanitizedJournalName(record.name)
        } else {
            defaults.removeObject(forKey: Self.storageKey)
        }
    }

    func clear() {
        defer { onChange?() }
        disconnected()
        identity = nil
        version = nil
        name = nil
        defaults.removeObject(forKey: Self.storageKey)
    }

    func disconnected() {
        defer { onChange?() }
        generation &+= 1
        activePort = nil
        isCurrent = false
        task?.cancel()
        task = nil
    }

    func noteConnected(localPort: Int) {
        self.activePort = localPort
    }

    @discardableResult
    func connected(localPort: Int) -> Task<Void, Never>? {
        guard let identity else { return task }
        disconnected()
        activePort = localPort
        let expectedGeneration = generation
        let fetch = self.fetch
        let request = Task { @MainActor [weak self] in
            let result = await fetch(localPort)
            guard let self, self.generation == expectedGeneration,
                  self.identity == identity, self.activePort == localPort,
                  let result, let version = sanitizedJournalVersion(result) else { return }
            // Validation and persistence share this actor turn with pairing/lifecycle changes.
            let currentName = self.name
            if let data = try? JSONEncoder().encode(Record(identity: identity, version: version, name: currentName)) {
                self.defaults.set(data, forKey: Self.storageKey)
            }
            self.version = version
            self.isCurrent = true
            self.onChange?()
        }
        task = request
        return request
    }

    func applyValidated(
        name: String?,
        version: String?,
        pairingIdentity: String,
        isClientsSelfUpdate: Bool = true
    ) {
        guard let identity = self.identity,
              identity == pairingIdentity,
              self.activePort != nil else { return }

        let cleanVersion = version.flatMap(sanitizedJournalVersion)
        guard let cleanVersion else { return }

        let cleanName = name.flatMap(sanitizedJournalName)
        let effectiveName: String? = isClientsSelfUpdate ? cleanName : (cleanName ?? self.name)

        if let data = try? JSONEncoder().encode(Record(identity: identity, version: cleanVersion, name: effectiveName)) {
            self.defaults.set(data, forKey: Self.storageKey)
        }
        self.version = cleanVersion
        self.name = effectiveName
        self.isCurrent = true
        self.onChange?()
    }
}

nonisolated func sanitizedJournalName(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    for scalar in trimmed.unicodeScalars {
        if CharacterSet.controlCharacters.contains(scalar) {
            return nil
        }
    }

    guard trimmed.utf8.count <= 80 else {
        return nil
    }

    return trimmed
}

nonisolated internal func journalVersionMetadataIdentity(for pairing: StoredPairing) -> String? {
    guard let normalizedCAFingerprint = normalizedCAFingerprint(for: pairing.caChainPEM),
          let clientCertFingerprint = clientCertFingerprint(for: pairing.clientCertPEM) else {
        return nil
    }
    return opaqueSHA256([
        "journal-version-metadata-v2",
        pairing.instanceID,
        normalizedCAFingerprint,
        clientCertFingerprint
    ])
}

nonisolated private func clientCertFingerprint(for pem: String) -> String? {
    guard let certificate = try? CertChain.certificates(fromPEM: pem).first else {
        return nil
    }
    return CertChain.sha256Fingerprint(of: certificate)
}

nonisolated private func normalizedCAFingerprint(for pem: String) -> String? {
    guard let certificates = try? CertChain.certificates(fromPEM: pem), !certificates.isEmpty else {
        return nil
    }
    let fingerprints = certificates.map(CertChain.sha256Fingerprint(of:))
    return opaqueSHA256(["journal-version-ca-chain-v1"] + fingerprints)
}

nonisolated private func opaqueSHA256(_ parts: [String]) -> String {
    let canonical = parts.joined(separator: "\u{1F}")
    let digest = SHA256.hash(data: Data(canonical.utf8))
    return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
}
