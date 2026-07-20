// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

@MainActor
@Observable
final class WatchSourceFacts {
    nonisolated struct Snapshot: Equatable, Sendable {
        let watchAppCheckedIn: Bool
        let segmentFileReceived: Bool
        let installTapped: Bool
        let firstSegmentCelebrationShown: Bool

        var hasCheckedIn: Bool {
            self.watchAppCheckedIn || self.segmentFileReceived
        }
    }

    private(set) var watchAppCheckedIn: Bool
    private(set) var segmentFileReceived: Bool
    private(set) var installTapped: Bool
    private(set) var firstSegmentCelebrationShown: Bool

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.watchAppCheckedIn = defaults.bool(forKey: Self.Key.watchAppCheckedIn)
        self.segmentFileReceived = defaults.bool(forKey: Self.Key.segmentFileReceived)
        self.installTapped = defaults.bool(forKey: Self.Key.installTapped)
        self.firstSegmentCelebrationShown = defaults.bool(forKey: Self.Key.firstSegmentCelebrationShown)
    }

    var snapshot: Snapshot {
        Snapshot(
            watchAppCheckedIn: self.watchAppCheckedIn,
            segmentFileReceived: self.segmentFileReceived,
            installTapped: self.installTapped,
            firstSegmentCelebrationShown: self.firstSegmentCelebrationShown
        )
    }

    func noteStatusContextCheckedIn() {
        self.setWatchAppCheckedIn()
    }

    func noteSegmentFileReceived() {
        self.setWatchAppCheckedIn()
        guard !self.segmentFileReceived else {
            return
        }
        self.segmentFileReceived = true
        self.defaults.set(true, forKey: Self.Key.segmentFileReceived)
    }

    func noteInstallTapped() {
        guard !self.installTapped else {
            return
        }
        self.installTapped = true
        self.defaults.set(true, forKey: Self.Key.installTapped)
    }

    func noteFirstSegmentCelebrationShown() {
        guard !self.firstSegmentCelebrationShown else {
            return
        }
        self.firstSegmentCelebrationShown = true
        self.defaults.set(true, forKey: Self.Key.firstSegmentCelebrationShown)
    }
}

private extension WatchSourceFacts {
    enum Key {
        static let watchAppCheckedIn = "watchSource.watchAppCheckedIn"
        static let segmentFileReceived = "watchSource.segmentFileReceived"
        static let installTapped = "watchSource.installTapped"
        static let firstSegmentCelebrationShown = "watchSource.firstSegmentCelebrationShown"
    }

    func setWatchAppCheckedIn() {
        guard !self.watchAppCheckedIn else {
            return
        }
        self.watchAppCheckedIn = true
        self.defaults.set(true, forKey: Self.Key.watchAppCheckedIn)
    }
}
