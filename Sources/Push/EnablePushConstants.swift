// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Security

nonisolated enum EnablePushConstants {
    static let NONCE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
    static let NONCE_LENGTH_CHARS = 52
    static let NONCE_REGEX = #"^[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{52}$"#
    static let DEVICE_TOKEN_REGEX = #"^[a-zA-Z0-9_-]{32,256}$"#
    static let BUNDLE_ID_REGEX = #"^[a-zA-Z0-9.-]{1,128}$"#
    static let PUSH_PLATFORM_ALLOWLIST = ["ios", "macos"]

    private static let alphabet = Array(NONCE_ALPHABET)
    private static let rejectionThreshold = UInt8((UInt16(UInt8.max) + 1) / UInt16(Self.alphabet.count) * UInt16(Self.alphabet.count))

    static func nonceCharacter(for byte: UInt8) -> Character? {
        guard byte < self.rejectionThreshold else {
            return nil
        }
        return self.alphabet[Int(byte) % self.alphabet.count]
    }

    static func mintNonce() -> String {
        var output: [Character] = []
        output.reserveCapacity(Self.NONCE_LENGTH_CHARS)

        while output.count < Self.NONCE_LENGTH_CHARS {
            var bytes = Data(count: 64)
            let status = bytes.withUnsafeMutableBytes { buffer in
                SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
            }
            precondition(status == errSecSuccess, "secure random failed")

            for byte in bytes {
                guard let character = self.nonceCharacter(for: byte) else {
                    continue
                }
                output.append(character)
                if output.count == Self.NONCE_LENGTH_CHARS {
                    break
                }
            }
        }

        return String(output)
    }
}
