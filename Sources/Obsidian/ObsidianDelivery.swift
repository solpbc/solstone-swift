// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

nonisolated private let obsidianDeliveryLog = Logger(subsystem: "app.solstone.swift", category: "obsidian")

nonisolated enum ObsidianTransfer {
    static let sourceKey = "obsidian"
    static let partID = "obsidian"
    static let contentType = "application/x-ndjson"
    static let capability = "obsidian_notes"

    static func manifest(for item: ObsidianOutboxItem) -> TransferManifest {
        var metaFields: [String: JSONValue] = [
            "vaultID": .string(item.vaultID),
            "folderName": .string(item.folderName),
            "notes": .int(item.lineCount)
        ]
        if !item.noteIdentityHashes.isEmpty {
            metaFields["noteIdentities"] = .array(item.noteIdentityHashes.map { .string($0) })
        }
        return TransferManifest(
            itemID: item.itemID,
            source: Self.sourceKey,
            createdAt: item.createdAt,
            priority: TransferPriorityInputs(basePriority: .low, sourceKey: Self.sourceKey),
            payloadParts: [
                TransferPayloadPartDescriptor(
                    partID: Self.partID,
                    kind: .file,
                    relativePath: item.filename,
                    filename: item.filename,
                    contentType: Self.contentType,
                    byteCount: item.byteCount,
                    contentHash: item.sha256Hex
                )
            ],
            endpoint: TransferEndpointDescriptor(destinationKind: .observerIngest, path: "/app/devices/ingest"),
            observerIngest: TransferObserverIngestMetadata(
                platform: "ios",
                segment: item.window.segment,
                day: item.window.day,
                startedAt: item.createdAt,
                durationS: TimeInterval(ObsidianWire.windowSeconds),
                sources: [Self.sourceKey],
                ingestProtocolVersion: 3,
                tz: item.timeZoneIdentifier,
                utcOffsetSeconds: Int(item.offsetSeconds)
            ),
            meta: .object(metaFields),
            appVersion: AppVersion.shortVersion
        )
    }

    static func noteIdentities(from manifest: TransferManifest) -> [String] {
        if case .object(let fields) = manifest.meta,
           case .array(let arr) = fields["noteIdentities"] {
            return arr.compactMap {
                if case .string(let s) = $0 { return s }
                return nil
            }
        }
        return []
    }

    static func vaultID(from manifest: TransferManifest) -> String? {
        if case .object(let fields) = manifest.meta {
            if case .string(let id) = fields["vaultID"] { return id }
            if case .string(let id) = fields["vault_id"] { return id }
            if case .string(let id) = fields["vaultId"] { return id }
        }
        return nil
    }

    static func folderName(from manifest: TransferManifest) -> String? {
        if case .object(let fields) = manifest.meta {
            if case .string(let name) = fields["folderName"] { return name }
            if case .string(let name) = fields["folder_name"] { return name }
        }
        return nil
    }

    static func isLaneHeld(from manifest: TransferManifest) -> Bool {
        if case .object(let fields) = manifest.meta,
           case .bool(let held) = fields["laneHold"] {
            return held
        }
        return false
    }

    static func noteCount(_ manifest: TransferManifest) -> Int {
        if case .object(let fields) = manifest.meta, case .int(let count) = fields["notes"] {
            return count
        }
        return 0
    }
}

@MainActor
protocol ObsidianNoteDelivering: AnyObject {
    func deliver(item: ObsidianOutboxItem, fileURL: URL) async throws -> TransferEnqueueIfAbsentOutcome
    func queuedFileCount() async -> Int
    func itemSnapshots() async -> [TransferItemSnapshot]
}

extension ObsidianNoteDelivering {
    func itemSnapshots() async -> [TransferItemSnapshot] { [] }
}

@MainActor
final class ObsidianTransferDelivery: ObsidianNoteDelivering {
    private let engine: TransferEngine
    init(engine: TransferEngine) {
        self.engine = engine
    }

    func deliver(item: ObsidianOutboxItem, fileURL: URL) async throws -> TransferEnqueueIfAbsentOutcome {
        let manifest = ObsidianTransfer.manifest(for: item)
        // Transfer consumes file-URL inputs. Keep the producer's copy until its
        // adoption record has committed, including across a process interruption.
        let stagingURL = try await Task.detached(priority: .utility) {
            let stagingURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("obsidian-adopt-\(UUID().uuidString).jsonl")
            try FileManager.default.copyItem(at: fileURL, to: stagingURL)
            return stagingURL
        }.value
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        return try await self.engine.enqueueIfAbsent(
            manifest: manifest,
            payloadFileURLs: [ObsidianTransfer.partID: stagingURL]
        )
    }

