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

    func open(path: String = "/") {
        self.request = Request(path: path)
    }

    func consume(pairingPresented: Bool) -> Request? {
        guard !pairingPresented, let request = self.request else { return nil }
        self.request = nil
        return request
    }
}
