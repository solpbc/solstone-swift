// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

nonisolated private let watchRelayRecoveryRouteLog = Logger(
    subsystem: "app.solstone.swift",
    category: "watch-relay-recovery"
)

nonisolated struct WatchRelayRecoveryRouteRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let eraID: UUID
    let successfulTransferGeneration: Int
    let durableACKGeneration: Int

    init(
        version: Int = Self.currentVersion,
        eraID: UUID = UUID(),
        successfulTransferGeneration: Int = 0,
        durableACKGeneration: Int = 0
    ) {
        self.version = version
        self.eraID = eraID
        self.successfulTransferGeneration = successfulTransferGeneration
        self.durableACKGeneration = durableACKGeneration
    }
}

@MainActor
final class WatchRelayRecoveryRouteStore {
    static let filename = ".relay-recovery-route.json"

    private enum Event {
        case successfulTransfer
        case durableACK
    }

    private enum ReadResult {
        case missing
        case valid(WatchRelayRecoveryRouteRecord)
        case invalid
        case unavailable(any Error)
    }

    private let storage: WatchCaptureStorage
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(storage: WatchCaptureStorage) {
        self.storage = storage
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()
    }

    func recordURL() -> URL {
        self.storage.rootURL.appendingPathComponent(Self.filename, isDirectory: false)
    }

    @discardableResult
    func establishRecord() -> WatchRelayRecoveryRouteRecord? {
        switch self.readResult() {
        case let .valid(record):
            return record
        case .missing, .invalid:
            return self.persistNewRecord(event: nil)
        case let .unavailable(error):
            self.logFailure("read", error: error)
            return nil
        }
    }

    @discardableResult
    func recordSuccessfulTransfer() -> Bool {
        self.record(.successfulTransfer)
    }

    @discardableResult
    func recordDurableACK() -> Bool {
        self.record(.durableACK)
    }
}

private extension WatchRelayRecoveryRouteStore {
    private func record(_ event: Event) -> Bool {
        let next: WatchRelayRecoveryRouteRecord
        switch self.readResult() {
        case let .valid(record):
            guard let incremented = self.incremented(record, event: event) else {
                return self.persistNewRecord(event: event) != nil
            }
            next = incremented
        case .missing, .invalid:
            return self.persistNewRecord(event: event) != nil
        case let .unavailable(error):
            self.logFailure("read", error: error)
            return false
        }

        do {
            try self.write(next)
            return true
        } catch {
            self.logFailure("write", error: error)
            return false
        }
    }

    private func persistNewRecord(event: Event?) -> WatchRelayRecoveryRouteRecord? {
        let generations: (successfulTransfer: Int, durableACK: Int)
        switch event {
        case .successfulTransfer:
            generations = (1, 0)
        case .durableACK:
            generations = (0, 1)
        case nil:
            generations = (0, 0)
        }
        let record = WatchRelayRecoveryRouteRecord(
            successfulTransferGeneration: generations.successfulTransfer,
            durableACKGeneration: generations.durableACK
        )
        do {
            try self.write(record)
            return record
        } catch {
            self.logFailure("write", error: error)
            return nil
        }
    }

    private func incremented(
        _ record: WatchRelayRecoveryRouteRecord,
        event: Event
    ) -> WatchRelayRecoveryRouteRecord? {
        switch event {
        case .successfulTransfer:
            let (next, overflow) = record.successfulTransferGeneration.addingReportingOverflow(1)
            guard !overflow, next < Int.max else { return nil }
            return WatchRelayRecoveryRouteRecord(
                eraID: record.eraID,
                successfulTransferGeneration: next,
                durableACKGeneration: record.durableACKGeneration
            )
        case .durableACK:
            let (next, overflow) = record.durableACKGeneration.addingReportingOverflow(1)
            guard !overflow, next < Int.max else { return nil }
            return WatchRelayRecoveryRouteRecord(
                eraID: record.eraID,
                successfulTransferGeneration: record.successfulTransferGeneration,
                durableACKGeneration: next
            )
        }
    }

    private func readResult() -> ReadResult {
        let url = self.recordURL()
        guard self.storage.fileWriter.fileExists(at: url) else {
            return .missing
        }
        let data: Data
        do {
            data = try self.storage.fileWriter.readData(from: url)
        } catch {
            return .unavailable(error)
        }
        do {
            let record = try self.decoder.decode(WatchRelayRecoveryRouteRecord.self, from: data)
            guard record.version == WatchRelayRecoveryRouteRecord.currentVersion,
                  record.successfulTransferGeneration >= 0,
                  record.successfulTransferGeneration < Int.max,
                  record.durableACKGeneration >= 0,
                  record.durableACKGeneration < Int.max
            else {
                return .invalid
            }
            return .valid(record)
        } catch {
            return .invalid
        }
    }

    func write(_ record: WatchRelayRecoveryRouteRecord) throws {
        let data = try self.encoder.encode(record)
        try self.storage.fileWriter.writeData(data, to: self.recordURL(), options: .atomic)
    }

    func logFailure(_ operation: String, error: any Error) {
        watchRelayRecoveryRouteLog.error(
            "watch relay recovery route \(operation, privacy: .public) failed: \(String(describing: error), privacy: .private)"
        )
    }
}
