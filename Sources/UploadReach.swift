// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@MainActor
func uploadTotals(
    mobileSegment: MobileSegmentUploader,
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
    observer: ObserverUploader,
    omi: OmiUploaderHolder,
    watch: WatchUploaderHolder,
    importQueue: ImportQueue
) -> Int {
    // Transfer activity intentionally excludes MobileSegmentUploader; mobile segment URLSession work is owned by ObserverUploader.
    confirmedTransferCount(
        observer: observer.confirmedActiveTransferCount,
        omi: omi.confirmedActiveTransferCount,
        watch: watch.confirmedActiveTransferCount,
        importQueue: importQueue.confirmedActiveTransferCount
    )
}

nonisolated func confirmedTransferCount(
    observer: Int,
    omi: Int,
    watch: Int,
    importQueue: Int
) -> Int {
    observer + omi + watch + importQueue
}

@MainActor
func recentBytesTotal(
    observer: ObserverUploader,
    omi: OmiUploaderHolder,
    watch: WatchUploaderHolder,
    importQueue: ImportQueue
) -> Double {
    // Transfer activity intentionally excludes MobileSegmentUploader; mobile segment bytes are recorded by ObserverUploader.
    recentBytesTotal(
        observer: observer.recentBytesPerSecond,
        omi: omi.recentBytesPerSecond,
        watch: watch.recentBytesPerSecond,
        importQueue: importQueue.recentBytesPerSecond
    )
}

nonisolated func recentBytesTotal(
    observer: Double,
    omi: Double,
    watch: Double,
    importQueue: Double
) -> Double {
    observer + omi + watch + importQueue
}

@MainActor
func uploadInFlight(
    mobileSegment: MobileSegmentUploader,
    omi: OmiUploaderHolder,
    watch: WatchUploaderHolder,
    importQueue: ImportQueue
) -> Int {
    mobileSegment.inFlightCount + omi.inFlightCount + watch.inFlightCount + importQueue.inFlightCount
}

@MainActor
func uploadFailedTotal(
    mobileSegment: MobileSegmentUploader,
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
    mobileSegment: MobileSegmentUploader,
    omi: OmiUploaderHolder,
    watch: WatchUploaderHolder,
    importQueue: ImportQueue
) -> Date? {
    lastSyncedAt([
        mobileSegment.lastUploadAt,
        omi.uploader.lastUploadAt,
        watch.lastUploadAt,
        importQueue.lastDeliveredAt,
    ])
}
