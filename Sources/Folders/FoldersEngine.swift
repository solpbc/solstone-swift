// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

/// Pending inline prompt shown on the folders list when picking a folder triggers
/// an overlap warning, already-added notice, or OS/provider refusal.
nonisolated enum FoldersPickerNotice: Equatable, Sendable {
    case alreadyAdded(folderID: String, name: String)
    case overlap(probe: FolderProbeResult, target: FolderOverlapTarget)
    case refusedLocal
    case refusedProvider
}

/// Home tile summary derived from all configured folders using worst-signal-wins rollup.
nonisolated struct FoldersTileRollup: Equatable, Sendable {
    var state: SourceState
    var subtext: String?
    var showsSubtext: Bool
}

/// Multi-folder source engine for iPhone and iPad.
/// All filesystem walks, file hashing, and reads execute off `@MainActor`.
@MainActor
@Observable
final class FoldersEngine {
    let store: FoldersStore
    private let fileSystem: any FolderFileSystem
    private let transport: any FoldersTransport
    private let clock: any FolderClock
    private let intake: SourceIntakeStore?
    private let obsidianVaultProvider: @MainActor () -> (canonicalPath: String, name: String)?

    var isPairedProvider: @MainActor () -> Bool = { false }
    var isConnectedProvider: @MainActor () -> Bool = { true }

    /// Monotonic counter incremented on every state mutation so SwiftUI views observe all changes.
    private(set) var revision: UInt64 = 0
    private(set) var supported: FolderSupportedList = .default
    private(set) var facets: [FolderFacet] = []
    private(set) var facetsAvailability: FolderFacetsAvailability = .unpaired
    /// `nil` = unknown (not yet fetched / offline), `true` = listed, `false` = journal lacks `"folder"` capability.
    private(set) var capabilityListed: Bool? = nil
    private(set) var isChecking: Bool = false
    private(set) var previewLoadingFolderID: String? = nil
    private(set) var previewsByFolderID: [String: FolderPreviewSummary] = [:]
    private(set) var pickerNotice: FoldersPickerNotice? = nil
    private(set) var inFlightCount: Int = 0
    /// Diagnostic count of evicted iCloud placeholders skipped on the most recent walk.
    private(set) var lastPlaceholdersSkipped: Int = 0

    private var isScanning = false
    private var scanRequestedAgain = false
    private var isDraining = false
    private var drainRequestedAgain = false
    private var appIsActive = false
    private var activeLoopTask: Task<Void, Never>? = nil
    private var lastScanDuration: TimeInterval = 0
    /// Foreground poll cadence (seconds); overridable in tests.
    var activePollIntervalSeconds: TimeInterval = 60

    init(
        store: FoldersStore,
        fileSystem: any FolderFileSystem = LiveFolderFileSystem(),
        transport: any FoldersTransport,
        clock: any FolderClock = SystemFolderClock(),
        intake: SourceIntakeStore? = nil,
        obsidianVaultProvider: @escaping @MainActor () -> (canonicalPath: String, name: String)? = { nil }
    ) {
        self.store = store
        self.fileSystem = fileSystem
        self.transport = transport
        self.clock = clock
        self.intake = intake
        self.obsidianVaultProvider = obsidianVaultProvider
    }

    var folders: [FolderRecord] {
        _ = self.revision
        return self.store.ledger.folders
    }

    func folder(id: String) -> FolderRecord? {
        _ = self.revision
        return self.store.ledger.folders.first { $0.id == id }
    }

    var isPaired: Bool { self.isPairedProvider() }
    var isConnected: Bool { self.isConnectedProvider() }

    var wantsBackgroundRefresh: Bool {
        self.store.ledger.folders.contains { $0.mode == .on || $0.mode == .paused }
    }

    /// Pending events waiting to reach the journal across active (`on`) folders.
    var waitingCount: Int {
        _ = self.revision
        return self.store.ledger.folders
            .filter { $0.mode == .on }
            .reduce(0) { $0 + $1.pending.count }
    }

    /// Pending events currently blocked by missing journal capability or folder attention faults.
    var unsendableCount: Int {
        _ = self.revision
        let capabilityBlocked = self.capabilityListed == false
        return self.store.ledger.folders
            .filter { $0.mode == .on }
            .reduce(0) { acc, folder in
                if capabilityBlocked || folder.attention != nil {
                    return acc + folder.pending.count
                }
                return acc
            }
    }

    /// Worst-signal-wins rollup for the single `folders` Home tile.
    func tileRollup() -> FoldersTileRollup {
        _ = self.revision
        return Self.computeTileRollup(
            folders: self.store.ledger.folders,
            isPaired: self.isPaired,
            capabilityListed: self.capabilityListed
        )
    }

    nonisolated static func computeTileRollup(
        folders: [FolderRecord],
        isPaired: Bool,
        capabilityListed: Bool?
    ) -> FoldersTileRollup {
        guard !folders.isEmpty else {
            return FoldersTileRollup(state: .readyToSetUp, subtext: nil, showsSubtext: false)
        }

        // 1. needs attention (only for non-off folders)
        let attentionFolders = folders.filter { $0.mode != .off && $0.attention != nil }
        if !attentionFolders.isEmpty {
            let sub = attentionFolders.count == 1
                ? FoldersVocabulary.attentionTile(folder: attentionFolders[0].name)
                : FoldersVocabulary.needAttentionMany(attentionFolders.count)
            return FoldersTileRollup(state: .needsAttention, subtext: sub, showsSubtext: true)
        }

        // 2. setting up
        if let setupFolder = folders.first(where: { $0.mode == .settingUp }) {
            return FoldersTileRollup(
                state: .enrolling,
                subtext: FoldersVocabulary.finishSetup(folder: setupFolder.name),
                showsSubtext: true
            )
        }

        // 3. on
        let onFolders = folders.filter { $0.mode == .on }
        let pausedFolders = folders.filter { $0.mode == .paused }
        if !onFolders.isEmpty {
            if !isPaired {
                return FoldersTileRollup(state: .active, subtext: FoldersVocabulary.unpaired, showsSubtext: true)
            }
            if capabilityListed == false {
                return FoldersTileRollup(state: .active, subtext: FoldersVocabulary.journalUpdate, showsSubtext: true)
            }
            if let backfilling = onFolders.first(where: { $0.backfillTotal > 0 && $0.backfillDone < $0.backfillTotal }) {
                return FoldersTileRollup(
                    state: .active,
                    subtext: FoldersVocabulary.tileProgress(
                        folder: backfilling.name,
                        done: backfilling.backfillDone,
                        total: backfilling.backfillTotal
                    ),
                    showsSubtext: true
                )
            }
            let totalWaiting = onFolders.reduce(0) { $0 + $1.pending.count }
            if totalWaiting > 0 {
                let sub = onFolders.count == 1
                    ? FoldersVocabulary.waitingFolder(onFolders[0].name, count: totalWaiting)
                    : FoldersVocabulary.waiting(totalWaiting)
                return FoldersTileRollup(state: .active, subtext: sub, showsSubtext: true)
            }
            if !pausedFolders.isEmpty {
                return FoldersTileRollup(
                    state: .active,
                    subtext: FoldersVocabulary.splitCounts(on: onFolders.count, paused: pausedFolders.count),
                    showsSubtext: true
                )
            }
            let steadySub: String
            switch onFolders.count {
            case 1:
                steadySub = onFolders[0].name
            case 2:
                steadySub = FoldersVocabulary.twoFolders(onFolders[0].name, onFolders[1].name)
            default:
                steadySub = FoldersVocabulary.manyFolders(onFolders.count)
            }
            return FoldersTileRollup(state: .active, subtext: steadySub, showsSubtext: true)
        }

        // 4. paused
        if !pausedFolders.isEmpty {
            return FoldersTileRollup(state: .paused, subtext: FoldersVocabulary.pausedFolder, showsSubtext: true)
        }

        // 5. all off
        return FoldersTileRollup(state: .off, subtext: FoldersVocabulary.offReason, showsSubtext: true)
    }

