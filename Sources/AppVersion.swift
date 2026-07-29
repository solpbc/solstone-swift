// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum AppVersion {
    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    static var sourceCommit: String {
        Bundle.main.infoDictionary?["solstoneSourceCommit"] as? String ?? "unknown"
    }

    static var buildConfiguration: String {
        // make-driven builds refresh this generated metadata before compile; direct xcode app builds can be stale.
        Bundle.main.infoDictionary?["solstoneBuildConfiguration"] as? String ?? "unknown"
    }

    static var splSwiftIdentity: String {
        Bundle.main.infoDictionary?["solstoneSPLSwiftIdentity"] as? String ?? "unknown"
    }

    static var splSwiftVersion: String {
        Bundle.main.infoDictionary?["solstoneSPLSwiftVersion"] as? String ?? "unknown"
    }

    static var splSwiftRevision: String {
        Bundle.main.infoDictionary?["solstoneSPLSwiftRevision"] as? String ?? "unknown"
    }
}
