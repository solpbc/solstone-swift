// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

typealias OmiHeardTallyPayload = [String: OmiHeardDayTally]

nonisolated struct OmiHeardDayTally: Codable, Equatable, Sendable {
    var totalSeconds: TimeInterval
    var seenIdentities: Set<String>
}

@MainActor
@Observable
final class OmiHeardTally {
    nonisolated static let retainedDayCount = 7

    nonisolated static var defaultFileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("solstone", isDirectory: true)
            .appendingPathComponent("omi-heard-tally.json")
    }

    private(set) var payload: OmiHeardTallyPayload

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let log = Logger(subsystem: "app.solstone.swift", category: "omi-heard-tally")

    init(fileURL: URL = OmiHeardTally.defaultFileURL) {
        self.fileURL = fileURL
        let loaded = (try? Self.loadPayload(from: fileURL)) ?? [:]
        var pruned = loaded
        Self.prune(&pruned)
        self.payload = pruned
        if pruned != loaded {
            self.persist()
        }
    }

    func record(day: String, durationS: TimeInterval, identity: String) {
        var dayTally = self.payload[day] ?? OmiHeardDayTally(totalSeconds: 0, seenIdentities: [])
        guard !dayTally.seenIdentities.contains(identity) else { return }

        dayTally.totalSeconds += durationS
        dayTally.seenIdentities.insert(identity)
        self.payload[day] = dayTally
        Self.prune(&self.payload)
        self.persist()
    }

    func tally(for day: String) -> OmiHeardDayTally? {
        self.payload[day]
    }

    func persist() {
        do {
            try FileManager.default.createDirectory(
                at: self.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(self.payload)
            try data.write(to: self.fileURL, options: [.atomic])
        } catch {
            self.log.error("omi heard tally write failed: \(String(describing: error), privacy: .public)")
        }
    }
}

private extension OmiHeardTally {
    static func loadPayload(from fileURL: URL) throws -> OmiHeardTallyPayload {
        try JSONDecoder().decode(OmiHeardTallyPayload.self, from: Data(contentsOf: fileURL))
    }

    static func prune(_ payload: inout OmiHeardTallyPayload) {
        let keysToDrop = payload.keys.sorted().dropLast(Self.retainedDayCount)
        for key in keysToDrop {
            payload.removeValue(forKey: key)
        }
    }
}
