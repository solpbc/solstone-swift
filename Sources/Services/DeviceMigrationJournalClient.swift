// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private nonisolated let migrationJournalLog = Logger(subsystem: "app.solstone.swift", category: "device-migration")

nonisolated enum DeviceMigrationJournalResult<Value: Sendable>: Sendable {
    case success(Value)
    case unavailable
    case invalidResponse
    case refused
}

nonisolated protocol DeviceMigrationJournalAccess: Sendable {
    func fetchState(localPort: Int) async -> DeviceMigrationJournalResult<DeviceMigrationServerSnapshot>
    func putDecision(localPort: Int, exactBody: Data) async -> DeviceMigrationJournalResult<DeviceMigrationDecisionResponse>
    func fetchClients(localPort: Int) async -> DeviceMigrationJournalResult<ReplacementClientList>
}

nonisolated struct DeviceMigrationJournalClient: DeviceMigrationJournalAccess {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchState(localPort: Int) async -> DeviceMigrationJournalResult<DeviceMigrationServerSnapshot> {
        await self.fetch(localPort: localPort, path: "/app/network/api/clients/self/migration", method: "GET", body: nil)
    }

    func putDecision(localPort: Int, exactBody: Data) async -> DeviceMigrationJournalResult<DeviceMigrationDecisionResponse> {
        await self.fetch(localPort: localPort, path: "/app/network/api/clients/self/migration", method: "PUT", body: exactBody)
    }

    func fetchClients(localPort: Int) async -> DeviceMigrationJournalResult<ReplacementClientList> {
        await self.fetch(localPort: localPort, path: "/app/network/api/clients", method: "GET", body: nil)
    }

    nonisolated static func validCID(_ cid: String) -> Bool {
        guard cid.hasPrefix("sha256:") else { return false }
        let hex = cid.dropFirst("sha256:".count)
        return hex.count == 64 && hex.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    private func fetch<Value: Decodable & Sendable>(
        localPort: Int,
        path: String,
        method: String,
        body: Data?
    ) async -> DeviceMigrationJournalResult<Value> {
        guard let url = Self.url(localPort: localPort, path: path) else { return .invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = method
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.attachLoopbackCapability()
        do {
            let (data, response) = try await self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unavailable
            }
            guard http.statusCode == 200 else {
                // These two pinned decision errors occur after the journal verifies
                // current authorization and before preparing any decision. Other
                // 4xx responses can mean revoked access or an already-applied replay.
                if method == "PUT", http.statusCode == 409,
                   let refusal = try? JSONDecoder().decode(AuthorizedRefusal.self, from: data),
                   refusal.error == refusal.reasonCode, refusal.detail == refusal.reasonCode,
                   ["migration_proof_missing", "migration_self_replacement"].contains(refusal.reasonCode) {
                    return .refused
                }
                return .unavailable
            }
            guard !data.isEmpty,
                  let value = try? JSONDecoder().decode(Value.self, from: data) else {
                return .invalidResponse
            }
            return .success(value)
        } catch {
            migrationJournalLog.debug("migration API request unavailable")
            return .unavailable
        }
    }

    private struct AuthorizedRefusal: Decodable {
        let error: String
        let reasonCode: String
        let detail: String

        enum CodingKeys: String, CodingKey {
            case error, detail
            case reasonCode = "reason_code"
        }
    }

    private nonisolated static func url(localPort: Int, path: String) -> URL? {
        guard (1...65535).contains(localPort) else { return nil }
        return URL(string: "http://127.0.0.1:\(localPort)\(path)")
    }
}
