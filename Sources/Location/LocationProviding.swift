// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreLocation
import Foundation
import Observation
import os

private let locationProviderLog = Logger(subsystem: "app.solstone.swift", category: "location")

nonisolated enum LocationCapability: Sendable, Equatable {
    case notDetermined
    case servicesDisabled
    case denied
    case restricted
    case whenInUse(accuracy: LocationAccuracy)
    case always(accuracy: LocationAccuracy)
}

nonisolated enum LocationObservationMode: Sendable, Equatable, Hashable {
    case visits
    case significantChanges
    case liveUpdates
}

nonisolated enum LocationGapReason: Sendable, Equatable {
    case authorizationChanged
    case unavailable
    case backgroundUnavailable
    case accuracyLimited
}

@MainActor
protocol LocationProviding: AnyObject {
    var onAuthorizationChanged: (@Sendable (LocationCapability) -> Void)? { get set }
    var onFix: (@Sendable (LocationFix) -> Void)? { get set }
    var onVisit: (@Sendable (LocationVisit) -> Void)? { get set }
    var onGap: (@Sendable (LocationGapReason) -> Void)? { get set }

    func currentCapability() -> LocationCapability
    func requestWhenInUseAuthorization()
    func requestAlwaysAuthorization()
    func startObservation(modes: Set<LocationObservationMode>) async throws
    func stopObservation() async
    func beginBackgroundSustain() async
    func endBackgroundSustain() async
}

@MainActor
final class LiveLocationProvider: NSObject, LocationProviding, CLLocationManagerDelegate {
    var onAuthorizationChanged: (@Sendable (LocationCapability) -> Void)?
    var onFix: (@Sendable (LocationFix) -> Void)?
    var onVisit: (@Sendable (LocationVisit) -> Void)?
    var onGap: (@Sendable (LocationGapReason) -> Void)?

    private let manager: CLLocationManager
    private var liveUpdatesTask: Task<Void, Never>?
    private var backgroundSession: CLBackgroundActivitySession?
    private var serviceSession: CLServiceSession?

    init(manager: CLLocationManager = CLLocationManager()) {
        self.manager = manager
        super.init()
        self.manager.delegate = self
    }

    func currentCapability() -> LocationCapability {
        guard CLLocationManager.locationServicesEnabled() else {
            return .servicesDisabled
        }

        let accuracy = self.manager.accuracyAuthorization == .fullAccuracy ? LocationAccuracy.full : .reduced
        switch self.manager.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorizedWhenInUse:
            return .whenInUse(accuracy: accuracy)
        case .authorizedAlways:
            return .always(accuracy: accuracy)
        @unknown default:
            return .denied
        }
    }

    func requestWhenInUseAuthorization() {
        self.manager.requestWhenInUseAuthorization()
    }

    func requestAlwaysAuthorization() {
        self.manager.requestAlwaysAuthorization()
    }

    func startObservation(modes: Set<LocationObservationMode>) async throws {
        if modes.contains(.significantChanges) || modes.contains(.liveUpdates) {
            self.manager.allowsBackgroundLocationUpdates = true
        }

        if modes.contains(.visits) {
            self.manager.startMonitoringVisits()
        }
        if modes.contains(.significantChanges) {
            self.manager.startMonitoringSignificantLocationChanges()
        }
        if modes.contains(.liveUpdates) {
            self.liveUpdatesTask?.cancel()
            self.liveUpdatesTask = Task { @MainActor [weak self] in
                do {
                    for try await update in CLLocationUpdate.liveUpdates(.default) {
                        guard !Task.isCancelled else { return }
                        self?.handle(update)
                    }
                } catch {
                    locationProviderLog.error("location live updates failed: \(String(describing: error), privacy: .public)")
                    self?.onGap?(.unavailable)
                }
            }
        }
    }

    func stopObservation() async {
        self.manager.stopMonitoringVisits()
        self.manager.stopMonitoringSignificantLocationChanges()
        self.liveUpdatesTask?.cancel()
        self.liveUpdatesTask = nil
        self.manager.allowsBackgroundLocationUpdates = false
    }

    func beginBackgroundSustain() async {
        if self.backgroundSession == nil {
            self.backgroundSession = CLBackgroundActivitySession()
        }
        if self.serviceSession == nil {
            self.serviceSession = CLServiceSession(authorization: .always)
        }
    }

    func endBackgroundSustain() async {
        self.backgroundSession?.invalidate()
        self.backgroundSession = nil
        self.serviceSession?.invalidate()
        self.serviceSession = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onAuthorizationChanged?(self.currentCapability())
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map { Self.fix(from: $0, stationary: false) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for fix in fixes {
                self.onFix?(fix)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let locationVisit = Self.visit(from: visit)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onVisit?(locationVisit)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Task { @MainActor [weak self] in
            locationProviderLog.error("location provider failed: \(String(describing: error), privacy: .public)")
            self?.onGap?(.unavailable)
        }
    }
}

private extension LiveLocationProvider {
    func handle(_ update: CLLocationUpdate) {
        if let location = update.location {
            self.onFix?(Self.fix(from: location, stationary: update.stationary))
        } else if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
            self.onGap?(.authorizationChanged)
        } else if update.locationUnavailable {
            self.onGap?(.unavailable)
        } else if update.insufficientlyInUse || update.serviceSessionRequired {
            self.onGap?(.backgroundUnavailable)
        } else if update.accuracyLimited {
            self.onGap?(.accuracyLimited)
        }
    }

    nonisolated static func fix(from location: CLLocation, stationary: Bool) -> LocationFix {
        LocationFix(
            t: location.timestamp,
            lat: location.coordinate.latitude,
            lon: location.coordinate.longitude,
            hAcc: location.horizontalAccuracy,
            alt: location.verticalAccuracy >= 0 ? location.altitude : nil,
            vAcc: location.verticalAccuracy >= 0 ? location.verticalAccuracy : nil,
            speed: location.speed >= 0 ? location.speed : nil,
            course: location.course >= 0 ? location.course : nil,
            stationary: stationary
        )
    }

    nonisolated static func visit(from visit: CLVisit) -> LocationVisit {
        LocationVisit(
            arrival: visit.arrivalDate,
            departure: visit.departureDate == Date.distantFuture ? nil : visit.departureDate,
            lat: visit.coordinate.latitude,
            lon: visit.coordinate.longitude,
            hAcc: visit.horizontalAccuracy
        )
    }
}
