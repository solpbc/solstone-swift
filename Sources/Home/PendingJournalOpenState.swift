// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

@MainActor
@Observable
final class PendingJournalOpenState {
    struct Request: Equatable {
        let id = UUID()
        let path: String
    }

    var request: Request?
    var showsInvalidLinkNotice = false
    /// Monotonic token incremented on every explicit journal open so an already-mounted
    /// `WKWebView` navigates in place even when reopening the same URL after in-page browsing.
    private(set) var navigationToken = 0
    /// Monotonic counter incremented when the phone journal sheet or iPad journal pane closes
    /// so the underlying screen can restore VoiceOver focus via `@AccessibilityFocusState`.
    private(set) var dismissCount = 0

    func open(path: String = "/") {
        self.request = Request(path: path)
    }

    func noteNavigation() {
        self.navigationToken &+= 1
    }

    func noteDismissal() {
        self.dismissCount &+= 1
    }

    func consume(pairingPresented: Bool) -> Request? {
        guard !pairingPresented, let request = self.request else { return nil }
        self.request = nil
        return request
    }
}
