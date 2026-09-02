// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

/// The owner's journal mark, held locally so it survives launches and outages.
///
/// 🔒 **The invariant: once this device is paired to a journal, its mark is an absolute.**
/// It is a property of the pairing, not of the connection, so it must render on the very
/// first frame after launch and must never degrade to the generic mark because a tunnel is
/// down, slow, or not up yet. The mark is how an owner recognises *their* journal at a
/// glance; showing the generic one while connecting says "we don't know whose journal this
/// is," which is both false and exactly the wrong thing to say about identity.
///
/// ⛔ Never blank a stored mark on a connection failure. The only thing that clears it is
/// unpairing, because that is the only event that actually ends the relationship it records.
///
/// This is the owner's own data, on the owner's own device, used solely to render their own
/// journal's identity to them. It is never transmitted anywhere.
nonisolated struct JournalMarkStore: Sendable {
    private static let key = "solstone.journalMark.v1"
    private static let log = Logger(subsystem: "app.solstone.swift", category: "journal-mark")

    /// A suite *name* rather than a `UserDefaults`, which is not `Sendable` and so can be
    /// neither stored on a `Sendable` struct nor captured in a `@Sendable` closure. `nil`
    /// means the standard defaults; tests pass a unique suite so they cannot see each other.
    private let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        guard let suiteName, let suite = UserDefaults(suiteName: suiteName) else {
            return .standard
        }
        return suite
    }

    /// The stored mark, or `nil` when this device has never completed a link.
    ///
    /// Re-validates on read: a stored mark still has to be a *valid* mark. A malformed blob
    /// (a schema change, a partial write) resolves to "no mark yet" rather than rendering
    /// something broken, and is cleared so it cannot fail again on every launch.
    func load() -> JournalMark? {
        guard let data = self.defaults.data(forKey: Self.key) else { return nil }
        guard let decoded = try? JSONDecoder().decode(JournalMark.self, from: data),
              let valid = JournalMark.validate(decoded)
        else {
            Self.log.error("stored journal mark was unreadable or invalid; clearing it")
            self.clear()
            return nil
        }
        return valid
    }

    /// Records the mark the journal reported. Idempotent, and cheap enough to call on every
    /// successful fetch so a mark the owner re-rolled on the journal side lands here too.
    func save(_ mark: JournalMark) {
        guard let data = try? JSONEncoder().encode(mark) else {
            Self.log.error("journal mark encode failed; leaving the stored value alone")
            return
        }
        self.defaults.set(data, forKey: Self.key)
    }

    /// ⛔ Only ever called from unpairing. See the type's invariant.
    func clear() {
        self.defaults.removeObject(forKey: Self.key)
    }
}
