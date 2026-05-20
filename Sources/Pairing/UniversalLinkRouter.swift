// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel

public enum UniversalLinkRouter {
    // nil = not a pair link (caller falls through). .failure = pair link by host/path but body failed to parse (caller shows variant-specific message).
    public nonisolated static func route(_ url: URL) -> Result<PairURL, PairURLError>? {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "link.solpbc.org",
              url.path == "/p" else {
            return nil
        }
        do {
            return .success(try PairURL.parse(url))
        } catch let error as PairURLError {
            return .failure(error)
        } catch {
            preconditionFailure("PairURL.parse threw non-PairURLError: \(error)")
        }
    }
}