    func queuedFileCount() async -> Int {
        await self.engine.itemSnapshots(sourceKey: ObsidianTransfer.sourceKey)
            .filter { $0.state != .attention }
            .count
    }

    func itemSnapshots() async -> [TransferItemSnapshot] {
        await self.engine.itemSnapshots(sourceKey: ObsidianTransfer.sourceKey)
    }
}

nonisolated struct ObsidianSameNameAdvisory: Equatable, Sendable {
    var vault: String
    var device: String?
    var lastSyncedAt: String?
}

/// Capability and same-name gate for Obsidian.
actor ObsidianCapabilityGate: TransferSourceGate {
    nonisolated enum Capability: Equatable, Sendable {
        case unknown
        case listed
        case notListed
    }

    private let readStatus: @Sendable (TransferResolvedEndpoint) async -> JournalStatusReport
    private let fetchVaults: @Sendable (TransferResolvedEndpoint) async -> [ObsidianSameNameAdvisory]?
    private let isCurrent: @Sendable (TransferResolvedEndpoint) async -> Bool
    private let retryDelay: Duration

    private var wake: (@Sendable () async -> Void)?
    private var publishCapability: (@Sendable (Capability) -> Void)?
    private var publishAdvisory: (@Sendable (ObsidianSameNameAdvisory?) -> Void)?

    private var endpoint: TransferResolvedEndpoint?
    private var capability: Capability = .unknown
    private var generation: UInt64 = 0
    private var admissionIdentity = UUID().uuidString
    private var readingStatus = false
    private var fetchingSameName = false
    private var retryScheduled = false
    private var journal: (identity: String?, version: String?) = (nil, nil)

    /// State check providers supplied by engine / app
    private var isSourceEnabled: (@Sendable () async -> Bool)?
    private var isSourcePaused: (@Sendable () async -> Bool)?
    private var activeVaultID: (@Sendable () async -> String?)?
    private var isAcceptedForSameName: (@Sendable (String, String) async -> Bool)?
    private var recordAcceptance: (@Sendable (String, String) async -> Bool)?
    private var turnSourceOff: (@Sendable () async -> Void)?

    private var pendingAdvisory: ObsidianSameNameAdvisory?
    private var pendingAdvisoryVaultID: String?
    private var activeVaultContext: String?

    init(
        readStatus: @escaping @Sendable (TransferResolvedEndpoint) async -> JournalStatusReport,
        fetchVaults: @escaping @Sendable (TransferResolvedEndpoint) async -> [ObsidianSameNameAdvisory]? = { _ in nil },
        isCurrent: @escaping @Sendable (TransferResolvedEndpoint) async -> Bool = { _ in true },
        retryDelay: Duration = .seconds(30)
    ) {
        self.readStatus = readStatus
        self.fetchVaults = fetchVaults
        self.isCurrent = isCurrent
        self.retryDelay = retryDelay
    }

    func configure(
        isSourceEnabled: @escaping @Sendable () async -> Bool,
        isSourcePaused: @escaping @Sendable () async -> Bool,
        activeVaultID: @escaping @Sendable () async -> String?,
        isAcceptedForSameName: @escaping @Sendable (String, String) async -> Bool,
        recordAcceptance: @escaping @Sendable (String, String) async -> Bool = { _, _ in false },
        turnSourceOff: @escaping @Sendable () async -> Void = {},
        wake: @escaping @Sendable () async -> Void,
        publishCapability: @escaping @Sendable (Capability) -> Void,
        publishAdvisory: @escaping @Sendable (ObsidianSameNameAdvisory?) -> Void
    ) {
        self.isSourceEnabled = isSourceEnabled
        self.isSourcePaused = isSourcePaused
        self.activeVaultID = activeVaultID
        self.isAcceptedForSameName = isAcceptedForSameName
        self.recordAcceptance = recordAcceptance
        self.turnSourceOff = turnSourceOff
        self.wake = wake
        self.publishCapability = publishCapability
        self.publishAdvisory = publishAdvisory
    }

    private func endpointID(for endpoint: TransferResolvedEndpoint) -> String {
        // Acceptance never survives an endpoint, pairing, version or gate reset.
        // A recycled loopback port is not a journal identity.
        self.admissionIdentity
    }

    func continueSameName() async {
        guard self.pendingAdvisory != nil,
              let endpoint = self.endpoint,
              let vaultID = self.pendingAdvisoryVaultID
        else { return }
        let generation = self.generation
        let acceptance = self.admissionIdentity
        guard await self.isCurrent(endpoint),
              self.generation == generation, self.endpoint == endpoint,
              await self.activeVaultID?() == vaultID
        else { return }
        // Store the captured generation's token. A concurrent reset cannot make
        // this acceptance authorize the replacement journal.
        guard await self.recordAcceptance?(vaultID, acceptance) == true,
              self.generation == generation else { return }
        self.pendingAdvisory = nil
        self.pendingAdvisoryVaultID = nil
        self.publishAdvisory?(nil)
        await self.wake?()
    }

    func cancelSameName() async {
        self.pendingAdvisory = nil
        self.pendingAdvisoryVaultID = nil
        self.publishAdvisory?(nil)
        await self.turnSourceOff?()
    }

    var currentCapability: Capability {
        self.capability
    }

    var currentAdvisory: ObsidianSameNameAdvisory? {
        self.pendingAdvisory
    }

    func admits(manifest: TransferManifest, endpoint: TransferResolvedEndpoint) async -> Bool {
        guard manifest.sourceKey == ObsidianTransfer.sourceKey else { return true }
        guard self.isSourceEnabled != nil, self.isSourcePaused != nil,
              self.activeVaultID != nil, self.isAcceptedForSameName != nil
        else { return false }

        if self.endpoint != endpoint {
            self.endpoint = endpoint
            self.reset()
        }

        // Check capability
        switch self.capability {
        case .listed:
            break
        case .notListed:
            return false
        case .unknown:
            self.startReadStatus()
            return false
        }

        // Re-check pause, off, current endpoint, same-name acceptance, and selected vault at dispatch
        if let isEnabled = await self.isSourceEnabled?(), !isEnabled { return false }
        if let isPaused = await self.isSourcePaused?(), isPaused { return false }

        guard let vaultID = ObsidianTransfer.vaultID(from: manifest) else { return false }
        let selectedID = await self.activeVaultID?()
        if self.activeVaultContext != selectedID {
            self.activeVaultContext = selectedID
            self.generation &+= 1
            self.fetchingSameName = false
            self.retryScheduled = false
            self.pendingAdvisory = nil
            self.pendingAdvisoryVaultID = nil
            self.publishAdvisory?(nil)
        }
        let currentGeneration = self.generation
        if selectedID != vaultID {
            // Inactive vault A does not block selected vault B, but is not admitted
            return false
        }

        guard let folderName = ObsidianTransfer.folderName(from: manifest) else {
            // Missing folder name holds and retries. It does not authorize.
            self.scheduleRetry(generation: self.generation)
            return false
        }

        // Check same-name acceptance
        let endpointID = self.endpointID(for: endpoint)
        if let isAccepted = await self.isAcceptedForSameName?(vaultID, endpointID), !isAccepted {
            if let pending = self.pendingAdvisory, pending.vault == folderName, self.pendingAdvisoryVaultID == vaultID {
                return false
            }
            self.startFetchSameName(vaultID: vaultID, folderName: folderName, endpoint: endpoint)
            return false
        }

        guard await self.isCurrent(endpoint) else { return false }
        return self.generation == currentGeneration && self.endpoint == endpoint && self.capability == .listed
    }

    func journalChanged(identity: String?, version: String?) async {
        guard identity != self.journal.identity || version != self.journal.version else { return }
        self.journal = (identity, version)
        self.reset()
        await self.wake?()
    }

    private func reset() {
        self.generation &+= 1
        self.admissionIdentity = UUID().uuidString
        self.readingStatus = false
        self.fetchingSameName = false
        self.retryScheduled = false
        self.pendingAdvisory = nil
        self.pendingAdvisoryVaultID = nil
        self.activeVaultContext = nil
        self.setCapability(.unknown)
        self.publishAdvisory?(nil)
    }

    private func setCapability(_ capability: Capability) {
        guard self.capability != capability else { return }
        self.capability = capability
        self.publishCapability?(capability)
    }

    private func startReadStatus() {
        guard !self.readingStatus, !self.retryScheduled, let endpoint = self.endpoint else { return }
        self.readingStatus = true
        let gen = self.generation
        Task { [weak self] in
            guard let self else { return }
            let report = await self.readStatus(endpoint)
            guard await self.isCurrent(endpoint) else { return }
            await self.finishReadStatus(report: report, generation: gen)
        }
    }

    private func finishReadStatus(report: JournalStatusReport, generation: UInt64) async {
        guard self.generation == generation else { return }
        self.readingStatus = false
        switch report {
        case .read(_, let capabilities):
            let takesNotes = capabilities?.contains(ObsidianTransfer.capability) == true
            self.setCapability(takesNotes ? .listed : .notListed)
            if takesNotes {
                await self.wake?()
            }
        case .failed:
            self.setCapability(.unknown)
            self.scheduleRetry(generation: generation)
        }
    }

    private func startFetchSameName(vaultID: String, folderName: String, endpoint: TransferResolvedEndpoint) {
        guard !self.fetchingSameName else { return }
        self.fetchingSameName = true
        let gen = self.generation
        Task { [weak self] in
            guard let self else { return }
            let advisories = await self.fetchVaults(endpoint)
            guard await self.isCurrent(endpoint) else { return }
            await self.finishFetchSameName(vaultID: vaultID, folderName: folderName, endpoint: endpoint, advisories: advisories, generation: gen)
        }
    }

    private func finishFetchSameName(
        vaultID: String,
        folderName: String,
        endpoint: TransferResolvedEndpoint,
        advisories: [ObsidianSameNameAdvisory]?,
        generation: UInt64
    ) async {
        guard await self.activeVaultID?() == vaultID,
              await self.isCurrent(endpoint),
              self.generation == generation else { return }
        self.fetchingSameName = false
        guard let advisories else {
            // Network failure / retry
            self.scheduleRetry(generation: generation)
            return
        }

        // Check if another device shares a vault with the same name:
        if let matching = advisories.first(where: { $0.vault == folderName }) {
            self.pendingAdvisory = matching
            self.pendingAdvisoryVaultID = vaultID
            self.publishAdvisory?(matching)
        } else {
            // 404, empty list, or no matching vault name: authorized
            self.pendingAdvisory = nil
            self.pendingAdvisoryVaultID = nil
            self.publishAdvisory?(nil)
            let endpointID = self.endpointID(for: endpoint)
            guard await self.recordAcceptance?(vaultID, endpointID) == true,
                  self.generation == generation else { return }
            await self.wake?()
        }
    }

    private func scheduleRetry(generation: UInt64) {
        guard !self.retryScheduled else { return }
        self.retryScheduled = true
        let delay = self.retryDelay
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            await self.clearRetry(generation: generation)
        }
    }

    private func clearRetry(generation: UInt64) async {
        guard self.generation == generation else { return }
        self.retryScheduled = false
        await self.wake?()
    }
}

