// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel

enum PairingHandoffPresentation {
    nonisolated static func shouldPresent(pairURL: PairURL?, pairURLError: PairURLError?) -> Bool {
        pairURL != nil || pairURLError != nil
    }
}

nonisolated enum ExternalPairLinkIntake {
    static func collect(urlContextURLs: [URL], browsingWebURLs: [URL]) -> [URL] {
        urlContextURLs + browsingWebURLs
    }
}

@MainActor
final class ExternalPairLinkQueue {
    static let shared = ExternalPairLinkQueue()

    private var items: [URL] = []

    func enqueue(_ urls: [URL]) {
        self.items.append(contentsOf: urls)
    }

    func enqueue(_ url: URL) {
        self.items.append(url)
    }

    func drain() -> [URL] {
        let drained = self.items
        self.items.removeAll()
        return drained
    }
}

@MainActor
extension ExternalPairLinkIntake {
    static func handle(
        url: URL,
        pairingHandoff: PairingHandoffState,
        pendingObserverCommand: PendingObserverCommandState = PendingObserverCommandState(),
        pendingJournalOpen: PendingJournalOpenState = PendingJournalOpenState()
    ) {
        if pairingHandoff.stageExternalLink(url) {
            return
        }
        switch SolstoneDeepLink.parse(url) {
        case .observerStop:
            pendingObserverCommand.command = .stopRequested
        case .journal:
            pendingJournalOpen.isOpenRequested = true
        case nil:
            break
        }
    }
}

@MainActor
extension PairingHandoffState {
    @discardableResult
    func stageExternalLink(_ url: URL) -> Bool {
        if self.externalLinkAttemptInFlight || self.heldMarkConfirmation || self.pairingInProgress {
            return false
        }

        let rawString = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)

        if let scheme = url.scheme, scheme.caseInsensitiveCompare("solstone") == .orderedSame {
            guard let canonical = PairAliasNormalizer.canonicalURL(from: rawString) else {
                return false
            }
            guard case .success = UniversalLinkRouter.route(canonical) else {
                return false
            }
            self.stagedDraft = rawString
            return true
        }

        if case .success = UniversalLinkRouter.route(url) {
            self.stagedDraft = rawString
            return true
        }

        return false
    }

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
