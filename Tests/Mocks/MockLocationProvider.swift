// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation

@MainActor
final class MockLocationProvider: LocationProviding {
    var onAuthorizationChanged: (@Sendable (LocationCapability) -> Void)?
    var onFix: (@Sendable (LocationFix, LocationDeliveryContext) -> Void)?
    var onVisit: (@Sendable (LocationVisit) -> Void)?
    var onGap: (@Sendable (LocationGapReason) -> Void)?

    var capability: LocationCapability = .notDetermined
    var requestWhenInUseCallCount = 0
    var requestAlwaysCallCount = 0
    var startCallCount = 0
    var stopCallCount = 0
    var beginBackgroundSustainCallCount = 0
    var endBackgroundSustainCallCount = 0
    var startedModesHistory: [Set<LocationObservationMode>] = []
    var startError: (any Error)?

    var currentStartedModes: Set<LocationObservationMode>? {
        self.startedModesHistory.last
    }

    func currentCapability() -> LocationCapability {
        self.capability
    }

    func requestWhenInUseAuthorization() {
        self.requestWhenInUseCallCount += 1
    }

    func requestAlwaysAuthorization() {
        self.requestAlwaysCallCount += 1
    }

    func startObservation(modes: Set<LocationObservationMode>) async throws {
        self.startCallCount += 1
        if let startError { throw startError }
        self.startedModesHistory.append(modes)
    }

    func stopObservation() async {
        self.stopCallCount += 1
    }

    func beginBackgroundSustain() async {
        self.beginBackgroundSustainCallCount += 1
    }

    func endBackgroundSustain() async {
        self.endBackgroundSustainCallCount += 1
    }

    func emitAuthorization(_ capability: LocationCapability) {
        self.capability = capability
        self.onAuthorizationChanged?(capability)
    }

    func emitFix(_ fix: LocationFix = MockLocationProvider.fix(), context: LocationDeliveryContext = .foreground) {
        self.onFix?(fix, context)
    }

    func emitVisit(_ visit: LocationVisit = MockLocationProvider.visit()) {
        self.onVisit?(visit)
    }

    func emitGap(_ reason: LocationGapReason = .unavailable) {
        self.onGap?(reason)
    }

    static func fix(time: Date = Date(timeIntervalSince1970: 1_713_624_000)) -> LocationFix {
        LocationFix(
            t: time,
            lat: 39.7392,
            lon: -104.9903,
            hAcc: 25,
            alt: nil,
            vAcc: nil,
            speed: nil,
            course: nil,
            stationary: false
        )
    }

    static func visit(time: Date = Date(timeIntervalSince1970: 1_713_624_000)) -> LocationVisit {
        LocationVisit(
            arrival: time,
            departure: nil,
            lat: 39.7392,
            lon: -104.9903,
            hAcc: 25
        )
    }
}
