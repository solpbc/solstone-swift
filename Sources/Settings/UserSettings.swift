// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

enum UserSettings: Sendable {
    nonisolated static var haptics: Bool {
        get {
            if UserDefaults.standard.object(forKey: "haptics") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "haptics")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "haptics")
        }
    }

    nonisolated static var verboseErrors: Bool {
        get {
            if UserDefaults.standard.object(forKey: "verboseErrors") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "verboseErrors")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "verboseErrors")
        }
    }

    nonisolated static var onThisPhoneBacklogNudgeDismissed: Bool {
        get {
            UserDefaults.standard.bool(forKey: "onThisPhoneBacklogNudgeDismissed")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "onThisPhoneBacklogNudgeDismissed")
        }
    }

    nonisolated static var problemReportsEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: "problemReportsEnabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "problemReportsEnabled")
        }
    }

    nonisolated static let hiddenHomeSourceIDsKey = "hiddenHomeSourceIDs"

    nonisolated static var hiddenHomeSourceIDs: Set<String> {
        get {
            Self.decodeHiddenHomeSourceIDs(UserDefaults.standard.data(forKey: Self.hiddenHomeSourceIDsKey))
        }
        set {
            UserDefaults.standard.set(Self.encodeHiddenHomeSourceIDs(newValue), forKey: Self.hiddenHomeSourceIDsKey)
        }
    }

    nonisolated static func encodeHiddenHomeSourceIDs(_ ids: Set<String>) -> Data {
        let sorted = ids.sorted()
        return (try? JSONEncoder().encode(sorted)) ?? Data()
    }

    nonisolated static func decodeHiddenHomeSourceIDs(_ data: Data?) -> Set<String> {
        guard let data, !data.isEmpty,
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return Set(ids)
    }
}
