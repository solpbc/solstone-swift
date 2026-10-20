// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

private let photoLibraryImportLog = Logger(subsystem: "app.solstone.swift", category: "photo-library")

/// Brings an owner-chosen album and range of days in from the photo library, one photo at a time,
/// through the same share route a picked or shared photo takes. Nothing is read before the owner
/// starts an import, and a photo is copied only shortly before it can move on toward the journal,
/// so a pause takes hold at once and a long import never piles copies up on this device.
@MainActor
@Observable
final class PhotoLibraryImporter {
    /// How many of an import's photos may sit on this device, not yet in the journal, before
    /// the next one is copied.
    nonisolated static let window = 3

    struct Dependencies {
        /// The ids of import items not yet settled: still on this device or being sent.
        var unsettledItemIDs: @MainActor () async -> Set<String>
        /// Moves waiting imports on toward the journal.
        var drain: @MainActor () async -> Void
        var sleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
        var now: @MainActor () -> Date = { Date() }
    }

    private(set) var access: PhotoLibraryAccess
    private(set) var latest: PhotoLibraryBatch?
    /// The import is running but waiting for its photos to reach the journal before taking more.
    private(set) var isWaitingForJournal = false
    /// Bumps when what the app can see in the library changes, so a shown count is recounted.
    private(set) var libraryRevision = 0

    @ObservationIgnored private let library: any PhotoLibraryProviding
    @ObservationIgnored private let store: PhotoLibraryImportStore
    @ObservationIgnored private let queue: any ShareImportQueueing
    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private let exportDirectory: URL
    @ObservationIgnored private var runTask: Task<Void, Never>?

    init(
        library: any PhotoLibraryProviding,
        store: PhotoLibraryImportStore,
        queue: any ShareImportQueueing,
        exportDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoLibraryImport", isDirectory: true),
        dependencies: Dependencies
    ) {
        self.library = library
        self.store = store
        self.queue = queue
        self.exportDirectory = exportDirectory
        self.dependencies = dependencies
        self.access = library.access()
        self.latest = store.latest
        library.onChange = { [weak self] in
            guard let self else { return }
            self.libraryRevision += 1
            self.refreshAccess()
        }
    }

    var isRunning: Bool {
        self.latest?.state == .running
    }

    func refreshAccess() {
        self.access = self.library.access()
        // Access the owner turned back on lets an import that lost it carry on.
        if self.access.canRead, self.latest?.state == .pausedForAccess {
            self.setState(.running)
            self.run()
        }
    }

    func requestAccess() async {
        self.access = await self.library.requestAccess()
        self.refreshAccess()
    }

    func albums() -> [PhotoLibraryAlbum] {
        self.library.albums()
    }

    func preview(_ scope: PhotoLibraryScope) -> PhotoLibraryPreview {
        let imported = self.store.importedAssetIDs
        let all = self.library.assetIDs(in: scope)
        let fresh = all.filter { !imported.contains($0) }
        return PhotoLibraryPreview(assetIDs: fresh, alreadyIn: all.count - fresh.count)
    }

    /// Starts an import of exactly the photos the owner was shown.
    func start(_ scope: PhotoLibraryScope, assetIDs: [String]) {
        guard !assetIDs.isEmpty, self.latest.map({ $0.state.isEnded }) ?? true else { return }
        let batch = PhotoLibraryBatch(
            id: UUID(),
            scope: scope,
            assetIDs: assetIDs,
            next: 0,
            itemIDs: [:],
            unreadable: [],
            state: .running,
            startedAt: self.dependencies.now(),
            endedAt: nil
        )
        self.latest = batch
        self.store.save(batch)
        photoLibraryImportLog.info("photo library import started count=\(assetIDs.count, privacy: .public)")
        self.run()
    }

    func pause() {
        guard self.latest?.state == .running else { return }
        self.setState(.paused)
    }

    func resume() {
        guard let state = self.latest?.state, state.isPaused else { return }
        self.access = self.library.access()
        guard self.access.canRead else {
            self.setState(.pausedForAccess)
            return
        }
        self.setState(.running)
        self.run()
    }

