// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

private let watchPhoneSessionHistoryLog = Logger(subsystem: "app.solstone.swift", category: "watch-phone-history")

nonisolated struct WatchPhoneSessionHistorySnapshot: Codable, Equatable, Sendable {
    let entries: [WatchCaptureSessionHistoryEntry]
    let retainedCount: Int
    let prunedForAgeTotal: Int
    let distinctMergedTotal: Int
    let retentionDays: Int
    let adjustedWatchStarted: DiagnosticAvailability<Int>
    let counterEpoch: DiagnosticAvailability<String>
    let baselineEpoch: String?
    let baselineAdjustedWatchStarted: Int?
    let baselineDistinctMerged: Int?
}

nonisolated private struct WatchPhoneSessionHistoryMetadata: Codable, Equatable, Sendable {
    var counterEpoch: String?
    var adjustedWatchStarted: Int?
    var counterUnavailableReason: String?
    var baselineEpoch: String?
    var baselineAdjustedWatchStarted: Int?
    var baselineDistinctMerged: Int?
    var distinctMergedTotal: Int
    var prunedForAgeTotal: Int

    static let empty = Self(
        counterEpoch: nil,
        adjustedWatchStarted: nil,
        counterUnavailableReason: nil,
        baselineEpoch: nil,
        baselineAdjustedWatchStarted: nil,
        baselineDistinctMerged: nil,
        distinctMergedTotal: 0,
        prunedForAgeTotal: 0
    )
}

nonisolated private struct WatchPhoneSessionHistoryRecord: Codable, Equatable, Sendable {
    var entry: WatchCaptureSessionHistoryEntry
    var retentionAnchorAt: Date
}

nonisolated private enum WatchPhoneSessionHistoryFileLine: Codable, Equatable, Sendable {
    case metadata(WatchPhoneSessionHistoryMetadata)
    case session(WatchPhoneSessionHistoryRecord)

    private enum CodingKeys: String, CodingKey {
        case kind
        case version
        case metadata
        case record
    }

    private enum Kind: String, Codable {
        case metadata
        case session
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .metadata:
            _ = try container.decode(Int.self, forKey: .version)
            self = .metadata(try container.decode(WatchPhoneSessionHistoryMetadata.self, forKey: .metadata))
        case .session:
            self = .session(try container.decode(WatchPhoneSessionHistoryRecord.self, forKey: .record))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .metadata(metadata):
            try container.encode(Kind.metadata, forKey: .kind)
            try container.encode(1, forKey: .version)
            try container.encode(metadata, forKey: .metadata)
        case let .session(record):
            try container.encode(Kind.session, forKey: .kind)
            try container.encode(record, forKey: .record)
        }
    }
}

@MainActor
@Observable
final class WatchPhoneSessionHistoryStore {
    static let historyFileName = "phone-watch-session-history.jsonl"
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    private let fileURL: URL?
    private let clock: @MainActor @Sendable () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var metadata = WatchPhoneSessionHistoryMetadata.empty
    private var recordsByID: [String: WatchPhoneSessionHistoryRecord] = [:]
    private var unreadableLines: [Data] = []
    private var hadDamage = false
    private var metadataReadable = true

