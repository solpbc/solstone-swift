// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

nonisolated struct SourceDeclaration: Codable, Equatable, Sendable {
    let source: String
    let state: String
    let detail: String?

    init?(_ source: Source, detail: String? = nil) {
        switch source.state {
        case .active: state = "on"
        case .paused: state = "paused"
        case .needsAttention: state = "needs_attention"
        default: return nil
        }
        self.source = source.kind == .screencast ? "screen" : source.id
        self.detail = detail
    }
}

nonisolated struct KnownSources: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let source: String
        let origin: String
        let detail: String?
        let state: String?
        let declared_at: String?
        let last_synced_at: String?

        func time(seen: String?) -> Date? {
            let stamps = origin == "observed" ? [last_synced_at] : [last_synced_at, declared_at, seen]
            return stamps.compactMap { value in
                guard let value else { return nil }
                return (try? Date(value, strategy: .iso8601)) ??
                    (try? Date(value, strategy: .iso8601.time(includingFractionalSeconds: true)))
            }.max()
        }
    }
    struct Device: Codable, Sendable {
        let cid: String
        let display_label: String
        let device_type: String?
        let device_last_seen_at: String?
        var sources: [Entry]

        var latest: Date? { sources.first?.time(seen: device_last_seen_at) }
    }

    let sources_rev: String
    let self_cid: String?
    let devices: [Device]

    func others(_ source: String) -> [Device] {
        guard source == "calendar" || source == "obsidian", let self_cid else { return [] }
        return devices.compactMap { device -> Device? in
            guard device.cid != self_cid else { return nil }
            var result = device
            result.sources = device.sources.filter {
                $0.source == source && ($0.origin == "observed" ||
                    ($0.origin == "declared" && ["on", "paused", "needs_attention"].contains($0.state)))
            }.sorted {
                let l = $0.time(seen: device.device_last_seen_at)
                let r = $1.time(seen: device.device_last_seen_at)
                if l != r { return (l ?? .distantPast) > (r ?? .distantPast) }
                return ($0.detail ?? "") < ($1.detail ?? "")
            }
            return result.sources.isEmpty ? nil : result
        }.sorted {
            if $0.latest != $1.latest { return ($0.latest ?? .distantPast) > ($1.latest ?? .distantPast) }
            if $0.display_label != $1.display_label { return $0.display_label < $1.display_label }
            return $0.cid < $1.cid
        }
    }
}

@MainActor
@Observable
final class SharedSources {
    nonisolated struct Identity: Codable, Equatable {
        let credential: String
        let owner: UUID
    }
    nonisolated struct Connection: Equatable {
        let identity: Identity
        let port: Int
        let epoch: UInt64
    }
    private struct Cache: Codable {
        let identity: Identity
        let fetched: Date
        let document: KnownSources
    }
    private struct Capability: Decodable {
        let capabilities: [String]?
        let sources_rev: String?
    }

    let client: AuthenticatedHomeClient
    private let credentials: PairingCredentialStore
    private let defaults: UserDefaults
    private let cacheKey = "pairedKnownSources"
    private let revokedKey = "revokedSourcePairing"
    private let log = Logger(subsystem: "app.solstone.swift", category: "shared-sources")
    private var cache: Cache?
    private var identity: Identity?
    private var revoked: Identity?
    private var connection: Connection?
    private var pairingGeneration: UInt64?
    private var listed = false
    private var discovery = false
    private var forceRead = false
    private var desired: [SourceDeclaration]?
    private var accepted: [SourceDeclaration]?
    private var refused: [SourceDeclaration]?
    private(set) var task: Task<Void, Never>?
    private var generation = 0
    @ObservationIgnored var admitted: () -> Bool = { false }

    init(credentials: PairingCredentialStore, defaults: UserDefaults = .standard, client: AuthenticatedHomeClient? = nil) {
        self.credentials = credentials
        self.defaults = defaults
        self.client = client ?? AuthenticatedHomeClient(pairingGeneration: { credentials.snapshot().pairingGeneration })
        cache = defaults.data(forKey: cacheKey).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
        revoked = defaults.data(forKey: revokedKey).flatMap { try? JSONDecoder().decode(Identity.self, from: $0) }
        if cache?.identity != currentIdentity { clearCache() }
        if revoked != nil && revoked != currentIdentity {
            revoked = nil
            defaults.removeObject(forKey: revokedKey)
        }
        credentials.registerOnCredentialInvalidation { [weak self] in self?.forget() }
        credentials.registerOnCredentialReplacement { [weak self] in self?.forget() }
        credentials.registerOnNewPairing { [weak self] in self?.forget() }
    }

    var currentIdentity: Identity? {
        let snapshot = credentials.snapshot()
        guard let credential = snapshot.pairingIdentity, let owner = snapshot.deviceOwnerID else { return nil }
        return Identity(credential: credential, owner: owner)
    }

