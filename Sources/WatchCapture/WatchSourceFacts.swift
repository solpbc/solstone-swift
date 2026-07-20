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

        var hasCheckedIn: Bool {
            self.watchAppCheckedIn || self.segmentFileReceived
        }
    }

    private(set) var watchAppCheckedIn: Bool
    private(set) var segmentFileReceived: Bool

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.watchAppCheckedIn = defaults.bool(forKey: Self.Key.watchAppCheckedIn)
        self.segmentFileReceived = defaults.bool(forKey: Self.Key.segmentFileReceived)
    }

    var snapshot: Snapshot {
        Snapshot(
            watchAppCheckedIn: self.watchAppCheckedIn,
            segmentFileReceived: self.segmentFileReceived
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
}

private extension WatchSourceFacts {
    enum Key {
        static let watchAppCheckedIn = "watchSource.watchAppCheckedIn"
        static let segmentFileReceived = "watchSource.segmentFileReceived"
    }

    func setWatchAppCheckedIn() {
        guard !self.watchAppCheckedIn else {
            return
        }
        self.watchAppCheckedIn = true
        self.defaults.set(true, forKey: Self.Key.watchAppCheckedIn)
    }
}
