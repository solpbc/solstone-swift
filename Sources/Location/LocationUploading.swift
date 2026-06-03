// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum LocationAccuracy: String, Sendable, Equatable {
    case full
    case reduced
}

nonisolated struct LocationFix: Sendable, Equatable {
    let t: Date
    let lat: Double
    let lon: Double
    let hAcc: Double
    let alt: Double?
    let vAcc: Double?
    let speed: Double?
    let course: Double?
    let stationary: Bool
}

nonisolated struct LocationVisit: Sendable, Equatable {
    let arrival: Date
    let departure: Date?
    let lat: Double
    let lon: Double
    let hAcc: Double
}

nonisolated struct LocationSegmentBatch: Sendable, Equatable {
    let tier: LocationTier
    let accuracy: LocationAccuracy
    let segmentStart: Date
    let coveredSeconds: Int
    let fixes: [LocationFix]
    let visits: [LocationVisit]
    let gap: Bool
}

nonisolated protocol LocationUploading: Sendable {
    func enqueue(_ batch: LocationSegmentBatch) async
}

actor LocationUploader: LocationUploading {
    // W1.L2 seam: upload wiring lands in a later lode; keep the live default inert.
    func enqueue(_ batch: LocationSegmentBatch) async {
        _ = batch
    }
}
