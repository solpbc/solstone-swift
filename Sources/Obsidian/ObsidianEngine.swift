// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import CryptoKit
import Observation
import os

nonisolated private let obsidianEngineLog = Logger(subsystem: "app.solstone.swift", category: "obsidian")

@MainActor
protocol ObsidianEngineControlling: AnyObject {
    var status: ObsidianSourceStatus { get }
    var wantsBackgroundRefresh: Bool { get }
    func turnOn() async
    func turnOff()
    func pause()
    func resume()
    func checkNow() async
    func chooseVault(url: URL) async -> Result<Void, ObsidianLocationRefusal>
    func backgroundRefresh() async -> Bool
    func launch() async
    func isAcceptedForSameName(vaultID: String) -> Bool
    func markSameNameAccepted(vaultID: String) -> Bool
}

nonisolated struct ObsidianSourceStatus: Equatable, Sendable {
    enum AttentionReason: Equatable, Sendable {
        case accessLost
        case privateStoreFault
        case privateSaveFault
        case incompleteScan
        case custom(String)

        var sentence: String {
            switch self {
            case .accessLost: ObsidianVocabulary.ACCESS_LOST
            case .privateStoreFault: ObsidianVocabulary.PRIVATE_STORE_FAULT
            case .privateSaveFault: ObsidianVocabulary.PRIVATE_SAVE_FAULT
            case .incompleteScan: ObsidianVocabulary.INCOMPLETE_SCAN
            case .custom(let s): s
            }
        }
    }

    var selectedVaultID: String?
    var vaultName: String?
    var isEnabled: Bool = false
    var isPaused: Bool = false
    var isScanning: Bool = false
    var isEnrolling: Bool = false
    var attention: AttentionReason?
    var lastChecked: Date?
    var unavailableCount: Int = 0
    var tooLargeCount: Int = 0
    var hasHeldEarlierVault: Bool = false
    var totalFoundNotes: Int = 0
    var deliveredNotesCount: Int = 0
    var pendingAndQueuedNotes: Int = 0

    var tileState: SourceState {
        if self.attention != nil { return .needsAttention }
        if self.selectedVaultID == nil { return .readyToSetUp }
        if self.isEnrolling { return .enrolling }
        if !self.isEnabled { return .off }
        if self.isScanning { return .checking }
        if self.isPaused { return .paused }
        return .active
    }
}

@MainActor
@Observable
final class ObsidianSourceEngine: ObsidianEngineControlling {
    let store: ObsidianStore
    let intakeStore: SourceIntakeStore?
    var delivery: (any ObsidianNoteDelivering)?

    private var statusValue = ObsidianSourceStatus()
    private var deliveredCount = 0
    /// Progress is the journal paired now's. With none paired there is nothing to count.
    var isPairedProvider: (@MainActor () -> Bool)?
    var status: ObsidianSourceStatus {
        var presentation = self.statusValue
        presentation.deliveredNotesCount = self.isPairedProvider?() == true ? self.deliveredCount : 0
        return presentation
    }
    private var isScanning = false
    private var isClosingWindows = false
    private var currentPacking: Task<ObsidianPackedWindows, Error>?
    private var currentWalk: Task<ObsidianScopedWalk, Error>?
    private var activeLoop: Task<Void, Never>?
    private var appIsActive = false
    private var isResolvingBookmark = false
    private var lastScanEndedAt: Date?
    private var lastScanDuration: TimeInterval = 0
    var incompleteScanOccurred = false
    private var accessLostOccurred = false
    private var persistenceFailed = false

    /// TimeZone and clock provider
    var timeZone: TimeZone = .autoupdatingCurrent
    var clock: @Sendable () -> Date = Date.init
    var documentIdentifierProvider: (@Sendable (URL) -> Int?)? = nil
    var transferSnapshots: [TransferItemSnapshot] = []
    var testAfterWalkBeforeGenerationCheck: (@MainActor () -> Void)? = nil
    var testAfterPreparingCheckpoint: (@MainActor () -> Void)? = nil

    init(
        store: ObsidianStore,
        intakeStore: SourceIntakeStore? = nil,
        delivery: (any ObsidianNoteDelivering)? = nil
    ) {
        self.store = store
        self.intakeStore = intakeStore
        self.delivery = delivery
        self.replayOnLaunch()
        self.refreshStatus()
    }

