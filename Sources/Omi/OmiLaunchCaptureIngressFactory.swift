// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@MainActor
func makeOmiSourceManager(
    appGroupRoot: @escaping () throws -> URL = { try AppGroupContainer.rootURL() },
    io: any OmiLaunchCaptureIO = FoundationOmiLaunchCaptureIO(),
    generationID: UUID = UUID(),
    defaults: UserDefaults = .standard,
    diagnostics: OmiDiagnostics = OmiDiagnostics(),
    heardTally: OmiHeardTally = OmiHeardTally(),
    clock: any ObserverClock = SystemObserverClock(),
    bluetoothPort: any OmiBluetoothPort = LiveOmiBluetoothPort()
) -> OmiSourceManager {
    let ingress = OmiLaunchCaptureIngress(
        appGroupRoot: appGroupRoot,
        generationID: generationID,
        clock: clock,
        io: io
    )
    if defaults.bool(forKey: "omiSource.enabled") {
        _ = ingress.arm()
    }
    return OmiSourceManager(
        defaults: defaults,
        diagnostics: diagnostics,
        heardTally: heardTally,
        clock: clock,
        bluetoothPort: bluetoothPort,
        launchCaptureIngress: ingress
    )
}
