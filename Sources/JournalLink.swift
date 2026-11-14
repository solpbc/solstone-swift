// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// An inbound link is only an opaque journal target, never a pairing or credential.
nonisolated enum JournalLink {
    enum Route: Equatable {
        case open(path: String)
        case invalid
    }

    static func route(_ url: URL) -> Route? {
        let isWebLink = url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "go.solstone.app" && url.path == "/j"
        let isAppLink = url.scheme?.lowercased() == "solstone" && url.host?.lowercased() == "open"
        guard isWebLink || isAppLink else { return nil }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil, parts.query == nil,
              parts.percentEncodedPath == (isWebLink ? "/j" : ""),
              let target = parts.percentEncodedFragment,
              self.isValidTarget(target)
        else { return .invalid }
        return .open(path: "/app/open/" + target)
    }

    private static func isValidTarget(_ target: String) -> Bool {
        let parts = target.split(separator: "~", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
              let sealed = parts.first, (1...512).contains(sealed.utf8.count),
              sealed.utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte)
                      || (48...57).contains(byte) || byte == 45 || byte == 95
              })
        else { return false }
        return parts.count == 1 || (parts[1].utf8.count == 6 && parts[1].utf8.allSatisfy { (48...57).contains($0) })
    }
}
