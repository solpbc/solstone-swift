// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

nonisolated struct WatchJournalVersionPayload: Codable {
    static let contextKey = "journalVersion"
    static let requestKey = "journalVersionRequest"
    let revision: Int
    let identity: String?
    let version: String?
    let current: Bool
    let nonce: String?
}

/// Context replays and disk restores carry a value, but only a response to this
/// reachability session can establish freshness on the watch.
@MainActor
@Observable
final class WatchJournalVersionState {
    private(set) var version: String?
    private(set) var isCurrent = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var nonce: String?
    private static let storageKey = "receivedJournalVersion"

    var displayValue: String {
        guard let version else { return "unknown" }
        return isCurrent ? version : "\(version) (last known)"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey) {
            receive(data, live: false)
        }
    }

    func disconnected() {
        nonce = nil
        isCurrent = false
    }

    func beginReachableSession() -> String {
        disconnected()
        let nonce = UUID().uuidString
        self.nonce = nonce
        return nonce
    }

    func receive(_ data: Data, live: Bool) {
        guard let payload = try? JSONDecoder().decode(WatchJournalVersionPayload.self, from: data),
              payload.revision > 0, payload.revision >= revision,
              payload.version == nil || sanitizedJournalVersion(payload.version!) != nil else { return }
        if payload.revision > revision {
            revision = payload.revision
            version = payload.identity == nil ? nil : payload.version
            isCurrent = false
            defaults.set(data, forKey: Self.storageKey)
        }
        if live, let nonce, payload.nonce == nonce {
            isCurrent = payload.current && version != nil
        }
    }
}

nonisolated func sanitizedJournalVersion(_ value: String) -> String? {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !value.unicodeScalars.contains(where: {
              $0.value <= 0x1F || (0x7F...0x9F).contains($0.value) || CharacterSet.newlines.contains($0)
          }) else { return nil }
    return value
}
