// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

private let appConfigLog = Logger(subsystem: "org.solpbc.solstone-swift", category: "app-config")

@MainActor
@Observable
final class AppConfig {
    private enum DefaultsKey {
        static let host = "pairing.host"
        static let port = "pairing.port"
        static let journalRoot = "pairing.journalRoot"
        static let ownerIdentity = "pairing.ownerIdentity"
        static let deviceID = "pairing.deviceID"
        static let serverVersion = "pairing.serverVersion"
        static let seededPairSession = "pairing.seededPairSession"
    }

    var host: String
    var port: Int
    var journalRoot: String
    var ownerIdentity: String
    var deviceID: String
    var serverVersion: String
    var isPaired: Bool

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let loadPairSession: @Sendable () throws -> String?
    @ObservationIgnored private let savePairSession: @Sendable (String) throws -> Void
    @ObservationIgnored private let deletePairSession: @Sendable () throws -> Void
    @ObservationIgnored private let deletePairIdentity: @Sendable () throws -> Void
    @ObservationIgnored private var seededPairSession: String?

    init(
        defaults: UserDefaults = .standard,
        loadPairSession: @escaping @Sendable () throws -> String? = { try KeychainStore.loadPairSession() },
        savePairSession: @escaping @Sendable (String) throws -> Void = { try KeychainStore.savePairSession($0) },
        deletePairSession: @escaping @Sendable () throws -> Void = { try KeychainStore.deletePairSession() },
        deletePairIdentity: @escaping @Sendable () throws -> Void = { try KeychainStore.deletePairIdentity() }
    ) {
        self.defaults = defaults
        self.loadPairSession = loadPairSession
        self.savePairSession = savePairSession
        self.deletePairSession = deletePairSession
        self.deletePairIdentity = deletePairIdentity
        self.seededPairSession = nil
        self.host = defaults.string(forKey: DefaultsKey.host) ?? ""
        self.port = defaults.object(forKey: DefaultsKey.port) as? Int ?? 22
        self.journalRoot = defaults.string(forKey: DefaultsKey.journalRoot) ?? ""
        self.ownerIdentity = defaults.string(forKey: DefaultsKey.ownerIdentity) ?? ""
        self.deviceID = defaults.string(forKey: DefaultsKey.deviceID) ?? ""
        self.serverVersion = defaults.string(forKey: DefaultsKey.serverVersion) ?? ""
        let existingSession = try? loadPairSession()
        switch existingSession {
        case .some(let session):
            self.isPaired = !session.isEmpty
        default:
            self.isPaired = false
        }
    }

    func applyPairConfirm(_ response: PairConfirmResponse) throws {
        try self.savePairSession(response.sessionKey)
        self.seededPairSession = response.sessionKey
        self.host = response.host
        self.port = response.port
        self.journalRoot = response.journalRoot
        self.ownerIdentity = response.ownerIdentity
        self.deviceID = response.deviceID
        self.serverVersion = response.serverVersion ?? ""
        self.isPaired = true
        self.defaults.removeObject(forKey: DefaultsKey.seededPairSession)
        self.persist()
        appConfigLog.info("pairing applied for host \(response.host, privacy: .public)")
    }

    func clearPairing() {
        do {
            try self.deletePairSession()
            try self.deletePairIdentity()
        } catch {
            appConfigLog.error("clear pairing keychain failed: \(String(describing: error), privacy: .public)")
        }

        self.host = ""
        self.port = 22
        self.journalRoot = ""
        self.ownerIdentity = ""
        self.deviceID = ""
        self.serverVersion = ""
        self.isPaired = false
        self.seededPairSession = nil
        self.defaults.removeObject(forKey: DefaultsKey.host)
        self.defaults.removeObject(forKey: DefaultsKey.port)
        self.defaults.removeObject(forKey: DefaultsKey.journalRoot)
        self.defaults.removeObject(forKey: DefaultsKey.ownerIdentity)
        self.defaults.removeObject(forKey: DefaultsKey.deviceID)
        self.defaults.removeObject(forKey: DefaultsKey.serverVersion)
        self.defaults.removeObject(forKey: DefaultsKey.seededPairSession)
        appConfigLog.info("pairing cleared")
    }

    func currentSessionKey() -> String? {
        if let seededPairSession, !seededPairSession.isEmpty {
            return seededPairSession
        }
        switch try? self.loadPairSession() {
        case .some(let session):
            return session
        default:
            return self.defaults.string(forKey: DefaultsKey.seededPairSession)
        }
    }

    func seedUITestPairing(
        host: String = "journal.local",
        port: Int = 22,
        journalRoot: String = "http://127.0.0.1:7071",
        deviceID: String = "ui-test-device",
        sessionKey: String? = nil
    ) {
        self.host = host
        self.port = port
        self.journalRoot = journalRoot
        self.ownerIdentity = "sol"
        self.deviceID = deviceID
        self.serverVersion = "ui-test"
        self.isPaired = true
        if let sessionKey {
            self.seededPairSession = sessionKey
            self.defaults.set(sessionKey, forKey: DefaultsKey.seededPairSession)
            try? self.savePairSession(sessionKey)
        } else {
            self.seededPairSession = nil
            self.defaults.removeObject(forKey: DefaultsKey.seededPairSession)
        }
        self.persist()
    }

    private func persist() {
        self.defaults.set(self.host, forKey: DefaultsKey.host)
        self.defaults.set(self.port, forKey: DefaultsKey.port)
        self.defaults.set(self.journalRoot, forKey: DefaultsKey.journalRoot)
        self.defaults.set(self.ownerIdentity, forKey: DefaultsKey.ownerIdentity)
        self.defaults.set(self.deviceID, forKey: DefaultsKey.deviceID)
        self.defaults.set(self.serverVersion, forKey: DefaultsKey.serverVersion)
    }
}
