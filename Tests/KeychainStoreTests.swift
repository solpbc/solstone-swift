// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import NIOSSH
@testable import solstone_swift
import XCTest

final class KeychainStoreTests: XCTestCase {
    override func tearDown() {
        try? KeychainStore.deleteIdentityKey()
        try? KeychainStore.deleteHostKey()
    }

    func testIdentityKeyRoundTrip() throws {
        let key = Curve25519.Signing.PrivateKey()
        try KeychainStore.saveIdentityKey(key)

        let loaded = try KeychainStore.loadIdentityKey()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.rawRepresentation, key.rawRepresentation)
    }

    func testHostKeyRoundTrip() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let hostKey = NIOSSHPrivateKey(ed25519Key: privateKey).publicKey
        try KeychainStore.saveHostKey(hostKey)

        let loaded = try KeychainStore.loadHostKey()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded, hostKey)
    }

    func testDeleteIdentityKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        try KeychainStore.saveIdentityKey(key)
        try KeychainStore.deleteIdentityKey()

        let loaded = try KeychainStore.loadIdentityKey()
        XCTAssertNil(loaded)
    }

    func testOverwriteIdentityKey() throws {
        let key1 = Curve25519.Signing.PrivateKey()
        let key2 = Curve25519.Signing.PrivateKey()
        try KeychainStore.saveIdentityKey(key1)
        try KeychainStore.saveIdentityKey(key2)

        let loaded = try KeychainStore.loadIdentityKey()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.rawRepresentation, key2.rawRepresentation)
    }
}