    /// Build per-folder source declarations for `PUT /app/network/api/clients/self/sources`
    /// respecting the 64-entry wire limit and severity-first ordering.
    func sourceDeclarations(nonFolderCount: Int) -> [SourceDeclaration] {
        _ = self.revision
        return Self.buildSourceDeclarations(
            folders: self.store.ledger.folders,
            capabilityListed: self.capabilityListed,
            nonFolderCount: nonFolderCount
        )
    }

    nonisolated static func buildSourceDeclarations(
        folders: [FolderRecord],
        capabilityListed: Bool?,
        nonFolderCount: Int
    ) -> [SourceDeclaration] {
        guard capabilityListed != false else { return [] }
        let slots = max(0, 64 - nonFolderCount)
        guard slots > 0 else { return [] }

        struct Ranked {
            var priority: Int
            var id: String
            var state: String
        }

        var seen = Set<String>()
        var candidates: [Ranked] = []
        for folder in folders {
            guard folder.mode == .on || folder.mode == .paused else { continue }
            guard !folder.id.isEmpty, seen.insert(folder.id).inserted else { continue }
            if folder.attention != nil {
                candidates.append(Ranked(priority: 1, id: folder.id, state: "needs_attention"))
            } else if folder.mode == .paused {
                candidates.append(Ranked(priority: 2, id: folder.id, state: "paused"))
            } else {
                candidates.append(Ranked(priority: 3, id: folder.id, state: "on"))
            }
        }
        candidates.sort { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            return lhs.id.utf8.lexicographicallyPrecedes(rhs.id.utf8)
        }
        return candidates.prefix(slots).map {
            SourceDeclaration(source: FolderConstants.wireSource, state: $0.state, detail: $0.id)
        }
    }

    /// Canonical state word for a single folder row/detail view.
    nonisolated static func stateForFolder(_ folder: FolderRecord) -> SourceState {
        if folder.mode != .off && folder.attention != nil {
            return .needsAttention
        }
        switch folder.mode {
        case .settingUp: return .enrolling
        case .on: return .active
        case .paused: return .paused
        case .off: return .off
        }
    }

    // MARK: - Picking & Lifecycle

    func clearPickerNotice() {
        self.pickerNotice = nil
        self.bump()
    }

    /// Validate a picked folder URL off-main-actor; returns the new folder ID if immediately ready,
    /// or populates `pickerNotice` on already-added, overlap, or refusal.
    func handlePickedFolder(url: URL) async -> String? {
        self.pickerNotice = nil
        let fs = self.fileSystem
        let probeResult: Result<FolderProbeResult, Error> = await Task.detached(priority: .userInitiated) {
            Result { try fs.probePickedFolder(url: url) }
        }.value

        switch probeResult {
        case .failure(let error):
            if let walkErr = error as? FolderWalkError, walkErr == .refusedProvider {
                self.pickerNotice = .refusedProvider
            } else {
                self.pickerNotice = .refusedLocal
            }
            self.bump()
            return nil
        case .success(let probe):
            let existing = self.store.ledger.folders.map { ($0.id, $0.canonicalPath, $0.name) }
            let obsidian = self.obsidianVaultProvider()
            switch FoldersClassifier.detectOverlap(
                candidateCanonicalPath: probe.canonicalPath,
                obsidianVault: obsidian,
                existingFolders: existing
            ) {
            case .alreadyAdded(let id, let name):
                self.pickerNotice = .alreadyAdded(folderID: id, name: name)
                self.bump()
                return nil
            case .overlap(let target):
                self.pickerNotice = .overlap(probe: probe, target: target)
                self.bump()
                return nil
            case .none:
                return self.insertFolder(from: probe, overlap: nil)
            }
        }
    }

    /// Explicit override when the owner clicks `use this folder anyway` on an overlap notice.
    func confirmOverlappingFolder(probe: FolderProbeResult, target: FolderOverlapTarget) -> String {
        self.pickerNotice = nil
        return self.insertFolder(from: probe, overlap: target)
    }

    private func insertFolder(from probe: FolderProbeResult, overlap: FolderOverlapTarget?) -> String {
        let existingNorm = FoldersClassifier.normalizedComparablePath(probe.canonicalPath)
        if let existing = self.store.ledger.folders.first(where: {
            FoldersClassifier.normalizedComparablePath($0.canonicalPath) == existingNorm
        }) {
            return existing.id
        }
        let id = FoldersClassifier.makeFolderID(name: probe.name, canonicalPath: probe.canonicalPath)
        let record = FolderRecord(
            id: id,
            name: probe.name,
            displayLabel: probe.displayLabel,
            bookmarkData: probe.bookmarkData,
            canonicalPath: probe.canonicalPath,
            isCloudProvider: probe.isCloudProvider,
            mode: .settingUp,
            returning: false,
            kinds: .allOn,
            facet: nil,
            overlap: overlap
        )
        self.store.ledger.folders.append(record)
        self.store.save()
        self.bump()
        return id
    }

    /// Re-bind a folder's security-scoped bookmark (e.g., from `needs attention` -> `choose the folder`).
    @discardableResult
    func rechooseFolder(folderID: String, url: URL) async -> Bool {
        let fs = self.fileSystem
        let probeResult: Result<FolderProbeResult, Error> = await Task.detached(priority: .userInitiated) {
            Result { try fs.probePickedFolder(url: url) }
        }.value

        guard case .success(let probe) = probeResult,
              let idx = self.store.ledger.folders.firstIndex(where: { $0.id == folderID })
        else {
            if case .failure(let error) = probeResult,
               let walkErr = error as? FolderWalkError, walkErr == .refusedProvider
            {
                self.pickerNotice = .refusedProvider
            } else {
                self.pickerNotice = .refusedLocal
            }
            self.bump()
            return false
        }

        self.store.ledger.folders[idx].name = probe.name
        self.store.ledger.folders[idx].displayLabel = probe.displayLabel
        self.store.ledger.folders[idx].bookmarkData = probe.bookmarkData
        self.store.ledger.folders[idx].canonicalPath = probe.canonicalPath
        self.store.ledger.folders[idx].isCloudProvider = probe.isCloudProvider
        self.store.ledger.folders[idx].attention = nil
        self.previewsByFolderID.removeValue(forKey: folderID)
        self.store.save()
        self.bump()

        if self.store.ledger.folders[idx].mode == .on || self.store.ledger.folders[idx].mode == .paused {
            await self.scanAll()
            await self.drainPending()
        }
        return true
    }

    func setKinds(folderID: String, kinds: FolderKinds) {
        guard let idx = self.store.ledger.folders.firstIndex(where: { $0.id == folderID }) else { return }
        self.store.ledger.folders[idx].kinds = kinds
        self.previewsByFolderID.removeValue(forKey: folderID)
        self.store.save()
        self.bump()
    }

    func setFacet(folderID: String, facet: FolderFacet?) {
        guard let idx = self.store.ledger.folders.firstIndex(where: { $0.id == folderID }) else { return }
        self.store.ledger.folders[idx].facet = facet
        self.store.save()
        self.bump()
    }

    func pause(folderID: String) {
        guard let idx = self.store.ledger.folders.firstIndex(where: { $0.id == folderID }),
              self.store.ledger.folders[idx].mode == .on
        else { return }
        self.store.ledger.folders[idx].mode = .paused
        self.store.save()
        self.bump()
    }

    func resume(folderID: String) async {
        guard let idx = self.store.ledger.folders.firstIndex(where: { $0.id == folderID }),
              self.store.ledger.folders[idx].mode == .paused
        else { return }
        self.store.ledger.folders[idx].mode = .on
        self.store.save()
        self.bump()
        await self.scanAll()
        await self.drainPending()
    }

    func turnOff(folderID: String) {
        guard let idx = self.store.ledger.folders.firstIndex(where: { $0.id == folderID }) else { return }
        self.store.ledger.folders[idx].mode = .off
        self.store.ledger.folders[idx].pending.removeAll()
        self.store.ledger.folders[idx].backfillTotal = 0
        self.store.ledger.folders[idx].backfillDone = 0
        self.store.ledger.folders[idx].attention = nil
        self.store.save()
        self.bump()
    }

    func turnOn(folderID: String) {
        guard let idx = self.store.ledger.folders.firstIndex(where: { $0.id == folderID }) else { return }
        self.store.ledger.folders[idx].mode = .settingUp
        self.store.ledger.folders[idx].returning = true
        self.previewsByFolderID.removeValue(forKey: folderID)
        self.store.save()
        self.bump()
    }

