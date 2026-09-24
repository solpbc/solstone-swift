// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Foundation
import Security
import os

private let keyStoreLog = Logger(subsystem: "app.solstone.swift", category: "push-key")

enum PushKeyStoreError: Error, Equatable, Sendable {
    case badPrefix
    case interactionNotAllowed
    case secItemError(OSStatus)
    case invalidLength
}

nonisolated final class PushKeyStore: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    final class SecItemSeam: @unchecked Sendable {
        typealias CopyHandler = @Sendable ([String: Any]) -> (OSStatus, Data?)
        typealias AddHandler = @Sendable ([String: Any]) -> OSStatus
        typealias DeleteHandler = @Sendable ([String: Any]) -> OSStatus

        let copyItem: CopyHandler
        let addItem: AddHandler
        let deleteItem: DeleteHandler

        init(
            copy: @escaping CopyHandler,
            add: @escaping AddHandler,
            delete: @escaping DeleteHandler
        ) {
            self.copyItem = copy
            self.addItem = add
            self.deleteItem = delete
        }

        static let live = SecItemSeam(
            copy: { query in
                var query = query
                query[kSecReturnData as String] = kCFBooleanTrue
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                return (status, item as? Data)
            },
            add: { attributes in
                SecItemAdd(attributes as CFDictionary, nil)
            },
            delete: { query in
                SecItemDelete(query as CFDictionary)
            }
        )
    }

    private let bundle: Bundle
    private let seam: SecItemSeam
    private let prefixOverride: String?

    init(bundle: Bundle = .main, seam: SecItemSeam = .live, prefix: String? = nil) {
        self.bundle = bundle
        self.seam = seam
        self.prefixOverride = prefix
    }

    static func production(bundle: Bundle = .main) -> PushKeyStore {
        PushKeyStore(bundle: bundle, seam: .live)
    }

    static func memory(initialKey: Data? = nil, prefix: String = "7QCG8V4M6H.") -> PushKeyStore {
        let storage = OSAllocatedUnfairLock<Data?>(initialState: initialKey)
        let seam = SecItemSeam(
            copy: { _ in
                let current = storage.withLock { $0 }
                if let current {
                    return (errSecSuccess, current)
                }
                return (errSecItemNotFound, nil)
            },
            add: { query in
                let data = query[kSecValueData as String] as? Data
                return storage.withLock { current in
                    if current != nil {
                        return errSecDuplicateItem
                    }
                    current = data
                    return errSecSuccess
                }
            },
            delete: { _ in
                storage.withLock { current in
                    current = nil
                    return errSecSuccess
                }
            }
        )
        return PushKeyStore(seam: seam, prefix: prefix)
    }

    var description: String {
        "PushKeyStore"
    }

    var debugDescription: String {
        "PushKeyStore"
    }

    func loadOrCreate() throws -> Data {
        let prefix = try self.validatedTeamPrefix()
        let query = self.baseQuery(prefix: prefix)

        let (copyStatus, existingData) = self.seam.copyItem(query)
        switch copyStatus {
        case errSecSuccess:
            if let existingData, existingData.count == 32 {
                return existingData
            }
            _ = self.seam.deleteItem(query)
            return try self.createNewKey(prefix: prefix)
        case errSecItemNotFound:
            return try self.createNewKey(prefix: prefix)
        case errSecInteractionNotAllowed:
            throw PushKeyStoreError.interactionNotAllowed
        default:
            throw PushKeyStoreError.secItemError(copyStatus)
        }
    }

    func load() throws -> Data? {
        let prefix = try self.validatedTeamPrefix()
        let query = self.baseQuery(prefix: prefix)

        let (copyStatus, existingData) = self.seam.copyItem(query)
        switch copyStatus {
        case errSecSuccess:
            guard let existingData, existingData.count == 32 else {
                throw PushKeyStoreError.invalidLength
            }
            return existingData
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            throw PushKeyStoreError.interactionNotAllowed
        default:
            throw PushKeyStoreError.secItemError(copyStatus)
        }
    }

    func delete() throws {
        let prefix = try self.validatedTeamPrefix()
        let query = self.baseQuery(prefix: prefix)

        let status = self.seam.deleteItem(query)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }
        throw PushKeyStoreError.secItemError(status)
    }

    private func createNewKey(prefix: String) throws -> Data {
        let newKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var attributes = self.baseQuery(prefix: prefix)
        attributes[kSecValueData as String] = newKey

        let addStatus = self.seam.addItem(attributes)
        switch addStatus {
        case errSecSuccess:
            return newKey
        case errSecDuplicateItem:
            let query = self.baseQuery(prefix: prefix)
            let (reReadStatus, reReadData) = self.seam.copyItem(query)
            if reReadStatus == errSecSuccess, let reReadData, reReadData.count == 32 {
                return reReadData
            }
            if reReadStatus == errSecInteractionNotAllowed {
                throw PushKeyStoreError.interactionNotAllowed
            }
            if reReadStatus == errSecSuccess {
                throw PushKeyStoreError.invalidLength
            }
            throw PushKeyStoreError.secItemError(reReadStatus)
        case errSecInteractionNotAllowed:
            throw PushKeyStoreError.interactionNotAllowed
        default:
            throw PushKeyStoreError.secItemError(addStatus)
        }
    }

    private func baseQuery(prefix: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.solstone.push",
            kSecAttrAccount as String: "push-key",
            kSecAttrAccessGroup as String: "\(prefix)app.solstone.push",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
    }

    private func validatedTeamPrefix() throws -> String {
        let raw: String
        if let prefixOverride = self.prefixOverride {
            raw = prefixOverride
        } else if let fromBundle = self.bundle.object(forInfoDictionaryKey: "solstoneTeamPrefix") as? String {
            raw = fromBundle
        } else {
            throw PushKeyStoreError.badPrefix
        }

        guard !raw.isEmpty, self.isValidTeamPrefix(raw) else {
            throw PushKeyStoreError.badPrefix
        }
        return raw
    }

    private func isValidTeamPrefix(_ prefix: String) -> Bool {
        let regex = try? NSRegularExpression(pattern: "^[A-Z0-9]{10}\\.$")
        let range = NSRange(prefix.startIndex..<prefix.endIndex, in: prefix)
        return regex?.firstMatch(in: prefix, range: range) != nil
    }
}
