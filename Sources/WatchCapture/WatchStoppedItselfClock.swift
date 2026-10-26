// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// When the phone first saw the watch's current stopped-itself state.
nonisolated struct WatchStoppedItselfRecord: Codable, Equatable, Sendable {
    var sessionID: String?
    var firstReceivedAt: Date
    var firstAsOf: Date

    /// The watch's own publish time bounds the end from above, so the earlier of the two counts.
    var since: Date {
        min(self.firstReceivedAt, self.firstAsOf)
    }
}

/// The phone shows a watch session that stopped on its own for a day from its end, then what it
/// would show without it. The end is the session's end in the phone's watch history when present;
/// otherwise this clock's record of when the phone first saw that state. One record is kept, across
/// relaunch, so a relaunch or a republish never restarts the day. The record in memory governs even
/// when it cannot be saved.
@MainActor
final class WatchStoppedItselfClock {
    static let defaultsKey = "watchStoppedItselfRecord"

    private let defaults: UserDefaults
    private(set) var record: WatchStoppedItselfRecord?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey) {
            self.record = try? JSONDecoder().decode(WatchStoppedItselfRecord.self, from: data)
        }
    }

    func note(_ context: WatchStatusContext?, receivedAt: Date) {
        // A missing or unreadable status says nothing about the session.
        guard let context else { return }
        if Self.isStoppedItself(context) {
            let replace: Bool
            if let record = self.record {
                if let sessionID = context.sessionID {
                    replace = record.sessionID != sessionID
                } else {
                    replace = record.sessionID != nil
                }
            } else {
                replace = true
            }
            if replace {
                self.set(WatchStoppedItselfRecord(
                    sessionID: context.sessionID,
                    firstReceivedAt: receivedAt,
                    firstAsOf: context.asOf
                ))
            }
            return
        }
        // Only a new start or the owner stopping clears it. The watch republishes an idle status
        // with no session while it settles after a relaunch, and that must not restart the day.
        let startedAgain = context.phase == .observing
            || context.audioTerminalDisposition == .ownerStopped
            || (context.sessionID != nil && context.sessionID != self.record?.sessionID)
        if startedAgain, self.record != nil {
            self.set(nil)
        }
    }

    /// When the stopped-itself day starts for this status: the history's end for its session, else the record.
    static func since(
        context: WatchStatusContext?,
        historyEntries: [WatchCaptureSessionHistoryEntry],
        record: WatchStoppedItselfRecord?
    ) -> Date? {
        guard let context, Self.isStoppedItself(context) else { return nil }
        if let sessionID = context.sessionID,
           let terminalAt = historyEntries.last(where: { $0.sessionID == sessionID })?.terminalAt {
            return terminalAt
        }
        guard let record, record.sessionID == context.sessionID else { return nil }
        return record.since
    }

    static func isStoppedItself(_ context: WatchStatusContext) -> Bool {
        WatchNoticeCopy(
            terminalReason: context.audioTerminalReason,
            terminalDisposition: context.audioTerminalDisposition
        ) != nil
    }

    private func set(_ record: WatchStoppedItselfRecord?) {
        self.record = record
        if let record, let data = try? JSONEncoder().encode(record) {
            self.defaults.set(data, forKey: Self.defaultsKey)
        } else {
            self.defaults.removeObject(forKey: Self.defaultsKey)
        }
    }
}
