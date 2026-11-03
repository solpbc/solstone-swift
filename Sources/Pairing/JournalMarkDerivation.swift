// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SPLMark
import SPLTunnel

/// The mark the owner is asked about and sees, computed here from the CA a pairing pinned. A pair
/// link pins whichever key it names, so anything the peer serves is a claim. This needs no network.
nonisolated enum JournalMarkDerivation {
    private static let log = Logger(subsystem: "app.solstone.swift", category: "journal-mark")

    /// The mark for a pairing's stored CA chain: the one kept for that CA, or derived off the main
    /// thread and kept. `nil` when it can't be computed, which every surface draws as unavailable.
    static func mark(
        forCAChainPEM caChainPEM: String,
        store: JournalMarkStore = JournalMarkStore(),
        derive: @Sendable (String) async throws -> MarkRenderSpec = { try await deriveMark(fromJournalID: $0) }
    ) async -> JournalMark? {
        do {
            let journalID = try CertChain.journalID(ofCAChainPEM: caChainPEM)
            if let kept = store.mark(forJournalID: journalID) {
                return kept
            }
            guard let mark = JournalMark.validate(JournalMark(try await derive(journalID))) else {
                Self.log.error("derived journal mark was invalid")
                return nil
            }
            store.save(mark, journalID: journalID)
            return mark
        } catch {
            Self.log.error("journal mark derivation failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

nonisolated extension JournalMark {
    init(_ spec: MarkRenderSpec) {
        func icon(_ spec: MarkIconSpec) -> Icon {
            Icon(
                name: spec.name,
                color: MarkColor(hex: spec.color.hex, name: spec.color.name),
                rot: spec.rot,
                svg: spec.svg
            )
        }
        self.init(icon1: icon(spec.icon1), icon2: icon(spec.icon2), words: spec.words)
    }
}
