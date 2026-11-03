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
/// the pairing ending: unpairing, or a different journal paired in its place.
///
/// What's kept is the mark this device derived from the CA a pairing pinned, with that CA's
/// journal ID. Earlier versions kept a copy of the spec the journal served, tied to no key. That
/// copy still draws the first frame after an update, until `JournalMarkDerivation` replaces it, and
/// nothing asks the owner about it.
///
/// This is the owner's own data, on the owner's own device, used solely to render their own
/// journal's identity to them. It is never transmitted anywhere.
nonisolated struct JournalMarkStore: Sendable {
    private struct Derived: Codable {
        let journalID: String
        let mark: JournalMark
    }

    private static let derivedKey = "solstone.journalMark.v2"
    private static let servedKey = "solstone.journalMark.v1"
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

    /// The mark to draw now, or `nil` when this device holds none.
    ///
    /// Re-validates on read: a stored mark still has to be a *valid* mark. A malformed blob
    /// (a schema change, a partial write) resolves to "no mark yet" rather than rendering
    /// something broken, and is cleared so it cannot fail again on every launch.
    func load() -> JournalMark? {
        self.loadDerived()?.mark ?? self.loadServed()
    }

    /// The mark derived for this journal ID, if that's the one kept.
    func mark(forJournalID journalID: String) -> JournalMark? {
        guard let derived = self.loadDerived(), derived.journalID == journalID else { return nil }
        return derived.mark
    }

    /// Keeps a derived mark, and retires any served copy from an earlier version.
    func save(_ mark: JournalMark, journalID: String) {
        guard let data = try? JSONEncoder().encode(Derived(journalID: journalID, mark: mark)) else {
            Self.log.error("journal mark encode failed; leaving the stored value alone")
            return
        }
        self.defaults.set(data, forKey: Self.derivedKey)
        self.defaults.removeObject(forKey: Self.servedKey)
    }

    /// ⛔ Only ever called when the pairing ends. See the type's invariant.
    func clear() {
        self.defaults.removeObject(forKey: Self.derivedKey)
        self.defaults.removeObject(forKey: Self.servedKey)
    }

    private func loadDerived() -> Derived? {
        guard let data = self.defaults.data(forKey: Self.derivedKey) else { return nil }
        guard let decoded = try? JSONDecoder().decode(Derived.self, from: data),
              JournalMark.validate(decoded.mark) != nil
        else {
            Self.log.error("stored journal mark was unreadable or invalid; clearing it")
            self.defaults.removeObject(forKey: Self.derivedKey)
            return nil
        }
        return decoded
    }

    private func loadServed() -> JournalMark? {
        guard let data = self.defaults.data(forKey: Self.servedKey) else { return nil }
        guard let decoded = try? JSONDecoder().decode(JournalMark.self, from: data),
              let valid = JournalMark.validate(decoded)
        else {
            Self.log.error("stored journal mark was unreadable or invalid; clearing it")
            self.defaults.removeObject(forKey: Self.servedKey)
            return nil
        }
        return valid
    }
}