    func others(_ source: String) -> [KnownSources.Device] {
        guard let identity, identity == cache?.identity, identity != revoked,
              identity == currentIdentity, admitted() else { return [] }
        return cache?.document.others(source) ?? []
    }

    func update(identity: Identity?, connection next: Connection?, declarations: [SourceDeclaration]) {
        if cache != nil && cache?.identity != identity { clearCache() }
        if self.identity != identity { refused = nil }
        if self.identity != identity || connection != next {
            stop()
            self.identity = identity
            connection = next
            pairingGeneration = credentials.snapshot().pairingGeneration
            discovery = next != nil
        }
        if next != nil && desired != declarations {
            refused = nil
            desired = declarations
        }
        start()
    }

    func refresh(detail: Bool) {
        guard connection != nil, detail || cache.map({ Date().timeIntervalSince($0.fetched) > 300 }) != false else { return }
        discovery = true
        forceRead = true
        start()
    }

    func revoke() {
        guard let identity = currentIdentity else { forget(); return }
        stop()
        revoked = identity
        defaults.set(try? JSONEncoder().encode(identity), forKey: revokedKey)
        clearCache()
    }

    func forget() {
        stop()
        identity = nil
        revoked = nil
        refused = nil
        desired = nil
        defaults.removeObject(forKey: revokedKey)
        clearCache()
    }

    private func stop() {
        generation += 1
        task?.cancel()
        task = nil
        connection = nil
        pairingGeneration = nil
        discovery = false
        forceRead = false
        listed = false
        accepted = nil
    }

    private func clearCache() {
        cache = nil
        defaults.removeObject(forKey: cacheKey)
    }

    private func current(_ link: Connection, _ gen: Int) -> Bool {
        generation == gen && connection == link && currentIdentity == link.identity &&
            revoked != link.identity && admitted() && !Task.isCancelled
    }

    private func start() {
        guard task == nil, let link = connection, current(link, generation),
              discovery || (listed && desired != accepted && desired != refused) else { return }
        let gen = generation
        task = Task {
            defer { if generation == gen { task = nil } }
            while current(link, gen) {
                do {
                    if discovery {
                        discovery = false
                        let force = forceRead
                        forceRead = false
                        let (data, code) = try await client.statusResponse(localPort: link.port)
                        guard current(link, gen), handle(code), code == 200 else { return }
                        let status = try JSONDecoder().decode(Capability.self, from: data)
                        listed = status.capabilities?.contains("shared_sources") == true
                        guard listed else { accepted = nil; clearCache(); return }
                        if force || cache == nil || cache?.document.sources_rev != status.sources_rev {
                            await readSnapshot(link, generation: gen)
                            guard current(link, gen) else { return }
                        }
                    }
                    guard listed, let payload = desired, payload != accepted, payload != refused else {
                        if discovery { continue }
                        return
                    }
                    // Once a PUT starts, a lost response leaves the journal's state unknown.
                    // A newer local state, including a return to the old value, still needs a PUT.
                    accepted = nil
                    let code: Int
                    do {
                        code = try await client.declareSources(localPort: link.port, body: JSONEncoder().encode(payload)) { start in
                            guard current(link, gen), let pairing = credentials.snapshot().pairing,
                                  let expected = pairingGeneration else { return false }
                            return credentials.migrationStore.withCurrentCredentialAdmission(ownerID: link.identity.owner, pairing: pairing) {
                                guard credentials.snapshot().pairingGeneration == expected else { return nil }
                                start()
                                return true
                            } == true
                        }
                    } catch {
                        if current(link, gen), desired != payload { continue }
                        return
                    }
                    guard current(link, gen), handle(code) else { return }
                    switch code {
                    case 204: accepted = payload
                    case 400:
                        log.error("Journal rejected this source declaration (400); waiting for a configuration change")
                        refused = payload
                    default:
                        if desired == payload { return }
                    }
                } catch {
                    return
                }
            }
        }
    }

    private func readSnapshot(_ link: Connection, generation: Int) async {
        do {
            let (data, code) = try await client.sourceRequest(localPort: link.port, path: "/app/network/api/sources")
            guard current(link, generation), handle(code), code == 200 else { return }
            let document = try JSONDecoder().decode(KnownSources.self, from: data)
            guard document.self_cid != nil else { clearCache(); return }
            let record = Cache(identity: link.identity, fetched: Date(), document: document)
            defaults.set(try JSONEncoder().encode(record), forKey: cacheKey)
            cache = record
        } catch {
            log.debug("Known sources unavailable; retaining last snapshot")
        }
    }

    private func handle(_ code: Int) -> Bool {
        switch code {
        case 403: revoke(); return false
        case 404: listed = false; accepted = nil; clearCache(); return false
        default: return true
        }
    }
}
