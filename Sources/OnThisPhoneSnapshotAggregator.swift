// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@MainActor
enum OnThisPhoneSnapshotAggregator {
    static func snapshot(
        importQueue: ImportQueue,
        observerUploader: ObserverUploader,
        omiUploader: ObserverUploader,
        locationUploader: LocationUploader
    ) -> OnThisPhoneAggregateSnapshot {
        // Share includes delivered ledger entries; audio and location only have local pending/failed files.
        self.snapshot(sources: [
            OnThisPhoneSourceSnapshot(
                sourceKind: .audio,
                result: self.combinedAudioResult(
                    observerUploader.onThisPhoneSnapshot(),
                    omiUploader.onThisPhoneSnapshot()
                )
            ),
            OnThisPhoneSourceSnapshot(sourceKind: .location, result: locationUploader.onThisPhoneSnapshot()),
            OnThisPhoneSourceSnapshot(sourceKind: .share, result: importQueue.onThisPhoneSourceSnapshot()),
        ])
    }

    static func snapshot(sources: [OnThisPhoneSourceSnapshot]) -> OnThisPhoneAggregateSnapshot {
        let items = sources.flatMap { source in
            source.result.items
        }
        return OnThisPhoneAggregateSnapshot(
            sources: sources,
            items: OnThisPhoneItemSort.newestFirst(items)
        )
    }

    static func combinedAudioResult(
        _ observerResult: OnThisPhoneSourceResult,
        _ omiResult: OnThisPhoneSourceResult
    ) -> OnThisPhoneSourceResult {
        switch (observerResult, omiResult) {
        case (.failed, .failed):
            return .failed
        default:
            return .loaded(items: OnThisPhoneItemSort.newestFirst(observerResult.items + omiResult.items))
        }
    }
}