    func removeFolder(folderID: String) {
        self.store.ledger.folders.removeAll { $0.id == folderID }
        self.previewsByFolderID.removeValue(forKey: folderID)
        self.store.save()
        self.bump()
    }

    /// Pairing principle 9: a new journal pairing returns active/paused folders to first setup
    /// while preserving the owner's folder bookmarks, kind switches, and facet choices.
    /// Pending events from the old pairing never cross over.
    func restartFirstSetup() {
        for idx in self.store.ledger.folders.indices {
            if self.store.ledger.folders[idx].mode == .on || self.store.ledger.folders[idx].mode == .paused {
                self.store.ledger.folders[idx].mode = .settingUp
                self.store.ledger.folders[idx].returning = true
            }
            self.store.ledger.folders[idx].pending.removeAll()
            self.store.ledger.folders[idx].backfillTotal = 0
            self.store.ledger.folders[idx].backfillDone = 0
            self.store.ledger.folders[idx].spanFromMs = nil
            for key in self.store.ledger.folders[idx].files.keys {
                self.store.ledger.folders[idx].files[key]?.deliveredToJournal = false
                self.store.ledger.folders[idx].files[key]?.lastSentHash = nil
                self.store.ledger.folders[idx].files[key]?.pendingRevisionSaveMs = nil
                self.store.ledger.folders[idx].files[key]?.pendingRevisionHash = nil
            }
        }
        self.previewsByFolderID.removeAll()
        self.capabilityListed = nil
        self.facets = []
        self.facetsAvailability = self.isPaired ? .offline : .unpaired
        self.store.save()
        self.bump()
    }

    // MARK: - Journal Metadata (Capability, Supported, Facets)

    func refreshJournalMetadata() async {
        guard self.isPaired else {
            self.capabilityListed = nil
            self.facets = []
            self.facetsAvailability = .unpaired
            self.bump()
            return
        }
        let cap = await self.transport.checkCapability()
        if let cap {
            self.capabilityListed = cap
        }
        if self.capabilityListed == true {
            if let remoteSupported = await self.transport.fetchSupported() {
                self.supported = remoteSupported
            }
            let (availability, list) = await self.transport.fetchFacets()
            self.facetsAvailability = availability
            if availability == .ready {
                self.facets = list
            }
        } else if self.capabilityListed == nil {
            self.facetsAvailability = .offline
        } else {
            self.facetsAvailability = .offline
        }
        self.bump()
    }

    // MARK: - Preview & Confirm

    /// Scan a folder off-main-actor and compute preview counts and optional journal estimate
    /// without queuing or sending anything.
    @discardableResult
    func computePreview(folderID: String, range: FolderBackfillRange) async -> FolderPreviewSummary? {
        guard let folder = self.store.ledger.folders.first(where: { $0.id == folderID }) else { return nil }
        self.previewLoadingFolderID = folderID
        self.bump()
        defer {
            if self.previewLoadingFolderID == folderID {
                self.previewLoadingFolderID = nil
                self.bump()
            }
        }

        let bookmark = folder.bookmarkData
        let fallbackPath = folder.canonicalPath
        let isCloud = folder.isCloudProvider
        let kinds = folder.kinds
        let alreadyDelivered = Set(folder.files.values.filter(\.deliveredToJournal).map(\.relPath))
        let supported = self.supported
        let clock = self.clock
        let fs = self.fileSystem

        let computed: (FolderPreviewSummary, [FolderEstimateItem], Data?) = await Task.detached(priority: .userInitiated) {
            let stamp = clock.now()
            let fromMs = range.startMs(nowMs: stamp.ms, offsetSeconds: stamp.offsetSeconds)
            let walk: FolderWalkOutcome
            do {
                walk = try fs.walk(bookmarkData: bookmark, fallbackPath: fallbackPath, isCloudProvider: isCloud)
            } catch {
                var failed = FolderPreviewSummary(range: range)
                failed.failed = true
                return (failed, [], nil)
            }

            var summary = FolderPreviewSummary(
                range: range,
                unreadable: walk.unreadable,
                placeholdersSkipped: walk.placeholdersSkipped
            )
            var windows = Set<FolderWindow>()
            var days = Set<String>()
            var contentThoughts = 0
            var estimateItems: [FolderEstimateItem] = []

            for file in walk.files {
                if file.metadata.modifiedMs < fromMs { continue }
                if alreadyDelivered.contains(file.relPath) { continue }
                let noteBytes: Data?
                if FoldersClassifier.isNoteCandidate(extensionLower: file.metadata.extensionLower, supported: supported),
                   file.sizeBytes <= supported.maxNoteBytes
                {
                    noteBytes = try? fs.readFile(
                        bookmarkData: bookmark,
                        fallbackPath: fallbackPath,
                        relPath: file.relPath,
                        maxBytes: supported.maxNoteBytes
                    )
                } else {
                    noteBytes = nil
                }
                let (kind, delivery) = FoldersClassifier.classifyFile(
                    extensionLower: file.metadata.extensionLower,
                    sizeBytes: file.sizeBytes,
                    isScreenshot: file.isScreenshot,
                    noteBytes: noteBytes,
                    kinds: kinds,
                    supported: supported
                )
                if delivery == .ignore { continue }

                summary.totalItems += 1
                switch delivery {
                case .content:
                    summary.contentItems += 1
                    summary.contentBytes = summary.contentBytes &+ file.sizeBytes
                    contentThoughts += 1
                    switch kind {
                    case .note: summary.notes += 1
                    case .document: summary.documents += 1
                    case .transcript: summary.transcripts += 1
                    case .screenshot: summary.screenshots += 1
                    case .photo: summary.photos += 1
                    case .other: summary.other += 1
                    }
                case .metadataOnly:
                    summary.metadataOnlyItems += 1
                    summary.other += 1
                case .ignore:
                    break
                }

                let clampedMs = min(file.metadata.modifiedMs, stamp.ms)
                summary.oldestMs = summary.oldestMs.map { min($0, clampedMs) } ?? clampedMs
                summary.newestMs = summary.newestMs.map { max($0, clampedMs) } ?? clampedMs
                let evStamp = clock.stamp(at: clampedMs)
                let win = evStamp.window()
                windows.insert(win)
                days.insert(win.day)

                if estimateItems.count < FolderConstants.maxEstimateItems {
                    let hasContent = delivery == .content
                    let contentHash = hasContent ? noteBytes.map(folderSHA256Hex) : nil
                    estimateItems.append(FolderEstimateItem(
                        path: file.relPath,
                        at: evStamp.rfc3339(),
                        fileType: file.metadata.extensionLower,
                        kindHint: hasContent ? kind.kindHint : nil,
                        contentHash: contentHash,
                        hasContent: hasContent
                    ))
                }
            }

            summary.estimate = FolderBackfillEstimate(
                segments: windows.count,
                days: days.count,
                thoughts: contentThoughts,
                alreadyInJournal: 0,
                fromJournal: false
            )
            return (summary, estimateItems, walk.refreshedBookmark)
        }.value

        var summary = computed.0
        let estimateItems = computed.1
        if let refreshed = computed.2,
           let idx = self.store.ledger.folders.firstIndex(where: { $0.id == folderID })
        {
            self.store.ledger.folders[idx].bookmarkData = refreshed
            self.store.save()
        }

        if !summary.failed && self.isPaired {
            if self.capabilityListed == nil {
                await self.refreshJournalMetadata()
            }
            if self.capabilityListed == true,
               let remoteEstimate = await self.transport.fetchEstimate(folderID: folderID, items: estimateItems)
            {
                summary.estimate = remoteEstimate
            }
        }

        self.previewsByFolderID[folderID] = summary
        self.bump()
        return summary
    }

