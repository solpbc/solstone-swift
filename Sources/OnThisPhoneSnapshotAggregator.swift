// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@MainActor
enum OnThisPhoneSnapshotAggregator {
    static func snapshot(
        importQueue: ImportQueue,
        mobileSegmentUploader: MobileSegmentUploader,
        transferEngine: TransferEngine
    ) async -> OnThisPhoneAggregateSnapshot {
        let mobileSnapshots = await transferEngine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let omiSnapshots = await transferEngine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        let watchSnapshots = await transferEngine.itemSnapshots(sourceKey: ObserverAudioTransferSource.watch)
        let mobileResults = await ObserverAudioTransferSnapshotMapper.mobileSegmentSourceResults(
            snapshots: mobileSnapshots,
            engine: transferEngine
        )
        let omiResult = await ObserverAudioTransferSnapshotMapper.sourceResult(
            snapshots: omiSnapshots,
            source: .omi,
            engine: transferEngine
        )
        let watchResult = await ObserverAudioTransferSnapshotMapper.sourceResult(
            snapshots: watchSnapshots,
            source: .watch,
            engine: transferEngine
        )
        // Share includes delivered ledger entries; observation rows combine engine items with local finalize failures.
        return self.snapshot(sources: [
            OnThisPhoneSourceSnapshot(
                sourceKind: .audio,
                result: self.combinedResult(
                    mobileSegmentUploader.onThisPhoneSnapshot(for: .audio),
                    mobileResults[.audio] ?? .loaded(items: []),
                    omiResult,
                    watchResult
                )
            ),
            OnThisPhoneSourceSnapshot(
                sourceKind: .location,
                result: self.combinedResult(
                    mobileSegmentUploader.onThisPhoneSnapshot(for: .location),
                    mobileResults[.location] ?? .loaded(items: [])
                )
            ),
            OnThisPhoneSourceSnapshot(
                sourceKind: .screencast,
                result: self.combinedResult(
                    mobileSegmentUploader.onThisPhoneSnapshot(for: .screencast),
                    mobileResults[.screencast] ?? .loaded(items: [])
                )
            ),
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

    static func combinedResult(
        _ results: OnThisPhoneSourceResult...
    ) -> OnThisPhoneSourceResult {
        if results.allSatisfy({ result in
            if case .failed = result { return true }
            return false
        }) {
            return .failed
        }
        var items: [OnThisPhoneItem] = []
        for result in results {
            items.append(contentsOf: result.items)
        }
        return .loaded(items: OnThisPhoneItemSort.newestFirst(items))
    }
}
