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

    static let `default` = AppConfig(
        lanHost: "fedora.local",
        lanPort: 22,
        remoteHost: "jeremie.com",
        remotePort: 22222,
        sshUsername: "jer",
        forwardHost: "localhost",
        forwardPort: 7071,
        connectTimeoutLan: .seconds(3),
        connectTimeoutRemote: .seconds(15)
    )
}