    /// Confirm setup or `bring in older files` for one folder. Transitions folder to `.on`,
    /// enqueues eligible existing files within `range` without duplicating already-delivered items,
    /// and starts delivery.
    @discardableResult
    func confirmFolder(folderID: String, range: FolderBackfillRange) async -> Bool {
        guard let idx = self.store.ledger.folders.firstIndex(where: { $0.id == folderID }) else {
            return false
        }
        guard self.store.ledger.folders[idx].kinds.anySelected else {
            return false
        }

        let bookmark = self.store.ledger.folders[idx].bookmarkData
        let fallbackPath = self.store.ledger.folders[idx].canonicalPath
        let isCloud = self.store.ledger.folders[idx].isCloudProvider
        let kinds = self.store.ledger.folders[idx].kinds
        let existingFiles = self.store.ledger.folders[idx].files
        let supported = self.supported
        let clock = self.clock
        let fs = self.fileSystem

        struct ConfirmPrepared: Sendable {
            var nowMs: Int64
            var fromMs: Int64
            var unreadable: Int
            var placeholdersSkipped: Int
            var refreshedBookmark: Data?
            var newEvents: [FolderPendingEvent]
            var updatedFiles: [String: FolderTrackedFile]
        }

        let prepared: ConfirmPrepared? = await Task.detached(priority: .userInitiated) {
            let stamp = clock.now()
            let fromMs = range.startMs(nowMs: stamp.ms, offsetSeconds: stamp.offsetSeconds)
            guard let walk = try? fs.walk(bookmarkData: bookmark, fallbackPath: fallbackPath, isCloudProvider: isCloud) else {
                return nil
            }
            var updatedFiles = existingFiles
            var newEvents: [FolderPendingEvent] = []

            for file in walk.files {
                if let existing = updatedFiles[file.relPath], existing.deliveredToJournal {
                    continue
                }
                if file.metadata.modifiedMs < fromMs {
                    updatedFiles[file.relPath] = FolderTrackedFile(
                        relPath: file.relPath,
                        identity: file.identity,
                        sizeBytes: file.sizeBytes,
                        mtimeMs: file.mtimeMs,
                        contentHash: nil,
                        kind: .other,
                        delivery: .ignore,
                        deliveredToJournal: false,
                        excludedBeforeSpan: true
                    )
                    continue
                }

                let noteBytes: Data?
                if FoldersClassifier.isNoteCandidate(extensionLower: file.metadata.extensionLower, supported: supported),
                   file.sizeBytes <= supported.maxNoteBytes
                {
                    noteBytes = try? fs.readFile(
                        bookmarkData: bookmark,
                        fallbackPath: fallbackPath,
                        relPath: file.relPath,
                        maxBytes: supported.maxNoteBytes
                    )
                } else {
                    noteBytes = nil
                }

                let (kind, delivery) = FoldersClassifier.classifyFile(
                    extensionLower: file.metadata.extensionLower,
                    sizeBytes: file.sizeBytes,
                    isScreenshot: file.isScreenshot,
                    noteBytes: noteBytes,
                    kinds: kinds,
                    supported: supported
                )
                if delivery == .ignore { continue }

                let contentHash: String?
                if delivery == .content {
                    if let nb = noteBytes {
                        contentHash = folderSHA256Hex(nb)
                    } else if let raw = try? fs.readFile(
                        bookmarkData: bookmark,
                        fallbackPath: fallbackPath,
                        relPath: file.relPath,
                        maxBytes: supported.maxContentBytes
                    ) {
                        contentHash = folderSHA256Hex(raw)
                    } else {
                        contentHash = nil
                    }
                } else {
                    contentHash = nil
                }

                let noteText: String? = (kind == .note && delivery == .content)
                    ? noteBytes.flatMap(FoldersClassifier.decodeText)
                    : nil

                let evMs = min(file.metadata.modifiedMs, stamp.ms)
                let evStamp = clock.stamp(at: evMs)
                let win = evStamp.window()
                let winEnd = evStamp.windowEndMs()
                let isBackfill = winEnd <= stamp.ms
                let evID = folderEventID(folderID: folderID, relPath: file.relPath, verb: .added, eventMs: evMs)

                newEvents.append(FolderPendingEvent(
                    id: evID,
                    relPath: file.relPath,
                    previousPath: nil,
                    verb: .added,
                    kind: kind,
                    delivery: delivery,
                    eventMs: evMs,
                    observedMs: stamp.ms,
                    offsetSeconds: evStamp.offsetSeconds,
                    window: win,
                    windowEndMs: winEnd,
                    metadata: file.metadata,
                    contentHash: contentHash,
                    notePayload: noteText,
                    isRevision: false,
                    backfill: isBackfill
                ))
                updatedFiles[file.relPath] = FolderTrackedFile(
                    relPath: file.relPath,
                    identity: file.identity,
                    sizeBytes: file.sizeBytes,
                    mtimeMs: file.mtimeMs,
                    contentHash: contentHash,
                    kind: kind,
                    delivery: delivery,
                    deliveredToJournal: false,
                    excludedBeforeSpan: false
                )
            }

            return ConfirmPrepared(
                nowMs: stamp.ms,
                fromMs: fromMs,
                unreadable: walk.unreadable,
                placeholdersSkipped: walk.placeholdersSkipped,
                refreshedBookmark: walk.refreshedBookmark,
                newEvents: newEvents,
                updatedFiles: updatedFiles
            )
        }.value

        guard let prepared,
              let freshIdx = self.store.ledger.folders.firstIndex(where: { $0.id == folderID })
        else { return false }

        if let refreshed = prepared.refreshedBookmark {
            self.store.ledger.folders[freshIdx].bookmarkData = refreshed
        }
        self.store.ledger.folders[freshIdx].mode = .on
        self.store.ledger.folders[freshIdx].returning = true
        self.store.ledger.folders[freshIdx].attention = nil
        self.store.ledger.folders[freshIdx].lastCheckedMs = prepared.nowMs
        self.store.ledger.folders[freshIdx].cantRead = prepared.unreadable
        self.lastPlaceholdersSkipped = prepared.placeholdersSkipped
        if let prev = self.store.ledger.folders[freshIdx].spanFromMs {
            self.store.ledger.folders[freshIdx].spanFromMs = min(prev, prepared.fromMs)
        } else {
            self.store.ledger.folders[freshIdx].spanFromMs = prepared.fromMs
        }
        self.store.ledger.folders[freshIdx].files = prepared.updatedFiles

        let newPaths = Set(prepared.newEvents.map(\.relPath))
        self.store.ledger.folders[freshIdx].pending.removeAll { newPaths.contains($0.relPath) }
        self.store.ledger.folders[freshIdx].pending.append(contentsOf: prepared.newEvents)
        if !prepared.newEvents.isEmpty {
            let prevDone = self.store.ledger.folders[freshIdx].backfillDone
            self.store.ledger.folders[freshIdx].backfillTotal = prevDone + prepared.newEvents.count
        }

        self.store.save()
        self.bump()
        self.ensureActiveLoop()
        await self.drainPending()
        return true
    }

    // MARK: - Foreground, Active Poll Loop, Manual Check & Background Refresh

    /// Keep checking configured folders and closing five-minute windows while the app is open
    /// (for example, in iPad Split View beside Files). Stops cleanly when backgrounded.
    func setAppActive(_ active: Bool) {
        self.appIsActive = active
        if !active {
            self.activeLoopTask?.cancel()
            self.activeLoopTask = nil
            return
        }
        self.ensureActiveLoop()
    }

    private func ensureActiveLoop() {
        guard self.appIsActive, self.wantsBackgroundRefresh, self.activeLoopTask == nil else { return }
        self.activeLoopTask = Task { [weak self] in
            defer { self?.activeLoopTask = nil }
            while !Task.isCancelled {
                guard let self, self.appIsActive, self.wantsBackgroundRefresh else { return }
                let adaptiveFloor = self.lastScanDuration > 0.6
                    ? min(900.0, self.lastScanDuration * 100.0)
                    : self.activePollIntervalSeconds
                let nextWake = self.nextForegroundWakeDelay(defaultInterval: adaptiveFloor)
                do {
                    try await Task.sleep(for: .seconds(nextWake))
                } catch {
                    return
                }
                guard !Task.isCancelled, self.appIsActive, self.wantsBackgroundRefresh else { return }
                let started = Date()
                await self.scanAll()
                self.lastScanDuration = Date().timeIntervalSince(started)
                await self.drainPending()
            }
        }
    }