    init(
        fileURL: URL? = nil,
        clock: @escaping @MainActor @Sendable () -> Date = Date.init
    ) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = try? AppGroupContainer.rootURL()
                .appendingPathComponent(WatchRelayReceiver.rootDirectoryName, isDirectory: true)
                .appendingPathComponent(Self.historyFileName, isDirectory: false)
        }
        self.clock = clock
        self.encoder = WatchRelayDiagnosticsEnvelope.makeEncoder()
        self.decoder = WatchRelayDiagnosticsEnvelope.makeDecoder()
        self.load()
    }

    static var retentionDays: Int {
        Int(Self.retention / (24 * 60 * 60))
    }

    @discardableResult
    func merge(
        diagnostics: WatchRelayDiagnosticsEnvelopeResult,
        status: WatchStatusContext?
    ) -> Bool {
        guard let payload = diagnostics.payload else { return false }
        let now = self.clock()
        var changed = false

        if case let .available(entries) = payload.sessionHistoryWindow {
            for entry in entries {
                changed = self.merge(entry: entry, now: now) || changed
            }
        }

        changed = self.updateCounters(payload: payload, status: status) || changed

        if case .available = payload.sessionHistoryWindow {
            changed = self.captureBaselineIfNeeded() || changed
        }

        guard changed else { return false }
        self.pruneAndPersist(force: true)
        return true
    }

    func load() {
        guard let fileURL else {
            self.metadataReadable = false
            self.hadDamage = true
            return
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL) else {
            self.metadataReadable = false
            self.hadDamage = true
            return
        }

        var parsedMetadata: WatchPhoneSessionHistoryMetadata?
        var parsedRecords: [String: WatchPhoneSessionHistoryRecord] = [:]
        var parsedUnreadableLines: [Data] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let lineData = Data(line)
            guard let decoded = try? self.decoder.decode(WatchPhoneSessionHistoryFileLine.self, from: lineData) else {
                parsedUnreadableLines.append(lineData)
                continue
            }
            switch decoded {
            case let .metadata(value):
                if parsedMetadata == nil {
                    parsedMetadata = value
                } else {
                    parsedUnreadableLines.append(lineData)
                }
            case let .session(record):
                parsedRecords[record.entry.sessionID] = record
            }
        }

        self.metadata = parsedMetadata ?? .empty
        self.metadataReadable = parsedMetadata != nil
        self.recordsByID = parsedRecords
        self.unreadableLines = parsedUnreadableLines
        self.hadDamage = !parsedUnreadableLines.isEmpty || !self.metadataReadable
        self.pruneAndPersist()
    }

    func pruneAndPersist(force: Bool = false) {
        guard self.metadataReadable else {
            watchPhoneSessionHistoryLog.error("watch phone history metadata is unreadable; preserving existing file")
            return
        }
        let dropped = self.prune(asOf: self.clock())
        guard dropped > 0 || force else { return }
        do {
            try self.persist()
        } catch {
            watchPhoneSessionHistoryLog.error("watch phone history persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    func readSnapshot(asOf: Date) -> DiagnosticAvailability<WatchPhoneSessionHistorySnapshot> {
        guard self.metadataReadable, !self.hadDamage else {
            return .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.sessionHistoryUnreadable)
        }

        let retainedRecords = self.recordsByID.values.filter { self.isRetained($0, asOf: asOf) }
        let agedOutCount = self.recordsByID.count - retainedRecords.count
        let entries = retainedRecords
            .map(\.entry)
            .sorted { $0.startedAt > $1.startedAt }
        return .available(WatchPhoneSessionHistorySnapshot(
            entries: entries,
            retainedCount: entries.count,
            prunedForAgeTotal: self.metadata.prunedForAgeTotal + agedOutCount,
            distinctMergedTotal: self.metadata.distinctMergedTotal,
            retentionDays: Self.retentionDays,
            adjustedWatchStarted: self.adjustedWatchStartedAvailability,
            counterEpoch: self.counterEpochAvailability,
            baselineEpoch: self.metadata.baselineEpoch,
            baselineAdjustedWatchStarted: self.metadata.baselineAdjustedWatchStarted,
            baselineDistinctMerged: self.metadata.baselineDistinctMerged
        ))
    }
}

private extension WatchPhoneSessionHistoryStore {
    var adjustedWatchStartedAvailability: DiagnosticAvailability<Int> {
        guard let value = self.metadata.adjustedWatchStarted,
              self.metadata.counterUnavailableReason == nil
        else {
            return .unavailable(reason: self.metadata.counterUnavailableReason ?? WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild)
        }
        return .available(value)
    }

