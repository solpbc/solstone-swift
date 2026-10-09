// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// What a settled journal refusal was made under, recorded on the attention item in readable
/// form so a later round can say which of them changed.
///
/// The first three describe this device and the journal it sends to; the rest are the item's
/// own envelope as it was sent. The journal decides a settled refusal from the envelope alone,
/// so while all of these hold, sending the same item again gets the same answer.
nonisolated struct TransferRefusalConditions: Codable, Equatable, Sendable {
    /// This app's build (`CFBundleVersion`). `nil` when it was not known.
    var appBuild: String?
    /// The pairing the refusal came through. `nil` when it was not known.
    var pairingIdentity: String?
    /// The journal's version, without a leading `v`. Its build is not used: it clears and
    /// refills on every journal upgrade. `nil` when it was not known yet.
    var journalVersion: String?
    var endpointPath: String
    var source: String
    var day: String
    var segment: String
    var ingestProtocolVersion: Int?

    /// The conditions that differ between this record and `current`.
    ///
    /// For the device and journal fields an unknown current value never counts as a change (the
    /// last known one stands), and a known current value counts as a change from an unknown
    /// recorded one. The envelope fields are always known now and compare as they are.
    func changes(to current: TransferRefusalConditions) -> [TransferRefusalCondition] {
        var changed: [TransferRefusalCondition] = []
        if Self.knownValueChanged(recorded: self.appBuild, current: current.appBuild) {
            changed.append(.appBuild)
        }
        if Self.knownValueChanged(recorded: self.pairingIdentity, current: current.pairingIdentity) {
            changed.append(.pairing)
        }
        if Self.knownValueChanged(
            recorded: Self.normalizedJournalVersion(self.journalVersion),
            current: Self.normalizedJournalVersion(current.journalVersion)
        ) {
            changed.append(.journalVersion)
        }
        if self.endpointPath != current.endpointPath {
            changed.append(.endpointPath)
        }
        if self.source != current.source {
            changed.append(.source)
        }
        if self.day != current.day {
            changed.append(.day)
        }
        if self.segment != current.segment {
            changed.append(.segment)
        }
        if self.ingestProtocolVersion != current.ingestProtocolVersion {
            changed.append(.ingestProtocolVersion)
        }
        return changed
    }

    /// A journal version as it is compared and recorded: trimmed, without a leading `v`, and
    /// `nil` when empty.
    static func normalizedJournalVersion(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = AboutBlock.trimLeadingV(value.trimmingCharacters(in: .whitespacesAndNewlines))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func knownValueChanged(recorded: String?, current: String?) -> Bool {
        guard let current else { return false }
        return recorded != current
    }
}

/// One recorded condition, named as the round's log line counts it.
nonisolated enum TransferRefusalCondition: String, CaseIterable, Sendable {
    case appBuild = "app-build"
    case pairing
    case journalVersion = "journal-version"
    case endpointPath = "endpoint"
    case source
    case day
    case segment
    case ingestProtocolVersion = "ingest-protocol"
}

/// Why a settled refusal is offered again in a round.
nonisolated enum TransferRefusalReoffer: Hashable, Sendable {
    case changed(TransferRefusalCondition)
    case dayElapsed
    case clockMovedBack

    var logName: String {
        switch self {
        case .changed(let condition):
            condition.rawValue
        case .dayElapsed:
            "day-elapsed"
        case .clockMovedBack:
            "clock-moved-back"
        }
    }

    static let logOrder: [TransferRefusalReoffer] = TransferRefusalCondition.allCases.map { .changed($0) }
        + [.dayElapsed, .clockMovedBack]
}

/// How the round on each new connection treats an item the journal refused.
///
/// Nothing here deletes, ages out or caps anything: a paced item stays in attention and is
/// evaluated again by every round. It is skipped only while everything it was refused under
/// still holds and less than a day has passed.
nonisolated enum TransferRefusalPacing {
    /// How long a settled refusal waits before a round offers it again when nothing changed.
    static let recheckInterval: TimeInterval = 86_400
    /// How far the wall clock may sit before the refusal before the clock is taken to have moved
    /// back, which offers the item again.
    static let clockMovedBackTolerance: TimeInterval = 60

    /// Reason codes the journal derives only from the envelope's own fields. Sending the same
    /// envelope again gets the same answer. Every other code, and any code not listed here, is
    /// left to today's retry on each new connection.
    static let settledReasonCodes: Set<String> = [
        "day_invalid",
        "segment_invalid",
        "envelope_invalid",
        "legacy_observer_field",
        "legacy_stream_field",
        "source_not_utf8",
        "source_too_long",
        "source_contains_nul",
        "source_contains_path_separator",
        "source_contains_dot",
        "source_invalid_character",
    ]

    /// Statuses that say "not now" rather than "not this", whatever reason code they carry.
    static let unsettledClientStatuses: Set<Int> = [408, 426, 429]

    /// Whether a refusal is settled, decided where it is received: an observer-ingest 4xx (not a
    /// 2xx carrying a failed status, and not a "not now" status) whose reason code is one the
    /// journal derives only from the envelope.
    static func isSettled(_ reason: TransferAttentionReason, phase: TransferEndpointPhase) -> Bool {
        guard phase == .observerIngest,
              case .httpClientError(let statusCode, _, let journalReasonCode) = reason,
              400..<500 ~= statusCode,
              !Self.unsettledClientStatuses.contains(statusCode),
              let journalReasonCode
        else {
            return false
        }
        return Self.settledReasonCodes.contains(journalReasonCode)
    }

    nonisolated enum Verdict: Equatable, Sendable {
        /// Not a settled refusal: the round treats it as it always has.
        case unsettled
        /// Skipped by this round only.
        case paced
        /// Offered again, for these reasons.
        case reoffered([TransferRefusalReoffer])
    }

    static func verdict(
        for attention: TransferAttentionInfo,
        current: TransferRefusalConditions?,
        now: Date
    ) -> Verdict {
        guard let recorded = attention.refusedUnder else { return .unsettled }
        var reasons: [TransferRefusalReoffer] = []
        if let current {
            reasons.append(contentsOf: recorded.changes(to: current).map { .changed($0) })
        }
        if now.timeIntervalSince(attention.movedAt) >= Self.recheckInterval {
            reasons.append(.dayElapsed)
        }
        if attention.movedAt.timeIntervalSince(now) > Self.clockMovedBackTolerance {
            reasons.append(.clockMovedBack)
        }
        return reasons.isEmpty ? .paced : .reoffered(reasons)
    }
}