    private func nextForegroundWakeDelay(defaultInterval: TimeInterval) -> TimeInterval {
        let nowMs = self.clock.nowMs()
        var delay = max(0.05, defaultInterval)
        for folder in self.store.ledger.folders where folder.mode == .on && folder.attention == nil {
            for ev in folder.pending {
                let dueMs = max(ev.windowEndMs, ev.retryAtMs ?? 0)
                let deltaSec = Double(max(1_000, dueMs - nowMs)) / 1_000.0
                if deltaSec < delay {
                    delay = max(0.05, deltaSec)
                }
            }
        }
        return delay
    }

    func foreground() async {
        await self.refreshJournalMetadata()
        await self.scanAll()
        await self.drainPending()
        self.ensureActiveLoop()
    }

    func checkNow(folderID: String? = nil) async {
        self.isChecking = true
        self.bump()
        defer {
            self.isChecking = false
            self.bump()
        }
        await self.refreshJournalMetadata()
        if let folderID {
            await self.scanFolder(folderID: folderID)
        } else {
            await self.scanAll()
        }
        await self.drainPending()
    }

    func backgroundRefresh() async -> Bool {
        guard self.wantsBackgroundRefresh else { return true }
        await self.refreshJournalMetadata()
        await self.scanAll()
        await self.drainPending()
        return !Task.isCancelled
    }

    // MARK: - Scanning & Reconciliation (Off Main Actor)

    func scanAll() async {
        if self.isScanning || self.isDraining {
            self.scanRequestedAgain = true
            return
        }
        self.isScanning = true
        defer {
            self.isScanning = false
        }
        repeat {
            self.scanRequestedAgain = false
            let ids = self.store.ledger.folders
                .filter { $0.mode == .on || $0.mode == .paused }
                .map(\.id)
            for id in ids {
                if Task.isCancelled { break }
                await self.scanFolder(folderID: id)
            }
        } while self.scanRequestedAgain && !Task.isCancelled
        self.isScanning = false
        if self.drainRequestedAgain && !Task.isCancelled {
            self.drainRequestedAgain = false
            await self.drainPending()
        }
    }

    func clearRetryBackoff() {
        var touched = false
        for idx in self.store.ledger.folders.indices {
            for evIdx in self.store.ledger.folders[idx].pending.indices {
                if self.store.ledger.folders[idx].pending[evIdx].retryAtMs != nil {
                    self.store.ledger.folders[idx].pending[evIdx].retryAtMs = nil
                    touched = true
                }
            }
        }
        if touched {
            self.store.save()
            self.bump()
        }
    }

    func scanFolder(folderID: String) async {
        guard let snapshot = self.store.ledger.folders.first(where: { $0.id == folderID }),
              snapshot.mode == .on || snapshot.mode == .paused
        else { return }

        let supported = self.supported
        let clock = self.clock
        let fs = self.fileSystem

        let result = await Task.detached(priority: .utility) {
            Self.performScanOffMain(
                folder: snapshot,
                supported: supported,
                clock: clock,
                fileSystem: fs
            )
        }.value

        guard let freshIdx = self.store.ledger.folders.firstIndex(where: { $0.id == folderID }) else { return }
        // Preserve any concurrent user edits or live delivery counters while adopting scan updates.
        let live = self.store.ledger.folders[freshIdx]
        guard live.mode == .on || live.mode == .paused else { return }

        var merged = result.record
        merged.mode = live.mode
        merged.kinds = live.kinds
        merged.facet = live.facet
        merged.itemsTakenIn = max(merged.itemsTakenIn, live.itemsTakenIn)
        merged.lastTakenInMs = [merged.lastTakenInMs, live.lastTakenInMs].compactMap { $0 }.max()
        merged.fallbackToDetails = max(merged.fallbackToDetails, live.fallbackToDetails)
        self.store.ledger.folders[freshIdx] = merged
        self.lastPlaceholdersSkipped = result.placeholdersSkipped
        if result.changed {
            self.store.save()
        }
        self.bump()
    }