    var counterEpochAvailability: DiagnosticAvailability<String> {
        guard let value = self.metadata.counterEpoch,
              self.metadata.counterUnavailableReason == nil
        else {
            return .unavailable(reason: self.metadata.counterUnavailableReason ?? WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild)
        }
        return .available(value)
    }

    func merge(entry incoming: WatchCaptureSessionHistoryEntry, now: Date) -> Bool {
        guard var existing = self.recordsByID[incoming.sessionID] else {
            self.recordsByID[incoming.sessionID] = WatchPhoneSessionHistoryRecord(
                entry: incoming,
                retentionAnchorAt: self.retentionAnchor(
                    previous: nil,
                    entry: incoming,
                    now: now
                )
            )
            self.metadata.distinctMergedTotal += 1
            return true
        }

        let before = existing
        let existingComplete = existing.entry.isComplete
        let incomingComplete = incoming.isComplete
        self.mergeOptionalFields(from: incoming, into: &existing.entry)
        if incomingComplete && !existingComplete {
            existing.entry.noticeOwed = incoming.noticeOwed
            existing.entry.audioArmed = incoming.audioArmed
            existing.entry.audioSessionIsActive = incoming.audioSessionIsActive
            existing.entry.locationArmed = incoming.locationArmed
        }
        existing.entry.segmentsProduced = max(existing.entry.segmentsProduced, incoming.segmentsProduced)
        existing.retentionAnchorAt = self.retentionAnchor(
            previous: existing.retentionAnchorAt,
            entry: incoming,
            now: now
        )
        guard existing != before else { return false }
        self.recordsByID[incoming.sessionID] = existing
        return true
    }

    func mergeOptionalFields(
        from incoming: WatchCaptureSessionHistoryEntry,
        into existing: inout WatchCaptureSessionHistoryEntry
    ) {
        if existing.terminalAt == nil { existing.terminalAt = incoming.terminalAt }
        if existing.terminalReason == nil { existing.terminalReason = incoming.terminalReason }
        if existing.terminalDisposition == nil { existing.terminalDisposition = incoming.terminalDisposition }
        if existing.startRefusalReason == nil { existing.startRefusalReason = incoming.startRefusalReason }
        if existing.settingsRoute == nil { existing.settingsRoute = incoming.settingsRoute }
        if existing.noticeDecision == nil { existing.noticeDecision = incoming.noticeDecision }
        if existing.noticeDelivered == nil { existing.noticeDelivered = incoming.noticeDelivered }
        if existing.notificationAuthorizationStatus == nil { existing.notificationAuthorizationStatus = incoming.notificationAuthorizationStatus }
        if existing.notificationAlertSetting == nil { existing.notificationAlertSetting = incoming.notificationAlertSetting }
        if existing.wristAlertAssurance == nil { existing.wristAlertAssurance = incoming.wristAlertAssurance }
        if existing.batteryLevelAtEnd == nil { existing.batteryLevelAtEnd = incoming.batteryLevelAtEnd }
        if existing.batteryStateAtEnd == nil { existing.batteryStateAtEnd = incoming.batteryStateAtEnd }
        if existing.lowPowerModeEnabledAtEnd == nil { existing.lowPowerModeEnabledAtEnd = incoming.lowPowerModeEnabledAtEnd }
        if existing.thermalStateAtEnd == nil { existing.thermalStateAtEnd = incoming.thermalStateAtEnd }
        if existing.lastVerifiedAudioAt == nil { existing.lastVerifiedAudioAt = incoming.lastVerifiedAudioAt }
        if existing.lastAudioCurrentTime == nil { existing.lastAudioCurrentTime = incoming.lastAudioCurrentTime }
        if existing.zeroAudioCurrentTimeObservationCount == nil { existing.zeroAudioCurrentTimeObservationCount = incoming.zeroAudioCurrentTimeObservationCount }
        if existing.locationAdvisory == nil { existing.locationAdvisory = incoming.locationAdvisory }
        if existing.persistenceAdvisory == nil { existing.persistenceAdvisory = incoming.persistenceAdvisory }
    }

