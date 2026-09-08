// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@MainActor
func uploadTotals(
    mobileSegment: MobileSegmentTransferHolder,
    watch: WatchUploaderHolder,
    share: ShareTransferHolder
) -> (failed: Int, pending: Int) {
    (
        failed: mobileSegment.failedCount + watch.failedCount + share.failedCount,
        pending: mobileSegment.pendingCount + watch.pendingCount + share.pendingCount
    )
}

@MainActor
func captureUploadTotals(
    mobileSegment: MobileSegmentTransferHolder,
    watch: WatchUploaderHolder
) -> (failed: Int, pending: Int) {
    (
        failed: mobileSegment.failedCount + watch.failedCount,
        pending: mobileSegment.pendingCount + watch.pendingCount
    )
}

@MainActor
func confirmedTransferCount(
    mobileSegment: MobileSegmentTransferHolder,
    watch: WatchUploaderHolder,
    share: ShareTransferHolder
) -> Int {
    confirmedTransferCount(
        mobileSegment: mobileSegment.confirmedActiveTransferCount,
        watch: watch.confirmedActiveTransferCount,
        share: share.confirmedActiveTransferCount
    )
}

nonisolated func confirmedTransferCount(
    mobileSegment: Int,
    watch: Int,
    share: Int
) -> Int {
    mobileSegment + watch + share
}

@MainActor
func recentBytesTotal(
    mobileSegment: MobileSegmentTransferHolder,
    watch: WatchUploaderHolder,
    share: ShareTransferHolder
) -> Double {
    recentBytesTotal(
        mobileSegment: mobileSegment.recentBytesPerSecond,
        watch: watch.recentBytesPerSecond,
        share: share.recentBytesPerSecond
    )
}

nonisolated func recentBytesTotal(
    mobileSegment: Double,
    watch: Double,
    share: Double
) -> Double {
    mobileSegment + watch + share
}

nonisolated struct TransferBackoffStatus: Equatable, Sendable {
    var backoffPendingCount: Int
    var endpointHeld: Bool
}

@MainActor
func uploadBackoff(mirror: TransferStatusMirror) -> TransferBackoffStatus {
    TransferBackoffStatus(
        backoffPendingCount: mirror.backoffPendingCount,
        endpointHeld: mirror.endpointHeld
    )
}

@MainActor
func uploadInFlight(
    mobileSegment: MobileSegmentTransferHolder,
    watch: WatchUploaderHolder,
    share: ShareTransferHolder
) -> Int {
    mobileSegment.inFlightCount + watch.inFlightCount + share.inFlightCount
}

@MainActor
func uploadFailedTotal(
    mobileSegment: MobileSegmentTransferHolder,
    watch: WatchUploaderHolder,
    share: ShareTransferHolder
) -> Int {
    uploadTotals(
        mobileSegment: mobileSegment,
        watch: watch,
        share: share
    ).failed
}

nonisolated func lastSyncedAt(_ dates: [Date?]) -> Date? {
    dates.compactMap { $0 }.max()
}

@MainActor
func lastSyncedAt(
    mobileSegment: MobileSegmentTransferHolder,
    watch: WatchUploaderHolder,
    share: ShareTransferHolder
) -> Date? {
    lastSyncedAt([
        mobileSegment.lastUploadAt,
        watch.lastUploadAt,
        share.lastUploadAt,
    ])
}

@MainActor
func lastCaptureSyncedAt(
    mobileSegment: MobileSegmentTransferHolder,
    watch: WatchUploaderHolder
) -> Date? {
    lastSyncedAt([
        mobileSegment.lastUploadAt,
        watch.lastUploadAt,
    ])
}
