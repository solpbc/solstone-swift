// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum PairAliasNormalizer {
    static func canonicalURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed) else { return nil }
        guard let scheme = components.scheme, scheme.caseInsensitiveCompare("solstone") == .orderedSame else {
            return nil
        }
        guard let host = components.host, host.caseInsensitiveCompare("pair") == .orderedSame else {
            return nil
        }
        guard components.path.isEmpty || components.path == "/" else {
            return nil
        }
        if let query = components.percentEncodedQuery, !query.isEmpty {
            return nil
        }
        guard let encoded = components.percentEncodedFragment, !encoded.isEmpty else {
            return nil
        }
        var canonical = URLComponents()
        canonical.scheme = "https"
        canonical.host = "go.solstone.app"
        canonical.path = "/p"
        canonical.percentEncodedFragment = encoded
        return canonical.url
    }
}
