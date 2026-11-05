// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import WebKit

/// What keeps the in-app journal on one origin for a pairing: the loopback port
/// its proxy last bound, and the web data store its pages live in.
///
/// The page's origin is `http://127.0.0.1:<port>`, so a proxy rebuilt on the
/// same port keeps the page's HTTP cache and storage across reconnects,
/// background and relaunch. The data store is the pairing's own, so a later
/// pairing never inherits pages or storage through a reused port.
nonisolated final class JournalWebOriginStore: @unchecked Sendable {
    struct Record: Codable, Equatable {
        let instanceID: String
        let dataStoreID: UUID
        var port: UInt16?
    }

    static let shared = JournalWebOriginStore(defaults: .standard)

    private static let recordKey = "journalWebOrigin.record"
    private static let pendingRemovalKey = "journalWebOrigin.pendingRemoval"
    private static let defaultStoreSweptKey = "journalWebOrigin.defaultStoreSwept"

    // why: read by the transport off the main actor and by the web view on it; the lock makes each read-modify-write one step.
    private let lock = NSLock()
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The port the last proxy for this journal bound, if any.
    func preferredPort(for instanceID: String) -> UInt16? {
        self.lock.withLock {
            guard let record = self.load(), record.instanceID == instanceID else { return nil }
            return record.port
        }
    }

    /// Remembers the port a proxy for this journal bound.
    func recordPort(_ port: UInt16, for instanceID: String) {
        self.lock.withLock {
            var record = self.recordForJournal(instanceID).record
            record.port = port
            self.save(record)
        }
    }

    /// The identifier of this journal's web data store. A different journal than
    /// the one remembered starts a new record; the replaced store's identifier is
    /// returned so the caller can remove it.
    func dataStoreID(for instanceID: String) -> (id: UUID, replaced: UUID?) {
        self.lock.withLock {
            let (record, replaced) = self.recordForJournal(instanceID)
            self.save(record)
            return (record.dataStoreID, replaced)
        }
    }

    /// Forgets the pairing's port and store, and queues the store for clearing.
    func forget() {
        self.lock.withLock {
            if let record = self.load() {
                self.addPending(record.dataStoreID)
            }
            self.defaults.removeObject(forKey: Self.recordKey)
        }
    }

    /// Stores queued for clearing; an entry stays until its clear completes, so
    /// a clear cut short by the app exiting is retried.
    func pendingRemovals() -> [UUID] {
        self.lock.withLock { self.loadPending() }
    }

    func markRemoved(_ id: UUID) {
        self.lock.withLock {
            self.defaults.set(self.loadPending().filter { $0 != id }.map(\.uuidString), forKey: Self.pendingRemovalKey)
        }
    }

    private func addPending(_ id: UUID) {
        let pending = self.loadPending()
        guard !pending.contains(id) else { return }
        self.defaults.set((pending + [id]).map(\.uuidString), forKey: Self.pendingRemovalKey)
    }

    private func loadPending() -> [UUID] {
        (self.defaults.stringArray(forKey: Self.pendingRemovalKey) ?? []).compactMap(UUID.init(uuidString:))
    }

    /// Whether the default store's loopback records still need their one-time
    /// removal; marks them as handled.
    func takeDefaultStoreSweep() -> Bool {
        self.lock.withLock {
            guard !self.defaults.bool(forKey: Self.defaultStoreSweptKey) else { return false }
            self.defaults.set(true, forKey: Self.defaultStoreSweptKey)
            return true
        }
    }

    private func recordForJournal(_ instanceID: String) -> (record: Record, replaced: UUID?) {
        if let record = self.load() {
            if record.instanceID == instanceID { return (record, nil) }
            self.addPending(record.dataStoreID)
            return (Record(instanceID: instanceID, dataStoreID: UUID(), port: nil), record.dataStoreID)
        }
        return (Record(instanceID: instanceID, dataStoreID: UUID(), port: nil), nil)
    }

    private func load() -> Record? {
        self.defaults.data(forKey: Self.recordKey).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
    }

    private func save(_ record: Record) {
        if let data = try? JSONEncoder().encode(record) {
            self.defaults.set(data, forKey: Self.recordKey)
        }
    }
}

/// Web data store lifecycle for the in-app journal.
@MainActor
enum JournalWebDataStore {
    /// The data store for the paired journal's pages. Clears stores left by
    /// earlier pairings, and once, the loopback records earlier versions kept in
    /// the shared default store (one per connection's port, never read again).
    static func store(for instanceID: String, origins: JournalWebOriginStore = .shared) -> WKWebsiteDataStore {
        let id = origins.dataStoreID(for: instanceID).id
        self.clearPending(origins: origins)
        if origins.takeDefaultStoreSweep() {
            let defaultStore = WKWebsiteDataStore.default()
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            defaultStore.fetchDataRecords(ofTypes: types) { records in
                let loopback = records.filter { $0.displayName == "127.0.0.1" || $0.displayName == "localhost" }
                guard !loopback.isEmpty else { return }
                defaultStore.removeData(ofTypes: types, for: loopback) {}
            }
        }
        return WKWebsiteDataStore(forIdentifier: id)
    }

    /// Unpairing forgets the pairing's port and clears its data store.
    static func forgetPairing(origins: JournalWebOriginStore = .shared) {
        origins.forget()
        Task { @MainActor in
            // The journal pane is dismantled on the next layout pass after the
            // pairing clears; clear once it can no longer write to the store.
            try? await Task.sleep(for: .seconds(1))
            self.clearPending(origins: origins)
        }
    }

    /// Empties each queued store through a store object. Removing a store by
    /// identifier crashed inside WebKit when the app had not shown a web view
    /// yet, so a cleared store stays behind as an empty directory instead.
    private static func clearPending(origins: JournalWebOriginStore) {
        for id in origins.pendingRemovals() {
            let store = WKWebsiteDataStore(forIdentifier: id)
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                origins.markRemoved(id)
                journalWebLog.notice("journal web data store cleared")
            }
        }
    }
}
