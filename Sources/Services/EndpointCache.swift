// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel

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

    private struct RefreshResponse: Decodable {
        let localEndpoints: [LocalEndpoint]

        enum CodingKeys: String, CodingKey {
            case localEndpoints = "local_endpoints"
        }
    }

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

    public init(fileURL: URL = EndpointCache.defaultFileURL, ttl: TimeInterval = 24 * 60 * 60, session: URLSession = .shared) {
        self.fileURL = fileURL
        self.ttl = ttl
        self.session = session
    }

    public func bootstrap(from pairing: StoredPairing) async {
        let now = Date()
        entries = pairing.localEndpoints.map {
            Entry(host: $0.host, port: $0.port, scope: $0.scope, lastSeen: now)
        }
        loaded = true
        try? persist()
    }

    public func refresh(viaLoopbackPort port: Int) async throws {
        try loadIfNeeded()
        let url = URL(string: "http://127.0.0.1:\(port)/app/network/local-endpoints")!
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(RefreshResponse.self, from: data)
        merge(decoded.localEndpoints, seenAt: Date())
        try persist()
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
        entries = []
        loaded = true
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func merge(_ endpoints: [LocalEndpoint], seenAt: Date) {
        var merged = Dictionary(uniqueKeysWithValues: entries.map { (key(for: $0.localEndpoint), $0) })
        for endpoint in endpoints {
            merged[key(for: endpoint)] = Entry(
                host: endpoint.host,
                port: endpoint.port,
                scope: endpoint.scope,
                lastSeen: seenAt
            )
        }
        entries = Array(merged.values)
        pruneExpired()
    }

    private func pruneExpired() {
        let cutoff = Date().addingTimeInterval(-ttl)
        entries.removeAll { $0.lastSeen < cutoff }
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
