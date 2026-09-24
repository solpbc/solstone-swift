// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

nonisolated final class PushKeyStoreTests: XCTestCase {
    func testBadPrefixRefusesWithoutCallingSecItem() {
        let seamCalled = OSAllocatedUnfairLock<Bool>(initialState: false)
        let seam = PushKeyStore.SecItemSeam(
            copy: { _ in
                seamCalled.withLock { $0 = true }
                return (errSecSuccess, Data(repeating: 0xaa, count: 32))
            },
            add: { _ in
                seamCalled.withLock { $0 = true }
                return errSecSuccess
            },
            delete: { _ in
                seamCalled.withLock { $0 = true }
                return errSecSuccess
            }
        )

        let invalidPrefixes = ["", "123", "ABCDEFGHIJ", "ABCDEFGHIJK.", "7QCG8V4M6H"]
        for prefix in invalidPrefixes {
            let store = PushKeyStore(seam: seam, prefix: prefix)
            XCTAssertThrowsError(try store.loadOrCreate()) { error in
                XCTAssertEqual(error as? PushKeyStoreError, .badPrefix)
            }
            XCTAssertThrowsError(try store.load()) { error in
                XCTAssertEqual(error as? PushKeyStoreError, .badPrefix)
            }
            XCTAssertThrowsError(try store.delete()) { error in
                XCTAssertEqual(error as? PushKeyStoreError, .badPrefix)
            }
            XCTAssertFalse(seamCalled.withLock { $0 })
        }
    }

    func testLoadOrCreateGeneratesAndStoresKeyWhenNotFound() throws {
        let storedData = OSAllocatedUnfairLock<Data?>(initialState: nil)
        let seam = PushKeyStore.SecItemSeam(
            copy: { _ in
                if let data = storedData.withLock({ $0 }) {
                    return (errSecSuccess, data)
                }
                return (errSecItemNotFound, nil)
            },
            add: { attributes in
                if let data = attributes[kSecValueData as String] as? Data {
                    storedData.withLock { $0 = data }
                    return errSecSuccess
                }
                return errSecParam
            },
            delete: { _ in
                storedData.withLock { $0 = nil }
                return errSecSuccess
            }
        )

        let store = PushKeyStore(seam: seam, prefix: "7QCG8V4M6H.")
        let key = try store.loadOrCreate()
        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(storedData.withLock { $0 }, key)

        let loaded = try store.load()
        XCTAssertEqual(loaded, key)
    }

    func testLoadOrCreateReReadsOnDuplicateItemWithoutOverwrite() throws {
        let existingKey = Data(repeating: 0x42, count: 32)
        let copyCallCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let addCallCount = OSAllocatedUnfairLock<Int>(initialState: 0)

        let seam = PushKeyStore.SecItemSeam(
            copy: { _ in
                let count = copyCallCount.withLock { count -> Int in
                    count += 1
                    return count
                }
                if count == 1 {
                    return (errSecItemNotFound, nil)
                }
                return (errSecSuccess, existingKey)
            },
            add: { _ in
                addCallCount.withLock { $0 += 1 }
                return errSecDuplicateItem
            },
            delete: { _ in errSecSuccess }
        )

        let store = PushKeyStore(seam: seam, prefix: "7QCG8V4M6H.")
        let key = try store.loadOrCreate()
        XCTAssertEqual(key, existingKey)
        XCTAssertEqual(copyCallCount.withLock { $0 }, 2)
        XCTAssertEqual(addCallCount.withLock { $0 }, 1)
    }

    func testInteractionNotAllowedThrowsInteractionNotAllowed() {
        let seam = PushKeyStore.SecItemSeam(
            copy: { _ in (errSecInteractionNotAllowed, nil) },
            add: { _ in errSecInteractionNotAllowed },
            delete: { _ in errSecInteractionNotAllowed }
        )

        let store = PushKeyStore(seam: seam, prefix: "7QCG8V4M6H.")
        XCTAssertThrowsError(try store.loadOrCreate()) { error in
            XCTAssertEqual(error as? PushKeyStoreError, .interactionNotAllowed)
        }
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? PushKeyStoreError, .interactionNotAllowed)
        }
    }

    func testStoredKeyWithWrongCountIsReplacedOnLoadOrCreate() throws {
        let storedData = OSAllocatedUnfairLock<Data?>(initialState: Data(repeating: 0x11, count: 16))
        let deleteCallCount = OSAllocatedUnfairLock<Int>(initialState: 0)

        let seam = PushKeyStore.SecItemSeam(
            copy: { _ in
                if let data = storedData.withLock({ $0 }) {
                    return (errSecSuccess, data)
                }
                return (errSecItemNotFound, nil)
            },
            add: { attributes in
                if let data = attributes[kSecValueData as String] as? Data {
                    storedData.withLock { $0 = data }
                    return errSecSuccess
                }
                return errSecParam
            },
            delete: { _ in
                deleteCallCount.withLock { $0 += 1 }
                storedData.withLock { $0 = nil }
                return errSecSuccess
            }
        )

        let store = PushKeyStore(seam: seam, prefix: "7QCG8V4M6H.")
        let key = try store.loadOrCreate()
        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(deleteCallCount.withLock { $0 }, 1)
        XCTAssertEqual(storedData.withLock { $0 }, key)
    }

    func testLoadReturnsNilWhenNotFound() throws {
        let seam = PushKeyStore.SecItemSeam(
            copy: { _ in (errSecItemNotFound, nil) },
            add: { _ in errSecSuccess },
            delete: { _ in errSecSuccess }
        )

        let store = PushKeyStore(seam: seam, prefix: "7QCG8V4M6H.")
        let key = try store.load()
        XCTAssertNil(key)
    }

    func testDeleteSucceedsWhenItemNotFound() throws {
        let seam = PushKeyStore.SecItemSeam(
            copy: { _ in (errSecItemNotFound, nil) },
            add: { _ in errSecSuccess },
            delete: { _ in errSecItemNotFound }
        )

        let store = PushKeyStore(seam: seam, prefix: "7QCG8V4M6H.")
        try store.delete()
    }

    func testDuplicateItemFollowedByNotFoundThrowsWithOneAdd() {
        let copyCallCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let addCallCount = OSAllocatedUnfairLock<Int>(initialState: 0)

        let seam = PushKeyStore.SecItemSeam(
            copy: { _ in
                let count = copyCallCount.withLock { count -> Int in
                    count += 1
                    return count
                }
                return (errSecItemNotFound, nil)
            },
            add: { _ in
                addCallCount.withLock { $0 += 1 }
                return errSecDuplicateItem
            },
            delete: { _ in errSecSuccess }
        )

        let store = PushKeyStore(seam: seam, prefix: "7QCG8V4M6H.")
        XCTAssertThrowsError(try store.loadOrCreate())
        XCTAssertEqual(copyCallCount.withLock { $0 }, 2)
        XCTAssertEqual(addCallCount.withLock { $0 }, 1)
    }

    func testDuplicateItemFollowedByInteractionNotAllowedThrowsWithOneAdd() {
        let copyCallCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let addCallCount = OSAllocatedUnfairLock<Int>(initialState: 0)

        let seam = PushKeyStore.SecItemSeam(
            copy: { _ in
                let count = copyCallCount.withLock { count -> Int in
                    count += 1
                    return count
                }
                if count == 1 {
                    return (errSecItemNotFound, nil)
                }
                return (errSecInteractionNotAllowed, nil)
            },
            add: { _ in
                addCallCount.withLock { $0 += 1 }
                return errSecDuplicateItem
            },
            delete: { _ in errSecSuccess }
        )

        let store = PushKeyStore(seam: seam, prefix: "7QCG8V4M6H.")
        XCTAssertThrowsError(try store.loadOrCreate()) { error in
            XCTAssertEqual(error as? PushKeyStoreError, .interactionNotAllowed)
        }
        XCTAssertEqual(copyCallCount.withLock { $0 }, 2)
        XCTAssertEqual(addCallCount.withLock { $0 }, 1)
    }

    private struct CapturedQuery: Sendable {
        let accessGroup: String?
        let service: String?
        let account: String?
        let accessible: String?
        let synchronizable: Bool?
    }

    func testSeamRecordedQueryUsesPushGroupAndFirstUnlock() throws {
        let recordedAddQuery = OSAllocatedUnfairLock<CapturedQuery?>(initialState: nil)
        let seam = PushKeyStore.SecItemSeam(
            copy: { _ in (errSecItemNotFound, nil) },
            add: { query in
                let captured = CapturedQuery(
                    accessGroup: query[kSecAttrAccessGroup as String] as? String,
                    service: query[kSecAttrService as String] as? String,
                    account: query[kSecAttrAccount as String] as? String,
                    accessible: query[kSecAttrAccessible as String] as? String,
                    synchronizable: query[kSecAttrSynchronizable as String] as? Bool
                )
                recordedAddQuery.withLock { $0 = captured }
                return errSecSuccess
            },
            delete: { _ in errSecSuccess }
        )

        let store = PushKeyStore(seam: seam, prefix: "7QCG8V4M6H.")
        _ = try store.loadOrCreate()

        let query = try XCTUnwrap(recordedAddQuery.withLock { $0 })
        XCTAssertEqual(query.accessGroup, "7QCG8V4M6H.app.solstone.push")
        XCTAssertEqual(query.service, "app.solstone.push")
        XCTAssertEqual(query.account, "push-key")
        XCTAssertEqual(query.accessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(query.synchronizable, false)
    }

    func testNilGroupAccessGroupBehavior() throws {
        let uniqueService = "app.solstone.test.\(UUID().uuidString)"
        let account = "test-account"
        let data = Data([0x01, 0x02, 0x03, 0x04])

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: uniqueService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        let addStatus = SecItemAdd(addQuery as CFDictionary, &result)
        defer {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: uniqueService,
                kSecAttrAccount as String: account
            ] as CFDictionary)
        }

        guard addStatus == errSecSuccess, let attributes = result as? [String: Any] else {
            throw XCTSkip("SecItemAdd returned \(addStatus)")
        }

        guard let accessGroup = attributes[kSecAttrAccessGroup as String] as? String else {
            throw XCTSkip("No access group returned")
        }

        if accessGroup.hasSuffix("app.solstone.swift.tests") || accessGroup.contains("test") || accessGroup.isEmpty {
            throw XCTSkip("Recorded access group is a placeholder/test group: \(accessGroup)")
        }

        XCTAssertTrue(accessGroup.hasSuffix("app.solstone.swift"), "Expected access group to end with app.solstone.swift, got \(accessGroup)")
    }
}
