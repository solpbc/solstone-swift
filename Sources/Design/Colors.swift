// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

// Brand spec: sol brand canon (kept outside this repo).
// Canonical triples — locked by Tests/BrandColorTests.swift
// Do not edit values; mirror via `make brand-sync`.
extension Color {
    /// Sol orange — primary brand accent (#E8923A)
    static let solOrange = Color(red: 0.910, green: 0.573, blue: 0.227)
    /// Sol gold — decorative, rays/backgrounds (#F5C740)
    static let solGold = Color(red: 0.961, green: 0.780, blue: 0.251)
    /// Sol cream — warm day-home ground (#FAF3E4)
    static let solCream = Color(red: 0.980, green: 0.953, blue: 0.894)
    /// Sol cream bright — light surface tint (#FEFCF8)
    static let solCreamBright = Color(red: 0.996, green: 0.988, blue: 0.973)
    /// Sol orange accessible — WCAG AA on white (#b06a1a)
    static let solOrangeAccessible = Color(red: 0.690, green: 0.416, blue: 0.102)
    /// Saved-state green — local "saved on this phone" confirmation (#2E7C32 light / brighter dark)
    static let solSavedGreen = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.290, green: 0.871, blue: 0.502, alpha: 1)
            : UIColor(red: 0.180, green: 0.486, blue: 0.196, alpha: 1)
    })
}
