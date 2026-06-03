// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum LocationAuthorizationRequirement: Sendable, Equatable {
    case whenInUse
    case always
}

nonisolated enum LocationTier: String, CaseIterable, Sendable, Equatable {
    case light
    case balanced
    case full

    static let defaultTier: LocationTier = .balanced

    var label: String {
        switch self {
        case .light:
            LocationVocabulary.lightLabel
        case .balanced:
            LocationVocabulary.balancedLabel
        case .full:
            LocationVocabulary.fullLabel
        }
    }

    var body: String {
        switch self {
        case .light:
            LocationVocabulary.lightBody
        case .balanced:
            LocationVocabulary.balancedBody
        case .full:
            LocationVocabulary.fullBody
        }
    }

    // Light tier intentionally uses the low-power CLVisit API; CoreLocation decides when visit delivery is feasible.
    var requiredAuthorization: LocationAuthorizationRequirement {
        switch self {
        case .light:
            .whenInUse
        case .balanced, .full:
            .always
        }
    }

    var requiresFullAccuracy: Bool {
        self == .full
    }

    var modes: Set<LocationObservationMode> {
        switch self {
        case .light:
            [.visits]
        case .balanced:
            [.visits, .significantChanges]
        case .full:
            [.liveUpdates]
        }
    }

    static func matchToAllowed(for capability: LocationCapability) -> LocationTier? {
        switch capability {
        case .always(accuracy: .full):
            .full
        case .always(accuracy: .reduced):
            .balanced
        case .whenInUse:
            .light
        case .notDetermined, .servicesDisabled, .denied, .restricted:
            nil
        }
    }

    func isSatisfied(by capability: LocationCapability) -> Bool {
        switch (self, capability) {
        case (.light, .whenInUse), (.light, .always):
            true
        case (.balanced, .always):
            true
        case (.full, .always(accuracy: .full)):
            true
        case (.full, .always(accuracy: .reduced)),
             (.full, .whenInUse),
             (.balanced, .whenInUse),
             (_, .notDetermined),
             (_, .servicesDisabled),
             (_, .denied),
             (_, .restricted):
            false
        }
    }
}
