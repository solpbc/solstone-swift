// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation
import NIOSSH
import Security

enum KeychainError: Error {
    case unexpectedStatus(OSStatus)
}

nonisolated enum KeychainStore {
    static let service = "app.solstone.swift"
    static let identityKeyAccount = "solstone-swift-identity-key"
    static let hostKeyAccount = "solstone-swift-host-key"
    static let observerIngestKeyAccount = "solstone-swift-observer-ingest-key"
    static let pairIdentityAccount = "solstone-swift-pair-identity"
    static let pairSessionAccount = "solstone-swift-pair-session"

    static func saveIdentityKey(_ key: Curve25519.Signing.PrivateKey) throws {
        try save(data: Data(key.rawRepresentation), account: identityKeyAccount)
    }

    static func loadIdentityKey() throws -> Curve25519.Signing.PrivateKey? {
        guard let data = try load(account: identityKeyAccount) else {
            return nil
        }

        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    static func deleteIdentityKey() throws {
        try delete(account: identityKeyAccount)
    }

    static func saveHostKey(_ key: NIOSSHPublicKey) throws {
        let data = Data(String(openSSHPublicKey: key).utf8)
        try save(data: data, account: hostKeyAccount)
    }

    static func loadHostKey() throws -> NIOSSHPublicKey? {
        guard let data = try load(account: hostKeyAccount) else {
            return nil
        }

        let keyString = String(decoding: data, as: UTF8.self)
        return try NIOSSHPublicKey(openSSHPublicKey: keyString)
    }

    static func deleteHostKey() throws {
        try delete(account: hostKeyAccount)
    }

    static func saveObserverIngestKey(_ key: String) throws {
        try save(data: Data(key.utf8), account: observerIngestKeyAccount)
    }

    static func loadObserverIngestKey() throws -> String? {
        guard let data = try load(account: observerIngestKeyAccount) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func deleteObserverIngestKey() throws {
        try delete(account: observerIngestKeyAccount)
    }

    static func savePairIdentity(_ key: Curve25519.Signing.PrivateKey) throws {
        try save(data: Data(key.rawRepresentation), account: pairIdentityAccount)
    }

    static func loadPairIdentity() throws -> Curve25519.Signing.PrivateKey? {
        guard let data = try load(account: pairIdentityAccount) else {
            return nil
        }

        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    static func deletePairIdentity() throws {
        try delete(account: pairIdentityAccount)
    }

    static func loadOrCreatePairIdentity() throws -> Curve25519.Signing.PrivateKey {
        if let existing = try loadPairIdentity() {
            return existing
        }

        let key = Curve25519.Signing.PrivateKey()
        try savePairIdentity(key)
        return key
    }

    static func savePairSession(_ sessionKey: String) throws {
        try save(data: Data(sessionKey.utf8), account: pairSessionAccount)
    }

    static func loadPairSession() throws -> String? {
        guard let data = try load(account: pairSessionAccount) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    static func deletePairSession() throws {
        try delete(account: pairSessionAccount)
    }

    private static func save(data: Data, account: String) throws {
        let addQuery = baseQuery(account: account).merging([kSecValueData as String: data]) { _, new in new }
        let status = SecItemAdd(addQuery as CFDictionary, nil)

        if status == errSecSuccess {
            return
        }

        guard status == errSecDuplicateItem else {
            throw KeychainError.unexpectedStatus(status)
        }

        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary, attributesToUpdate as CFDictionary)

        guard updateStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    private static func load(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.unexpectedStatus(errSecInternalError)
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private static func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}
