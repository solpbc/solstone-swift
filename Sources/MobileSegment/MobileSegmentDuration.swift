// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation
import os

nonisolated private let mobileSegmentDurationLog = Logger(subsystem: "app.solstone.swift", category: "mobile-segment-duration")

nonisolated enum MobileSegmentAudioContainerVerdict: Sendable, Equatable {
    case decodable(TimeInterval?)
    case permanentlyUndecodable(domain: String, code: Int)
    case unknownOrTransient(domain: String, code: Int)
}

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

    nonisolated static func audioContainerVerdict(duration: TimeInterval?, error: (any Error)?) -> MobileSegmentAudioContainerVerdict {
        guard let error else {
            if let duration, duration.isFinite, duration > 0 {
                return .decodable(duration)
            }
            return .decodable(nil)
        }
        let nsError = error as NSError
        if nsError.domain == AVFoundationErrorDomain, nsError.code == -11829 {
            return .permanentlyUndecodable(domain: nsError.domain, code: nsError.code)
        }
        return .unknownOrTransient(domain: nsError.domain, code: nsError.code)
    }

    nonisolated static func classifyAudioContainer(at url: URL) async -> MobileSegmentAudioContainerVerdict {
        do {
            let seconds = CMTimeGetSeconds(try await AVURLAsset(url: url).load(.duration))
            return self.audioContainerVerdict(duration: seconds, error: nil)
        } catch {
            return self.audioContainerVerdict(duration: nil, error: error)
        }
    }
}