    nonisolated private static func performScanOffMain(
        folder input: FolderRecord,
        supported: FolderSupportedList,
        clock: any FolderClock,
        fileSystem: any FolderFileSystem
    ) -> (nowMs: Int64, record: FolderRecord, placeholdersSkipped: Int, changed: Bool) {
        var folder = input
        let nowStamp = clock.now()
        let nowMs = nowStamp.ms

        let walk: FolderWalkOutcome
        do {
            walk = try fileSystem.walk(
                bookmarkData: folder.bookmarkData,
                fallbackPath: folder.canonicalPath,
                isCloudProvider: folder.isCloudProvider
            )
            folder.attention = nil
            folder.lastCheckedMs = nowMs
            folder.cantRead = walk.unreadable
            if let refreshed = walk.refreshedBookmark {
                folder.bookmarkData = refreshed
            }
        } catch let error as FolderWalkError {
            folder.lastCheckedMs = nowMs
            switch error {
            case .bookmarkInvalid, .missing:
                folder.attention = .bookmarkInvalid
            case .refusedProvider:
                folder.attention = .providerRefused
            case .refusedLocal:
                folder.attention = .unreadable
            case .cancelled:
                return (nowMs, folder, 0, false)
            }
            return (nowMs, folder, 0, true)
        } catch {
            folder.lastCheckedMs = nowMs
            folder.attention = .unreadable
            return (nowMs, folder, 0, true)
        }

        var changed = walk.refreshedBookmark != nil
        var seenPaths = Set<String>()
        var newCandidates: [FolderWalkedFile] = []
        var modifiedCandidates: [FolderWalkedFile] = []

        for file in walk.files {
            seenPaths.insert(file.relPath)
            // Let freshly written files settle before hashing/reading.
            if nowMs - file.metadata.modifiedMs < FolderConstants.settleMs {
                continue
            }
            if let tracked = folder.files[file.relPath] {
                if tracked.sizeBytes != file.sizeBytes || tracked.mtimeMs != file.mtimeMs {
                    modifiedCandidates.append(file)
                }
            } else {
                newCandidates.append(file)
            }
        }

        // Only a complete listing may treat disappeared paths as renames or deletions.
        let disappearedPaths: [String] = walk.complete
            ? folder.files.keys.filter { !seenPaths.contains($0) }.sorted()
            : []

        var matchedDisappeared = Set<String>()
        var remainingNew: [FolderWalkedFile] = []
        let disappearedSizes = Set(disappearedPaths.compactMap { folder.files[$0]?.sizeBytes })

        // 1. Match renames first: same documentIdentifier / (dev, ino) OR same (size, sha256).
        for cand in newCandidates {
            var matchedOld: String? = nil
            if let candIdentity = cand.identity {
                for oldRel in disappearedPaths where !matchedDisappeared.contains(oldRel) {
                    if let oldIdentity = folder.files[oldRel]?.identity,
                       oldIdentity.matches(candIdentity)
                    {
                        matchedOld = oldRel
                        break
                    }
                }
            }
            if matchedOld == nil,
               disappearedSizes.contains(cand.sizeBytes),
               let raw = try? fileSystem.readFile(
                    bookmarkData: folder.bookmarkData,
                    fallbackPath: folder.canonicalPath,
                    relPath: cand.relPath,
                    maxBytes: supported.maxContentBytes
               )
            {
                let candHash = folderSHA256Hex(raw)
                for oldRel in disappearedPaths where !matchedDisappeared.contains(oldRel) {
                    if let old = folder.files[oldRel],
                       old.sizeBytes == cand.sizeBytes,
                       old.contentHash == candHash
                    {
                        matchedOld = oldRel
                        break
                    }
                }
            }

            if let oldRel = matchedOld, var oldTracked = folder.files.removeValue(forKey: oldRel) {
                matchedDisappeared.insert(oldRel)
                let wasDelivered = oldTracked.deliveredToJournal
                oldTracked.relPath = cand.relPath
                oldTracked.identity = cand.identity
                oldTracked.sizeBytes = cand.sizeBytes
                oldTracked.mtimeMs = cand.mtimeMs

                if !wasDelivered {
                    for i in folder.pending.indices where folder.pending[i].relPath == oldRel {
                        folder.pending[i].relPath = cand.relPath
                    }
                } else {
                    let evStamp = clock.stamp(at: nowMs)
                    let evID = folderEventID(folderID: folder.id, relPath: cand.relPath, verb: .renamed, eventMs: nowMs)
                    folder.pending.append(FolderPendingEvent(
                        id: evID,
                        relPath: cand.relPath,
                        previousPath: oldRel,
                        verb: .renamed,
                        kind: oldTracked.kind,
                        delivery: .metadataOnly,
                        eventMs: nowMs,
                        observedMs: nowMs,
                        offsetSeconds: evStamp.offsetSeconds,
                        window: evStamp.window(),
                        windowEndMs: evStamp.windowEndMs(),
                        metadata: cand.metadata,
                        contentHash: oldTracked.contentHash
                    ))
                }
                folder.files[cand.relPath] = oldTracked
                changed = true
            } else {
                remainingNew.append(cand)
            }
        }

        // 2. Delete-before-send & `removed` events (ONLY when walk.complete == true).
        if walk.complete {
            for oldRel in disappearedPaths where !matchedDisappeared.contains(oldRel) {
                guard let old = folder.files.removeValue(forKey: oldRel) else { continue }
                if !old.deliveredToJournal {
                    // Delete before send: drop waiting events silently; nothing leaves the device.
                    folder.pending.removeAll { $0.relPath == oldRel }
                    changed = true
                } else if !old.excludedBeforeSpan {
                    let evStamp = clock.stamp(at: nowMs)
                    let evID = folderEventID(folderID: folder.id, relPath: oldRel, verb: .removed, eventMs: nowMs)
                    folder.pending.append(FolderPendingEvent(
                        id: evID,
                        relPath: oldRel,
                        previousPath: nil,
                        verb: .removed,
                        kind: old.kind,
                        delivery: .metadataOnly,
                        eventMs: nowMs,
                        observedMs: nowMs,
                        offsetSeconds: evStamp.offsetSeconds,
                        window: evStamp.window(),
                        windowEndMs: evStamp.windowEndMs(),
                        metadata: FolderPlatformMetadata(
                            sizeBytes: old.sizeBytes,
                            modifiedMs: nowMs,
                            createdMs: nil,
                            extensionLower: FoldersClassifier.extensionLower(for: (oldRel as NSString).lastPathComponent)
                        )
                    ))
                    changed = true
                }
            }
        }

        // 3. Newly appeared files.
        for file in remainingNew {
            let noteBytes: Data?
            if FoldersClassifier.isNoteCandidate(extensionLower: file.metadata.extensionLower, supported: supported),
               file.sizeBytes <= supported.maxNoteBytes
            {
                noteBytes = try? fileSystem.readFile(
                    bookmarkData: folder.bookmarkData,
                    fallbackPath: folder.canonicalPath,
                    relPath: file.relPath,
                    maxBytes: supported.maxNoteBytes
                )
            } else {
                noteBytes = nil
            }
            let (kind, delivery) = FoldersClassifier.classifyFile(
                extensionLower: file.metadata.extensionLower,
                sizeBytes: file.sizeBytes,
                isScreenshot: file.isScreenshot,
                noteBytes: noteBytes,
                kinds: folder.kinds,
                supported: supported
            )
            if delivery == .ignore { continue }

            let contentHash: String?
            if delivery == .content {
                if let nb = noteBytes {
                    contentHash = folderSHA256Hex(nb)
                } else if let raw = try? fileSystem.readFile(
                    bookmarkData: folder.bookmarkData,
                    fallbackPath: folder.canonicalPath,
                    relPath: file.relPath,
                    maxBytes: supported.maxContentBytes
                ) {
                    contentHash = folderSHA256Hex(raw)
                } else {
                    contentHash = nil
                }
            } else {
                contentHash = nil
            }

            let noteText: String? = (kind == .note && delivery == .content)
                ? noteBytes.flatMap(FoldersClassifier.decodeText)
                : nil
            let evMs = min(file.metadata.modifiedMs, nowMs)
            let evStamp = clock.stamp(at: evMs)
            let evID = folderEventID(folderID: folder.id, relPath: file.relPath, verb: .added, eventMs: evMs)

            folder.pending.append(FolderPendingEvent(
                id: evID,
                relPath: file.relPath,
                previousPath: nil,
                verb: .added,
                kind: kind,
                delivery: delivery,
                eventMs: evMs,
                observedMs: nowMs,
                offsetSeconds: evStamp.offsetSeconds,
                window: evStamp.window(),
                windowEndMs: evStamp.windowEndMs(),
                metadata: file.metadata,
                contentHash: contentHash,
                notePayload: noteText
            ))
            folder.files[file.relPath] = FolderTrackedFile(
                relPath: file.relPath,
                identity: file.identity,
                sizeBytes: file.sizeBytes,
                mtimeMs: file.mtimeMs,
                contentHash: contentHash,
                kind: kind,
                delivery: delivery,
                deliveredToJournal: false,
                excludedBeforeSpan: false
            )
            changed = true
        }

        // 4. Modified files: note edits coalesce within 5-minute window; already-delivered docs/transcripts cool down 1 hour.
        for file in modifiedCandidates {
            let noteBytes: Data?
            if FoldersClassifier.isNoteCandidate(extensionLower: file.metadata.extensionLower, supported: supported),
               file.sizeBytes <= supported.maxNoteBytes
            {
                noteBytes = try? fileSystem.readFile(
                    bookmarkData: folder.bookmarkData,
                    fallbackPath: folder.canonicalPath,
                    relPath: file.relPath,
                    maxBytes: supported.maxNoteBytes
                )
            } else {
                noteBytes = nil
            }
            let (kind, delivery) = FoldersClassifier.classifyFile(
                extensionLower: file.metadata.extensionLower,
                sizeBytes: file.sizeBytes,
                isScreenshot: file.isScreenshot,
                noteBytes: noteBytes,
                kinds: folder.kinds,
                supported: supported
            )
            if delivery == .ignore { continue }

            let newHash: String?
            if delivery == .content {
                if let nb = noteBytes {
                    newHash = folderSHA256Hex(nb)
                } else if let raw = try? fileSystem.readFile(
                    bookmarkData: folder.bookmarkData,
                    fallbackPath: folder.canonicalPath,
                    relPath: file.relPath,
                    maxBytes: supported.maxContentBytes
                ) {
                    newHash = folderSHA256Hex(raw)
                } else {
                    newHash = nil
                }
            } else {
                newHash = nil
            }

            guard var tracked = folder.files[file.relPath] else { continue }
            tracked.identity = file.identity
            tracked.sizeBytes = file.sizeBytes
            tracked.mtimeMs = file.mtimeMs
            tracked.kind = kind
            tracked.delivery = delivery
            tracked.excludedBeforeSpan = false

            if let newHash, newHash == tracked.contentHash {
                folder.files[file.relPath] = tracked
                continue
            }
            tracked.contentHash = newHash

            let evMs = min(file.metadata.modifiedMs, nowMs)
            let evStamp = clock.stamp(at: evMs)
            let evWindow = evStamp.window()
            let evWindowEnd = evStamp.windowEndMs()

            switch (kind, delivery, tracked.deliveredToJournal) {
            case (.note, .content, _):
                let currentText = noteBytes.flatMap(FoldersClassifier.decodeText)
                let verb: FolderActivityVerb
                let payload: String?
                if let baseline = tracked.lastNoteText, let after = currentText {
                    if FoldersClassifier.netLineDiff(before: baseline, after: after) == nil {
                        // Reverted to baseline before window closed -> drop pending edit.
                        folder.pending.removeAll { $0.relPath == file.relPath && $0.window == evWindow }
                        folder.files[file.relPath] = tracked
                        changed = true
                        continue
                    }
                    verb = .edited
                    payload = after
                } else if let whole = currentText {
                    verb = .added
                    payload = whole
                } else {
                    verb = .edited
                    payload = nil
                }
                folder.pending.removeAll { $0.relPath == file.relPath && $0.window == evWindow }
                folder.pending.append(FolderPendingEvent(
                    id: folderEventID(folderID: folder.id, relPath: file.relPath, verb: verb, eventMs: evMs),
                    relPath: file.relPath,
                    previousPath: nil,
                    verb: verb,
                    kind: .note,
                    delivery: .content,
                    eventMs: evMs,
                    observedMs: nowMs,
                    offsetSeconds: evStamp.offsetSeconds,
                    window: evWindow,
                    windowEndMs: evWindowEnd,
                    metadata: file.metadata,
                    contentHash: newHash,
                    notePayload: payload
                ))
                folder.files[file.relPath] = tracked
                changed = true

            case (.document, .content, true), (.transcript, .content, true):
                if newHash != tracked.lastSentHash {
                    tracked.pendingRevisionSaveMs = evMs
                    tracked.pendingRevisionHash = newHash
                    changed = true
                } else if tracked.pendingRevisionSaveMs != nil || tracked.pendingRevisionHash != nil {
                    // Reverted back to the last delivered bytes during cool-down -> cancel pending revision.
                    tracked.pendingRevisionSaveMs = nil
                    tracked.pendingRevisionHash = nil
                    changed = true
                }
                folder.files[file.relPath] = tracked

            case (.document, .content, false), (.transcript, .content, false):
                folder.pending.removeAll { $0.relPath == file.relPath }
                folder.pending.append(FolderPendingEvent(
                    id: folderEventID(folderID: folder.id, relPath: file.relPath, verb: .added, eventMs: evMs),
                    relPath: file.relPath,
                    previousPath: nil,
                    verb: .added,
                    kind: kind,
                    delivery: .content,
                    eventMs: evMs,
                    observedMs: nowMs,
                    offsetSeconds: evStamp.offsetSeconds,
                    window: evWindow,
                    windowEndMs: evWindowEnd,
                    metadata: file.metadata,
                    contentHash: newHash
                ))
                folder.files[file.relPath] = tracked
                changed = true

            case (_, .metadataOnly, _):
                folder.pending.removeAll { $0.relPath == file.relPath && $0.window == evWindow }
                folder.pending.append(FolderPendingEvent(
                    id: folderEventID(folderID: folder.id, relPath: file.relPath, verb: .edited, eventMs: evMs),
                    relPath: file.relPath,
                    previousPath: nil,
                    verb: .edited,
                    kind: kind,
                    delivery: .metadataOnly,
                    eventMs: evMs,
                    observedMs: nowMs,
                    offsetSeconds: evStamp.offsetSeconds,
                    window: evWindow,
                    windowEndMs: evWindowEnd,
                    metadata: file.metadata
                ))
                folder.files[file.relPath] = tracked
                changed = true

            default:
                folder.files[file.relPath] = tracked
            }
        }

        // 5. Check one-hour revision cool-downs across tracked documents & transcripts.
        let cooldownMs = supported.documentRevisionCooldownMs
        let dueRevisions: [(String, Int64, FolderFileKind, String?)] = folder.files.values.compactMap { tracked in
            guard let saveMs = tracked.pendingRevisionSaveMs,
                  nowMs - saveMs >= cooldownMs
            else { return nil }
            return (tracked.relPath, saveMs, tracked.kind, tracked.pendingRevisionHash)
        }
        for (relPath, saveMs, kind, revHash) in dueRevisions {
            guard let meta = fileSystem.fileMetadata(
                bookmarkData: folder.bookmarkData,
                fallbackPath: folder.canonicalPath,
                relPath: relPath
            ) else { continue }
            let evStamp = clock.stamp(at: saveMs)
            let evID = folderEventID(folderID: folder.id, relPath: relPath, verb: .revised, eventMs: saveMs)
            folder.pending.append(FolderPendingEvent(
                id: evID,
                relPath: relPath,
                previousPath: nil,
                verb: .revised,
                kind: kind,
                delivery: .content,
                eventMs: saveMs,
                observedMs: nowMs,
                offsetSeconds: evStamp.offsetSeconds,
                window: evStamp.window(),
                windowEndMs: evStamp.windowEndMs(),
                metadata: meta,
                contentHash: revHash,
                isRevision: true
            ))
            folder.files[relPath]?.pendingRevisionSaveMs = nil
            folder.files[relPath]?.pendingRevisionHash = nil
            changed = true
        }

        return (nowMs, folder, walk.placeholdersSkipped, changed)
    }

