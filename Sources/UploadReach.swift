// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@MainActor
func uploadTotals(
    mobileSegment: MobileSegmentTransferHolder,
    omi: OmiUploaderHolder,
    watch: WatchUploaderHolder,
    share: ShareTransferHolder
) -> (failed: Int, pending: Int) {
    (
        failed: mobileSegment.failedCount + omi.failedCount + watch.failedCount + share.failedCount,
        pending: mobileSegment.pendingCount + omi.pendingCount + watch.pendingCount + share.pendingCount
    )
}

@MainActor
func confirmedTransferCount(
    mobileSegment: MobileSegmentTransferHolder,
    omi: OmiUploaderHolder,
    watch: WatchUploaderHolder,
    share: ShareTransferHolder
) -> Int {
    confirmedTransferCount(
        mobileSegment: mobileSegment.confirmedActiveTransferCount,
        omi: omi.confirmedActiveTransferCount,
        watch: watch.confirmedActiveTransferCount,
        share: share.confirmedActiveTransferCount
    )
}

nonisolated func confirmedTransferCount(
    mobileSegment: Int,
    omi: Int,
    watch: Int,
    share: Int
) -> Int {
    mobileSegment + omi + watch + share
}

@MainActor
func recentBytesTotal(
    mobileSegment: MobileSegmentTransferHolder,
    omi: OmiUploaderHolder,
    watch: WatchUploaderHolder,
    share: ShareTransferHolder
) -> Double {
    recentBytesTotal(
        mobileSegment: mobileSegment.recentBytesPerSecond,
        omi: omi.recentBytesPerSecond,
        watch: watch.recentBytesPerSecond,
        share: share.recentBytesPerSecond
    )
}

nonisolated func recentBytesTotal(
    mobileSegment: Double,
    omi: Double,
    watch: Double,
    share: Double
) -> Double {
    mobileSegment + omi + watch + share
}

@MainActor
func uploadInFlight(
    mobileSegment: MobileSegmentTransferHolder,
    omi: OmiUploaderHolder,
    watch: WatchUploaderHolder,
    share: ShareTransferHolder
) -> Int {
    mobileSegment.inFlightCount + omi.inFlightCount + watch.inFlightCount + share.inFlightCount
}

@MainActor
func uploadFailedTotal(
    mobileSegment: MobileSegmentTransferHolder,
    omi: OmiUploaderHolder,
    watch: WatchUploaderHolder,
    share: ShareTransferHolder
) -> Int {
    uploadTotals(
        mobileSegment: mobileSegment,
        omi: omi,
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
    omi: OmiUploaderHolder,
    watch: WatchUploaderHolder,
    share: ShareTransferHolder
) -> Date? {
    lastSyncedAt([
        mobileSegment.lastUploadAt,
        omi.lastUploadAt,
        watch.lastUploadAt,
        share.lastUploadAt,
    ])
}
