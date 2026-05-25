// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Security

nonisolated struct EnabledPushRecord: Codable, Equatable, Sendable {
    let accountId: String
    let deviceId: String
    let dispatchToken: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case deviceId = "device_id"
        case dispatchToken = "dispatch_token"
        case createdAt = "created_at"
    }
}

nonisolated enum PushEnablementKeychainError: Error, Equatable, Sendable {
    case encodingFailed
    case decodingFailed
    case unexpectedStatus(OSStatus)
}

nonisolated struct PushEnablementKeychain: Sendable {
    static let defaultService = "app.solstone.swift.push"
    static let account = "solstone-swift-push-enablement"

    private let keychainService: String

    init(serviceOverride: String? = nil) {
        self.keychainService = serviceOverride ?? Self.defaultService
    }

    func save(_ credential: EnabledPushRecord) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(credential)
        } catch {
            throw PushEnablementKeychainError.encodingFailed
        }

        let addQuery = self.baseQuery().merging([kSecValueData as String: data]) { _, new in new }
        let status = SecItemAdd(addQuery as CFDictionary, nil)

        if status == errSecSuccess {
            return
        }

        guard status == errSecDuplicateItem else {
            throw PushEnablementKeychainError.unexpectedStatus(status)
        }

        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let updateStatus = SecItemUpdate(self.baseQuery() as CFDictionary, attributesToUpdate as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw PushEnablementKeychainError.unexpectedStatus(updateStatus)
        }
    }

    func load() throws -> EnabledPushRecord? {
        var query = self.baseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw PushEnablementKeychainError.unexpectedStatus(errSecInternalError)
            }
            do {
                return try JSONDecoder().decode(EnabledPushRecord.self, from: data)
            } catch {
                throw PushEnablementKeychainError.decodingFailed
            }
        case errSecItemNotFound:
            return nil
        default:
            throw PushEnablementKeychainError.unexpectedStatus(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(self.baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PushEnablementKeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.keychainService,
            kSecAttrAccount as String: Self.account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}
