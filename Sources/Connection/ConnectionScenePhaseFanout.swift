// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SwiftUI
import SPLTunnel

@MainActor
enum ConnectionScenePhaseFanout {
    static func deliver(_ phase: ScenePhase, tunnel: TunnelManager, monitor: ConnectionStallMonitor) {
        tunnel.receiveScenePhase(Self.tunnelPhase(phase))
        monitor.receiveScenePhase(phase)
    }

    private static func tunnelPhase(_ phase: ScenePhase) -> TunnelScenePhase {
        switch phase {
        case .active:
            .active
        case .background:
            .background
        case .inactive:
            .inactive
        @unknown default:
            .inactive
        }
    }
}
