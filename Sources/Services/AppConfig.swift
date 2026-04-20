// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import NIOCore

nonisolated struct AppConfig: Sendable {
    let lanHost: String
    let lanPort: Int
    let remoteHost: String
    let remotePort: Int
    let sshUsername: String
    let forwardHost: String
    let forwardPort: Int
    let connectTimeoutLan: TimeAmount
    let connectTimeoutRemote: TimeAmount

    /// Wave 1 placeholders.
    /// Wave 5 onboarding replaces these values at runtime with user-configured settings.
    /// No runtime override path is implemented yet in this wave.
    static let `default` = AppConfig(
        lanHost: "journal.local",
        lanPort: 22,
        remoteHost: "journal.example.invalid",
        remotePort: 22,
        sshUsername: "solstone",
        forwardHost: "localhost",
        forwardPort: 7071,
        connectTimeoutLan: .seconds(3),
        connectTimeoutRemote: .seconds(15)
    )

    var isPlaceholder: Bool {
        self.remoteHost.hasSuffix(".invalid")
    }
}
