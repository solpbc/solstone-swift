// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Security
import os

enum KeychainError: Error {
    case unexpectedStatus(OSStatus)
}

nonisolated enum ObserverKeychain {
    private static let log = Logger(subsystem: "app.solstone.swift", category: "observer-keychain")

    static let service = "app.solstone.swift"
    static let observerIngestKeyAccount = "solstone-swift-observer-ingest-key"
    static let observerIngestPrefixAccount = "solstone-swift-observer-ingest-prefix"
    static let omiIngestKeyAccount = "solstone-swift-omi-ingest-key"
    static let omiIngestPrefixAccount = "solstone-swift-omi-ingest-prefix"
    static let watchIngestKeyAccount = "solstone-swift-watch-ingest-key"
    static let watchIngestPrefixAccount = "solstone-swift-watch-ingest-prefix"

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

    static func legacyLoadObserverIngestPrefix() throws -> String? {
        guard let data = try load(account: observerIngestPrefixAccount) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func legacyDeleteObserverIngestPrefix() throws {
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

    static func legacyLoadOmiIngestPrefix() throws -> String? {
        guard let data = try load(account: omiIngestPrefixAccount) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func legacyDeleteOmiIngestPrefix() throws {
        try delete(account: omiIngestPrefixAccount)
    }

    static func saveWatchIngestKey(_ key: String) throws {
        try save(data: Data(key.utf8), account: watchIngestKeyAccount)
    }

    static func loadWatchIngestKey() throws -> String? {
        guard let data = try load(account: watchIngestKeyAccount) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func deleteWatchIngestKey() throws {
        try delete(account: watchIngestKeyAccount)
    }

    static func legacyLoadWatchIngestPrefix() throws -> String? {
        guard let data = try load(account: watchIngestPrefixAccount) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func legacyDeleteWatchIngestPrefix() throws {
        try delete(account: watchIngestPrefixAccount)
    }

    // Keys and prefixes share this helper; newly saved keychain items use
    // AfterFirstUnlockThisDeviceOnly. Prefix migration is intentionally out of scope.
    private static func save(data: Data, account: String) throws {
        let status = SecItemAdd(addAttributes(data: data, account: account) as CFDictionary, nil)

        if status == errSecSuccess {
            return
        }

        guard status == errSecDuplicateItem else {
            throw KeychainError.unexpectedStatus(status)
        }

        let updateStatus = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            updateAttributes(data: data) as CFDictionary
        )

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

    private static func performAccessibilityMigration(account: String) throws -> Bool {
        let attributes: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery(account: account) as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func migrateIngestKeyAccessibility() -> Int {
        migrateIngestKeyAccessibility(
            accounts: [observerIngestKeyAccount, omiIngestKeyAccount, watchIngestKeyAccount],
            perform: performAccessibilityMigration(account:)
        )
    }

    static func migrateIngestKeyAccessibility(accounts: [String], perform: (String) throws -> Bool) -> Int {
        var count = 0
        for account in accounts {
            do {
                if try perform(account) {
                    count += 1
                }
            } catch {
                log.error("ingest-key accessibility migration failed for account \(account, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return count
    }

    static func addAttributes(data: Data, account: String) -> [String: Any] {
        baseQuery(account: account).merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { _, new in new }
    }

    static func updateAttributes(data: Data) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}
