// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import NIOSSH

nonisolated protocol KeyManaging: Sendable {
    func loadOrCreateIdentityKey() throws -> Curve25519.Signing.PrivateKey
    func loadHostKey() throws -> NIOSSHPublicKey?
    func saveHostKey(_ key: NIOSSHPublicKey) throws
    func deleteHostKey() throws
    func deleteIdentityKey() throws
}

nonisolated struct KeyManager: KeyManaging {
    func loadOrCreateIdentityKey() throws -> Curve25519.Signing.PrivateKey {
        if let existing = try KeychainStore.loadIdentityKey() {
            return existing
        }
        let newKey = Curve25519.Signing.PrivateKey()
        try KeychainStore.saveIdentityKey(newKey)
        return newKey
    }

    func loadHostKey() throws -> NIOSSHPublicKey? {
        try KeychainStore.loadHostKey()
    }

    func saveHostKey(_ key: NIOSSHPublicKey) throws {
        try KeychainStore.saveHostKey(key)
    }

    func deleteHostKey() throws {
        try KeychainStore.deleteHostKey()
    }

    func deleteIdentityKey() throws {
        try KeychainStore.deleteIdentityKey()
    }
}
