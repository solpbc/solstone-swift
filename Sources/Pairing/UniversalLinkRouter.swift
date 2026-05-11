// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel

@MainActor
public enum UniversalLinkRouter {
    public static func route(_ url: URL) -> PairURL? {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "link.solpbc.org",
              url.path == "/p" else {
            return nil
        }
        return try? PairURL.parse(url)
    }
}