    // MARK: - Delivery

    /// Select the next ready closed five-minute segment across `on` folders (newest window first),
    /// applying delete-before-send check and 63-part chunking.
    func nextDelivery() async -> FolderSegmentDelivery? {
        let nowMs = self.clock.nowMs()
        var best: (folderIdx: Int, window: FolderWindow)? = nil

        for (idx, folder) in self.store.ledger.folders.enumerated() {
            guard folder.mode == .on, folder.attention == nil else { continue }
            for ev in folder.pending {
                if ev.windowEndMs > nowMs { continue }
                if let retryAt = ev.retryAtMs, retryAt > nowMs { continue }
                if best == nil || ev.window > best!.window {
                    best = (idx, ev.window)
                }
            }
        }
        guard let (idx, window) = best else { return nil }

        let folder = self.store.ledger.folders[idx]
        let candidates = folder.pending
            .filter { $0.window == window && $0.windowEndMs <= nowMs && ($0.retryAtMs == nil || $0.retryAtMs! <= nowMs) }
            .sorted {
                if $0.eventMs != $1.eventMs { return $0.eventMs < $1.eventMs }
                return $0.relPath < $1.relPath
            }

        let bookmark = folder.bookmarkData
        let fallbackPath = folder.canonicalPath
        let fs = self.fileSystem
        let supported = self.supported
        let trackedFiles = folder.files

        struct CheckedDelivery: Sendable {
            var droppedIDs: Set<String>
            var droppedPaths: Set<String>
            var selectedEvents: [FolderPendingEvent]
            var contentFiles: [FolderStagedContentFile]
        }

        let checked: CheckedDelivery = await Task.detached(priority: .utility) {
            var droppedIDs = Set<String>()
            var droppedPaths = Set<String>()
            var selectedEvents: [FolderPendingEvent] = []
            var stagedFiles: [FolderStagedContentFile] = []

            for ev in candidates {
                if ev.delivery != .content {
                    selectedEvents.append(ev)
                    continue
                }
                if stagedFiles.count >= FolderConstants.maxUploadContentParts {
                    continue
                }
                let exists = fs.fileExists(bookmarkData: bookmark, fallbackPath: fallbackPath, relPath: ev.relPath)
                if !exists {
                    let delivered = trackedFiles[ev.relPath]?.deliveredToJournal == true
                    if !delivered {
                        droppedIDs.insert(ev.id)
                        droppedPaths.insert(ev.relPath)
                        continue
                    }
                }
                let ext = ev.metadata.extensionLower ?? ""
                let needsConvert = (ev.kind == .screenshot || ev.kind == .photo)
                    && supported.convertibleImageExtensions.contains(ext)
                stagedFiles.append(FolderStagedContentFile(
                    eventID: ev.id,
                    relPath: ev.relPath,
                    kind: ev.kind,
                    extensionLower: ev.metadata.extensionLower,
                    contentHash: ev.contentHash,
                    notePayload: ev.notePayload,
                    isRevision: ev.isRevision,
                    needsImageConvert: needsConvert
                ))
                selectedEvents.append(ev)
            }
            return CheckedDelivery(
                droppedIDs: droppedIDs,
                droppedPaths: droppedPaths,
                selectedEvents: selectedEvents,
                contentFiles: stagedFiles
            )
        }.value

        if !checked.droppedIDs.isEmpty,
           let freshIdx = self.store.ledger.folders.firstIndex(where: { $0.id == folder.id })
        {
            self.store.ledger.folders[freshIdx].pending.removeAll { checked.droppedIDs.contains($0.id) }
            for p in checked.droppedPaths {
                self.store.ledger.folders[freshIdx].files.removeValue(forKey: p)
            }
            self.store.save()
            self.bump()
            if checked.selectedEvents.isEmpty {
                return nil
            }
        }
        guard !checked.selectedEvents.isEmpty else { return nil }

        return FolderSegmentDelivery(
            folderID: folder.id,
            folderName: folder.name,
            facet: folder.facet?.name,
            kinds: folder.kinds,
            window: window,
            events: checked.selectedEvents,
            contentFiles: checked.contentFiles
        )
    }

