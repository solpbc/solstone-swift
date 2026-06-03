// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@MainActor
enum OnThisPhoneSnapshotAggregator {
    static func snapshot(
        importQueue: ImportQueue,
        observerUploader: ObserverUploader,
        locationUploader: LocationUploader
    ) -> OnThisPhoneAggregateSnapshot {
        // Share includes delivered ledger entries; audio and location only have local pending/failed files.
        self.snapshot(sources: [
            OnThisPhoneSourceSnapshot(sourceKind: .audio, result: observerUploader.onThisPhoneSnapshot()),
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
}
