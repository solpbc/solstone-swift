// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@MainActor
func makeOmiSourceManager(
    appGroupRoot: @escaping () throws -> URL = { try AppGroupContainer.rootURL() },
    io: any OmiLaunchCaptureIO = FoundationOmiLaunchCaptureIO(),
    generationID: UUID = UUID(),
    defaults: UserDefaults = .standard,
    clock: any ObserverClock = SystemObserverClock(),
    bluetoothPort: any OmiBluetoothPort = LiveOmiBluetoothPort()
) -> OmiSourceManager {
    let ingress = OmiLaunchCaptureIngress(
        appGroupRoot: appGroupRoot,
        generationID: generationID,
        clock: clock,
        io: io
    )
    if defaults.bool(forKey: OmiSourceManager.enabledKey) {
        _ = ingress.arm()
    }
    return OmiSourceManager(
        defaults: defaults,
        clock: clock,
        bluetoothPort: bluetoothPort,
        launchCaptureIngress: ingress
    )
}
