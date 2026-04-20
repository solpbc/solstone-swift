// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import NIOCore
import NIOSSH

enum HostKeyError: Error {
    case mismatch
}

nonisolated final class HostKeyValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    private let keyManager: any KeyManaging
    private let onMismatch: @Sendable (NIOSSHPublicKey) -> Void

    init(keyManager: any KeyManaging, onMismatch: @Sendable @escaping (NIOSSHPublicKey) -> Void) {
        self.keyManager = keyManager
        self.onMismatch = onMismatch
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        do {
            if let storedKey = try self.keyManager.loadHostKey() {
                if storedKey == hostKey {
                    validationCompletePromise.succeed(())
                } else {
                    self.onMismatch(hostKey)
                    validationCompletePromise.fail(HostKeyError.mismatch)
                }
            } else {
                try self.keyManager.saveHostKey(hostKey)
                validationCompletePromise.succeed(())
            }
        } catch {
            validationCompletePromise.fail(error)
        }
    }
}
