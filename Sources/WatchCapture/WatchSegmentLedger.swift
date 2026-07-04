// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

private let watchSegmentLedgerLog = Logger(subsystem: "app.solstone.swift", category: "watch-ledger")

nonisolated struct WatchSegmentLedgerStore: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var receivedAt: Date?
        var handedAt: Date?
        var droppedAt: Date?

        init(receivedAt: Date? = nil, handedAt: Date? = nil, droppedAt: Date? = nil) {
            self.receivedAt = receivedAt
            self.handedAt = handedAt
            self.droppedAt = droppedAt
        }

        var isTerminal: Bool {
            self.handedAt != nil || self.droppedAt != nil
        }

        var terminalAt: Date? {
            switch (self.handedAt, self.droppedAt) {
            case (.some(let handedAt), .some(let droppedAt)):
                max(handedAt, droppedAt)
            case (.some(let handedAt), .none):
                handedAt
            case (.none, .some(let droppedAt)):
                droppedAt
            case (.none, .none):
                nil
            }
        }
    }

    var entries: [String: Entry]
    var lifetimeReceived: Int
    var lifetimeHanded: Int

    static var empty: Self {
        Self(entries: [:], lifetimeReceived: 0, lifetimeHanded: 0)
    }
}

nonisolated private enum WatchSegmentLedgerError: Error, Sendable {
    case fileURLUnavailable
}

@MainActor
@Observable
final class WatchSegmentLedger {
    private static let ledgerFilename = "ledger.json"
    private static let pruneInterval: TimeInterval = 7 * 24 * 60 * 60

    private let fileURL: URL?
    private let clock: @MainActor @Sendable () -> Date
    private var store: WatchSegmentLedgerStore
    private(set) var lastLedgerError: String?

    init(
        fileURL: URL? = nil,
        clock: @escaping @MainActor @Sendable () -> Date = Date.init
    ) {
        let resolvedFileURL: URL?
        let initialError: String?
        if let fileURL {
            resolvedFileURL = fileURL
            initialError = nil
        } else {
            do {
                resolvedFileURL = try AppGroupContainer.rootURL()
                    .appendingPathComponent(WatchRelayReceiver.rootDirectoryName, isDirectory: true)
                    .appendingPathComponent(Self.ledgerFilename, isDirectory: false)
                initialError = nil
            } catch {
                resolvedFileURL = nil
                initialError = "watch ledger unavailable: \(String(describing: error))"
            }
        }

        self.fileURL = resolvedFileURL
        self.clock = clock
        self.store = .empty
        self.lastLedgerError = nil

        if let initialError {
            self.setLedgerError(initialError)
        } else {
            self.load()
        }
    }

    var lifetimeReceived: Int {
        self.store.lifetimeReceived
    }

    var lifetimeHanded: Int {
        self.store.lifetimeHanded
    }

    var nonTerminalCount: Int {
        self.store.entries.values.filter { entry in
            entry.receivedAt != nil && !entry.isTerminal
        }.count
    }

    var oldestNonTerminalReceivedAt: Date? {
        var oldest: Date?
        for entry in self.store.entries.values where entry.receivedAt != nil && !entry.isTerminal {
            guard let receivedAt = entry.receivedAt else {
                continue
            }
            if let current = oldest {
                if receivedAt < current {
                    oldest = receivedAt
                }
            } else {
                oldest = receivedAt
            }
        }
        return oldest
    }

    var lastHandedAt: Date? {
        var latest: Date?
        for entry in self.store.entries.values {
            guard let handedAt = entry.handedAt else { continue }
            if latest.map({ handedAt > $0 }) ?? true {
                latest = handedAt
            }
        }
        return latest
    }

    var committedOrTerminalSegmentIDs: [UUID] {
        // load() does not prune, so launch sweep size is bounded in practice by
        // persisted mutations and the 7-day terminal prune interval, not by a read-only load.
        self.store.entries.compactMap { key, entry in
            guard entry.isTerminal || entry.receivedAt != nil else { return nil }
            return UUID(uuidString: key)
        }
        .sorted { $0.uuidString < $1.uuidString }
    }

    func recordReceived(id: UUID) {
        let key = id.uuidString
        var entry = self.store.entries[key] ?? WatchSegmentLedgerStore.Entry()
        if self.store.entries[key] == nil || (entry.receivedAt == nil && !entry.isTerminal) {
            entry.receivedAt = self.clock()
            self.store.lifetimeReceived += 1
        }
        self.store.entries[key] = entry
        self.pruneAndPersist()
    }

    func recordHanded(id: UUID) {
        let key = id.uuidString
        let now = self.clock()
        var entry = self.store.entries[key] ?? WatchSegmentLedgerStore.Entry()

        if entry.droppedAt != nil && entry.handedAt == nil {
            self.logConflict("watch ledger hand-after-drop id=\(id.uuidString)")
            self.store.entries[key] = entry
            self.pruneAndPersist()
            return
        }

        if entry.handedAt == nil {
            if entry.receivedAt == nil {
                entry.receivedAt = now
                self.store.lifetimeReceived += 1
            }
            entry.handedAt = now
            self.store.lifetimeHanded += 1
        }

        self.store.entries[key] = entry
        self.pruneAndPersist()
    }

    func recordDropped(id: UUID) {
        let key = id.uuidString
        let now = self.clock()
        var entry = self.store.entries[key] ?? WatchSegmentLedgerStore.Entry()
        let wasUnknown = self.store.entries[key] == nil

        if entry.handedAt != nil {
            self.logConflict("watch ledger drop-after-hand id=\(id.uuidString)")
            self.store.entries[key] = entry
            self.pruneAndPersist()
            return
        }

        if entry.droppedAt == nil {
            entry.droppedAt = now
            if wasUnknown {
                self.store.lifetimeReceived += 1
            }
        }

        self.store.entries[key] = entry
        self.pruneAndPersist()
    }

    func isTerminal(id: UUID) -> Bool {
        self.store.entries[id.uuidString]?.isTerminal == true
    }
}

private extension WatchSegmentLedger {
    func load() {
        guard let fileURL else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            self.store = try decoder.decode(WatchSegmentLedgerStore.self, from: data)
        } catch {
            self.store = .empty
            self.setLedgerError("watch ledger load failed: \(String(describing: error))")
        }
    }

    func pruneAndPersist() {
        self.pruneTerminalEntries()
        do {
            try self.persist()
            self.lastLedgerError = nil
        } catch {
            self.setLedgerError("watch ledger persist failed: \(String(describing: error))")
        }
    }

    func pruneTerminalEntries() {
        let cutoff = self.clock().addingTimeInterval(-Self.pruneInterval)
        self.store.entries = self.store.entries.filter { _, entry in
            guard let terminalAt = entry.terminalAt else { return true }
            return terminalAt >= cutoff
        }
    }

    func persist() throws {
        guard let fileURL else {
            throw WatchSegmentLedgerError.fileURLUnavailable
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self.store)
        try data.write(to: fileURL, options: [.atomic])
    }

    func setLedgerError(_ message: String) {
        self.lastLedgerError = message
        watchSegmentLedgerLog.error("\(message, privacy: .public)")
    }

    func logConflict(_ message: String) {
        watchSegmentLedgerLog.error("\(message, privacy: .public)")
    }
}
