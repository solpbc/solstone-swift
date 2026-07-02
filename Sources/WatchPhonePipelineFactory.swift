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
    let watchLink: WatchLink
}

@MainActor
func makeWatchPhonePipeline(
    watchUploader: ObserverUploader,
    watchRegistration: ObserverRegistration,
    watchConnectivitySession: any WatchConnectivitySession,
    ledgerFileURL: URL? = nil,
    ledgerClock: @escaping @MainActor @Sendable () -> Date = Date.init,
    drainStagingRootURL: URL? = nil,
    receiverStagingRootURL: URL? = nil,
    drainTempDirectoryURL: URL? = nil
) -> WatchPhonePipeline {
    let ledger = WatchSegmentLedger(fileURL: ledgerFileURL, clock: ledgerClock)
    let holder = WatchUploaderHolder(watchUploader)

    let drain: WatchSegmentDrain?
    do {
        drain = try WatchSegmentDrain(
            stagingRootURL: drainStagingRootURL,
            ledger: ledger,
            watchUploader: watchUploader,
            watchRegistration: watchRegistration,
            localPortProvider: {
                watchRegistration.activeLocalPort
            },
            tempDirectoryURL: drainTempDirectoryURL
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

    let receiver: WatchRelayReceiver?
    do {
        receiver = try WatchRelayReceiver(
            session: watchConnectivitySession,
            ledger: ledger,
            stagingRootURL: receiverStagingRootURL
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

    let link = WatchLink(session: watchConnectivitySession, receiver: receiver)
    link.activate()

    return WatchPhonePipeline(
        watchUploaderHolder: holder,
        watchSegmentDrain: drain,
        watchRelayReceiver: receiver,
        watchSegmentLedger: ledger,
        watchLink: link
    )
}
