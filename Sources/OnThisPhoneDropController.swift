// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

@MainActor
@Observable
final class OnThisPhoneDropController {
    struct Entry: Identifiable {
        let id: String
        let descriptor: String
        let commit: @MainActor () -> Void
        var task: Task<Void, Never>?
        var isFinished = false
    }

    @ObservationIgnored private var entries: [Entry] = []
    @ObservationIgnored private let window: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    private(set) var pendingIDs: Set<String> = []
    private(set) var surfaced: Entry?

    init(
        window: Duration = .seconds(5),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.window = window
        self.sleep = sleep
    }

    deinit {
        MainActor.assumeIsolated {
            for entry in self.entries {
                entry.task?.cancel()
            }
        }
    }

    func requestDrop(
        itemID: String,
        descriptor: String,
        commit: @escaping @MainActor () -> Void
    ) {
        guard !self.entries.contains(where: { $0.id == itemID && !$0.isFinished }) else {
            return
        }

        self.entries.append(Entry(id: itemID, descriptor: descriptor, commit: commit))
        let index = self.entries.index(before: self.entries.endIndex)
        self.entries[index].task = self.makeTimerTask(itemID: itemID)
        self.refreshDerivedState()
    }

    func undo(itemID: String) {
        guard let index = self.entries.firstIndex(where: { $0.id == itemID && !$0.isFinished }) else {
            return
        }
        self.entries[index].isFinished = true
        self.entries[index].task?.cancel()
        self.entries.remove(at: index)
        self.refreshDerivedState()
    }

    func cancelAll() {
        for index in self.entries.indices {
            self.entries[index].isFinished = true
            self.entries[index].task?.cancel()
        }
        self.entries.removeAll()
        self.refreshDerivedState()
    }
}

private extension OnThisPhoneDropController {
    func makeTimerTask(itemID: String) -> Task<Void, Never> {
        let window = self.window
        let sleep = self.sleep
        return Task { @MainActor [weak self] in
            do {
                try await sleep(window)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.commitEntry(itemID: itemID)
        }
    }

    func commitEntry(itemID: String) {
        guard let index = self.entries.firstIndex(where: { $0.id == itemID && !$0.isFinished }) else {
            return
        }

        self.entries[index].isFinished = true
        self.entries[index].task = nil
        let commit = self.entries[index].commit
        commit()
        self.entries.remove(at: index)
        self.refreshDerivedState()
    }

    func refreshDerivedState() {
        self.pendingIDs = Set(self.entries.filter { !$0.isFinished }.map(\.id))
        self.surfaced = self.entries.last { !$0.isFinished }
    }
}

@MainActor
func makeDropCommit(
    for item: OnThisPhoneItem,
    importQueue: ImportQueue,
    observerUploader: ObserverUploader,
    transferEngine: TransferEngine,
    mobileSegmentUploader: MobileSegmentUploader,
    removeWatchStaging: (@MainActor @Sendable (UUID) -> Void)? = nil
) -> (@MainActor () -> Void)? {
    guard let itemID = OnThisPhoneItemID(sourceKind: item.sourceKind, id: item.id) else {
        return nil
    }

    switch itemID {
    case .share(let id):
        return {
            importQueue.dropItem(itemID: id)
        }
    case .mobileSegment(let segmentID, _):
        return {
            mobileSegmentUploader.dropSegment(segmentID: segmentID)
        }
    case .transfer(let itemID, let source):
        return {
            Task { @MainActor in
                let snapshot = await transferEngine.itemSnapshot(itemID: itemID)
                await transferEngine.drop(itemID: itemID)
                guard source == .watch,
                      let segmentID = snapshot?.manifest.observerIngest?.sessionID
                else {
                    return
                }
                removeWatchStaging?(segmentID)
            }
        }
    case .audio(let sessionID, let chunkID, let source):
        return {
            switch source {
            case .observer:
                observerUploader.dropItem(sessionID: sessionID, chunkID: chunkID)
            case .omi, .watch:
                break
            }
        }
    }
}

@MainActor
func makeRetryCommit(
    for item: OnThisPhoneItem,
    importQueue: ImportQueue,
    observerUploader: ObserverUploader,
    transferEngine: TransferEngine,
    mobileSegmentUploader: MobileSegmentUploader
) -> (@MainActor () async -> Void)? {
    guard let itemID = OnThisPhoneItemID(sourceKind: item.sourceKind, id: item.id) else {
        return nil
    }

    switch itemID {
    case .share(let id):
        return { try? await importQueue.requeueFailedItem(itemID: id) }
    case .mobileSegment:
        // no per-segment requeue exists; retry is source-level
        return { await mobileSegmentUploader.retryFailed(respectingCooldown: false) }
    case .transfer(let itemID, _):
        return {
            try? await transferEngine.retryAttention(itemID: itemID)
        }
    case .audio(let sessionID, let chunkID, let source):
        return {
            switch source {
            case .observer:
                try? await observerUploader.requeueFailedItem(sessionID: sessionID, chunkID: chunkID)
            case .omi, .watch:
                break
            }
        }
    }
}
