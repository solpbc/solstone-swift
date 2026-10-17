// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel

enum PairingHandoffPresentation {
    nonisolated static func shouldPresent(
        pairURL: PairURL?, pairURLError: PairURLError?, stagedDraft: String? = nil, presenceCount: Int = 0
    ) -> Bool {
        presenceCount == 0 && (pairURL != nil || pairURLError != nil || stagedDraft != nil)
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
        appConfig: AppConfig,
        pendingObserverCommand: PendingObserverCommandState = PendingObserverCommandState(),
        pendingJournalOpen: PendingJournalOpenState = PendingJournalOpenState()
    ) {
        if pairingHandoff.stageExternalLink(url, awaitingMarkConfirmation: appConfig.awaitingMarkConfirmation) {
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
    func stageExternalLink(_ url: URL, awaitingMarkConfirmation: Bool = false) -> Bool {
        if awaitingMarkConfirmation || self.externalLinkAttemptInFlight || self.heldMarkConfirmation || self.pairingInProgress {
            return false
        }

        let rawString = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)

        let isAlias = url.scheme?.lowercased() == "solstone" && url.host?.lowercased() == "pair"
        let result: Result<PairURL, PairURLError>?
        if isAlias {
            result = PairAliasNormalizer.canonicalURL(from: rawString).flatMap(UniversalLinkRouter.route)
                ?? .failure(.malformedOuterURL)
        } else {
            result = UniversalLinkRouter.route(url)
        }
        switch result {
        case .success:
            self.stagedDraft = rawString
            self.pairURLError = nil
            return true
        case .failure(let error):
            self.stagedDraft = nil
            self.pairURLError = error
            return true
        case nil:
            return false
        }
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
