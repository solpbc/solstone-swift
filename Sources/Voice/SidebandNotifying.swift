// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

nonisolated protocol SidebandNotifying: Sendable {
    func notify(callId: String, localPort: Int) async
}
