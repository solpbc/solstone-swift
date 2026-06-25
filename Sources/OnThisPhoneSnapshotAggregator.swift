// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@MainActor
enum OnThisPhoneSnapshotAggregator {
    static func snapshot(
        importQueue: ImportQueue,
        observerUploader: ObserverUploader,
        omiUploader: ObserverUploader,
        watchUploader: ObserverUploader,
        locationUploader: LocationUploader
    ) -> OnThisPhoneAggregateSnapshot {
        // Share includes delivered ledger entries; audio and location only have local pending/failed files.
        self.snapshot(sources: [
            OnThisPhoneSourceSnapshot(
                sourceKind: .audio,
                result: self.combinedAudioResult(
                    observerUploader.onThisPhoneSnapshot(),
                    omiUploader.onThisPhoneSnapshot(),
                    watchUploader.onThisPhoneSnapshot()
                )
            ),
            OnThisPhoneSourceSnapshot(sourceKind: .location, result: locationUploader.onThisPhoneSnapshot()),
            OnThisPhoneSourceSnapshot(sourceKind: .share, result: importQueue.onThisPhoneSourceSnapshot()),
        ])
    }

    static func snapshot(sources: [OnThisPhoneSourceSnapshot]) -> OnThisPhoneAggregateSnapshot {
        let interval = DrainSignpost.begin(.aggregatePublication, source: .aggregate)
        let items = sources.flatMap { source in
            source.result.items
        }
        let snapshot = OnThisPhoneAggregateSnapshot(
            sources: sources,
            items: OnThisPhoneItemSort.newestFirst(items)
        )
        DrainSignpost.end(
            interval,
            source: .aggregate,
            fields: DrainFields(
                status: "success",
                items: snapshot.items.count,
                sources: sources.count,
                failedSources: snapshot.failedSourceCount
            )
        )
        return snapshot
    }

    static func combinedAudioResult(
        _ observerResult: OnThisPhoneSourceResult,
        _ omiResult: OnThisPhoneSourceResult,
        _ watchResult: OnThisPhoneSourceResult
    ) -> OnThisPhoneSourceResult {
        switch (observerResult, omiResult, watchResult) {
        case (.failed, .failed, .failed):
            return .failed
        default:
            return .loaded(items: OnThisPhoneItemSort.newestFirst(
                observerResult.items + omiResult.items + watchResult.items
            ))
        }
    }
}