    func stop() {
        guard let state = self.latest?.state, !state.isEnded else { return }
        self.setState(.stopped)
    }

    /// Carries on an import the owner started that was still running when the app last closed.
    func resumeIfRunning() {
        self.access = self.library.access()
        guard self.latest?.state == .running else { return }
        self.run()
    }

    /// Waits for the current run, if one is going. For tests.
    func waitForRun() async {
        await self.runTask?.value
    }

    private func setState(_ state: PhotoLibraryBatchState) {
        guard var batch = self.latest else { return }
        batch.state = state
        if state.isEnded {
            batch.endedAt = self.dependencies.now()
        }
        self.latest = batch
        self.store.save(batch)
        if state != .running {
            self.isWaitingForJournal = false
        }
    }

    private func run() {
        guard self.runTask == nil else { return }
        self.runTask = Task { @MainActor in
            await self.runLoop()
            self.runTask = nil
            self.isWaitingForJournal = false
            // A resume that landed while the last photo was finishing gets its own run.
            if self.latest?.state == .running, (self.latest?.remaining ?? 0) > 0 {
                self.run()
            }
        }
    }

    private func runLoop() async {
        while let batch = self.latest, batch.state == .running {
            self.access = self.library.access()
            guard self.access.canRead else {
                self.setState(.pausedForAccess)
                return
            }
            guard batch.remaining > 0 else {
                self.setState(.finished)
                photoLibraryImportLog.info("photo library import finished brought_in=\(batch.broughtIn, privacy: .public)")
                await self.dependencies.drain()
                return
            }
            if await self.unsettledCount(of: batch) >= Self.window {
                await self.dependencies.drain()
                if await self.unsettledCount(of: batch) >= Self.window {
                    self.isWaitingForJournal = true
                    await self.dependencies.sleep(.seconds(3))
                    continue
                }
            }
            self.isWaitingForJournal = false
            await self.bringInNext()
            Task { await self.dependencies.drain() }
        }
    }

    private func unsettledCount(of batch: PhotoLibraryBatch) async -> Int {
        let unsettled = await self.dependencies.unsettledItemIDs()
        return batch.itemIDs.values.reduce(0) { $0 + (unsettled.contains($1) ? 1 : 0) }
    }

    private func bringInNext() async {
        guard let batch = self.latest, batch.state == .running, batch.remaining > 0 else { return }
        let assetID = batch.assetIDs[batch.next]
        var outcome: Outcome
        var exportedURL: URL?
        do {
            let export = try await self.library.export(assetID: assetID, into: self.exportDirectory)
            exportedURL = export.fileURL
            outcome = await self.land(export)
        } catch {
            outcome = .unreadable
        }
        if let exportedURL {
            try? FileManager.default.removeItem(at: exportedURL)
        }
        // The owner may have paused or stopped while this photo was being copied; it still
        // counts, because it has already been taken in.
        guard var current = self.latest, current.id == batch.id else { return }
        switch outcome {
        case .landed(let itemID):
            current.itemIDs[assetID] = ShareImportStore.itemIDString(itemID)
            current.next += 1
        case .unreadable:
            current.unreadable.append(assetID)
            current.next += 1
        case .noRoom:
            if current.state == .running {
                current.state = .pausedForSpace
            }
        }
        // A pause that landed while the last photo was being copied has nothing left to hold.
        if current.remaining == 0, current.state == .paused {
            current.state = .finished
            current.endedAt = self.dependencies.now()
        }
        self.latest = current
        self.store.save(current)
    }

    private enum Outcome {
        case landed(UUID)
        case unreadable
        case noRoom
    }

    private func land(_ export: PhotoLibraryExport) async -> Outcome {
        guard let provider = NSItemProvider(contentsOf: export.fileURL) else { return .unreadable }
        provider.suggestedName = export.filename
        let coordinator = ShareImportCoordinator(queue: self.queue, originApp: ShareImportOrigin.photos)
        switch await coordinator.accept(provider: ShareExtensionItemProvider(provider: provider)) {
        case .success(let itemID):
            return .landed(itemID)
        case .failure(.noRoom):
            return .noRoom
        case .failure, .dropped:
            return .unreadable
        }
    }
}
