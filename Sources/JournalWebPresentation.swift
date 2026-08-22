// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum JournalWebPresentation {
    enum LoadState: Equatable {
        case loading
        case loaded
        case error(message: String)
    }

    enum NavigationOutcome: Equatable {
        case started
        case committed
        case finished
        case failed(urlErrorCode: Int)
    }

    /// Resolves the live loopback journal URL at present time. Thin wrapper over
    /// ConveyURL.rootURL so the in-app view has a single presentation-layer entry.
    static func resolvedURL(activeLocalPort: Int?) -> URL? {
        ConveyURL.rootURL(activeLocalPort: activeLocalPort)
    }

    static func loadState(for outcome: NavigationOutcome) -> LoadState {
        switch outcome {
        case .started:
            return .loading
        case .committed:
            return .loaded
        case .finished:
            return .loaded
        case .failed:
            return .error(message: Self.loadFailureMessage)
        }
    }

    /// Tunnel/connection dropped while the view is open.
    static let connectionLostState: LoadState = .error(message: Self.connectionLostMessage)

    static let loadFailureMessage = "couldn't reach your journal. keep the solstone app open and try again."
    static let connectionLostMessage = "lost the connection to your journal. keep the solstone app open and try again."
}
