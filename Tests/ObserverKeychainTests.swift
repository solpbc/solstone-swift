// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import Security
import XCTest

nonisolated final class ObserverKeychainTests: XCTestCase {
    func testAddAttributesUseAfterFirstUnlockThisDeviceOnly() {
        let data = Data("k".utf8)
        let attributes = ObserverKeychain.addAttributes(
            data: data,
            account: ObserverKeychain.observerIngestKeyAccount
        )

        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        XCTAssertEqual(attributes[kSecValueData as String] as? Data, data)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(
            attributes[kSecAttrAccount as String] as? String,
            ObserverKeychain.observerIngestKeyAccount
        )
    }

    func testUpdateAttributesUseAfterFirstUnlockThisDeviceOnly() {
        let data = Data("k".utf8)
        let attributes = ObserverKeychain.updateAttributes(data: data)

        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        XCTAssertEqual(attributes[kSecValueData as String] as? Data, data)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
    }

    func testBaseQueryOmitsAccessibleAttribute() {
        let query = ObserverKeychain.baseQuery(account: ObserverKeychain.observerIngestKeyAccount)

        // AC2: load, delete, and update queries all reuse baseQuery, so accessibility must stay out of it.
        XCTAssertNil(query[kSecAttrAccessible as String])
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService as String] as? String, ObserverKeychain.service)
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, ObserverKeychain.observerIngestKeyAccount)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
    }

    func testMigrationAttemptsAllAccountsWhenOneFails() {
        var attempted: [String] = []

        let count = ObserverKeychain.migrateIngestKeyAccessibility(accounts: ["a", "b", "c"]) { account in
            attempted.append(account)
            if account == "b" {
                throw MigrationTestError.injected
            }
            return true
        }

        XCTAssertEqual(attempted, ["a", "b", "c"])
        XCTAssertEqual(count, 2)
    }

    func testRealMigrationPreservesObserverKeyAcrossRepeatedRuns() throws {
        try? ObserverKeychain.deleteObserverIngestKey()
        defer { try? ObserverKeychain.deleteObserverIngestKey() }

        let value = "tf29-observer-key-\(UUID().uuidString)"
        try ObserverKeychain.saveObserverIngestKey(value)

        // Simulator read-back ignores kSecAttrAccessible, so this verifies value round-trip and idempotence.
        _ = ObserverKeychain.migrateIngestKeyAccessibility()
        XCTAssertEqual(try ObserverKeychain.loadObserverIngestKey(), value)

        _ = ObserverKeychain.migrateIngestKeyAccessibility()
        XCTAssertEqual(try ObserverKeychain.loadObserverIngestKey(), value)
    }
}

private enum MigrationTestError: Error {
    case injected
}
