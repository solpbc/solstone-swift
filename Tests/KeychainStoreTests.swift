// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import NIOSSH
@testable import solstone_swift
import XCTest

nonisolated final class KeychainStoreTests: XCTestCase {
    override func tearDown() {
        try? KeychainStore.deleteIdentityKey()
        try? KeychainStore.deleteHostKey()
        try? KeychainStore.deleteObserverIngestKey()
    }

    @MainActor
    func testIdentityKeyRoundTrip() throws {
        let key = Curve25519.Signing.PrivateKey()
        try KeychainStore.saveIdentityKey(key)

        let loaded = try KeychainStore.loadIdentityKey()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.rawRepresentation, key.rawRepresentation)
    }

    @MainActor
    func testHostKeyRoundTrip() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let hostKey = NIOSSHPrivateKey(ed25519Key: privateKey).publicKey
        try KeychainStore.saveHostKey(hostKey)

        let loaded = try KeychainStore.loadHostKey()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded, hostKey)
    }

    @MainActor
    func testDeleteIdentityKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        try KeychainStore.saveIdentityKey(key)
        try KeychainStore.deleteIdentityKey()

        let loaded = try KeychainStore.loadIdentityKey()
        XCTAssertNil(loaded)
    }

    @MainActor
    func testOverwriteIdentityKey() throws {
        let key1 = Curve25519.Signing.PrivateKey()
        let key2 = Curve25519.Signing.PrivateKey()
        try KeychainStore.saveIdentityKey(key1)
        try KeychainStore.saveIdentityKey(key2)

        let loaded = try KeychainStore.loadIdentityKey()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.rawRepresentation, key2.rawRepresentation)
    }

    @MainActor
    func testObserverIngestKeyRoundTrip() throws {
        try KeychainStore.saveObserverIngestKey("observer-key-123")

        let loaded = try KeychainStore.loadObserverIngestKey()

        XCTAssertEqual(loaded, "observer-key-123")
    }

    @MainActor
    func testDeleteObserverIngestKey() throws {
        try KeychainStore.saveObserverIngestKey("observer-key-123")
        try KeychainStore.deleteObserverIngestKey()

        let loaded = try KeychainStore.loadObserverIngestKey()

        XCTAssertNil(loaded)
    }
}
