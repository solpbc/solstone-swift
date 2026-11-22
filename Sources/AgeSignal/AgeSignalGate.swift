// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Whether this binary carries the store age check. A build turns it on with the
/// `SOLSTONE_AGE_SIGNAL` build setting; off, the app asks for no age and behaves as before.
nonisolated enum AgeSignalBuild {
#if SOLSTONE_AGE_SIGNAL
    static let isEnabled = true
#else
    static let isEnabled = false
#endif
}

/// What a launch check decided. It is never an age: `stopped` and `held` are the only values
/// ever written down, and `run` is written as nothing at all.
nonisolated enum AgeSignalOutcome: String, Sendable, Equatable {
    case run
    case stopped
    case held
}

/// The outcome of the last check, kept in the App Group so that work iOS starts in a fresh
/// process, and the app's extensions, stay stopped until the next launch check replaces it.
/// The only other value kept is the App Store rating code cleared by a parent's approval, an
/// adult's acknowledgment, or a first install, which is a rating, not an age.
nonisolated struct AgeSignalStore: Sendable {
    static let appGroup = AgeSignalStore(suiteName: AppGroupContainer.identifier)

    static let outcomeKey = "ageSignal.outcome"
    static let approvedRatingKey = "ageSignal.approvedRatingCode"

    let suiteName: String

    private var defaults: UserDefaults? { UserDefaults(suiteName: self.suiteName) }

    func outcome() -> AgeSignalOutcome {
        guard let raw = self.defaults?.string(forKey: Self.outcomeKey),
              let outcome = AgeSignalOutcome(rawValue: raw) else { return .run }
        return outcome
    }

    func saveOutcome(_ outcome: AgeSignalOutcome) {
        switch outcome {
        case .run:
            self.defaults?.removeObject(forKey: Self.outcomeKey)
        case .stopped, .held:
            self.defaults?.set(outcome.rawValue, forKey: Self.outcomeKey)
        }
    }

    func approvedRatingCode() -> Int? {
        self.defaults?.object(forKey: Self.approvedRatingKey) as? Int
    }

    func saveApprovedRatingCode(_ code: Int) {
        self.defaults?.set(code, forKey: Self.approvedRatingKey)
    }
}

/// The one question every capture, pairing and sending path asks before it runs.
nonisolated struct AgeSignalGate: Sendable {
    static let live = AgeSignalGate(isEnabled: AgeSignalBuild.isEnabled, store: .appGroup)

    let isEnabled: Bool
    let store: AgeSignalStore

    var outcome: AgeSignalOutcome {
        self.isEnabled ? self.store.outcome() : .run
    }

    func allowsActivity() -> Bool {
        self.outcome == .run
    }
}
