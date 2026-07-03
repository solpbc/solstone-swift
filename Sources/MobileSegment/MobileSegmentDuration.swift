// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation
import os

nonisolated private let mobileSegmentDurationLog = Logger(subsystem: "app.solstone.swift", category: "mobile-segment-duration")

enum MobileSegmentDuration {
    static let rotationCeiling: TimeInterval = 300

    static func bounded(container: TimeInterval?, elapsed: TimeInterval) -> TimeInterval {
        if let container, container.isFinite, container > 0 {
            return min(container, Self.rotationCeiling)
        }
        return min(max(elapsed, 1), Self.rotationCeiling)
    }

    nonisolated static func probeContainerDuration(at url: URL) async -> TimeInterval? {
        do {
            let seconds = CMTimeGetSeconds(try await AVURLAsset(url: url).load(.duration))
            guard seconds.isFinite, seconds > 0 else { return nil }
            return seconds
        } catch {
            mobileSegmentDurationLog.debug("container duration probe failed file=\(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
