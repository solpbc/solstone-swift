// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@MainActor
final class ThroughputMeter {
    private let window: TimeInterval
    private let maxEntries = 256
    private var entries: [(time: Date, bytes: Int)] = []

    init(window: TimeInterval = 15) {
        self.window = window
    }

    func record(bytes: Int, at time: Date = Date()) {
        guard bytes > 0 else { return }
        self.entries.append((time: time, bytes: bytes))
        if self.entries.count > self.maxEntries {
            self.entries.removeFirst(self.entries.count - self.maxEntries)
        }
        self.prune(now: time)
    }

    func bytesPerSecond(now: Date = Date()) -> Double {
        self.prune(now: now)
        guard !self.entries.isEmpty else { return 0 }
        let bytes = self.entries.reduce(0) { $0 + $1.bytes }
        return Double(bytes) / self.window
    }

    var recentBytesPerSecond: Double {
        self.bytesPerSecond()
    }

    nonisolated static func byteCount(of url: URL) -> Int {
        do {
            return try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        } catch {
            return 0
        }
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-self.window)
        self.entries.removeAll { $0.time <= cutoff }
    }
}
