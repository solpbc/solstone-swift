// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct WatchCaptureLivenessEvidence: Codable, Equatable, Sendable {
    let audioCurrentTime: Double?
    let zeroAudioCurrentTimeObservationCount: Int?
}

nonisolated struct WatchCaptureSessionHistoryEntry: Codable, Equatable, Sendable {
    let sessionID: String
    let startedAt: Date
    var terminalAt: Date?
    var terminalReason: WatchCaptureTerminalReason?
    var terminalDisposition: WatchCaptureTerminalDisposition?
    var startRefusalReason: WatchCaptureStartRefusalReason?
    var settingsRoute: WatchCaptureSettingsRoute?
    var noticeOwed: Bool
    var noticeDecision: String?
    var noticeDelivered: Bool?
    var notificationAuthorizationStatus: WatchNotificationAuthorizationStatus?
    var notificationAlertSetting: WatchNotificationAlertSetting?
    var wristAlertAssurance: WatchWristAlertAssurance?
    var audioArmed: Bool
    var audioSessionIsActive: Bool
    var locationArmed: Bool
    var segmentsProduced: Int
    var batteryLevelAtEnd: Double?
    var batteryStateAtEnd: String?
    var lowPowerModeEnabledAtEnd: Bool?
    var thermalStateAtEnd: String?
    var lastVerifiedAudioAt: Date?
    var lastAudioCurrentTime: Double?
    var zeroAudioCurrentTimeObservationCount: Int?
    var locationAdvisory: WatchCaptureLocationAdvisory?
    var persistenceAdvisory: WatchCapturePersistenceAdvisory?

    enum CodingKeys: String, CodingKey {
        case sessionID = "id"
        case startedAt = "sa"
        case terminalAt = "ta"
        case terminalReason = "tr"
        case terminalDisposition = "td"
        case startRefusalReason = "sr"
        case settingsRoute = "rt"
        case noticeOwed = "no"
        case noticeDecision = "nd"
        case noticeDelivered = "dl"
        case notificationAuthorizationStatus = "na"
        case notificationAlertSetting = "ns"
        case wristAlertAssurance = "wa"
        case audioArmed = "aa"
        case audioSessionIsActive = "as"
        case locationArmed = "la"
        case segmentsProduced = "sp"
        case batteryLevelAtEnd = "bl"
        case batteryStateAtEnd = "bs"
        case lowPowerModeEnabledAtEnd = "lp"
        case thermalStateAtEnd = "th"
        case lastVerifiedAudioAt = "lv"
        case lastAudioCurrentTime = "ac"
        case zeroAudioCurrentTimeObservationCount = "zc"
        case locationAdvisory = "lo"
        case persistenceAdvisory = "pe"
    }

    var isComplete: Bool {
        self.terminalAt != nil || self.startRefusalReason != nil
    }
}

nonisolated struct WatchCaptureSessionHistoryCounter: Codable, Equatable, Sendable {
    let epoch: String
    let lifetimeSessionsStarted: Int
}

nonisolated enum WatchCaptureSessionHistoryReadResult: Equatable, Sendable {
    case available([WatchCaptureSessionHistoryEntry])
    case unreadable
}

@MainActor
final class WatchCaptureSessionHistoryStore {
    static let historyFileName = ".watch-capture-session-history.jsonl"
    static let counterFileName = ".watch-capture-session-counter.json"
    static let maximumEntryCount = 40
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    private let storage: WatchCaptureStorage
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(storage: WatchCaptureStorage) {
        self.storage = storage
        self.encoder = WatchRelayDiagnosticsEnvelope.makeEncoder()
        self.decoder = WatchRelayDiagnosticsEnvelope.makeDecoder()
    }

    func read(asOf: Date) -> WatchCaptureSessionHistoryReadResult {
        let parsed = self.readParsedEntries()
        guard parsed.fileExists else { return .available([]) }
        let entries = self.pruned(parsed.entries, asOf: asOf)
        if entries.count != parsed.entries.count {
            do {
                try self.write(entries: entries, unreadableLines: parsed.unreadableLines)
            } catch {
                return .unreadable
            }
        }
        guard !parsed.hadDamage || !entries.isEmpty else { return .unreadable }
        return .available(entries)
    }

    func entry(sessionID: String, asOf: Date) -> WatchCaptureSessionHistoryEntry? {
        guard case let .available(entries) = self.read(asOf: asOf) else { return nil }
        return entries.first { $0.sessionID == sessionID }
    }