/// Coordinates presentation and upload reach counts for the active vault.
@MainActor
@Observable
final class ObsidianTransferHolder {
    private let transferEngine: TransferEngine
    private let mirror: TransferStatusMirror
    var capability: ObsidianCapabilityGate.Capability = .unknown
    var sameNameAdvisory: ObsidianSameNameAdvisory?
    var continueSameNameAction: (@MainActor () async -> Void)?
    var cancelSameNameAction: (@MainActor () async -> Void)?

    var publishSnapshots: (@MainActor ([TransferItemSnapshot]) -> Void)?
    var activeVaultIDProvider: (() -> String?)?
    var isEnabledProvider: (() -> Bool)?
    var isPausedProvider: (() -> Bool)?

    private var _activeVaultID: String?
    private var _isEnabled: Bool = false
    private var _isPaused: Bool = false

    var activeVaultID: String? {
        get { self.activeVaultIDProvider?() ?? self._activeVaultID }
        set { self._activeVaultID = newValue }
    }

    var isEnabled: Bool {
        get { self.isEnabledProvider?() ?? self._isEnabled }
        set { self._isEnabled = newValue }
    }

    var isPaused: Bool {
        get { self.isPausedProvider?() ?? self._isPaused }
        set { self._isPaused = newValue }
    }

