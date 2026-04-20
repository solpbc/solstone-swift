// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import NIOSSH
@testable import solstone_swift

final class MockKeyManager: KeyManaging, @unchecked Sendable {
    var identityKey = Curve25519.Signing.PrivateKey()
    var hostKey: NIOSSHPublicKey? = nil
    var shouldThrow: Bool = false
    var saveHostKeyCalled: Bool = false
    var deleteHostKeyCalled: Bool = false
    var deleteIdentityKeyCalled: Bool = false

    func loadOrCreateIdentityKey() throws -> Curve25519.Signing.PrivateKey {
        if self.shouldThrow { throw KeychainError.unexpectedStatus(-1) }
        return self.identityKey
    }

    func loadHostKey() throws -> NIOSSHPublicKey? {
        if self.shouldThrow { throw KeychainError.unexpectedStatus(-1) }
        return self.hostKey
    }

    func saveHostKey(_ key: NIOSSHPublicKey) throws {
        if self.shouldThrow { throw KeychainError.unexpectedStatus(-1) }
        self.saveHostKeyCalled = true
        self.hostKey = key
    }

    func deleteHostKey() throws {
        if self.shouldThrow { throw KeychainError.unexpectedStatus(-1) }
        self.deleteHostKeyCalled = true
        self.hostKey = nil
    }

    func deleteIdentityKey() throws {
        if self.shouldThrow { throw KeychainError.unexpectedStatus(-1) }
        self.deleteIdentityKeyCalled = true
    }
}
