// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SPLTunnel

nonisolated enum SPLRuntime {
    static let clientInfo = SPLClientInfo(userAgent: "solstone-ios/\(AppVersion.shortVersion)", platform: .ios)

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

    // why: built from the pairing's own policy, so any launch that can read the pairing,
    // a background one included, can read the credential's refusal count and stop.
    static let refusalStore = keychainStore.refusalStore

    static let confirmationStore = JournalSendConfirmationStore.production()

    static let deviceMigrationStore = DeviceMigrationStore()

    static let pairingStore = PairingCredentialStore(
        store: keychainStore,
        confirmationStore: confirmationStore,
        migrationStore: deviceMigrationStore
    )
}
