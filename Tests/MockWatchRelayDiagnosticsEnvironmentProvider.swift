// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation

@MainActor
final class MockWatchRelayDiagnosticsEnvironmentProvider: WatchRelayDiagnosticsEnvironmentProviding {
    var value = WatchRelayDiagnosticsEnvironmentSnapshot(
        watchAppMarketingVersion: .available("0.1.0"),
        watchAppBuild: .available("55"),
        watchOSVersion: .available("26.0"),
        watchBatteryLevel: .available(0.75),
        watchBatteryState: .available("unplugged"),
        watchLowPowerModeEnabled: .available(false),
        watchThermalState: .available("nominal")
    )

    func snapshot() -> WatchRelayDiagnosticsEnvironmentSnapshot {
        self.value
    }
}
