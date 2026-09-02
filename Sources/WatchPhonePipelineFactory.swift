// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

@MainActor
struct WatchPhonePipeline {
    let watchUploaderHolder: WatchUploaderHolder
    let watchSegmentDrain: WatchSegmentDrain?
    let watchRelayReceiver: WatchRelayReceiver?
    let watchSegmentLedger: WatchSegmentLedger
    let phoneSessionHistoryStore: WatchPhoneSessionHistoryStore
    let watchLink: WatchLink
}

@MainActor
func makeWatchPhonePipeline(
    transferEngine: TransferEngine,
    transferStatusMirror: TransferStatusMirror,
    transferEnqueuer: ObserverAudioTransferEnqueuer,
    watchConnectivitySession: any WatchConnectivitySession,
    watchSourceFacts: WatchSourceFacts,
    diagnosticLog: DiagnosticLog? = nil,
    ledgerFileURL: URL? = nil,
    ledgerClock: @escaping @MainActor @Sendable () -> Date = Date.init,
    drainStagingRootURL: URL? = nil,
    receiverStagingRootURL: URL? = nil
) -> WatchPhonePipeline {
    let ledger = WatchSegmentLedger(fileURL: ledgerFileURL, clock: ledgerClock)
    let phoneSessionHistoryStore = WatchPhoneSessionHistoryStore()
    let holder = WatchUploaderHolder(transferEngine: transferEngine, mirror: transferStatusMirror)

    let drain: WatchSegmentDrain?
    do {
        drain = try WatchSegmentDrain(
            stagingRootURL: drainStagingRootURL,
            ledger: ledger,
            transferEnqueuer: transferEnqueuer,
            transferEngine: transferEngine
        )
    } catch {
        Logger(subsystem: "app.solstone.swift", category: "watch-drain")
            .error("watch segment drain unavailable: \(String(describing: error), privacy: .public)")
        drain = nil
    }

    holder.removeStaging = { [weak drain, weak ledger] id in
        ledger?.recordDropped(id: id)
        drain?.removeStaged(id)
    }

    Task { [transferEngine, weak drain, weak ledger] in
        await transferEngine.registerDeliveredHook(sourceKey: ObserverAudioTransferSource.watch) { [weak drain, weak ledger] manifest, _ in
            guard let id = manifest.observerIngest?.sessionID else {
                throw ObserverAudioTransferError.missingSessionID
            }
            await MainActor.run {
                ledger?.recordHanded(id: id)
                drain?.removeStaged(id)
            }
        }
    }

    let receiver: WatchRelayReceiver?
    do {
        receiver = try WatchRelayReceiver(
            session: watchConnectivitySession,
            ledger: ledger,
            stagingRootURL: receiverStagingRootURL,
            facts: watchSourceFacts
        )
    } catch {
        Logger(subsystem: "app.solstone.swift", category: "watch-relay")
            .error("watch relay receiver unavailable: \(String(describing: error), privacy: .public)")
        receiver = nil
    }

    receiver?.onSegmentStaged = { [weak drain] _ in
        Task { @MainActor in
            await drain?.drain()
        }
    }

    let link = WatchLink(
        session: watchConnectivitySession,
        receiver: receiver,
        facts: watchSourceFacts,
        phoneSessionHistoryStore: phoneSessionHistoryStore,
        diagnosticLog: diagnosticLog
    )
    link.activate()

    return WatchPhonePipeline(
        watchUploaderHolder: holder,
        watchSegmentDrain: drain,
        watchRelayReceiver: receiver,
        watchSegmentLedger: ledger,
        phoneSessionHistoryStore: phoneSessionHistoryStore,
        watchLink: link
    )
}
