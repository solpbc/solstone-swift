// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

nonisolated private let appGroupMirrorLog = Logger(subsystem: "app.solstone.swift", category: "app-group-mirror")

nonisolated private final class AppGroupMirrorDefaultsBox: @unchecked Sendable {
    let defaults: UserDefaults?

    nonisolated init(defaults: UserDefaults?) {
        self.defaults = defaults
    }
}

nonisolated struct AppGroupMirror: Sendable {
    struct PairingSnapshot: Equatable, Sendable {
        let journalName: String?
        let isPaired: Bool
    }

    struct ShareSourceState: Equatable, Sendable {
        let isActivated: Bool
        let isPaused: Bool
    }

    private enum Key {
        static let pairingIsPaired = "appGroupMirror.pairing.isPaired"
        static let pairingJournalName = "appGroupMirror.pairing.journalName"
        static let shareSourceIsActivated = "appGroupMirror.shareSource.isActivated"
        static let shareSourceIsPaused = "appGroupMirror.shareSource.isPaused"
    }

    private let defaultsBox: AppGroupMirrorDefaultsBox

    nonisolated init(defaults: UserDefaults? = UserDefaults(suiteName: AppGroupContainer.identifier)) {
        self.defaultsBox = AppGroupMirrorDefaultsBox(defaults: defaults)
    }

    nonisolated func pairingSnapshot() -> PairingSnapshot {
        guard let defaults = self.defaultsBox.defaults else {
            return PairingSnapshot(journalName: nil, isPaired: false)
        }

        return PairingSnapshot(
            journalName: defaults.string(forKey: Key.pairingJournalName),
            isPaired: defaults.bool(forKey: Key.pairingIsPaired)
        )
    }

    nonisolated func writePairing(journalName: String) {
        guard let defaults = self.defaultsBox.defaults else {
            appGroupMirrorLog.error("pairing mirror write skipped: app group defaults unavailable")
            return
        }

        defaults.set(true, forKey: Key.pairingIsPaired)
        defaults.set(journalName, forKey: Key.pairingJournalName)
    }

    nonisolated func clearPairing() {
        guard let defaults = self.defaultsBox.defaults else {
            appGroupMirrorLog.error("pairing mirror clear skipped: app group defaults unavailable")
            return
        }

        defaults.set(false, forKey: Key.pairingIsPaired)
        defaults.removeObject(forKey: Key.pairingJournalName)
    }

    nonisolated func shareSourceState() -> ShareSourceState {
        guard let defaults = self.defaultsBox.defaults else {
            return ShareSourceState(isActivated: false, isPaused: false)
        }

        return ShareSourceState(
            isActivated: defaults.bool(forKey: Key.shareSourceIsActivated),
            isPaused: defaults.bool(forKey: Key.shareSourceIsPaused)
        )
    }

    nonisolated func setShareActivated(_ value: Bool) {
        guard let defaults = self.defaultsBox.defaults else {
            appGroupMirrorLog.error("share source activation write skipped: app group defaults unavailable")
            return
        }

        defaults.set(value, forKey: Key.shareSourceIsActivated)
    }

    nonisolated func setSharePaused(_ value: Bool) {
        guard let defaults = self.defaultsBox.defaults else {
            appGroupMirrorLog.error("share source pause write skipped: app group defaults unavailable")
            return
        }

        defaults.set(value, forKey: Key.shareSourceIsPaused)
    }

    nonisolated func activateShareSource() {
        self.setShareActivated(true)
    }

    nonisolated func resumeShareSourceAndActivate() {
        guard let defaults = self.defaultsBox.defaults else {
            appGroupMirrorLog.error("share source resume write skipped: app group defaults unavailable")
            return
        }

        defaults.set(false, forKey: Key.shareSourceIsPaused)
        defaults.set(true, forKey: Key.shareSourceIsActivated)
    }
}
