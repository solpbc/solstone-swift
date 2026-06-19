// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel

enum PairingHandoffPresentation {
    nonisolated static func shouldPresent(pairURL: PairURL?, pairURLError: PairURLError?) -> Bool {
        pairURL != nil || pairURLError != nil
    }
}

@MainActor
extension PairingHandoffState {
    @discardableResult
    func applyUniversalLink(_ url: URL) -> Bool {
        guard let result = UniversalLinkRouter.route(url) else {
            return false
        }

        switch result {
        case .success(let pairURL):
            self.pairURL = pairURL
            self.pairURLError = nil
        case .failure(let error):
            self.pairURL = nil
            self.pairURLError = error
        }
        return true
    }
}