    var wantsBackgroundRefresh: Bool {
        self.store.isLoaded && !self.persistenceFailed && self.store.document.enabled && self.store.document.selectedVaultID != nil
    }

    var canDeliver: Bool { self.store.isLoaded && !self.persistenceFailed && self.store.document.enabled }

    func chooseVault(url: URL) async -> Result<Void, ObsidianLocationRefusal> {
        await self.chooseVault(url: url, resources: nil)
    }

    func chooseVault(url: URL, resources: ObsidianLocationResources? = nil) async -> Result<Void, ObsidianLocationRefusal> {
        guard self.store.isLoaded, !self.store.hasFault else {
            return .failure(.invalidFolder(sentence: ObsidianVocabulary.PRIVATE_STORE_FAULT))
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let validation = ObsidianLocationValidator.validate(url: url, resources: resources)
        switch validation {
        case .failure(let refusal):
            return .failure(refusal)
        case .success:
            break
        }

        self.isResolvingBookmark = true
        defer { self.isResolvingBookmark = false; self.refreshStatus() }
        self.refreshStatus()

        // Create security-scoped bookmark
        let bookmarkData: Data?
        do {
            bookmarkData = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            return .failure(.invalidFolder(sentence: ObsidianVocabulary.ACCESS_LOST))
        }

        let folderName = url.lastPathComponent
        let rootDocID = ObsidianVaultWalker.readDocumentIdentifier(url: url, provider: self.documentIdentifierProvider)

        // Find existing vault by root documentIdentifier ONLY. Never restore by folder name.
        var chosenVaultID: String?
        if let rootDocID {
            for (vid, vault) in self.store.document.vaults {
                if vault.rootDocumentIdentifier == rootDocID {
                    chosenVaultID = vid
                    break
                }
            }
        }
        let finalVaultID = chosenVaultID ?? UUID().uuidString

        var vaultState = self.store.document.vaults[finalVaultID] ?? ObsidianVaultState(
            id: finalVaultID,
            folderName: folderName,
            bookmarkData: bookmarkData,
            rootDocumentIdentifier: rootDocID
        )
        vaultState.folderName = folderName
        vaultState.bookmarkData = bookmarkData
        vaultState.rootDocumentIdentifier = rootDocID

        let prevDoc = self.store.document

        self.store.document.vaults[finalVaultID] = vaultState
        self.store.document.selectedVaultID = finalVaultID
        self.store.document.generation &+= 1
        self.accessLostOccurred = false
        self.incompleteScanOccurred = false
        self.isResolvingBookmark = false

        do {
            try self.store.save()
        } catch {
            self.store.document = prevDoc
            obsidianEngineLog.error("failed saving chosen vault: \(String(describing: error), privacy: .public)")
            self.refreshStatus()
            return .failure(.invalidFolder(sentence: ObsidianVocabulary.PRIVATE_SAVE_FAULT))
        }

        self.refreshStatus()
        return .success(())
    }

    func turnOn() async {
        guard self.store.isLoaded, self.store.document.selectedVaultID != nil else { return }
        self.store.document.enabled = true
        self.store.document.paused = false
        self.store.document.generation &+= 1
        self.saveControlState()
        self.refreshStatus()
        await self.scanIfPossible()
        self.ensureActiveLoop()
    }

    func turnOff() {
        self.currentWalk?.cancel()
        self.currentPacking?.cancel()
        self.activeLoop?.cancel()
        self.activeLoop = nil
        guard self.store.isLoaded else { return }
        self.store.document.enabled = false
        self.store.document.generation &+= 1
        self.saveControlState()
        self.refreshStatus()
    }

    func pause() {
        guard self.store.isLoaded, self.store.document.enabled else { return }
        self.store.document.paused = true
        self.saveControlState()
        self.refreshStatus()
    }

    func resume() {
        guard self.store.isLoaded, self.store.document.enabled else { return }
        self.store.document.paused = false
        self.saveControlState()
        self.refreshStatus()
        Task {
            await self.closeDueWindowsAndDeliver()
        }
    }

    func checkNow() async {
        guard self.store.isLoaded, self.store.document.enabled else { return }
        if self.persistenceFailed { self.saveControlState() }
        guard !self.persistenceFailed else { return }
        self.replayOnLaunch()
        await self.scanIfPossible()
    }

    func backgroundRefresh() async -> Bool {
        guard self.wantsBackgroundRefresh else { return true }
        await self.scanIfPossible()
        return !self.incompleteScanOccurred && !Task.isCancelled
    }

    func launch() async {
        self.replayOnLaunch()
        await self.closeDueWindowsAndDeliver()
        if self.store.document.enabled {
            await self.scanIfPossible()
        }
    }

    /// A new pairing: the next scan sends every vault's current notes once, after the same-name
    /// check, with nothing chosen again. On, off and paused stay as the owner left them, and the
    /// outbox and open windows still go, to the journal paired now. Saved before it returns.
    func restartFirstSetup() {
        guard self.store.isLoaded else { return }
        for vaultID in self.store.document.vaults.keys {
            self.store.document.vaults[vaultID]?.restartFirstSetup()
        }
        // Fences any walk, packing or checkpoint that started against the earlier record.
        self.store.document.generation &+= 1
        self.saveControlState()
        self.refreshStatus()
        guard self.store.document.enabled else { return }
        Task { await self.scanIfPossible() }
    }

    private func saveControlState() {
        do { try self.store.save(); self.persistenceFailed = false }
        catch {
            self.persistenceFailed = true
            self.currentWalk?.cancel()
            self.currentPacking?.cancel()
            self.activeLoop?.cancel(); self.activeLoop = nil
        }
    }

    func setAppActive(_ active: Bool) {
        self.appIsActive = active
        if !active {
            // Also fences a manual check whose worker completed just before
            // cancellation, while allowing a later system background scan.
            self.store.document.generation &+= 1
            self.currentWalk?.cancel()
            self.currentPacking?.cancel()
            self.activeLoop?.cancel()
            self.activeLoop = nil
            return
        }
        self.ensureActiveLoop()
    }

    private func ensureActiveLoop() {
        guard self.appIsActive, self.store.document.enabled, self.activeLoop == nil else { return }
        self.activeLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.appIsActive, self.store.document.enabled else { return }
                let interval = self.lastScanDuration > 0.6 ? min(900, self.lastScanDuration * 100) : 60
                let nextScan = self.lastScanEndedAt?.addingTimeInterval(interval) ?? self.clock()
                if self.clock() >= nextScan {
                    await self.scanIfPossible()
                } else {
                    await self.closeDueWindowsAndDeliver()
                }
                let now = self.clock()
                let followingScan = self.lastScanEndedAt?.addingTimeInterval(ObsidianWire.scanInterval(afterScanTaking: self.lastScanDuration)) ?? now.addingTimeInterval(60)
                var nextWake = max(followingScan, now.addingTimeInterval(1))
                if !self.store.document.paused,
                   let vault = self.store.selectedVault {
                    let due = vault.pendingChanges.compactMap { change in
                        ObsidianWindow(key: change.windowKey)?.closeDate(offsetSeconds: change.changedAt.offsetSeconds)
                    }.min()
                    if let due {
                        // A failed close gets a paced retry, never a tight loop.
                        nextWake = min(nextWake, due > now ? due : now.addingTimeInterval(60))
                    }
                }
                do { try await Task.sleep(for: .seconds(max(1, nextWake.timeIntervalSince(now)))) }
                catch { return }
            }
        }
    }

    func isAcceptedForSameName(vaultID: String) -> Bool {
        self.store.document.vaults[vaultID]?.sameNameChecked == true
    }

    func markSameNameAccepted(vaultID: String) -> Bool {
        guard self.store.isLoaded, var vault = self.store.document.vaults[vaultID] else { return false }
        if vault.sameNameChecked { return true }
        let previous = vault
        vault.sameNameChecked = true
        self.store.document.vaults[vaultID] = vault
        do { try self.store.save(); return true }
        catch {
            self.store.document.vaults[vaultID] = previous
            self.persistenceFailed = true; self.refreshStatus()
            return false
        }
    }

    // MARK: - Scan Orchestration

    func scanIfPossible() async {
        guard !self.isScanning, !self.isClosingWindows, !self.persistenceFailed,
              self.store.isLoaded, self.store.document.enabled,
              let vaultID = self.store.document.selectedVaultID,
              let vault = self.store.document.vaults[vaultID],
              let bookmarkData = vault.bookmarkData
        else {
            return
        }

        self.isScanning = true
        self.refreshStatus()
        defer {
            self.isScanning = false
            self.refreshStatus()
        }

        let generation = self.store.document.generation
        var previous: [String: (mtimeMs: Int64, size: Int64, contentHash: String, text: String)] = [:]
        for (path, record) in vault.table where record.contentIsCurrent {
            previous[path] = (record.mtimeMs, record.sizeBytes, record.contentHash, record.text)
        }
        let documentIdentifierProvider = self.documentIdentifierProvider
        let clock = self.clock
        let zone = self.timeZone
        let worker = Task.detached(priority: .utility) {
            var walked = try ObsidianVaultWalker.scopedWalk(bookmarkData: bookmarkData,
                previousTable: previous, documentIdentifierProvider: documentIdentifierProvider)
            walked.plannedVault = try ObsidianComparison.reduce(vault, snapshot: walked.snapshot,
                observed: ObsidianStamp(date: clock(), timeZone: zone))
            return walked
        }
        self.currentWalk = worker
        defer { self.currentWalk = nil }
        let scopedWalk: ObsidianScopedWalk
        do {
            scopedWalk = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
        } catch is CancellationError {
            return
        } catch ObsidianWalkError.cancelled {
            return
        } catch {
            guard self.store.document.generation == generation else { return }
            if (error as NSError).code == CocoaError.fileReadNoPermission.rawValue {
                self.accessLostOccurred = true
            } else {
                self.incompleteScanOccurred = true
            }
            return
        }
        let walkSnapshot = scopedWalk.snapshot

        // Test hook: invoked after the walk returns and before the generation check
        self.testAfterWalkBeforeGenerationCheck?()

        // Generation and vault check: Off, reselection, and replacement drop late results.
        // A cancelled scan leaves the last committed state and does not publish.
        guard self.store.document.generation == generation,
              self.store.document.selectedVaultID == vaultID,
              !Task.isCancelled
        else {
            return
        }

        guard var planned = scopedWalk.plannedVault else { return }
        if let bookmark = scopedWalk.refreshedBookmark { planned.bookmarkData = bookmark }
        guard await self.commitPlannedVault(planned, vaultID: vaultID, generation: generation) else { return }
        self.accessLostOccurred = false
        self.persistenceFailed = false
        self.incompleteScanOccurred = false
        self.lastScanDuration = walkSnapshot.duration
        self.lastScanEndedAt = self.clock()
        self.replayOnLaunch()
        self.isScanning = false
        if !self.store.document.paused { await self.closeDueWindowsAndDeliver() }
    }

    private func commitPlannedVault(_ plan: ObsidianVaultState, vaultID: String, generation: UInt64, requiresUnpaused: Bool = false) async -> Bool {
        while !Task.isCancelled {
            guard self.store.isLoaded, !self.persistenceFailed, self.store.document.enabled,
                  !requiresUnpaused || !self.store.document.paused,
                  self.store.document.generation == generation,
                  self.store.document.selectedVaultID == vaultID,
                  let current = self.store.document.vaults[vaultID] else { return false }
            let revision = self.store.revision
            var candidate = self.store.document
            var merged = plan
            merged.deliveredNotes = current.deliveredNotes
            merged.sameNameChecked = current.sameNameChecked
            candidate.vaults[vaultID] = merged
            let prepared: ObsidianPreparedCheckpoint
            do {
                try self.store.ensureDirectories()
                let root = self.store.rootURL
                let writer = Task.detached(priority: .utility) { try ObsidianStore.prepare(candidate, rootURL: root) }
                prepared = try await withTaskCancellationHandler { try await writer.value } onCancel: { writer.cancel() }
            } catch is CancellationError { return false }
            catch { self.persistenceFailed = true; self.refreshStatus(); return false }
            defer { try? FileManager.default.removeItem(at: prepared.temporaryURL) }
            self.testAfterPreparingCheckpoint?()
            guard !Task.isCancelled, !self.persistenceFailed,
                  !requiresUnpaused || !self.store.document.paused,
                  self.store.document.generation == generation,
                  self.store.document.selectedVaultID == vaultID,
                  self.store.document.enabled else { return false }
            // An acknowledgement or admission committed while encoding. Merge
            // its fresh fields and prepare again rather than overwriting it.
            guard self.store.revision == revision else { continue }
            do { try self.store.commitPrepared(prepared); return true }
            catch { self.persistenceFailed = true; self.refreshStatus(); return false }
        }
        return false
    }

    // Counter effects are replayed only from a committed source checkpoint.
    private func replayOnLaunch() {
        guard self.store.isLoaded, let intakeStore = self.intakeStore else { return }
        for vaultID in self.store.document.vaults.keys.sorted() {
            guard var vault = self.store.document.vaults[vaultID] else { continue }
            let previous = vault
            var applied = 0
            for operation in vault.unappliedIntakeOps {
                let result = intakeStore.applyObsidianOperation(vaultID: vaultID, operation: operation)
                guard result == .recorded || result == .unchanged else { break }
                applied += 1
            }
            guard applied > 0 else { continue }
            vault.unappliedIntakeOps.removeFirst(applied)
            self.store.document.vaults[vaultID] = vault
            do { try self.store.save() }
            catch { self.store.document.vaults[vaultID] = previous; self.persistenceFailed = true }
        }
    }

    func recordDelivered(manifest: TransferManifest, successKind: TransferSuccessKind) async {
        do { try await self.commitDelivered(manifest: manifest, successKind: successKind) }
        catch { self.persistenceFailed = true; self.refreshStatus() }
    }

    func commitDelivered(manifest: TransferManifest, successKind: TransferSuccessKind) async throws {
        if successKind == .removedInJournal { return }
        guard manifest.sourceKey == ObsidianTransfer.sourceKey,
              let vaultID = ObsidianTransfer.vaultID(from: manifest) else { throw CocoaError(.fileWriteUnknown) }
        let identities = ObsidianTransfer.noteIdentities(from: manifest)
        guard !identities.isEmpty else { return }
        while !Task.isCancelled {
            guard self.store.isLoaded, var vault = self.store.document.vaults[vaultID] else { throw CocoaError(.fileWriteUnknown) }
            guard !vault.deliveredNotes.isSuperset(of: identities) else { return }
            vault.deliveredNotes.formUnion(identities)
            let revision = self.store.revision
            var candidate = self.store.document
            candidate.vaults[vaultID] = vault
            try self.store.ensureDirectories()
            let root = self.store.rootURL
            let writer = Task.detached(priority: .utility) { try ObsidianStore.prepare(candidate, rootURL: root) }
            let prepared = try await withTaskCancellationHandler { try await writer.value } onCancel: { writer.cancel() }
            defer { try? FileManager.default.removeItem(at: prepared.temporaryURL) }
            try Task.checkCancellation()
            guard self.store.revision == revision else { continue }
            try self.store.commitPrepared(prepared)
            self.persistenceFailed = false
            self.refreshStatus()
            return
        }
        throw CancellationError()
    }

    // MARK: - Window Closing & Outbox Delivery

    func closeDueWindowsAndDeliver() async {
        guard self.store.isLoaded, !self.persistenceFailed,
              self.store.document.enabled,
              !self.store.document.paused,
              !self.isClosingWindows, !self.isScanning,
              let vaultID = self.store.document.selectedVaultID,
              var vault = self.store.document.vaults[vaultID]
        else {
            return
        }
        self.isClosingWindows = true
        defer { self.isClosingWindows = false }
        let generation = self.store.document.generation
        let now = self.clock()

        do {
            try self.store.ensureDirectories()
            let directory = self.store.outboxDirectoryURL
            let input = vault
            let packer = Task.detached(priority: .utility) { try ObsidianWindowPacker.pack(input, now: now, directory: directory) }
            self.currentPacking = packer
            defer { self.currentPacking = nil }
            let packed = try await withTaskCancellationHandler { try await packer.value } onCancel: { packer.cancel() }
            if packed.changed {
                guard await self.commitPlannedVault(packed.vault, vaultID: vaultID, generation: generation, requiresUnpaused: true) else { return }
            }
            guard self.store.document.generation == generation,
                  let fresh = self.store.document.vaults[vaultID] else { return }
            vault = fresh
        } catch is CancellationError { return }
        catch {
            self.persistenceFailed = true; self.refreshStatus()
            return
        }

        // Adoption can suspend while scans, controls and acknowledgements commit.
        // Remove only the adopted record from a fresh vault value, after verifying
        // this is still the selected enabled generation. Producer bytes go last.
        if let delivery = self.delivery {
            let items = vault.outboxItems.sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.filename < $1.filename
            }
            for item in items {
                guard self.store.document.generation == generation,
                      self.store.document.selectedVaultID == vaultID,
                      self.store.document.enabled, !self.store.document.paused
                else { break }
                do {
                    let fileURL = self.store.outboxDirectoryURL.appendingPathComponent("\(item.itemID.uuidString).jsonl")
                    let outcome = try await delivery.deliver(item: item, fileURL: fileURL)
                    guard outcome == .enqueued || outcome == .alreadyPresent else { continue }
                    self.transferSnapshots = await delivery.itemSnapshots()
                    guard self.store.document.generation == generation,
                          self.store.document.selectedVaultID == vaultID,
                          self.store.document.enabled, !self.store.document.paused,
                          var current = self.store.document.vaults[vaultID]
                    else { break }
                    current.outboxItems.removeAll { $0.itemID == item.itemID }
                    guard await self.commitPlannedVault(current, vaultID: vaultID, generation: generation, requiresUnpaused: true) else { break }
                    self.store.removeOutboxPayload(itemID: item.itemID)
                } catch {
                    // An earlier window remains in the outbox; do not adopt a
                    // later window ahead of it on this pass.
                    break
                }
            }
        }

        self.refreshStatus()
    }

    func refreshStatus() {
        var status = ObsidianSourceStatus()
        self.deliveredCount = 0
        status.selectedVaultID = self.store.document.selectedVaultID
        status.isEnabled = self.store.document.enabled
        status.isPaused = self.store.document.paused
        status.isScanning = self.isScanning
        status.isEnrolling = self.isResolvingBookmark

        if self.store.hasFault {
            status.attention = .privateStoreFault
        } else if self.persistenceFailed {
            status.attention = .privateSaveFault
        } else if self.accessLostOccurred {
            status.attention = .accessLost
        } else if self.incompleteScanOccurred {
            status.attention = .incompleteScan
        }

        if let vaultID = self.store.document.selectedVaultID,
           let vault = self.store.document.vaults[vaultID]
        {
            status.vaultName = vault.folderName
            status.lastChecked = vault.lastChecked
            status.unavailableCount = vault.unavailableCount
            status.tooLargeCount = vault.tooLargeCount
            status.totalFoundNotes = vault.foundNotesCount
            self.deliveredCount = vault.deliveredNotes.intersection(vault.foundNoteIdentities).count
            let activeTransfers = self.transferSnapshots.filter { ObsidianTransfer.vaultID(from: $0.manifest) == vaultID }
            let adoptedIDs = Set(activeTransfers.map(\.itemID))
            status.pendingAndQueuedNotes = vault.pendingChanges.count
                + vault.outboxItems.filter { !adoptedIDs.contains($0.itemID) }.reduce(0) { $0 + $1.lineCount }
                + activeTransfers.reduce(0) { $0 + ObsidianTransfer.noteCount($1.manifest) }
            if activeTransfers.contains(where: { $0.state == .attention }), status.attention == nil {
                status.attention = .custom(ObsidianVocabulary.DELIVERY_ATTENTION)
            }
        }

        // Check if any earlier vault has held data
        var heldEarlier = false
        for (vid, vault) in self.store.document.vaults {
            if vid != self.store.document.selectedVaultID {
                if !vault.outboxItems.isEmpty || !vault.pendingChanges.isEmpty {
                    heldEarlier = true
                    break
                }
            }
        }
        status.hasHeldEarlierVault = heldEarlier || self.transferSnapshots.contains {
            ObsidianTransfer.vaultID(from: $0.manifest) != self.store.document.selectedVaultID
        }

        self.statusValue = status
    }
}
