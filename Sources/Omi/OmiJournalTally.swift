// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

typealias OmiJournalTallyPayload = [String: OmiJournalDayTally]

nonisolated struct OmiJournalDayTally: Codable, Equatable, Sendable {
    var segmentCount: Int
    var totalSeconds: TimeInterval
    var seenIdentities: Set<String>

    init(
        segmentCount: Int = 0,
        totalSeconds: TimeInterval = 0,
        seenIdentities: Set<String> = []
    ) {
        self.segmentCount = segmentCount
        self.totalSeconds = totalSeconds
        self.seenIdentities = seenIdentities
    }
}

@MainActor
@Observable
final class OmiJournalTally {
    nonisolated static let retainedDayCount = 7

    nonisolated static var defaultFileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("solstone", isDirectory: true)
            .appendingPathComponent("omi-journal-tally.json")
    }

    private(set) var payload: OmiJournalTallyPayload

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let log = Logger(subsystem: "app.solstone.swift", category: "omi-journal-tally")

    init(fileURL: URL = OmiJournalTally.defaultFileURL) {
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
        var dayTally = self.payload[day] ?? OmiJournalDayTally()
        guard !dayTally.seenIdentities.contains(identity) else { return }

        dayTally.segmentCount += 1
        dayTally.totalSeconds += durationS
        dayTally.seenIdentities.insert(identity)
        self.payload[day] = dayTally
        Self.prune(&self.payload)
        self.persist()
    }

    func tally(for day: String) -> OmiJournalDayTally? {
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
            self.log.error("omi journal tally write failed: \(String(describing: error), privacy: .public)")
        }
    }
}

private extension OmiJournalTally {
    static func loadPayload(from fileURL: URL) throws -> OmiJournalTallyPayload {
        try JSONDecoder().decode(OmiJournalTallyPayload.self, from: Data(contentsOf: fileURL))
    }

    static func prune(_ payload: inout OmiJournalTallyPayload) {
        let keysToDrop = payload.keys.sorted().dropLast(Self.retainedDayCount)
        for key in keysToDrop {
            payload.removeValue(forKey: key)
        }
    }
}