    func updateCounters(payload: WatchRelayDiagnosticsPayload, status: WatchStatusContext?) -> Bool {
        guard case let .available(lifetime) = payload.lifetimeSessionsStarted,
              case let .available(epoch) = payload.sessionHistoryCounterEpoch
        else {
            let reason = payload.lifetimeSessionsStarted.unavailableReason
                ?? payload.sessionHistoryCounterEpoch.unavailableReason
                ?? WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild
            let changed = self.metadata.counterEpoch != nil
                || self.metadata.adjustedWatchStarted != nil
                || self.metadata.counterUnavailableReason != reason
            self.metadata.counterEpoch = nil
            self.metadata.adjustedWatchStarted = nil
            self.metadata.counterUnavailableReason = reason
            return changed
        }

        let liveUnmerged: Bool
        if let status,
           status.phase != .idle,
           let sessionID = status.sessionID
        {
            liveUnmerged = self.recordsByID[sessionID] == nil
        } else {
            liveUnmerged = false
        }
        let adjusted = lifetime - (liveUnmerged ? 1 : 0)
        let changed = self.metadata.counterEpoch != epoch
            || self.metadata.adjustedWatchStarted != adjusted
            || self.metadata.counterUnavailableReason != nil
        self.metadata.counterEpoch = epoch
        self.metadata.adjustedWatchStarted = adjusted
        self.metadata.counterUnavailableReason = nil
        return changed
    }

    func captureBaselineIfNeeded() -> Bool {
        guard let epoch = self.metadata.counterEpoch,
              let adjusted = self.metadata.adjustedWatchStarted,
              self.metadata.counterUnavailableReason == nil
        else { return false }
        guard self.metadata.baselineEpoch != epoch
            || self.metadata.baselineAdjustedWatchStarted == nil
            || self.metadata.baselineDistinctMerged == nil
        else { return false }
        self.metadata.baselineEpoch = epoch
        self.metadata.baselineAdjustedWatchStarted = adjusted
        self.metadata.baselineDistinctMerged = self.metadata.distinctMergedTotal
        return true
    }

    func retentionAnchor(
        previous: Date?,
        entry: WatchCaptureSessionHistoryEntry,
        now: Date
    ) -> Date {
        max(previous ?? .distantPast, min(entry.terminalAt ?? entry.startedAt, now))
    }

    func isRetained(_ record: WatchPhoneSessionHistoryRecord, asOf: Date) -> Bool {
        record.retentionAnchorAt >= asOf.addingTimeInterval(-Self.retention)
    }

    func prune(asOf: Date) -> Int {
        let expiredIDs = self.recordsByID.compactMap { id, record in
            self.isRetained(record, asOf: asOf) ? nil : id
        }
        guard !expiredIDs.isEmpty else { return 0 }
        for id in expiredIDs {
            self.recordsByID.removeValue(forKey: id)
        }
        self.metadata.prunedForAgeTotal += expiredIDs.count
        return expiredIDs.count
    }

    func persist() throws {
        guard let fileURL else { throw WatchPhoneSessionHistoryStoreError.fileURLUnavailable }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var data = Data()
        data.append(try self.encoder.encode(WatchPhoneSessionHistoryFileLine.metadata(self.metadata)))
        data.append(0x0A)
        for record in self.recordsByID.values.sorted(by: { $0.entry.startedAt < $1.entry.startedAt }) {
            data.append(try self.encoder.encode(WatchPhoneSessionHistoryFileLine.session(record)))
            data.append(0x0A)
        }
        for line in self.unreadableLines {
            data.append(line)
            data.append(0x0A)
        }
        try data.write(to: fileURL, options: [.atomic])
    }
}

nonisolated private enum WatchPhoneSessionHistoryStoreError: Error, Sendable {
    case fileURLUnavailable
}
