// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel

/// Where a session's unknown-journal sightings come from. `TunnelSession` publishes them and
/// `TunnelSessioning` doesn't ask for them, so the transport reaches them with a cast, as it does
/// attempt updates.
nonisolated protocol UnknownJournalObserving: Sendable {
    var unknownJournalSightings: AsyncStream<UnknownJournalSighting> { get }
}

extension TunnelSession: UnknownJournalObserving {}

/// A peer that answered where the paired journal was expected and is not it. A notice, never a
/// fault: it sits beside the connection's own state and never feeds it, and it never says what the
/// peer is.
nonisolated struct UnknownJournalNotice: Equatable, Sendable, Identifiable {
    /// One notice per place. Two sightings can't be assumed to share a cause, so places never merge.
    enum Place: Hashable, Sendable {
        case address(String)
        case relay

        init(_ dialled: ConnectedVia) {
            switch dialled {
            case .lanDirect(let host, let port):
                self = .address(JournalAddress.display(host: host, port: port))
            case .relay:
                self = .relay
            }
        }
    }

    /// What the `what answered` slot draws. The jid is what the peer claimed, not who it is.
    enum Claim: Equatable, Sendable {
        case noIdentity
        case deriving
        case mark(JournalMark)
        /// The peer presented an identity and its mark couldn't be computed. Retried on the next
        /// sighting.
        case unavailable
    }

    let place: Place
    var claimedJournalID: String?
    var claim: Claim

    var id: Place { self.place }
}

/// The notice's words, by key. Each slot's key is chosen here so a test can hold the mapping
/// without holding the copy.
nonisolated enum UnknownJournalCopy {
    static let expandKey = "unknown_journal.expand"
    static let headingKey = "unknown_journal.heading"
    static let whatAnsweredKey = "unknown_journal.label.what_answered"
    static let yourJournalKey = "unknown_journal.label.your_journal"
    static let notPresentedWordKeys = ["unknown_journal.slot.word_1", "unknown_journal.slot.word_2"]
    static let noIdentitySpokenKey = "unknown_journal.slot.spoken"

    static func rowKey(_ place: UnknownJournalNotice.Place) -> String {
        switch place {
        case .address: "unknown_journal.row.direct"
        case .relay: "unknown_journal.row.relay"
        }
    }

    static func bodyKey(_ place: UnknownJournalNotice.Place) -> String {
        switch place {
        case .address: "unknown_journal.body.direct"
        case .relay: "unknown_journal.body.relay"
        }
    }

    static func captionKey(_ claim: UnknownJournalNotice.Claim) -> String? {
        switch claim {
        case .noIdentity: "unknown_journal.caption.no_identity"
        case .deriving, .mark: "unknown_journal.caption.claimed"
        case .unavailable: nil
        }
    }

    static func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key))
    }

    static func localized(_ key: String, place: UnknownJournalNotice.Place) -> String {
        guard case .address(let address) = place else { return Self.localized(key) }
        return Self.localized(key).replacingOccurrences(of: "{address}", with: address)
    }

    /// The `what answered` slot as VoiceOver reads it. The no-identity slot's name is its caption,
    /// so that case says it once.
    static func whatAnsweredSpokenValue(_ claim: UnknownJournalNotice.Claim) -> String {
        let caption = Self.captionKey(claim).map { Self.localized($0) } ?? ""
        switch claim {
        case .noIdentity:
            return Self.localized(Self.noIdentitySpokenKey)
        case .deriving:
            return caption
        case .mark(let mark):
            return "\(JournalMarkAccessibility.spokenValue(mark: mark)), \(caption)"
        case .unavailable:
            return JournalIdentity.unavailableWords.joined(separator: ", ")
        }
    }
}
