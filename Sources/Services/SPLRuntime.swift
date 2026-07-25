// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SPLTunnel

nonisolated enum SPLRuntime {
    static let clientInfo = SPLClientInfo(userAgent: "solstone-ios/\(AppVersion.shortVersion)")

    static let keychainPolicy = KeychainPolicy(
        service: "app.solstone.observer.spl",
        account: "spl-pairing-bundle",
        accessGroup: nil,
        // Preserve the vendored four-key base query by not opting into the
        // Data Protection keychain key.
        useDataProtectionKeychain: false,
        // The SPL pairing bundle is intentionally backup-migratable
        // (AfterFirstUnlock rather than a device-only keychain class) so
        // restoring to a new device preserves pairing.
        accessibility: .afterFirstUnlock
    )

    static let keychainStore = SPLKeychainStore(policy: keychainPolicy)
}
