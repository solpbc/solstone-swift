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
    let reservation: OmiLaunchCaptureCutReservation?
    let ingress: OmiLaunchCaptureIngress?
    let hasReservationDefect: Bool
    if let captureRoot = try? appGroupRoot().appendingPathComponent(
        OmiLaunchCaptureFormat.rootDirectoryName,
        isDirectory: true
    ) {
        switch OmiLaunchCaptureCutReservationStore(rootURL: captureRoot, io: io).read() {
        case .valid(let value):
            reservation = value
            ingress = OmiLaunchCaptureIngress(
                captureRoot: { OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: captureRoot) },
                generationID: value.reservedGenerationID,
                clock: clock,
                io: io
            )
            hasReservationDefect = false
        case .unreadable:
            reservation = nil
            ingress = nil
            hasReservationDefect = true
        case .absent:
            reservation = nil
            ingress = OmiLaunchCaptureIngress(
                appGroupRoot: appGroupRoot,
                generationID: generationID,
                clock: clock,
                io: io
            )
            hasReservationDefect = false
        }
    } else {
        reservation = nil
        ingress = OmiLaunchCaptureIngress(
            appGroupRoot: appGroupRoot,
            generationID: generationID,
            clock: clock,
            io: io
        )
        hasReservationDefect = false
    }
    if defaults.bool(forKey: OmiSourceManager.enabledKey) {
        _ = ingress?.arm()
    }
    return OmiSourceManager(
        defaults: defaults,
        clock: clock,
        bluetoothPort: bluetoothPort,
        launchCaptureIngress: ingress,
        initialCutReservation: reservation,
        hasCutReservationDefect: hasReservationDefect
    )
}
