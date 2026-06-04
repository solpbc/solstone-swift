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
}
