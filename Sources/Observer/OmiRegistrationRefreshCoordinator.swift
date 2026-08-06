// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@MainActor
final class OmiRegistrationRefreshCoordinator {
    private let refresh: @MainActor @Sendable (Int) async -> Void
    private var lastConnectedPort: Int?
    private var isRefreshing = false
    private var pendingPort: Int?

    init(refresh: @escaping @MainActor @Sendable (Int) async -> Void) {
        self.refresh = refresh
    }

    func observe(tunnelState: TunnelState) {
        guard case .connected(let port, _) = tunnelState else {
            self.lastConnectedPort = nil
            return
        }

        guard self.lastConnectedPort != port else { return }
        self.lastConnectedPort = port
        self.requestRefresh(port: port)
    }

    private func requestRefresh(port: Int) {
        if self.isRefreshing {
            self.pendingPort = port
            return
        }

        self.isRefreshing = true
        Task { @MainActor in
            await self.runRefreshLoop(initialPort: port)
        }
    }

    private func runRefreshLoop(initialPort: Int) async {
        defer {
            self.pendingPort = nil
            self.isRefreshing = false
        }

        var port = initialPort
        while true {
            // Reset before each pass so all changes during it coalesce to one newest port.
            self.pendingPort = nil
            await self.refresh(port)
            guard let nextPort = self.pendingPort else { return }
            port = nextPort
        }
    }
}