    var notesWaiting: Int = 0
    var notesNeedingAttention: Int = 0
    private(set) var activePendingCount: Int = 0

    init(transferEngine: TransferEngine, mirror: TransferStatusMirror) {
        self.transferEngine = transferEngine
        self.mirror = mirror
    }

    var pendingCount: Int {
        self.status.queuedCount + self.status.inFlightCount
    }

    var failedCount: Int {
        self.status.attentionCount
    }

    var inFlightCount: Int {
        self.status.inFlightCount
    }

    var refusalPacedCount: Int {
        self.status.refusalPacedCount
    }

    var deliveredCount: Int {
        self.status.deliveredCount
    }

    /// Waiting files no drain can send: those from inactive vaults, held while off or paused,
    /// or held because capability is not listed.
    var unsendableCount: Int {
        if !self.isEnabled || self.isPaused || self.capability == .notListed {
            return self.pendingCount
        }
        guard self.activeVaultID != nil else {
            return self.pendingCount
        }
        return max(0, self.pendingCount - self.activePendingCount)
    }

    func refreshNoteCounts() async {
        guard let activeID = self.activeVaultID else {
            self.notesWaiting = 0
            self.notesNeedingAttention = 0
            self.activePendingCount = 0
            return
        }
        let snapshots = await self.transferEngine.itemSnapshots(sourceKey: ObsidianTransfer.sourceKey)
        self.publishSnapshots?(snapshots)
        let activeSnapshots = snapshots.filter { ObsidianTransfer.vaultID(from: $0.manifest) == activeID }
        self.activePendingCount = activeSnapshots.filter { $0.state != .attention }.count
        self.notesWaiting = activeSnapshots.filter { $0.state != .attention }.reduce(0) { $0 + ObsidianTransfer.noteCount($1.manifest) }
        self.notesNeedingAttention = activeSnapshots.filter { $0.state == .attention }.reduce(0) { $0 + ObsidianTransfer.noteCount($1.manifest) }
    }

