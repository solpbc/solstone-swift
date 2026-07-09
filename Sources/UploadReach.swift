// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@MainActor
func uploadTotals(
    mobileSegment: MobileSegmentTransferHolder,
    omi: OmiUploaderHolder,
    watch: WatchUploaderHolder,
    importQueue: ImportQueue
) -> (failed: Int, pending: Int) {
    (
        failed: mobileSegment.failedCount + omi.failedCount + watch.failedCount + importQueue.failedCount,
        pending: mobileSegment.pendingCount + omi.pendingCount + watch.pendingCount + importQueue.pendingCount
    )
}

@MainActor
func confirmedTransferCount(
    mobileSegment: MobileSegmentTransferHolder,
    omi: OmiUploaderHolder,
    watch: WatchUploaderHolder,
    importQueue: ImportQueue
) -> Int {
    confirmedTransferCount(
        mobileSegment: mobileSegment.confirmedActiveTransferCount,
        omi: omi.confirmedActiveTransferCount,
        watch: watch.confirmedActiveTransferCount,
        importQueue: importQueue.confirmedActiveTransferCount
    )
}

nonisolated func confirmedTransferCount(
    mobileSegment: Int,
    omi: Int,
    watch: Int,
    importQueue: Int
) -> Int {
    mobileSegment + omi + watch + importQueue
}

@MainActor
func recentBytesTotal(
    mobileSegment: MobileSegmentTransferHolder,
    omi: OmiUploaderHolder,
    watch: WatchUploaderHolder,
    importQueue: ImportQueue
) -> Double {
    recentBytesTotal(
        mobileSegment: mobileSegment.recentBytesPerSecond,
        omi: omi.recentBytesPerSecond,
        watch: watch.recentBytesPerSecond,
        importQueue: importQueue.recentBytesPerSecond
    )
}

nonisolated func recentBytesTotal(
    mobileSegment: Double,
    omi: Double,
    watch: Double,
    importQueue: Double
) -> Double {
    mobileSegment + omi + watch + importQueue
}

@MainActor
func uploadInFlight(
    mobileSegment: MobileSegmentTransferHolder,
    omi: OmiUploaderHolder,
    watch: WatchUploaderHolder,
    importQueue: ImportQueue
) -> Int {
    mobileSegment.inFlightCount + omi.inFlightCount + watch.inFlightCount + importQueue.inFlightCount
}

@MainActor
func uploadFailedTotal(
    mobileSegment: MobileSegmentTransferHolder,
    omi: OmiUploaderHolder,
    watch: WatchUploaderHolder,
    importQueue: ImportQueue
) -> Int {
    uploadTotals(
        mobileSegment: mobileSegment,
        omi: omi,
        watch: watch,
        importQueue: importQueue
    ).failed
}

nonisolated func lastSyncedAt(_ dates: [Date?]) -> Date? {
    dates.compactMap { $0 }.max()
}

@MainActor
func lastSyncedAt(
    mobileSegment: MobileSegmentTransferHolder,
    omi: OmiUploaderHolder,
    watch: WatchUploaderHolder,
    importQueue: ImportQueue
) -> Date? {
    lastSyncedAt([
        mobileSegment.lastUploadAt,
        omi.lastUploadAt,
        watch.lastUploadAt,
        importQueue.lastDeliveredAt,
    ])
}