    /// Record the journal's reply for a delivered five-minute segment.
    func recordOutcome(delivery: FolderSegmentDelivery, outcome: FolderDeliveryOutcome) {
        let nowMs = self.clock.nowMs()
        guard let idx = self.store.ledger.folders.firstIndex(where: { $0.id == delivery.folderID }) else { return }
        let ids = Set(delivery.events.map(\.id))

        switch outcome {
        case .delivered, .deliveredWithRefusedContent:
            let refusedPaths: Set<String>
            if case .deliveredWithRefusedContent(let paths) = outcome {
                refusedPaths = Set(paths)
                self.store.ledger.folders[idx].fallbackToDetails += paths.count
            } else {
                refusedPaths = []
            }
            var completedBackfill = 0
            var fallbackEvents: [FolderPendingEvent] = []
            let intakeDate = Date(timeIntervalSince1970: Double(nowMs) / 1_000.0)

            for ev in delivery.events {
                if refusedPaths.contains(ev.relPath) && ev.delivery == .content {
                    var metaOnly = ev
                    metaOnly.delivery = .metadataOnly
                    metaOnly.contentHash = nil
                    metaOnly.notePayload = nil
                    metaOnly.retryAtMs = nil
                    fallbackEvents.append(metaOnly)
                    continue
                }
                if ev.backfill {
                    completedBackfill += 1
                }
                self.store.ledger.folders[idx].itemsTakenIn += 1
                self.store.ledger.folders[idx].lastTakenInMs = nowMs
                self.intake?.recordFolderItem(eventID: ev.id, now: intakeDate)

                if var tracked = self.store.ledger.folders[idx].files[ev.relPath] {
                    tracked.deliveredToJournal = true
                    if let hash = ev.contentHash {
                        tracked.lastSentHash = hash
                    }
                    if ev.kind == .note && ev.delivery == .content, let noteText = ev.notePayload {
                        tracked.lastNoteText = noteText
                    }
                    self.store.ledger.folders[idx].files[ev.relPath] = tracked
                }
            }

            self.store.ledger.folders[idx].pending.removeAll { ids.contains($0.id) }
            self.store.ledger.folders[idx].pending.append(contentsOf: fallbackEvents)
            if completedBackfill > 0 {
                self.store.ledger.folders[idx].backfillDone += completedBackfill
                let remainingBackfill = self.store.ledger.folders[idx].pending.contains { $0.backfill }
                if !remainingBackfill {
                    self.store.ledger.folders[idx].backfillTotal = 0
                    self.store.ledger.folders[idx].backfillDone = 0
                }
            }

        case .allFilesRefused(let paths):
            let refusedSet = Set(paths)
            var converted = 0
            for i in self.store.ledger.folders[idx].pending.indices {
                let ev = self.store.ledger.folders[idx].pending[i]
                guard ids.contains(ev.id) else { continue }
                if ev.delivery == .content && (refusedSet.isEmpty || refusedSet.contains(ev.relPath)) {
                    self.store.ledger.folders[idx].pending[i].delivery = .metadataOnly
                    self.store.ledger.folders[idx].pending[i].contentHash = nil
                    self.store.ledger.folders[idx].pending[i].notePayload = nil
                    self.store.ledger.folders[idx].pending[i].retryAtMs = nil
                    converted += 1
                }
            }
            if converted > 0 {
                self.store.ledger.folders[idx].fallbackToDetails += converted
            } else {
                // Already metadata-only and still refused: drop to avoid looping.
                self.store.ledger.folders[idx].pending.removeAll { ids.contains($0.id) }
            }

        case .invalidPermanent:
            self.store.ledger.folders[idx].pending.removeAll { ids.contains($0.id) }

        case .hold:
            for i in self.store.ledger.folders[idx].pending.indices {
                if ids.contains(self.store.ledger.folders[idx].pending[i].id) {
                    let step = min(self.store.ledger.folders[idx].pending[i].tries, FolderConstants.retryMs.count - 1)
                    self.store.ledger.folders[idx].pending[i].tries += 1
                    self.store.ledger.folders[idx].pending[i].retryAtMs = nowMs + FolderConstants.retryMs[step]
                }
            }
        }

        self.store.save()
        self.bump()
    }

    /// Drain all ready closed five-minute segments when paired and journal advertises `"folder"`.
    func drainPending() async {
        if self.isDraining || self.isScanning {
            self.drainRequestedAgain = true
            return
        }
        self.isDraining = true
        defer {
            self.isDraining = false
        }

        repeat {
            self.drainRequestedAgain = false
            guard self.isPaired else { break }
            if self.capabilityListed != true {
                if let cap = await self.transport.checkCapability() {
                    self.capabilityListed = cap
                    self.bump()
                    if cap, let remoteSupported = await self.transport.fetchSupported() {
                        self.supported = remoteSupported
                    }
                }
            }
            guard self.capabilityListed == true else { break }

            var deliveredAny = 0
            while !Task.isCancelled && deliveredAny < 200 {
                guard let delivery = await self.nextDelivery() else { break }
                guard let folder = self.store.ledger.folders.first(where: { $0.id == delivery.folderID }) else { break }
                let bookmark = folder.bookmarkData
                let fallbackPath = folder.canonicalPath
                let fs = self.fileSystem
                let supported = self.supported

                self.inFlightCount = 1
                self.bump()
                let outcome = await self.transport.uploadSegment(
                    delivery,
                    supported: supported,
                    readContent: { staged in
                        try? fs.readFile(
                            bookmarkData: bookmark,
                            fallbackPath: fallbackPath,
                            relPath: staged.relPath,
                            maxBytes: supported.maxContentBytes
                        )
                    }
                )
                self.inFlightCount = 0
                self.recordOutcome(delivery: delivery, outcome: outcome)
                if case .hold = outcome {
                    break
                }
                deliveredAny += 1
            }
        } while self.drainRequestedAgain && !Task.isCancelled

        self.isDraining = false
        if self.scanRequestedAgain && !Task.isCancelled {
            self.scanRequestedAgain = false
            await self.scanAll()
        }
    }

    private func bump() {
        self.revision &+= 1
    }

#if DEBUG
    /// Deterministic UI test state seeding (uses temporary directories so live scans succeed).
    func applyUITestState(_ mode: String) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstone-ui-test-folders", isDirectory: true)
        switch mode {
        case "populated":
            let dir1 = base.appendingPathComponent("reading-pdfs", isDirectory: true)
            let dir2 = base.appendingPathComponent("meeting-notes", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
            self.store.ledger.folders = [
                FolderRecord(
                    id: "reading-pdfs-11111111",
                    name: "reading-pdfs",
                    displayLabel: "reading-pdfs",
                    bookmarkData: nil,
                    canonicalPath: dir1.path,
                    mode: .on,
                    returning: true,
                    kinds: .allOn,
                    facet: FolderFacet(name: "side-projects", title: "side projects", color: "#9A5B25"),
                    itemsTakenIn: 34,
                    lastTakenInMs: self.clock.nowMs() - 12 * 60 * 1_000,
                    lastCheckedMs: self.clock.nowMs() - 60 * 1_000
                ),
                FolderRecord(
                    id: "meeting-notes-22222222",
                    name: "meeting-notes",
                    displayLabel: "meeting-notes",
                    bookmarkData: nil,
                    canonicalPath: dir2.path,
                    mode: .paused,
                    returning: true,
                    kinds: .allOn,
                    facet: FolderFacet(name: "work", title: "work", color: "#2E6F9E"),
                    itemsTakenIn: 19,
                    lastTakenInMs: self.clock.nowMs() - 24 * 60 * 60 * 1_000,
                    lastCheckedMs: self.clock.nowMs() - 2 * 60 * 1_000
                ),
            ]
            self.capabilityListed = true
            self.facets = [
                FolderFacet(name: "side-projects", title: "side projects", color: "#9A5B25"),
                FolderFacet(name: "work", title: "work", color: "#2E6F9E"),
            ]
            self.facetsAvailability = .ready
            self.bump()
        case "attention":
            self.store.ledger.folders = [
                FolderRecord(
                    id: "field-docs-33333333",
                    name: "field-docs",
                    displayLabel: "field-docs",
                    bookmarkData: nil,
                    canonicalPath: base.appendingPathComponent("missing-field-docs", isDirectory: true).path,
                    mode: .on,
                    returning: true,
                    kinds: .allOn,
                    attention: .bookmarkInvalid
                ),
            ]
            self.capabilityListed = true
            self.bump()
        default:
            break
        }
    }
#endif
}
