// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Security

enum KeychainError: Error {
    case unexpectedStatus(OSStatus)
}

nonisolated enum ObserverKeychain {
    static let service = "app.solstone.swift"
    static let observerIngestKeyAccount = "solstone-swift-observer-ingest-key"
    static let observerIngestPrefixAccount = "solstone-swift-observer-ingest-prefix"
    static let omiIngestKeyAccount = "solstone-swift-omi-ingest-key"
    static let omiIngestPrefixAccount = "solstone-swift-omi-ingest-prefix"

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

    static func saveObserverIngestPrefix(_ prefix: String) throws {
        try save(data: Data(prefix.utf8), account: observerIngestPrefixAccount)
    }

    static func loadObserverIngestPrefix() throws -> String? {
        guard let data = try load(account: observerIngestPrefixAccount) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func deleteObserverIngestPrefix() throws {
        try delete(account: observerIngestPrefixAccount)
    }

    static func saveOmiIngestKey(_ key: String) throws {
        try save(data: Data(key.utf8), account: omiIngestKeyAccount)
    }

    static func loadOmiIngestKey() throws -> String? {
        guard let data = try load(account: omiIngestKeyAccount) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func deleteOmiIngestKey() throws {
        try delete(account: omiIngestKeyAccount)
    }

    static func saveOmiIngestPrefix(_ prefix: String) throws {
        try save(data: Data(prefix.utf8), account: omiIngestPrefixAccount)
    }

    static func loadOmiIngestPrefix() throws -> String? {
        guard let data = try load(account: omiIngestPrefixAccount) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func deleteOmiIngestPrefix() throws {
        try delete(account: omiIngestPrefixAccount)
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