    func onThisPhoneSourceSnapshot() async -> OnThisPhoneSourceResult {
        guard let activeID = self.activeVaultID else {
            return .loaded(items: [])
        }
        let snapshots = await self.transferEngine.itemSnapshots(sourceKey: ObsidianTransfer.sourceKey)
        self.publishSnapshots?(snapshots)
        let activeSnapshots = snapshots.filter { ObsidianTransfer.vaultID(from: $0.manifest) == activeID }
        return .loaded(items: OnThisPhoneItemSort.newestFirst(Self.items(snapshots: activeSnapshots)))
    }

    nonisolated static func items(snapshots: [TransferItemSnapshot]) -> [OnThisPhoneItem] {
        snapshots.map { snapshot in
            let manifest = snapshot.manifest
            let part = manifest.payloadParts.first
            let attention = manifest.attention
            return OnThisPhoneItem(
                id: OnThisPhoneItemID.obsidianTransferIDString(itemID: snapshot.itemID),
                sourceKind: .obsidian,
                sendState: OnThisPhoneSendState(transferState: snapshot.state),
                contentType: part?.contentType,
                filename: part?.filename,
                bytes: part?.byteCount.map(Int64.init),
                originApp: nil,
                basis: nil,
                itemTime: manifest.observerIngest?.startedAt ?? manifest.createdAt,
                targetJournal: nil,
                stream: nil,
                day: manifest.observerIngest?.day,
                segment: manifest.observerIngest?.segment,
                deliveredAt: nil,
                rawFileURL: nil,
                failureReason: attention.map(\.ownerFailureReason),
                failureAttemptCount: snapshot.attempts > 0 ? snapshot.attempts : nil,
                retryAvailable: snapshot.state == .attention,
                lastAttemptAt: attention?.movedAt,
                refusalPaced: snapshot.refusalPaced
            )
        }
    }

    private var status: TransferSourceStatusSnapshot {
        self.mirror.sources[ObsidianTransfer.sourceKey] ?? TransferSourceStatusSnapshot(
            queuedCount: 0,
            attentionCount: 0,
            inFlightCount: 0,
            deliveredCount: 0,
            droppedCount: 0,
            lastDeliveredAt: nil,
            lastErrorDetail: nil,
            recentErrorCount: 0,
            bytesPerSecond: 0
        )
    }
}
