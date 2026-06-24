// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreLocation
import Foundation
import os

nonisolated private let liveWatchLocationLog = Logger(subsystem: "app.solstone.swift", category: "watch-location")

@MainActor
final class LiveWatchLocationProvider: NSObject, WatchLocationProviding, CLLocationManagerDelegate {
    var onFix: (@MainActor @Sendable (WatchLocationFix) -> Void)?
    var onAuthorizationChanged: (@MainActor @Sendable (WatchLocationAuthorization) -> Void)?

    private let manager: CLLocationManager

    init(manager: CLLocationManager = CLLocationManager()) {
        self.manager = manager
        super.init()
        self.manager.delegate = self
    }

    var authorizationStatus: WatchLocationAuthorization {
        guard CLLocationManager.locationServicesEnabled() else { return .denied }
        switch self.manager.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .authorizedWhenInUse, .authorizedAlways:
            return .authorized
        case .restricted, .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    func requestWhenInUseAuthorization() {
        self.manager.requestWhenInUseAuthorization()
    }

    func start() throws {
        self.manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        self.manager.distanceFilter = 100
        self.manager.allowsBackgroundLocationUpdates = true
        self.manager.startUpdatingLocation()
    }

    func stop() {
        self.manager.stopUpdatingLocation()
        self.manager.allowsBackgroundLocationUpdates = false
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onAuthorizationChanged?(self.authorizationStatus)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map { Self.fix(from: $0) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for fix in fixes {
                self.onFix?(fix)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        liveWatchLocationLog.error("watch location failed: \(String(describing: error), privacy: .public)")
    }

    nonisolated static func fix(from location: CLLocation) -> WatchLocationFix {
        WatchLocationFix(
            t: location.timestamp,
            lat: location.coordinate.latitude,
            lon: location.coordinate.longitude,
            hAcc: location.horizontalAccuracy,
            alt: location.verticalAccuracy >= 0 ? location.altitude : nil,
            vAcc: location.verticalAccuracy >= 0 ? location.verticalAccuracy : nil,
            speed: location.speed >= 0 ? location.speed : nil,
            course: location.course >= 0 ? location.course : nil,
            stationary: false
        )
    }
}
