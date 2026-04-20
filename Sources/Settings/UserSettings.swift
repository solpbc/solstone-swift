// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

enum UserSettings: Sendable {
    static var verboseErrors: Bool {
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
}