    func upsert(_ entry: WatchCaptureSessionHistoryEntry, asOf: Date) throws {
        let parsed = self.readParsedEntries()
        var entriesByID = Dictionary(uniqueKeysWithValues: parsed.entries.map { ($0.sessionID, $0) })
        entriesByID[entry.sessionID] = entry
        let entries = self.pruned(Array(entriesByID.values), asOf: asOf)
            .sorted { $0.startedAt < $1.startedAt }
        try self.write(entries: entries, unreadableLines: parsed.unreadableLines)
    }

    func revertLifetimeCounterIncrement(_ incremented: WatchCaptureSessionHistoryCounter) throws {
        guard let current = self.readCounter(),
              current.epoch == incremented.epoch,
              current.lifetimeSessionsStarted == incremented.lifetimeSessionsStarted,
              current.lifetimeSessionsStarted > 0
        else { return }
        let reverted = WatchCaptureSessionHistoryCounter(
            epoch: current.epoch,
            lifetimeSessionsStarted: current.lifetimeSessionsStarted - 1
        )
        try self.storage.fileWriter.atomicReplaceFile(at: self.counterURL, with: self.encoder.encode(reverted))
    }

    private func write(entries: [WatchCaptureSessionHistoryEntry], unreadableLines: [Data]) throws {
        var data = Data()
        for entry in entries {
            data.append(try self.encoder.encode(entry))
            data.append(0x0A)
        }
        // Preserve malformed source lines for diagnosis; a damaged tail must never turn into a silent reset.
        for line in unreadableLines {
            data.append(line)
            data.append(0x0A)
        }
        try self.storage.fileWriter.atomicReplaceFile(at: self.historyURL, with: data)
    }

    func incrementLifetimeCounter() throws -> WatchCaptureSessionHistoryCounter? {
        let url = self.counterURL
        if self.storage.fileWriter.fileExists(at: url) {
            guard let current = try? self.decoder.decode(
                WatchCaptureSessionHistoryCounter.self,
                from: self.storage.fileWriter.readData(from: url)
            ) else {
                return nil
            }
            let updated = WatchCaptureSessionHistoryCounter(
                epoch: current.epoch,
                lifetimeSessionsStarted: current.lifetimeSessionsStarted + 1
            )
            try self.storage.fileWriter.atomicReplaceFile(at: url, with: self.encoder.encode(updated))
            return updated
        }
        let counter = WatchCaptureSessionHistoryCounter(epoch: UUID().uuidString, lifetimeSessionsStarted: 1)
        try self.storage.fileWriter.atomicReplaceFile(at: url, with: self.encoder.encode(counter))
        return counter
    }

    func readCounter() -> WatchCaptureSessionHistoryCounter? {
        guard self.storage.fileWriter.fileExists(at: self.counterURL) else { return nil }
        return try? self.decoder.decode(
            WatchCaptureSessionHistoryCounter.self,
            from: self.storage.fileWriter.readData(from: self.counterURL)
        )
    }

    private var historyURL: URL {
        self.storage.rootURL.appendingPathComponent(Self.historyFileName, isDirectory: false)
    }

    private var counterURL: URL {
        self.storage.rootURL.appendingPathComponent(Self.counterFileName, isDirectory: false)
    }

    private func readParsedEntries() -> (entries: [WatchCaptureSessionHistoryEntry], unreadableLines: [Data], hadDamage: Bool, fileExists: Bool) {
        guard self.storage.fileWriter.fileExists(at: self.historyURL) else {
            return ([], [], false, false)
        }
        guard let data = try? self.storage.fileWriter.readData(from: self.historyURL) else {
            return ([], [], true, true)
        }
        var newestByID: [String: WatchCaptureSessionHistoryEntry] = [:]
        var unreadableLines: [Data] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let lineData = Data(line)
            if let entry = try? self.decoder.decode(WatchCaptureSessionHistoryEntry.self, from: lineData) {
                newestByID[entry.sessionID] = entry
            } else {
                unreadableLines.append(lineData)
            }
        }
        return (Array(newestByID.values), unreadableLines, !unreadableLines.isEmpty, true)
    }

    private func pruned(_ entries: [WatchCaptureSessionHistoryEntry], asOf: Date) -> [WatchCaptureSessionHistoryEntry] {
        let cutoff = asOf.addingTimeInterval(-Self.retention)
        return entries
            .filter { $0.terminalAt ?? $0.startedAt >= cutoff }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(Self.maximumEntryCount)
            .map { $0 }
    }
}
