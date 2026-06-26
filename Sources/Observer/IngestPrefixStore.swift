// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

nonisolated private let ingestPrefixStoreLog = Logger(subsystem: "app.solstone.swift", category: "ingest-prefix-store")

nonisolated private final class IngestPrefixStoreDefaultsBox: @unchecked Sendable {
    let defaults: UserDefaults?

    nonisolated init(defaults: UserDefaults?) {
        self.defaults = defaults
    }
}

nonisolated struct IngestPrefixStore: Sendable {
    enum Stream {
        case observer
        case omi
        case watch
    }

    private enum Key {
        static let observer = "ingestPrefix.observer"
        static let omi = "ingestPrefix.omi"
        static let watch = "ingestPrefix.watch"
    }

    private let defaultsBox: IngestPrefixStoreDefaultsBox

    nonisolated init(defaults: UserDefaults? = UserDefaults(suiteName: AppGroupContainer.identifier)) {
        self.defaultsBox = IngestPrefixStoreDefaultsBox(defaults: defaults)
    }

    nonisolated func load(_ stream: Stream) -> String? {
        self.defaultsBox.defaults?.string(forKey: Self.key(for: stream))
    }

    nonisolated func save(_ prefix: String, for stream: Stream) {
        guard let defaults = self.defaultsBox.defaults else {
            ingestPrefixStoreLog.error("ingest prefix save skipped: app group defaults unavailable")
            return
        }

        defaults.set(prefix, forKey: Self.key(for: stream))
    }

    nonisolated func clear(_ stream: Stream) {
        guard let defaults = self.defaultsBox.defaults else {
            ingestPrefixStoreLog.error("ingest prefix clear skipped: app group defaults unavailable")
            return
        }

        defaults.removeObject(forKey: Self.key(for: stream))
    }

    private static func key(for stream: Stream) -> String {
        switch stream {
        case .observer:
            Key.observer
        case .omi:
            Key.omi
        case .watch:
            Key.watch
        }
    }
}
