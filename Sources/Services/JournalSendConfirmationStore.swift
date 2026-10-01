// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Security
import SPLTunnel
import os

private nonisolated let storeLog = Logger(subsystem: "app.solstone.swift", category: "journal-send")

nonisolated enum JournalSendConfirmationStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case confirmFailed
    case secItemError(OSStatus)

    var description: String {
        switch self {
        case .confirmFailed:
            return "journal-send-confirm-failed"
        case .secItemError(let status):
            return "secItemError(\(status))"
        }
    }
}

nonisolated struct SettleOutcome: Equatable, Sendable {
    let isConfirmed: Bool
    let isGrandfathered: Bool
}

nonisolated final class JournalSendConfirmationStore: @unchecked Sendable {
    static let service = "app.solstone.swift.journal-send"
    static let confirmationAccount = "confirmation"
    static let settledAccount = "settled"
    static let confirmFailedCode = "journal-send-confirm-failed"

    private struct ProcessState {
        var hasSettledSuccessfully: Bool = false
        var firstSettleReadFailed: Bool = false
        var suppressGrandfatherOnLaterSettle: Bool = false
    }

    private let lock = NSLock()
    private var processState = ProcessState()

    private let loadRecordClosure: @Sendable () throws -> String?
    private let saveRecordClosure: @Sendable (String) throws -> Void
    private let deleteRecordClosure: @Sendable () throws -> Void
    private let loadMarkerClosure: @Sendable () throws -> Bool
    private let saveMarkerClosure: @Sendable () throws -> Void
    private let deleteMarkerClosure: @Sendable () throws -> Void
    private let onFailNextRecordWrite: (@Sendable () -> Void)?
    private let onFailNextMarkerWrite: (@Sendable () -> Void)?

    init(
        loadRecord: @escaping @Sendable () throws -> String?,
        saveRecord: @escaping @Sendable (String) throws -> Void,
        deleteRecord: @escaping @Sendable () throws -> Void,
        loadMarker: @escaping @Sendable () throws -> Bool,
        saveMarker: @escaping @Sendable () throws -> Void,
        deleteMarker: @escaping @Sendable () throws -> Void,
        onFailNextRecordWrite: (@Sendable () -> Void)? = nil,
        onFailNextMarkerWrite: (@Sendable () -> Void)? = nil
    ) {
        self.loadRecordClosure = loadRecord
        self.saveRecordClosure = saveRecord
        self.deleteRecordClosure = deleteRecord
        self.loadMarkerClosure = loadMarker
        self.saveMarkerClosure = saveMarker
        self.deleteMarkerClosure = deleteMarker
        self.onFailNextRecordWrite = onFailNextRecordWrite
        self.onFailNextMarkerWrite = onFailNextMarkerWrite
    }

    static func production() -> JournalSendConfirmationStore {
        JournalSendConfirmationStore(
            loadRecord: {
                let query = baseQuery(account: confirmationAccount)
                var item: CFTypeRef?
                var copyQuery = query
                copyQuery[kSecReturnData as String] = kCFBooleanTrue
                copyQuery[kSecMatchLimit as String] = kSecMatchLimitOne
                let status = SecItemCopyMatching(copyQuery as CFDictionary, &item)
                if status == errSecItemNotFound { return nil }
                guard status == errSecSuccess, let data = item as? Data, let str = String(data: data, encoding: .utf8) else {
                    throw JournalSendConfirmationStoreError.secItemError(status)
                }
                return str
            },
            saveRecord: { key in
                let deleteQuery = baseQuery(account: confirmationAccount)
                SecItemDelete(deleteQuery as CFDictionary)
                guard let data = key.data(using: .utf8) else { return }
                let addQuery = addAttributes(account: confirmationAccount, valueData: data)
                let status = SecItemAdd(addQuery as CFDictionary, nil)
                guard status == errSecSuccess else {
                    throw JournalSendConfirmationStoreError.secItemError(status)
                }
            },
            deleteRecord: {
                let query = baseQuery(account: confirmationAccount)
                let status = SecItemDelete(query as CFDictionary)
                if status != errSecSuccess && status != errSecItemNotFound {
                    throw JournalSendConfirmationStoreError.secItemError(status)
                }
            },
            loadMarker: {
                let query = baseQuery(account: settledAccount)
                var item: CFTypeRef?
                var copyQuery = query
                copyQuery[kSecReturnData as String] = kCFBooleanTrue
                copyQuery[kSecMatchLimit as String] = kSecMatchLimitOne
                let status = SecItemCopyMatching(copyQuery as CFDictionary, &item)
                if status == errSecItemNotFound { return false }
                guard status == errSecSuccess else {
                    throw JournalSendConfirmationStoreError.secItemError(status)
                }
                return true
            },
            saveMarker: {
                let query = baseQuery(account: settledAccount)
                guard let data = "1".data(using: .utf8) else { return }
                let updateAttributes: [String: Any] = [
                    kSecValueData as String: data
                ]
                let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
                if updateStatus == errSecSuccess {
                    return
                }
                if updateStatus == errSecItemNotFound {
                    let addQuery = addAttributes(account: settledAccount, valueData: data)
                    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
                    guard addStatus == errSecSuccess else {
                        throw JournalSendConfirmationStoreError.secItemError(addStatus)
                    }
                    return
                }
                throw JournalSendConfirmationStoreError.secItemError(updateStatus)
            },
            deleteMarker: {
                let query = baseQuery(account: settledAccount)
                let status = SecItemDelete(query as CFDictionary)
                if status != errSecSuccess && status != errSecItemNotFound {
                    throw JournalSendConfirmationStoreError.secItemError(status)
                }
            }
        )
    }

    static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
    }

    static func addAttributes(account: String, valueData: Data) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: valueData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
    }

    private final class MemoryBacking: @unchecked Sendable {
        private let lock = NSLock()
        var record: String?
        var marker: Bool
        var shouldFailRead: Bool
        var shouldFailRecordWrite: Bool
        var shouldFailMarkerWrite: Bool

        init(
            record: String?,
            marker: Bool,
            shouldFailRead: Bool,
            shouldFailRecordWrite: Bool = false,
            shouldFailMarkerWrite: Bool = false
        ) {
            self.record = record
            self.marker = marker
            self.shouldFailRead = shouldFailRead
            self.shouldFailRecordWrite = shouldFailRecordWrite
            self.shouldFailMarkerWrite = shouldFailMarkerWrite
        }

        func failNextRecordWrite() {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.shouldFailRecordWrite = true
        }

        func failNextMarkerWrite() {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.shouldFailMarkerWrite = true
        }

        func readRecord() throws -> String? {
            self.lock.lock()
            defer { self.lock.unlock() }
            if self.shouldFailRead {
                self.shouldFailRead = false
                throw JournalSendConfirmationStoreError.secItemError(errSecInteractionNotAllowed)
            }
            return self.record
        }

        func writeRecord(_ key: String) throws {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.record = nil
            if self.shouldFailRecordWrite {
                self.shouldFailRecordWrite = false
                throw JournalSendConfirmationStoreError.secItemError(errSecIO)
            }
            self.record = key
        }

        func clearRecord() {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.record = nil
        }

        func readMarker() throws -> Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            if self.shouldFailRead {
                self.shouldFailRead = false
                throw JournalSendConfirmationStoreError.secItemError(errSecInteractionNotAllowed)
            }
            return self.marker
        }

        func writeMarker() throws {
            self.lock.lock()
            defer { self.lock.unlock() }
            if self.shouldFailMarkerWrite {
                self.shouldFailMarkerWrite = false
                throw JournalSendConfirmationStoreError.secItemError(errSecIO)
            }
            self.marker = true
        }

        func clearMarker() {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.marker = false
        }
    }

    static func memory(
        initialRecord: String? = nil,
        initialMarker: Bool = false,
        failFirstRead: Bool = false,
        failNextRecordWrite: Bool = false,
        failNextMarkerWrite: Bool = false
    ) -> JournalSendConfirmationStore {
        let backing = MemoryBacking(
            record: initialRecord,
            marker: initialMarker,
            shouldFailRead: failFirstRead,
            shouldFailRecordWrite: failNextRecordWrite,
            shouldFailMarkerWrite: failNextMarkerWrite
        )
        return JournalSendConfirmationStore(
            loadRecord: { try backing.readRecord() },
            saveRecord: { key in try backing.writeRecord(key) },
            deleteRecord: { backing.clearRecord() },
            loadMarker: { try backing.readMarker() },
            saveMarker: { try backing.writeMarker() },
            deleteMarker: { backing.clearMarker() },
            onFailNextRecordWrite: { backing.failNextRecordWrite() },
            onFailNextMarkerWrite: { backing.failNextMarkerWrite() }
        )
    }

    func failNextRecordWrite() {
        self.onFailNextRecordWrite?()
    }

    func failNextMarkerWrite() {
        self.onFailNextMarkerWrite?()
    }

    var hasSettledSuccessfully: Bool {
        self.lock.withLock { self.processState.hasSettledSuccessfully }
    }

    var firstSettleReadFailed: Bool {
        self.lock.withLock { self.processState.firstSettleReadFailed }
    }

    var suppressGrandfatherOnLaterSettle: Bool {
        self.lock.withLock { self.processState.suppressGrandfatherOnLaterSettle }
    }

    func noteApplyPairingAfterFailedRead() {
        self.lock.withLock {
            self.processState.suppressGrandfatherOnLaterSettle = true
        }
    }

    func allowsSend(pairing: StoredPairing?) -> Bool {
        guard let pairing else { return false }
        guard let expectedKey = journalSendConfirmationKey(for: pairing) else { return false }
        do {
            guard let record = try self.loadRecordClosure() else { return false }
            return record == expectedKey
        } catch {
            return false
        }
    }

    func writeRecord(for pairing: StoredPairing) throws {
        guard let key = journalSendConfirmationKey(for: pairing) else {
            storeLog.error("journal-send-confirm-failed: unable to derive confirmation key")
            throw JournalSendConfirmationStoreError.confirmFailed
        }
        try self.saveRecordClosure(key)
    }

    func grandfather(key: String) throws {
        try self.saveRecordClosure(key)
        do {
            try self.saveMarkerClosure()
        } catch {
            try? self.deleteRecordClosure()
            throw error
        }
    }

    func writeMarkerOnApplyPairing() throws {
        try self.saveMarkerClosure()
        try self.deleteRecordClosure()
    }

    func clearRecord() throws {
        try self.deleteRecordClosure()
    }

    func settle(
        loadPairing: () throws -> StoredPairing?,
        onRestoreSnapshot: ((StoredPairing) -> Void)? = nil
    ) throws -> SettleOutcome {
        let (alreadySettled, wasSuppressed) = self.lock.withLock {
            (self.processState.hasSettledSuccessfully, self.processState.suppressGrandfatherOnLaterSettle)
        }
        if alreadySettled {
            let pairing = try loadPairing()
            return SettleOutcome(isConfirmed: self.allowsSend(pairing: pairing), isGrandfathered: false)
        }

        let markerPresent: Bool
        let record: String?
        do {
            markerPresent = try self.loadMarkerClosure()
            record = try self.loadRecordClosure()
        } catch {
            self.lock.withLock {
                self.processState.firstSettleReadFailed = true
            }
            throw error
        }

        let pairing = try loadPairing()
        if let pairing {
            onRestoreSnapshot?(pairing)
        }

        let key = pairing.flatMap(journalSendConfirmationKey(for:))

        if markerPresent {
            self.lock.withLock {
                self.processState.hasSettledSuccessfully = true
            }
            if let key, let record, record == key {
                return SettleOutcome(isConfirmed: true, isGrandfathered: false)
            }
            return SettleOutcome(isConfirmed: false, isGrandfathered: false)
        }

        // Marker absent
        if pairing == nil {
            try self.saveMarkerClosure()
            self.lock.withLock {
                self.processState.hasSettledSuccessfully = true
            }
            return SettleOutcome(isConfirmed: false, isGrandfathered: false)
        }

        guard let key else {
            // Key underivable: write nothing, do not mark settle finished
            return SettleOutcome(isConfirmed: false, isGrandfathered: false)
        }

        if wasSuppressed {
            // applyPairing saved after failed read: do not grandfather
            self.lock.withLock {
                self.processState.hasSettledSuccessfully = true
            }
            return SettleOutcome(isConfirmed: false, isGrandfathered: false)
        }

        // Grandfathering: write record, then marker
        try self.grandfather(key: key)
        self.lock.withLock {
            self.processState.hasSettledSuccessfully = true
        }
        return SettleOutcome(isConfirmed: true, isGrandfathered: true)
    }
}
