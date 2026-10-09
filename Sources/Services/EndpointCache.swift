// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel
import os

nonisolated private let log = Logger(subsystem: "app.solstone.swift", category: "endpoint-cache")

public actor EndpointCache {
    private struct Entry: Codable, Sendable, Equatable {
        let host: String
        let port: Int
        let scope: String
        var lastSeen: Date

        var localEndpoint: LocalEndpoint {
            LocalEndpoint(host: host, port: port, scope: scope)
        }

        var transportEndpoint: TransportEndpoint {
            .lan(host: host, port: port, scope: scope)
        }
    }

    /// The journal's `/app/network/local-endpoints` body: `{"v":2,"endpoints":[{ip,port,scope}],...}`.
    /// From `v` 2 the list carries the journal's configured address, so it can replace the saved set;
    /// an older journal's list leaves that address out and is not used.
    private struct RefreshResponse: Decodable {
        let v: Int?
        let endpoints: [LocalEndpoint]
    }

    /// The app's one cache. The pairing, the tunnel and the pair flow all read and write the same
    /// file; separate instances each kept their own copy in memory, so forgetting a journal
    /// wiped one copy while another kept dialing, and re-saving, the old journal's addresses.
    public static let shared = EndpointCache()

    public static var defaultFileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("solstone", isDirectory: true)
            .appendingPathComponent("endpoints.json")
    }

    private let fileURL: URL
    private let ttl: TimeInterval
    private let session: URLSession
    private var entries: [Entry] = []
    private var loaded = false
    /// Bumped whenever the cache is reset for a pairing (bootstrap or wipe). A refresh awaits the
    /// network inside the actor, so another call can run meanwhile; a refresh that started under
    /// an older generation belongs to a journal this device may no longer be paired with.
    private var generation = 0

    public init(fileURL: URL = EndpointCache.defaultFileURL, ttl: TimeInterval = 24 * 60 * 60, session: URLSession = .shared) {
        self.fileURL = fileURL
        self.ttl = ttl
        self.session = session
    }

    public func bootstrap(from pairing: StoredPairing) async {
        generation += 1
        let now = Date()
        entries = pairing.localEndpoints.map {
            Entry(host: $0.host, port: $0.port, scope: $0.scope, lastSeen: now)
        }
        loaded = true
        try? persist()
    }

    /// Reads the journal's current direct addresses over the tunnel. The caller saves them on the
    /// pairing and re-bootstraps this cache from it; nil when the pairing changed meanwhile or the
    /// journal is too old to list its configured address.
    public func refresh(viaLoopbackPort port: Int) async throws -> [LocalEndpoint]? {
        try loadIfNeeded()
        let startedGeneration = generation
        let url = URL(string: "http://127.0.0.1:\(port)/app/network/local-endpoints")!
        var request = URLRequest(url: url)
        request.attachLoopbackCapability()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(RefreshResponse.self, from: data)
        guard generation == startedGeneration else {
            log.info("dropped a LAN endpoint refresh that started before the pairing changed")
            return nil
        }
        guard (decoded.v ?? 0) >= 2 else {
            log.info("journal address list predates its configured address; keeping the saved addresses")
            return nil
        }
        return decoded.endpoints
    }

    public func endpoints() async -> [TransportEndpoint] {
        try? loadIfNeeded()
        pruneExpired()
        try? persist()
        return entries
            .sorted { $0.lastSeen > $1.lastSeen }
            .map(\.transportEndpoint)
    }

    public func wipe() async {
        generation += 1
        entries = []
        loaded = true
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func pruneExpired() {
        let cutoff = Date().addingTimeInterval(-ttl)
        entries.removeAll { $0.lastSeen < cutoff }
    }

    /// Evicts the cached entry for this identity immediately, independent of the 24h TTL in
    /// pruneExpired(). Called from TunnelManager when a direct candidate's TLS handshake or
    /// connection attempt fails, since a failed address is stronger evidence of staleness than
    /// age alone. Persists immediately, matching merge()'s prune-then-persist pattern. Callers
    /// that trigger this from an attempt-failure signal do so via a fire-and-forget spawned Task
    /// (see TunnelManager.handleAttemptEvent), so removal is not synchronous with the failure
    /// event itself — it is guaranteed to have landed before that Task's continuation runs, but
    /// a concurrent candidateList() read racing the same failure may still observe the stale
    /// entry once.
    public func evict(host: String, port: Int, scope: String) async {
        try? loadIfNeeded()
        let targetKey = key(for: LocalEndpoint(host: host, port: port, scope: scope))
        let hadMatch = entries.contains { key(for: $0.localEndpoint) == targetKey }
        guard hadMatch else { return }
        entries.removeAll { key(for: $0.localEndpoint) == targetKey }
        pruneExpired()
        try? persist()
        log.info("evicted cached LAN endpoint after direct connection failure")
    }

    private func loadIfNeeded() throws {
        guard !loaded else {
            return
        }
        defer { loaded = true }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            entries = []
            return
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = try decoder.decode([Entry].self, from: data)
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        try data.write(to: fileURL, options: [.atomic])
    }

    private func key(for endpoint: LocalEndpoint) -> String {
        "\(endpoint.host)|\(endpoint.port)|\(endpoint.scope)"
    }
}
