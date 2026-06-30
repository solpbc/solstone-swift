// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation

enum PairWindowCrypto {
    static func deriveRelayKey(s: Data) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: s),
            salt: Data(),
            info: Data("spl-pair-window-v1".utf8),
            outputByteCount: 16
        )
        return key.withUnsafeBytes { Data($0) }
    }

    static func jid(fromSPKIDER spki: Data) throws -> UUID {
        let publicKey: P256.Signing.PublicKey
        do {
            publicKey = try P256.Signing.PublicKey(derRepresentation: spki)
        } catch {
            throw PairWindowCryptoError.invalidSPKI
        }

        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: publicKey.derRepresentation),
            salt: Data("solstone/journal/v1".utf8),
            info: Data("solstone/jid/uuidv8/v1".utf8),
            outputByteCount: 16
        )
        var bytes = [UInt8](key.withUnsafeBytes { Data($0) })
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

enum PairWindowCryptoError: Error, Equatable, Sendable {
    case invalidSPKI
}
