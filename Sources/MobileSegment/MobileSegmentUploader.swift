// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation
import Observation
import os

private let mobileSegmentUploadLog = Logger(subsystem: "app.solstone.swift", category: "mobile-segment")
private let mobileSegmentTransferTempRootName = "MobileSegmentTransferEnqueue"

private enum MobileSegmentUploaderError: Error, CustomStringConvertible {
    case storageUnavailable(String)
    case transferEngineUnavailable
    case copyVerificationFailed(URL)

    var description: String {
        switch self {
        case .storageUnavailable(let reason):
            reason
        case .transferEngineUnavailable:
            "transfer engine unavailable"
        case .copyVerificationFailed(let url):
            "copy verification failed \(url.lastPathComponent)"
        }
    }
}

private struct MobileSegmentDeclaredPart {
    let source: MobileSegmentSource
    let descriptor: TransferPayloadPartDescriptor
    let artifactURL: URL
}

nonisolated enum FinalizeFailureResolution: Equatable, Sendable {
    case repend
    case retired
    case deferred
}

@MainActor
@Observable
final class MobileSegmentUploader {
    private(set) var pendingCount = 0
    private(set) var failedCount = 0
    private(set) var finalizeFailedCount = 0
    var lastUploadAt: Date?
    var lastError: String?
    private(set) var recentErrorCount = 0
    private static let finalizeFailureStages: Set<String> = [
        "source-finalize",
        "segment-finalize",
        "schedule-gate",
        "reconcile",
    ]

    @ObservationIgnored private let store: MobileSegmentStore
    @ObservationIgnored private let transferEngine: TransferEngine?
    @ObservationIgnored private let clock: any ObserverClock
    @ObservationIgnored private let storageDisabledReason: String?
    @ObservationIgnored private let cooperator: MaintenanceCooperator
    @ObservationIgnored private var enqueuingSegmentIDs: Set<UUID> = []

    init(
        transferEngine: TransferEngine? = nil,
        store: MobileSegmentStore = MobileSegmentStore(),
        clock: any ObserverClock = SystemObserverClock(),
        storageDisabledReason: String? = nil,
        cooperator: MaintenanceCooperator = MaintenanceCooperator()
    ) {
        self.transferEngine = transferEngine
        self.store = store
        self.clock = clock
        self.storageDisabledReason = storageDisabledReason
        self.cooperator = cooperator
        if let storageDisabledReason {
            self.lastError = storageDisabledReason
            return
        }
        try? self.store.ensureRoot()
        self.refreshCounts()
    }

    func openSegment(sources: Set<MobileSegmentSource>, startedAt: Date, sourceSetVersion: Int) throws -> UUID {
        try self.requireStorageAvailable()
        let manifest = MobileSegmentManifest(
            segmentID: UUID(),
            startedAt: startedAt,
            openedWithSources: sources,
            activeSourceSetVersion: sourceSetVersion
        )
        _ = try self.store.createActive(manifest: manifest)
        self.refreshCounts()
        return manifest.segmentID
    }

    func adoptActiveSegment(
        segmentID: UUID,
        sources: Set<MobileSegmentSource>,
        startedAt: Date,
        sourceSetVersion: Int
    ) throws {
        try self.requireStorageAvailable()
        let directory = self.activeDirectory(segmentID: segmentID)
        if self.store.fileExists(directory), (try? self.store.readManifest(in: directory)) != nil {
            self.refreshCounts()
            return
        }
        let manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: sources,
            activeSourceSetVersion: sourceSetVersion
        )
        _ = try self.store.createActive(manifest: manifest)
        self.refreshCounts()
    }

    func activeDirectory(segmentID: UUID) -> URL {
        self.store.segmentDirectoryURL(.active, segmentID: segmentID)
    }

    var storeForTransferMigration: MobileSegmentStore {
        self.store
    }

    func activeAudioURL(segmentID: UUID) -> URL {
        self.store.audioURL(in: self.activeDirectory(segmentID: segmentID))
    }

    func recordAudioFinalized(
        segmentID: UUID,
        finalized: ObserverRecordedChunk?,
        startedAt: Date,
        endedAt: Date,
        mode: ObserverMode,
        minimumDuration: TimeInterval
    ) throws {
        try self.requireStorageAvailable()
        let directory = self.activeDirectory(segmentID: segmentID)
        var manifest = try self.store.readManifest(in: directory)
        guard manifest.openedWithSources.contains(.audio) else { return }

        guard let finalized else {
            let resolution = MobileSegmentSourceResolution(
                state: .failedToFinalize,
                reason: "audio source did not finalize",
                stage: "source-finalize",
                lastAttemptAt: endedAt,
                mode: mode
            )
            try self.store.writeOutcome(resolution, source: .audio, manifest: &manifest, in: directory, now: endedAt)
            return
        }

        guard finalized.duration >= minimumDuration else {
            self.store.removeIfExists(finalized.url)
            let resolution = MobileSegmentSourceResolution(
                state: .noArtifact,
                startedAt: startedAt,
                endedAt: endedAt,
                durationS: finalized.duration,
                reason: "audio_below_min_duration",
                mode: mode
            )
            try self.store.writeOutcome(resolution, source: .audio, manifest: &manifest, in: directory, now: endedAt)
            return
        }

        let target = self.store.audioURL(in: directory)
        if finalized.url != target {
            try self.store.moveOrReplaceItem(at: finalized.url, to: target)
        }
        let resolution = MobileSegmentSourceResolution(
            state: .finalizedArtifact,
            artifactFilename: target.lastPathComponent,
            bytes: self.store.fileSize(at: target),
            startedAt: startedAt,
            endedAt: endedAt,
            durationS: finalized.duration,
            mode: mode
        )
        try self.store.writeOutcome(resolution, source: .audio, manifest: &manifest, in: directory, now: endedAt)
    }

    func recordAudioFinalizeFailed(
        segmentID: UUID,
        startedAt: Date,
        endedAt: Date,
        mode: ObserverMode,
        reason: String
    ) throws {
        try self.requireStorageAvailable()
        let directory = self.activeDirectory(segmentID: segmentID)
        var manifest = try self.store.readManifest(in: directory)
        guard manifest.openedWithSources.contains(.audio) else { return }
        let resolution = MobileSegmentSourceResolution(
            state: .failedToFinalize,
            startedAt: startedAt,
            endedAt: endedAt,
            reason: reason,
            stage: "source-finalize",
            lastAttemptAt: endedAt,
            mode: mode
        )
        try self.store.writeOutcome(resolution, source: .audio, manifest: &manifest, in: directory, now: endedAt)
    }

    func activeScreencastURL(segmentID: UUID) -> URL {
        self.store.screenURL(in: self.activeDirectory(segmentID: segmentID))
    }

    func screencastResolution(segmentID: UUID) -> MobileSegmentSourceResolution? {
        guard let found = self.store.findDirectory(segmentID: segmentID),
              let manifest = try? self.store.readManifest(in: found.url) else {
            return nil
        }
        return manifest.screencast
    }

    func recordScreencastFinalized(
        segmentID: UUID,
        artifactURL: URL,
        startedAt: Date,
        endedAt: Date,
        durationS: TimeInterval?
    ) throws {
        try self.requireStorageAvailable()
        let directory = self.activeDirectory(segmentID: segmentID)
        var manifest = try self.store.readManifest(in: directory)
        guard manifest.openedWithSources.contains(.screencast) else { return }

        let target = self.store.screenURL(in: directory)
        if artifactURL != target {
            try self.store.moveOrReplaceItem(at: artifactURL, to: target)
        }
        let resolution = MobileSegmentSourceResolution(
            state: .finalizedArtifact,
            artifactFilename: target.lastPathComponent,
            bytes: self.store.fileSize(at: target),
            startedAt: startedAt,
            endedAt: endedAt,
            durationS: durationS
        )
        try self.store.writeOutcome(resolution, source: .screencast, manifest: &manifest, in: directory, now: endedAt)
    }

    func recordScreencastFinalizeFailed(
        segmentID: UUID,
        startedAt: Date,
        endedAt: Date,
        reason: String
    ) throws {
        try self.requireStorageAvailable()
        let directory = self.activeDirectory(segmentID: segmentID)
        var manifest = try self.store.readManifest(in: directory)
        guard manifest.openedWithSources.contains(.screencast) else { return }
        let resolution = MobileSegmentSourceResolution(
            state: .failedToFinalize,
            startedAt: startedAt,
            endedAt: endedAt,
            reason: reason,
            stage: "source-finalize",
            lastAttemptAt: endedAt
        )
        try self.store.writeOutcome(resolution, source: .screencast, manifest: &manifest, in: directory, now: endedAt)
    }

    func recordScreencastNoArtifact(
        segmentID: UUID,
        startedAt: Date,
        endedAt: Date,
        durationS: TimeInterval?,
        reason: String
    ) throws {
        try self.requireStorageAvailable()
        let directory = self.activeDirectory(segmentID: segmentID)
        var manifest = try self.store.readManifest(in: directory)
        guard manifest.openedWithSources.contains(.screencast) else { return }
        let resolution = MobileSegmentSourceResolution(
            state: .noArtifact,
            startedAt: startedAt,
            endedAt: endedAt,
            durationS: durationS,
            reason: reason
        )
        try self.store.writeOutcome(resolution, source: .screencast, manifest: &manifest, in: directory, now: endedAt)
    }

    func recordLocationFinalized(
        segmentID: UUID,
        batch: LocationSegmentBatch,
        endedAt: Date,
        reason: String?
    ) throws {
        let directory = self.activeDirectory(segmentID: segmentID)
        try self.recordLocationFinalized(segmentID: segmentID, directory: directory, batch: batch, endedAt: endedAt, reason: reason)
    }

    func recordLocationFinalized(
        segmentID: UUID,
        directory: URL,
        batch: LocationSegmentBatch,
        endedAt: Date,
        reason: String?
    ) throws {
        try self.requireStorageAvailable()
        var manifest = try self.store.readManifest(in: directory)
        guard manifest.openedWithSources.contains(.location) else { return }

        guard !batch.fixes.isEmpty || !batch.visits.isEmpty else {
            if batch.gap {
                try self.writeLocationArtifact(
                    batch: batch,
                    directory: directory,
                    endedAt: endedAt,
                    reason: reason,
                    manifest: &manifest
                )
            } else {
                let resolution = MobileSegmentSourceResolution(
                    state: .noArtifact,
                    startedAt: batch.segmentStart,
                    endedAt: endedAt,
                    durationS: TimeInterval(batch.coveredSeconds),
                    reason: reason ?? "location_no_fixes_or_visits",
                    fixCount: 0
                )
                try self.store.writeOutcome(resolution, source: .location, manifest: &manifest, in: directory, now: endedAt)
                self.removeLocationLiveFiles(in: directory)
            }
            return
        }

        try self.writeLocationArtifact(
            batch: batch,
            directory: directory,
            endedAt: endedAt,
            reason: reason,
            manifest: &manifest
        )
    }

    func appendLocationLiveState(
        segmentID: UUID,
        segmentStart: Date,
        tier: LocationTier,
        accuracy: LocationAccuracy,
        gap: Bool,
        recordedAt: Date
    ) throws {
        try self.requireStorageAvailable()
        let directory = self.activeDirectory(segmentID: segmentID)
        guard self.store.fileExists(directory) else {
            throw MobileSegmentUploaderError.storageUnavailable("mobile segment active directory missing")
        }
        let data = try MobileSegmentLocationWriter.liveStateLine(
            segmentID: segmentID,
            segmentStart: segmentStart,
            tier: tier,
            accuracy: accuracy,
            gap: gap,
            recordedAt: recordedAt
        )
        try self.store.appendData(data, to: self.store.locationPartURL(in: directory))
    }

    func appendLocationLiveFix(segmentID: UUID, fix: LocationFix) throws {
        try self.requireStorageAvailable()
        let directory = self.activeDirectory(segmentID: segmentID)
        guard self.store.fileExists(directory) else {
            throw MobileSegmentUploaderError.storageUnavailable("mobile segment active directory missing")
        }
        let data = try MobileSegmentLocationWriter.liveFixLine(fix)
        try self.store.appendData(data, to: self.store.locationPartURL(in: directory))
    }

    func appendLocationLiveVisit(segmentID: UUID, visit: LocationVisit) throws {
        try self.requireStorageAvailable()
        let directory = self.activeDirectory(segmentID: segmentID)
        guard self.store.fileExists(directory) else {
            throw MobileSegmentUploaderError.storageUnavailable("mobile segment active directory missing")
        }
        let data = try MobileSegmentLocationWriter.liveVisitLine(visit)
        try self.store.appendData(data, to: self.store.locationPartURL(in: directory))
    }

    func writeLocationLiveness(
        segmentID: UUID,
        sourceSetVersion: Int,
        lastSeenAt: Date,
        fixCount: Int,
        visitCount: Int,
        gap: Bool
    ) throws {
        try self.requireStorageAvailable()
        let directory = self.activeDirectory(segmentID: segmentID)
        guard self.store.fileExists(directory) else {
            throw MobileSegmentUploaderError.storageUnavailable("mobile segment active directory missing")
        }
        let liveness = MobileSegmentLocationSegmentLiveness(
            segmentID: segmentID,
            sourceSetVersion: sourceSetVersion,
            lastSeenAt: lastSeenAt,
            fixCount: fixCount,
            visitCount: visitCount,
            gap: gap
        )
        let data = try MobileSegmentLocationWriter.encoder().encode(liveness)
        try self.store.writeData(data, to: self.store.locationLivenessURL(in: directory))
    }

    func recordLocationFinalizeRemoved(
        segmentID: UUID,
        endedAt: Date,
        reason: String
    ) throws {
        try self.requireStorageAvailable()
        let directory = self.activeDirectory(segmentID: segmentID)
        var manifest = try self.store.readManifest(in: directory)
        guard manifest.openedWithSources.contains(.location) else { return }
        try self.writeLocationRemoved(
            segmentID: segmentID,
            directory: directory,
            manifest: &manifest,
            now: endedAt,
            reason: reason
        )
    }

    func finalizeActiveSegment(segmentID: UUID, endedAt: Date) async {
        guard self.guardStorageAvailable() else { return }
        let directory = self.activeDirectory(segmentID: segmentID)
        do {
            var manifest = try self.store.readManifest(in: directory)
            manifest.endedAt = endedAt
            let audioResolved = manifest.resolution(for: .audio).durationS
            manifest.durationS = audioResolved ?? max(0, endedAt.timeIntervalSince(manifest.startedAt))
            manifest.day = Self.dayString(for: manifest.startedAt)
            manifest.segment = ChunkSidecar.segmentString(for: manifest.startedAt, durationSeconds: manifest.durationS ?? 0)
            manifest.updatedAt = endedAt

            var deferredLiveScreencast = false
            var deferredLiveLocation = false
            for source in manifest.declaredSources where !manifest.resolution(for: source).state.isTerminal {
                if source == .screencast {
                    let screenURL = self.store.screenURL(in: directory)
                    let screenPartURL = self.store.screenPartURL(in: directory)
                    if self.store.fileExists(screenURL) {
                        let resolution = MobileSegmentSourceResolution(
                            state: .finalizedArtifact,
                            artifactFilename: screenURL.lastPathComponent,
                            bytes: self.store.fileSize(at: screenURL),
                            startedAt: manifest.startedAt,
                            endedAt: endedAt,
                            durationS: MobileSegmentDuration.bounded(
                                container: await MobileSegmentDuration.probeContainerDuration(at: screenURL),
                                elapsed: endedAt.timeIntervalSince(manifest.startedAt)
                            )
                        )
                        try self.store.writeOutcome(resolution, source: source, manifest: &manifest, in: directory, now: endedAt)
                        manifest = try self.store.readManifest(in: directory)
                        continue
                    }
                    if self.store.fileExists(screenPartURL),
                       self.hasFreshScreencastLiveness(segmentID: segmentID, directory: directory, now: endedAt) {
                        deferredLiveScreencast = true
                        continue
                    }
                    let resolution = MobileSegmentSourceResolution(
                        state: .failedToFinalize,
                        reason: self.store.fileExists(screenPartURL) ? "screencast_partial_artifact" : "missing outcome marker for \(source.rawValue)",
                        stage: "segment-finalize",
                        lastAttemptAt: endedAt
                    )
                    try self.store.writeOutcome(resolution, source: source, manifest: &manifest, in: directory, now: endedAt)
                    manifest = try self.store.readManifest(in: directory)
                    continue
                }
                if source == .location {
                    let locationURL = self.store.locationURL(in: directory)
                    let locationPartURL = self.store.locationPartURL(in: directory)
                    if self.store.fileExists(locationURL) {
                        try self.writeLocationArtifactOutcome(
                            segmentID: segmentID,
                            directory: directory,
                            manifest: &manifest,
                            now: endedAt
                        )
                        manifest = try self.store.readManifest(in: directory)
                        continue
                    }
                    if self.store.fileExists(locationPartURL) {
                        if self.hasFreshLocationLiveness(segmentID: segmentID, directory: directory, now: endedAt) {
                            deferredLiveLocation = true
                            continue
                        }
                        try self.recoverLocationLive(
                            segmentID: segmentID,
                            directory: directory,
                            manifest: &manifest,
                            now: endedAt
                        )
                        manifest = try self.store.readManifest(in: directory)
                        continue
                    }
                    try self.writeLocationRemoved(
                        segmentID: segmentID,
                        directory: directory,
                        manifest: &manifest,
                        now: endedAt,
                        reason: "location_live_missing"
                    )
                    manifest = try self.store.readManifest(in: directory)
                    continue
                }
                let resolution = MobileSegmentSourceResolution(
                    state: .failedToFinalize,
                    reason: "missing outcome marker for \(source.rawValue)",
                    stage: "segment-finalize",
                    lastAttemptAt: endedAt
                )
                try self.store.writeOutcome(resolution, source: source, manifest: &manifest, in: directory, now: endedAt)
                manifest = try self.store.readManifest(in: directory)
            }

            if deferredLiveScreencast || deferredLiveLocation {
                try self.store.writeManifest(manifest, in: directory)
                self.refreshCounts()
                return
            }

            if manifest.isEmptyResolved {
                manifest.upload = .empty
                try self.store.writeManifest(manifest, in: directory)
                try self.store.writeTombstone(segmentID: segmentID, kind: "empty", reason: "no_artifacts", now: endedAt)
                try self.store.remove(directory)
            } else if manifest.hasFinalizeFailure {
                manifest.upload = .failed
                try self.store.writeManifest(manifest, in: directory)
                try self.store.writeFailure(
                    MobileSegmentFailureSidecar(
                        reason: "source artifact failed to finalize",
                        httpStatus: nil,
                        transportError: nil,
                        attemptCount: 0,
                        stage: "source-finalize",
                        lastAttemptAt: endedAt
                    ),
                    in: directory
                )
                _ = try self.store.move(segmentID: segmentID, from: .active, to: .failed)
            } else if manifest.hasArtifact {
                manifest.upload = .pending
                try self.store.writeManifest(manifest, in: directory)
                _ = try self.store.move(segmentID: segmentID, from: .active, to: .pending)
                await self.enqueuePendingSegmentIntoTransfer(segmentID: segmentID)
            }
        } catch {
            let diagnostic = "mobile segment finalize failed segment=\(segmentID.uuidString) stage=segment-finalize"
            mobileSegmentUploadLog.error("\(diagnostic, privacy: .public)")
            self.lastError = diagnostic
        }
        self.refreshCounts()
    }

    func resumeFromDisk() async {
        guard self.guardStorageAvailable() else { return }
        do {
            try self.store.ensureRoot()
            self.sweepStaleTransferEnqueueTemps()
            try self.retireDeliveredResidue()
            await self.retireTransferOwnedResidue()
            try await self.reconcileActiveSegments()
            if Task.isCancelled {
                self.refreshCounts()
                return
            }
            await self.resolveFinalizeFailurePile()
            if Task.isCancelled {
                self.refreshCounts()
                return
            }
            let pending = try self.store.list(.pending)
            for directory in pending {
                if Task.isCancelled { break }
                await self.cooperator.step()
                if Task.isCancelled { break }
                guard let segmentID = UUID(uuidString: directory.lastPathComponent) else { continue }
                await self.enqueuePendingSegmentIntoTransfer(segmentID: segmentID)
            }
        } catch {
            let diagnostic = "mobile segment resume failed stage=resume"
            self.lastError = diagnostic
            mobileSegmentUploadLog.error("\(diagnostic, privacy: .public)")
        }
        self.refreshCounts()
    }

    func resolveFinalizeFailurePile() async {
        guard self.guardStorageAvailable() else { return }
        let failed: [URL]
        do {
            failed = try self.store.list(.failed)
        } catch {
            let diagnostic = "mobile segment finalize-failure scan failed stage=finalize-failure"
            self.lastError = diagnostic
            mobileSegmentUploadLog.error("\(diagnostic, privacy: .public)")
            self.refreshCounts()
            return
        }

        for directory in failed {
            if Task.isCancelled { break }
            await self.cooperator.step()
            if Task.isCancelled { break }
            guard let segmentID = UUID(uuidString: directory.lastPathComponent) else { continue }
            do {
                let manifest = try self.store.readManifest(in: directory)
                guard manifest.hasFinalizeFailure else { continue }
                let result = try await self.resolveFinalizeFailure(segmentID: segmentID, directory: directory, lifecycle: .failed)
                if result == .repend {
                    await self.enqueuePendingSegmentIntoTransfer(segmentID: segmentID)
                }
            } catch {
                let diagnostic = "mobile segment finalize-failure deferred segment=\(segmentID.uuidString) stage=finalize-failure"
                self.lastError = diagnostic
                mobileSegmentUploadLog.error("\(diagnostic, privacy: .public)")
            }
        }
        self.refreshCounts()
    }

    func resolveFinalizeFailure(
        segmentID: UUID,
        directory: URL,
        lifecycle: MobileSegmentLifecycle
    ) async throws -> FinalizeFailureResolution {
        try self.requireStorageAvailable()
        var manifest = try self.store.readManifest(in: directory)
        guard manifest.hasFinalizeFailure else { return .deferred }

        for source in [MobileSegmentSource.location, .screencast, .audio] {
            guard manifest.declaredSources.contains(source),
                  manifest.resolution(for: source).state == .failedToFinalize else {
                continue
            }
            let now = self.clock.now()
            switch source {
            case .location:
                let locationURL = self.store.locationURL(in: directory)
                let locationPartURL = self.store.locationPartURL(in: directory)
                if self.store.fileExists(locationURL) {
                    try self.writeLocationArtifactOutcome(
                        segmentID: segmentID,
                        directory: directory,
                        manifest: &manifest,
                        now: now
                    )
                } else if self.store.fileExists(locationPartURL) {
                    try self.recoverLocationLive(
                        segmentID: segmentID,
                        directory: directory,
                        manifest: &manifest,
                        now: now
                    )
                } else {
                    try self.writeLocationRemoved(
                        segmentID: segmentID,
                        directory: directory,
                        manifest: &manifest,
                        now: now,
                        reason: "location_no_local_data"
                    )
                }
            case .screencast:
                self.store.removeIfExists(self.store.screenURL(in: directory))
                self.store.removeIfExists(self.store.screenPartURL(in: directory))
                let resolution = MobileSegmentSourceResolution(
                    state: .removed,
                    reason: "screencast_removed",
                    lastAttemptAt: now
                )
                try self.store.writeOutcome(resolution, source: .screencast, manifest: &manifest, in: directory, now: now)
            case .audio:
                let audioURL = self.store.audioURL(in: directory)
                if self.store.fileExists(audioURL) {
                    let finalized = MobileSegmentSourceResolution(
                        state: .finalizedArtifact,
                        artifactFilename: audioURL.lastPathComponent,
                        bytes: self.store.fileSize(at: audioURL),
                        startedAt: manifest.startedAt,
                        endedAt: now,
                        durationS: MobileSegmentDuration.bounded(
                            container: await MobileSegmentDuration.probeContainerDuration(at: audioURL),
                            elapsed: now.timeIntervalSince(manifest.startedAt)
                        ),
                        mode: manifest.resolution(for: .audio).mode
                    )
                    try self.store.writeOutcome(finalized, source: .audio, manifest: &manifest, in: directory, now: now)
                } else {
                    self.store.removeIfExists(audioURL)
                    let resolution = MobileSegmentSourceResolution(
                        state: .removed,
                        reason: "audio_no_local_data",
                        lastAttemptAt: now
                    )
                    try self.store.writeOutcome(resolution, source: .audio, manifest: &manifest, in: directory, now: now)
                }
            }
            manifest = try self.store.readManifest(in: directory)
        }

        manifest = try self.store.readManifest(in: directory)
        if manifest.declaredSources.contains(where: { manifest.resolution(for: $0).state == .finalizedArtifact }) {
            manifest.upload = .pending
            manifest.updatedAt = self.clock.now()
            try self.store.writeManifest(manifest, in: directory)
            if lifecycle == .failed {
                let pendingDirectory = try self.store.move(segmentID: segmentID, from: .failed, to: .pending)
                try self.store.removeFailure(in: pendingDirectory)
            }
            return .repend
        }

        try self.store.writeTombstone(
            segmentID: segmentID,
            kind: "empty",
            reason: "unrecoverable_lost_data",
            now: self.clock.now()
        )
        try self.store.remove(directory)
        mobileSegmentUploadLog.notice("mobile segment retired unrecoverable segment=\(segmentID.uuidString, privacy: .public) reason=unrecoverable_lost_data")
        return .retired
    }

    func dropSegment(segmentID: UUID) {
        guard self.guardStorageAvailable() else { return }
        if let found = self.store.findDirectory(segmentID: segmentID) {
            try? self.store.remove(found.url)
        }
        self.refreshCounts()
    }

    func writeUploadedTombstone(segmentID: UUID) throws {
        try self.store.writeTombstone(segmentID: segmentID, kind: "uploaded", reason: "delivered", now: self.clock.now())
        try self.retireDeliveredResidue(segmentID: segmentID)
        self.refreshCounts()
    }

    func redactLocationFacet(segmentID: UUID) async {
        guard self.guardStorageAvailable() else { return }
        guard let found = self.store.findDirectory(segmentID: segmentID) else { return }
        do {
            var manifest = try self.store.readManifest(in: found.url)
            guard manifest.location.state.isLocalFacet else { return }
            let now = self.clock.now()
            try self.writeLocationRemoved(
                segmentID: segmentID,
                directory: found.url,
                manifest: &manifest,
                now: now,
                reason: "location_removed"
            )
            if manifest.audio.state == .finalizedArtifact || manifest.screencast.state == .finalizedArtifact {
                manifest.upload = .pending
                try self.store.writeManifest(manifest, in: found.url)
                if found.lifecycle == .failed {
                    _ = try self.store.move(segmentID: segmentID, from: .failed, to: .pending)
                }
                await self.enqueuePendingSegmentIntoTransfer(segmentID: segmentID)
            } else {
                try self.store.remove(found.url)
            }
        } catch {
            let diagnostic = "mobile segment location redaction failed segment=\(segmentID.uuidString) source=location"
            self.lastError = diagnostic
            mobileSegmentUploadLog.error("\(diagnostic, privacy: .public)")
        }
        self.refreshCounts()
    }

    func redactScreencastFacet(segmentID: UUID) async {
        guard self.guardStorageAvailable() else { return }
        guard let found = self.store.findDirectory(segmentID: segmentID) else { return }
        do {
            var manifest = try self.store.readManifest(in: found.url)
            guard manifest.screencast.state.isLocalFacet else { return }
            self.store.removeIfExists(self.store.screenURL(in: found.url))
            self.store.removeIfExists(self.store.screenPartURL(in: found.url))
            let resolution = MobileSegmentSourceResolution(
                state: .removed,
                reason: "screencast_removed",
                lastAttemptAt: self.clock.now()
            )
            try self.store.writeOutcome(resolution, source: .screencast, manifest: &manifest, in: found.url, now: self.clock.now())
            if manifest.audio.state == .finalizedArtifact || manifest.location.state == .finalizedArtifact {
                manifest.upload = .pending
                try self.store.writeManifest(manifest, in: found.url)
                if found.lifecycle == .failed {
                    _ = try self.store.move(segmentID: segmentID, from: .failed, to: .pending)
                }
                await self.enqueuePendingSegmentIntoTransfer(segmentID: segmentID)
            } else {
                try self.store.writeTombstone(segmentID: segmentID, kind: "empty", reason: "screencast_removed", now: self.clock.now())
                try self.store.remove(found.url)
            }
        } catch {
            let diagnostic = "mobile segment screencast redaction failed segment=\(segmentID.uuidString) source=screencast"
            self.lastError = diagnostic
            mobileSegmentUploadLog.error("\(diagnostic, privacy: .public)")
        }
        self.refreshCounts()
    }

    func deleteLocationLocalState() async {
        guard self.guardStorageAvailable() else { return }
        for lifecycle in [MobileSegmentLifecycle.pending, .failed] {
            guard let directories = try? self.store.list(lifecycle) else { continue }
            for directory in directories {
                guard let segmentID = UUID(uuidString: directory.lastPathComponent),
                      let manifest = try? self.store.readManifest(in: directory),
                      manifest.location.state.isLocalFacet
                else { continue }
                if manifest.audio.state == .finalizedArtifact || manifest.screencast.state == .finalizedArtifact {
                    await self.redactLocationFacet(segmentID: segmentID)
                } else {
                    self.dropSegment(segmentID: segmentID)
                }
            }
        }
    }

    func onThisPhoneSnapshot(for source: MobileSegmentSource) -> OnThisPhoneSourceResult {
        guard self.guardStorageAvailable() else { return .loaded(items: []) }
        do {
            var items: [OnThisPhoneItem] = []
            items.append(contentsOf: try self.onThisPhoneItems(source: source, lifecycle: .failed))
            return .loaded(items: OnThisPhoneItemSort.newestFirst(items))
        } catch {
            mobileSegmentUploadLog.error("mobile segment on-this-phone snapshot failed source=\(source.rawValue, privacy: .public)")
            return .failed
        }
    }

    func summary(for source: MobileSegmentSource) -> MobileSegmentSourceSummary {
        guard self.guardStorageAvailable() else {
            return MobileSegmentSourceSummary(
                pendingCount: 0,
                failedCount: 0,
                lastUploadAt: self.lastUploadAt,
                lastError: self.lastError
            )
        }
        var pending = 0
        var failed = 0
        for lifecycle in [MobileSegmentLifecycle.pending, .failed] {
            guard let directories = try? self.store.list(lifecycle) else { continue }
            for directory in directories {
                guard let manifest = try? self.store.readManifest(in: directory) else { continue }
                let resolution = manifest.resolution(for: source)
                guard resolution.state == .finalizedArtifact || resolution.state == .failedToFinalize else { continue }
                switch lifecycle {
                case .pending:
                    pending += 1
                case .failed:
                    failed += 1
                case .active:
                    break
                }
            }
        }
        return MobileSegmentSourceSummary(
            pendingCount: pending,
            failedCount: failed,
            lastUploadAt: self.lastUploadAt,
            lastError: self.lastError
        )
    }

    func refreshCounts() {
        guard self.storageDisabledReason == nil else {
            self.pendingCount = 0
            self.failedCount = 0
            self.finalizeFailedCount = 0
            return
        }
        self.pendingCount = (try? self.store.list(.pending).count) ?? 0
        let failed = (try? self.store.list(.failed)) ?? []
        self.failedCount = failed.count
        self.finalizeFailedCount = failed.reduce(into: 0) { count, directory in
            guard let failure = self.store.loadFailure(in: directory),
                  Self.finalizeFailureStages.contains(failure.stage)
            else {
                return
            }
            count += 1
        }
    }

    func migrateLegacyMobileItems(
        locationCacheRootURL: URL? = nil
    ) async {
        guard self.guardStorageAvailable() else { return }
        let fileManager = FileManager.default
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        let locationRoot = locationCacheRootURL ?? caches?.appendingPathComponent("Location", isDirectory: true)

        if let locationRoot {
            await self.migrateLegacyLocationItems(root: locationRoot, fileManager: fileManager)
            guard !Task.isCancelled else { return }
        }
        await self.resumeFromDisk()
    }
}

private extension MobileSegmentUploader {
    func guardStorageAvailable() -> Bool {
        guard let storageDisabledReason else { return true }
        self.lastError = storageDisabledReason
        return false
    }

    func requireStorageAvailable() throws {
        guard let storageDisabledReason else { return }
        self.lastError = storageDisabledReason
        throw MobileSegmentUploaderError.storageUnavailable(storageDisabledReason)
    }

    func writeLocationArtifact(
        batch: LocationSegmentBatch,
        directory: URL,
        endedAt: Date,
        reason: String?,
        manifest: inout MobileSegmentManifest
    ) throws {
        let frozen = try MobileSegmentLocationWriter.freeze(batch)
        let target = self.store.locationURL(in: directory)
        try self.store.writeData(frozen.data, to: target)
        let resolution = MobileSegmentSourceResolution(
            state: .finalizedArtifact,
            artifactFilename: target.lastPathComponent,
            bytes: self.store.fileSize(at: target),
            startedAt: batch.segmentStart,
            endedAt: endedAt,
            durationS: TimeInterval(batch.coveredSeconds),
            reason: reason,
            fixCount: frozen.fixCount
        )
        try self.store.writeOutcome(resolution, source: .location, manifest: &manifest, in: directory, now: endedAt)
        self.removeLocationLiveFiles(in: directory)
    }

    func removeLocationLiveFiles(in directory: URL) {
        self.store.removeIfExists(self.store.locationPartURL(in: directory))
        self.store.removeIfExists(self.store.locationLivenessURL(in: directory))
    }

    func removeLocationLocalFiles(in directory: URL) {
        self.store.removeIfExists(self.store.locationURL(in: directory))
        self.removeLocationLiveFiles(in: directory)
    }

    func writeLocationRemoved(
        segmentID: UUID,
        directory: URL,
        manifest: inout MobileSegmentManifest,
        now: Date,
        reason: String
    ) throws {
        self.removeLocationLocalFiles(in: directory)
        let resolution = MobileSegmentSourceResolution(
            state: .removed,
            reason: reason,
            lastAttemptAt: now
        )
        try self.store.writeOutcome(resolution, source: .location, manifest: &manifest, in: directory, now: now)
        mobileSegmentUploadLog.info("location facet removed segment=\(segmentID.uuidString, privacy: .public) reason=\(reason, privacy: .public)")
    }

    func writeLocationArtifactOutcome(
        segmentID: UUID,
        directory: URL,
        manifest: inout MobileSegmentManifest,
        now: Date
    ) throws {
        let locationURL = self.store.locationURL(in: directory)
        let header = try? MobileSegmentLocationWriter.loadSnapshotHeader(from: self.store.readData(at: locationURL))
        let resolution = MobileSegmentSourceResolution(
            state: .finalizedArtifact,
            artifactFilename: locationURL.lastPathComponent,
            bytes: self.store.fileSize(at: locationURL),
            startedAt: manifest.startedAt,
            endedAt: now,
            durationS: MobileSegmentDuration.bounded(container: nil, elapsed: now.timeIntervalSince(manifest.startedAt)),
            fixCount: header?.fixCount
        )
        try self.store.writeOutcome(resolution, source: .location, manifest: &manifest, in: directory, now: now)
        self.removeLocationLiveFiles(in: directory)
        mobileSegmentUploadLog.info("location canonical artifact recovered segment=\(segmentID.uuidString, privacy: .public)")
    }

    func readLocationLiveness(segmentID: UUID, directory: URL) -> MobileSegmentLocationSegmentLiveness? {
        let livenessURL = self.store.locationLivenessURL(in: directory)
        guard self.store.fileExists(livenessURL),
              let data = try? self.store.readData(at: livenessURL),
              let liveness = try? MobileSegmentLocationWriter.decoder().decode(
                MobileSegmentLocationSegmentLiveness.self,
                from: data
              ),
              liveness.segmentID == segmentID
        else {
            return nil
        }
        return liveness
    }

    func hasFreshLocationLiveness(segmentID: UUID, directory: URL, now: Date) -> Bool {
        guard let liveness = self.readLocationLiveness(segmentID: segmentID, directory: directory) else {
            return false
        }
        return MobileSegmentLocationLivenessPolicy.isFresh(lastSeenAt: liveness.lastSeenAt, now: now)
    }

    func recoverLocationLive(
        segmentID: UUID,
        directory: URL,
        manifest: inout MobileSegmentManifest,
        now: Date
    ) throws {
        let partURL = self.store.locationPartURL(in: directory)
        let data = try self.store.readData(at: partURL)
        let recovered: MobileSegmentLocationWriter.RecoveredLiveLocation
        do {
            recovered = try MobileSegmentLocationWriter.recoverLiveLocation(segmentID: segmentID, from: data)
        } catch {
            mobileSegmentUploadLog.error("location live recovery corrupt segment=\(segmentID.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
            try self.writeLocationRemoved(
                segmentID: segmentID,
                directory: directory,
                manifest: &manifest,
                now: now,
                reason: "location_live_corrupt"
            )
            return
        }

        let liveness = self.readLocationLiveness(segmentID: segmentID, directory: directory)
        let endedAt = liveness?.lastSeenAt ?? recovered.latestRecordAt
        let batch = recovered.batch(endedAt: endedAt)
        let reason = recovered.droppedLineCount == 0 ? nil : "location_live_partial_salvage"
        if recovered.droppedLineCount > 0 {
            mobileSegmentUploadLog.info("location live partial salvage segment=\(segmentID.uuidString, privacy: .public) dropped_lines=\(recovered.droppedLineCount, privacy: .public)")
        }
        try self.recordLocationFinalized(segmentID: segmentID, directory: directory, batch: batch, endedAt: endedAt, reason: reason)
        manifest = try self.store.readManifest(in: directory)
        mobileSegmentUploadLog.info("location live recovered segment=\(segmentID.uuidString, privacy: .public)")
    }

    func migrateLegacyLocationItems(root: URL, fileManager: FileManager) async {
        guard fileManager.fileExists(atPath: root.path) else { return }
        for legacyState in ["pending", "failed"] {
            let directory = root.appendingPathComponent(legacyState, isDirectory: true)
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for locationURL in entries where locationURL.pathExtension == "jsonl" {
                guard !Task.isCancelled else { return }
                await self.cooperator.step()
                guard !Task.isCancelled else { return }
                do {
                    try self.migrateLegacyLocationItem(locationURL: locationURL, fileManager: fileManager)
                } catch {
                    mobileSegmentUploadLog.error("legacy location migration skipped \(locationURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    func migrateLegacyLocationItem(locationURL: URL, fileManager: FileManager) throws {
        let parsed = self.parseLegacyLocationFilename(locationURL)
        let data = try Data(contentsOf: locationURL)
        let header = try? MobileSegmentLocationWriter.loadSnapshotHeader(from: data)
        let fileID = locationURL.deletingPathExtension().lastPathComponent
        let segmentID = self.legacySegmentID(kind: "location", key: fileID)
        if self.hasDurableBundle(segmentID: segmentID, source: .location) {
            try fileManager.removeItem(at: locationURL)
            mobileSegmentUploadLog.info("legacy location already migrated \(locationURL.lastPathComponent, privacy: .public)")
            return
        }
        if let found = self.store.findDirectory(segmentID: segmentID) {
            mobileSegmentUploadLog.error("legacy location migration collision \(segmentID.uuidString, privacy: .public) lifecycle=\(found.lifecycle.rawValue, privacy: .public)")
            throw MobileSegmentStoreError.destinationCollision(segmentID: segmentID, lifecycle: found.lifecycle)
        }
        let activeDirectory = try self.createSingleSourceMigrationBundle(
            segmentID: segmentID,
            source: .location,
            startedAt: parsed.startedAt,
            duration: parsed.duration,
            day: parsed.day,
            segment: parsed.segment,
            lifecycle: .pending
        )
        let target = self.store.locationURL(in: activeDirectory)
        try self.store.copyOrReplaceItem(at: locationURL, to: target)
        var manifest = try self.store.readManifest(in: activeDirectory)
        let resolution = MobileSegmentSourceResolution(
            state: .finalizedArtifact,
            artifactFilename: target.lastPathComponent,
            bytes: self.store.fileSize(at: target),
            startedAt: parsed.startedAt,
            endedAt: parsed.startedAt.addingTimeInterval(parsed.duration),
            durationS: parsed.duration,
            fixCount: header?.fixCount
        )
        try self.store.writeOutcome(resolution, source: .location, manifest: &manifest, in: activeDirectory, now: self.clock.now())
        try self.finishMigratedBundle(segmentID: segmentID, activeDirectory: activeDirectory, lifecycle: .pending)
        try fileManager.removeItem(at: locationURL)
        mobileSegmentUploadLog.info("legacy location migrated \(locationURL.lastPathComponent, privacy: .public)")
    }

    func createSingleSourceMigrationBundle(
        segmentID: UUID,
        source: MobileSegmentSource,
        startedAt: Date,
        duration: TimeInterval,
        day: String,
        segment: String,
        lifecycle: MobileSegmentLifecycle
    ) throws -> URL {
        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: Set([source]),
            activeSourceSetVersion: 0
        )
        manifest.day = day
        manifest.segment = segment
        manifest.endedAt = startedAt.addingTimeInterval(duration)
        manifest.durationS = duration
        manifest.upload = lifecycle == .failed ? .failed : .pending
        let directory = try self.store.createActive(manifest: manifest)
        return directory
    }

    func finishMigratedBundle(
        segmentID: UUID,
        activeDirectory: URL,
        lifecycle: MobileSegmentLifecycle
    ) throws {
        _ = try self.store.move(segmentID: segmentID, from: .active, to: lifecycle)
        self.refreshCounts()
    }

    func parseLegacyLocationFilename(_ url: URL) -> (day: String, segment: String, startedAt: Date, duration: TimeInterval) {
        let fileID = url.deletingPathExtension().lastPathComponent
        let parts = fileID.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let day = parts.first.map(String.init) ?? Self.dayString(for: self.clock.now())
        let segment = parts.count == 2 ? String(parts[1]) : ChunkSidecar.segmentString(for: self.clock.now(), durationSeconds: 1)
        let segmentParts = segment.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
        let duration = segmentParts.count == 2 ? TimeInterval(Int(segmentParts[1]) ?? 1) : 1
        return (day, segment, self.date(day: day, segment: segment) ?? self.clock.now(), max(duration, 1))
    }

    func date(day: String, segment: String) -> Date? {
        let time = segment.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "000000"
        guard day.count == 8, time.count == 6 else { return nil }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = Int(day.prefix(4))
        components.month = Int(day.dropFirst(4).prefix(2))
        components.day = Int(day.suffix(2))
        components.hour = Int(time.prefix(2))
        components.minute = Int(time.dropFirst(2).prefix(2))
        components.second = Int(time.suffix(2))
        return components.calendar?.date(from: components)
    }

    func fileDate(_ url: URL, fileManager: FileManager) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
    }

    func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    func hasDurableBundle(segmentID: UUID, source: MobileSegmentSource) -> Bool {
        guard let found = self.store.findDirectory(segmentID: segmentID),
              found.lifecycle != .active,
              let manifest = try? self.store.readManifest(in: found.url)
        else { return false }
        return manifest.resolution(for: source).state == .finalizedArtifact
    }

    func legacySegmentID(kind: String, key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("mobile-segment:\(kind):\(key)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    func enqueuePendingSegmentIntoTransfer(segmentID: UUID) async {
        guard self.guardStorageAvailable() else { return }
        guard self.enqueuingSegmentIDs.insert(segmentID).inserted else { return }
        defer { self.enqueuingSegmentIDs.remove(segmentID) }

        let directory = self.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        guard self.store.fileExists(directory) else { return }

        var manifest: MobileSegmentManifest
        do {
            manifest = try self.store.readManifest(in: directory)
        } catch {
            self.quarantinePendingDirectory(directory, reason: "manifest unreadable")
            self.refreshCounts()
            return
        }

        do {
            guard manifest.isFullyResolved else {
                let now = self.clock.now()
                for source in manifest.declaredSources where !manifest.resolution(for: source).state.isTerminal {
                    let resolution = MobileSegmentSourceResolution(
                        state: .failedToFinalize,
                        reason: "missing terminal outcome marker",
                        stage: "schedule-gate",
                        lastAttemptAt: now
                    )
                    try self.store.writeOutcome(resolution, source: source, manifest: &manifest, in: directory, now: now)
                    manifest = try self.store.readManifest(in: directory)
                }
                try self.failPendingSegment(
                    segmentID: segmentID,
                    reason: "missing terminal outcome marker",
                    stage: "schedule-gate"
                )
                return
            }

            if manifest.hasFinalizeFailure {
                do {
                    let result = try await self.resolveFinalizeFailure(segmentID: segmentID, directory: directory, lifecycle: .pending)
                    switch result {
                    case .repend:
                        manifest = try self.store.readManifest(in: directory)
                    case .retired, .deferred:
                        return
                    }
                } catch {
                    let diagnostic = "mobile segment finalize-failure deferred segment=\(segmentID.uuidString) stage=schedule"
                    self.lastError = diagnostic
                    mobileSegmentUploadLog.error("\(diagnostic, privacy: .public)")
                    return
                }
            }

            let declaredParts = try self.declaredTransferParts(
                manifest: manifest,
                directory: directory,
                segmentID: segmentID
            )
            guard !declaredParts.isEmpty else { return }
            guard let transferEngine else { throw MobileSegmentUploaderError.transferEngineUnavailable }

            let payloadParts = declaredParts.map(\.descriptor)
            let transferManifest = ObserverAudioTransferEnqueuer.makeMobileSegmentManifest(
                itemID: segmentID,
                manifest: manifest,
                now: self.clock.now(),
                sources: declaredParts.map(\.source),
                payloadParts: payloadParts
            )
            let tempDirectory = try self.copyDeclaredPartsToTemp(declaredParts, segmentID: segmentID)
            defer { try? FileManager.default.removeItem(at: tempDirectory) }
            var payloadFileURLs: [String: URL] = [:]
            for part in declaredParts {
                payloadFileURLs[part.descriptor.partID] = tempDirectory
                    .appendingPathComponent(part.descriptor.relativePath, isDirectory: false)
            }
            _ = try await transferEngine.enqueueIfAbsent(
                manifest: transferManifest,
                equivalentObserverSegmentID: segmentID,
                payloadFileURLs: payloadFileURLs
            )
            try self.store.remove(directory)
        } catch {
            let diagnostic = "mobile segment enqueue failed segment=\(segmentID.uuidString) stage=transfer-enqueue"
            self.lastError = diagnostic
            mobileSegmentUploadLog.error("\(diagnostic, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        self.refreshCounts()
    }

    private func retireDeliveredResidue() throws {
        for lifecycle in [MobileSegmentLifecycle.pending, .failed] {
            for directory in try self.store.list(lifecycle) {
                guard let segmentID = UUID(uuidString: directory.lastPathComponent),
                      self.store.hasTombstone(segmentID: segmentID, kind: "uploaded")
                else { continue }
                try self.store.remove(directory)
                mobileSegmentUploadLog.notice(
                    "mobile segment retired delivered residue segment=\(segmentID.uuidString, privacy: .public) lifecycle=\(lifecycle.rawValue, privacy: .public)"
                )
            }
        }
    }

    private func retireDeliveredResidue(segmentID: UUID) throws {
        for lifecycle in [MobileSegmentLifecycle.pending, .failed] {
            try self.store.remove(self.store.segmentDirectoryURL(lifecycle, segmentID: segmentID))
        }
    }

    private func retireTransferOwnedResidue() async {
        guard let transferEngine else { return }
        for lifecycle in [MobileSegmentLifecycle.pending, .failed] {
            guard let directories = try? self.store.list(lifecycle) else { continue }
            for directory in directories {
                guard let segmentID = UUID(uuidString: directory.lastPathComponent),
                      let manifest = try? self.store.readManifest(in: directory),
                      manifest.isFullyResolved,
                      !manifest.hasFinalizeFailure
                else { continue }
                let declaredParts = manifest.declaredSources.compactMap { source -> MobileSegmentDeclaredPart? in
                    guard manifest.resolution(for: source).state == .finalizedArtifact else { return nil }
                    let artifactURL = self.store.artifactURL(in: directory, source: source)
                    guard self.store.fileExists(artifactURL) else { return nil }
                    return MobileSegmentDeclaredPart(
                        source: source,
                        descriptor: self.transferPartDescriptor(for: source),
                        artifactURL: artifactURL
                    )
                }
                guard !declaredParts.isEmpty,
                      declaredParts.count == manifest.declaredSources.filter({
                          manifest.resolution(for: $0).state == .finalizedArtifact
                      }).count
                else { continue }
                let expectedManifest = ObserverAudioTransferEnqueuer.makeMobileSegmentManifest(
                    itemID: segmentID,
                    manifest: manifest,
                    now: self.clock.now(),
                    sources: declaredParts.map(\.source),
                    payloadParts: declaredParts.map(\.descriptor)
                )
                let payloadURLs = Dictionary(uniqueKeysWithValues: declaredParts.map {
                    ($0.descriptor.partID, $0.artifactURL)
                })
                do {
                    let verdict = try await transferEngine.verifyEquivalentOwnership(
                        expectedManifest: expectedManifest,
                        equivalentObserverSegmentID: segmentID,
                        expectedPayloadSourceURLs: payloadURLs
                    )
                    guard verdict == .ownedInQueued || verdict == .ownedInAttention else {
                        if case .conflict = verdict {
                            let diagnostic = "mobile segment ownership conflict segment=\(segmentID.uuidString) stage=transfer-recovery"
                            self.lastError = diagnostic
                            mobileSegmentUploadLog.error("\(diagnostic, privacy: .public)")
                        }
                        continue
                    }
                    try self.store.remove(directory)
                    mobileSegmentUploadLog.notice(
                        "mobile segment retired verified transfer-owned residue segment=\(segmentID.uuidString, privacy: .public) lifecycle=\(lifecycle.rawValue, privacy: .public)"
                    )
                } catch {
                    let diagnostic = "mobile segment ownership verification failed segment=\(segmentID.uuidString) stage=transfer-recovery"
                    self.lastError = diagnostic
                    mobileSegmentUploadLog.error(
                        "\(diagnostic, privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }
    }

    private func failPendingSegment(segmentID: UUID, reason: String, stage: String) throws {
        let pendingDirectory = self.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        guard self.store.fileExists(pendingDirectory) else { return }
        var manifest = try self.store.readManifest(in: pendingDirectory)
        let now = self.clock.now()
        manifest.upload = .failed
        manifest.updatedAt = now
        try self.store.writeManifest(manifest, in: pendingDirectory)
        try self.store.writeFailure(
            MobileSegmentFailureSidecar(
                reason: reason,
                httpStatus: nil,
                transportError: nil,
                attemptCount: 0,
                stage: stage,
                lastAttemptAt: now
            ),
            in: pendingDirectory
        )
        _ = try self.store.move(segmentID: segmentID, from: .pending, to: .failed)
        self.refreshCounts()
    }

    private func declaredTransferParts(
        manifest: MobileSegmentManifest,
        directory: URL,
        segmentID: UUID
    ) throws -> [MobileSegmentDeclaredPart] {
        var parts: [MobileSegmentDeclaredPart] = []
        for source in manifest.declaredSources where manifest.resolution(for: source).state == .finalizedArtifact {
            let artifactURL = self.store.artifactURL(in: directory, source: source)
            guard self.store.fileExists(artifactURL) else {
                try self.failPendingSegment(
                    segmentID: segmentID,
                    reason: "finalized artifact missing source=\(source.rawValue)",
                    stage: "schedule-gate"
                )
                return []
            }
            parts.append(MobileSegmentDeclaredPart(
                source: source,
                descriptor: self.transferPartDescriptor(for: source),
                artifactURL: artifactURL
            ))
        }
        return parts
    }

    private func transferPartDescriptor(for source: MobileSegmentSource) -> TransferPayloadPartDescriptor {
        switch source {
        case .audio:
            ObserverAudioTransferEnqueuer.audioPart()
        case .location:
            ObserverAudioTransferEnqueuer.locationPart()
        case .screencast:
            ObserverAudioTransferEnqueuer.screencastPart()
        }
    }

    private func copyDeclaredPartsToTemp(_ parts: [MobileSegmentDeclaredPart], segmentID: UUID) throws -> URL {
        let fileManager = FileManager.default
        let tempDirectory = self.transferEnqueueTempRoot()
            .appendingPathComponent("\(segmentID.uuidString)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        do {
            for part in parts {
                let destination = tempDirectory.appendingPathComponent(part.descriptor.relativePath, isDirectory: false)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: part.artifactURL, to: destination)
                guard try Data(contentsOf: part.artifactURL) == Data(contentsOf: destination) else {
                    throw MobileSegmentUploaderError.copyVerificationFailed(part.artifactURL)
                }
            }
            return tempDirectory
        } catch {
            try? fileManager.removeItem(at: tempDirectory)
            throw error
        }
    }

    private func transferEnqueueTempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(mobileSegmentTransferTempRootName, isDirectory: true)
    }

    private func sweepStaleTransferEnqueueTemps() {
        let root = self.transferEnqueueTempRoot()
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            mobileSegmentUploadLog.error("mobile segment temp sweep failed source=\(root.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func quarantinePendingDirectory(_ directory: URL, reason: String) {
        let quarantineRoot = MobileSegmentTransferSpoolMigrator.quarantineRootURL(
            appGroupRootURL: self.store.rootURL.deletingLastPathComponent()
        )
        _ = MobileSegmentTransferSpoolMigrator.quarantine(
            directory,
            quarantineRootURL: quarantineRoot,
            diagnosticLog: nil,
            reason: reason,
            fileManager: .default
        )
    }

    func reconcileActiveSegments() async throws {
        guard self.guardStorageAvailable() else { return }
        let active = try self.store.list(.active)
        for directory in active {
            guard !Task.isCancelled else { return }
            await self.cooperator.step()
            guard !Task.isCancelled else { return }
            guard let segmentID = UUID(uuidString: directory.lastPathComponent) else { continue }
            let now = self.clock.now()
            if self.isReservedLeasedScreencastSegment(segmentID: segmentID, now: now) {
                continue
            }
            var manifest = try self.store.readManifest(in: directory)
            let screenURL = self.store.screenURL(in: directory)
            var hasLiveUnresolvedScreencast = false
            var hasLiveUnresolvedLocation = false
            if !manifest.openedWithSources.contains(.screencast),
               manifest.screencast.state == .notDeclared,
               self.store.fileExists(screenURL) {
                let diagnostic = "ignored undeclared screencast artifact segment=\(segmentID.uuidString) source=screencast"
                self.lastError = diagnostic
                mobileSegmentUploadLog.error("\(diagnostic, privacy: .public)")
            }
            for source in manifest.declaredSources {
                let resolution = manifest.resolution(for: source)
                if source == .location,
                   resolution.state == .failedToFinalize,
                   !self.store.fileExists(self.store.locationURL(in: directory)),
                   !self.store.fileExists(self.store.locationPartURL(in: directory)) {
                    try self.writeLocationRemoved(
                        segmentID: segmentID,
                        directory: directory,
                        manifest: &manifest,
                        now: now,
                        reason: "location_live_missing"
                    )
                    manifest = try self.store.readManifest(in: directory)
                    continue
                }
                guard !resolution.state.isTerminal else { continue }
                switch source {
                case .audio:
                    let audioURL = self.store.audioURL(in: directory)
                    if self.store.fileExists(audioURL) {
                        let finalized = MobileSegmentSourceResolution(
                            state: .finalizedArtifact,
                            artifactFilename: audioURL.lastPathComponent,
                            bytes: self.store.fileSize(at: audioURL),
                            startedAt: manifest.startedAt,
                            endedAt: now,
                            durationS: MobileSegmentDuration.bounded(
                                container: await MobileSegmentDuration.probeContainerDuration(at: audioURL),
                                elapsed: now.timeIntervalSince(manifest.startedAt)
                            ),
                            mode: resolution.mode
                        )
                        try self.store.writeOutcome(finalized, source: .audio, manifest: &manifest, in: directory, now: now)
                    } else {
                        let failed = MobileSegmentSourceResolution(
                            state: .failedToFinalize,
                            reason: "unclean relaunch unresolved source",
                            stage: "reconcile",
                            lastAttemptAt: now
                        )
                        try self.store.writeOutcome(failed, source: .audio, manifest: &manifest, in: directory, now: now)
                    }
                case .location:
                    let locationURL = self.store.locationURL(in: directory)
                    let locationPartURL = self.store.locationPartURL(in: directory)
                    if self.store.fileExists(locationURL) {
                        try self.writeLocationArtifactOutcome(
                            segmentID: segmentID,
                            directory: directory,
                            manifest: &manifest,
                            now: now
                        )
                    } else if self.store.fileExists(locationPartURL) {
                        if self.hasFreshLocationLiveness(segmentID: segmentID, directory: directory, now: now) {
                            hasLiveUnresolvedLocation = true
                            continue
                        }
                        try self.recoverLocationLive(
                            segmentID: segmentID,
                            directory: directory,
                            manifest: &manifest,
                            now: now
                        )
                    } else {
                        try self.writeLocationRemoved(
                            segmentID: segmentID,
                            directory: directory,
                            manifest: &manifest,
                            now: now,
                            reason: "location_live_missing"
                        )
                    }
                case .screencast:
                    let screenPartURL = self.store.screenPartURL(in: directory)
                    if self.store.fileExists(screenURL) {
                        let finalized = MobileSegmentSourceResolution(
                            state: .finalizedArtifact,
                            artifactFilename: screenURL.lastPathComponent,
                            bytes: self.store.fileSize(at: screenURL),
                            startedAt: manifest.startedAt,
                            endedAt: now,
                            durationS: MobileSegmentDuration.bounded(
                                container: await MobileSegmentDuration.probeContainerDuration(at: screenURL),
                                elapsed: now.timeIntervalSince(manifest.startedAt)
                            )
                        )
                        try self.store.writeOutcome(finalized, source: .screencast, manifest: &manifest, in: directory, now: now)
                    } else {
                        if self.store.fileExists(screenPartURL),
                           self.hasFreshScreencastLiveness(segmentID: segmentID, directory: directory, now: now) {
                            hasLiveUnresolvedScreencast = true
                            continue
                        }
                        let failed = MobileSegmentSourceResolution(
                            state: .failedToFinalize,
                            reason: self.store.fileExists(screenPartURL) ? "screencast_partial_artifact" : "unclean relaunch unresolved source",
                            stage: "reconcile",
                            lastAttemptAt: now
                        )
                        try self.store.writeOutcome(failed, source: .screencast, manifest: &manifest, in: directory, now: now)
                    }
                }
                manifest = try self.store.readManifest(in: directory)
            }
            if !hasLiveUnresolvedScreencast && !hasLiveUnresolvedLocation {
                await self.finalizeActiveSegment(segmentID: segmentID, endedAt: now)
            }
        }
    }

    private func hasFreshScreencastLiveness(segmentID: UUID, directory: URL, now: Date) -> Bool {
        let diagnosticURL = MobileSegmentScreencastPaths.screenDiagnosticURL(inSegmentDirectory: directory)
        guard !self.store.fileExists(diagnosticURL) else { return false }
        let livenessURL = MobileSegmentScreencastPaths.screenLivenessURL(inSegmentDirectory: directory)
        guard self.store.fileExists(livenessURL),
              let liveness = try? MobileSegmentScreencastJSONStore.read(
                MobileSegmentScreencastSegmentLiveness.self,
                from: livenessURL
              ),
              liveness.segmentID == segmentID else {
            return false
        }
        return MobileSegmentScreencastLivenessPolicy.isFresh(lastSeenAt: liveness.lastSeenAt, now: now)
    }

    private func isReservedLeasedScreencastSegment(segmentID: UUID, now: Date) -> Bool {
        let leasesDirectory = self.store.rootURL
            .appendingPathComponent("screencast", isDirectory: true)
            .appendingPathComponent("leases", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: leasesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }
        return urls.contains { url in
            guard let lease = try? MobileSegmentScreencastJSONStore.read(
                MobileSegmentScreencastContinuationLease.self,
                from: url
            ) else { return false }
            return lease.segmentID == segmentID && now <= lease.expiresAt
        }
    }

    func onThisPhoneItems(source: MobileSegmentSource, lifecycle: MobileSegmentLifecycle) throws -> [OnThisPhoneItem] {
        let directories = try self.store.list(lifecycle)
        var items: [OnThisPhoneItem] = []
        for directory in directories {
            guard let segmentID = UUID(uuidString: directory.lastPathComponent) else { continue }
            let manifest = try self.store.readManifest(in: directory)
            let resolution = manifest.resolution(for: source)
            guard resolution.state == .finalizedArtifact || resolution.state == .failedToFinalize else { continue }
            let failure = lifecycle == .failed ? self.store.loadFailure(in: directory) : nil
            let url: URL?
            let contentType: String?
            let filename: String?
            let bytes: Int64?
            let sourceKind: OnThisPhoneSourceKind
            switch source {
            case .audio:
                url = resolution.state == .finalizedArtifact ? self.store.audioURL(in: directory) : nil
                contentType = "audio/mp4"
                filename = "audio.m4a"
                bytes = url.flatMap { self.store.fileSize(at: $0) } ?? resolution.bytes
                sourceKind = .audio
            case .location:
                url = resolution.state == .finalizedArtifact ? self.store.locationURL(in: directory) : nil
                contentType = "application/jsonl"
                filename = "location.jsonl"
                bytes = url.flatMap { self.store.fileSize(at: $0) } ?? resolution.bytes
                sourceKind = .location
            case .screencast:
                url = resolution.state == .finalizedArtifact ? self.store.screenURL(in: directory) : nil
                contentType = "video/mp4"
                filename = "screen.mp4"
                bytes = url.flatMap { self.store.fileSize(at: $0) } ?? resolution.bytes
                sourceKind = .screencast
            }
            items.append(OnThisPhoneItem(
                id: "mobile-segment:\(segmentID.uuidString):\(source.rawValue)",
                dropGroupID: "mobile-segment:\(segmentID.uuidString)",
                sourceKind: sourceKind,
                sendState: onThisPhoneSendState(location: lifecycle == .failed ? .failed : .pending, canRetry: lifecycle == .failed, isActivelyUploading: false),
                contentType: contentType,
                filename: filename,
                bytes: bytes,
                originApp: nil,
                basis: nil,
                itemTime: resolution.startedAt ?? manifest.startedAt,
                targetJournal: nil,
                stream: nil,
                day: manifest.day,
                segment: manifest.segment,
                deliveredAt: nil,
                rawFileURL: url,
                audioDurationS: source == .audio ? resolution.durationS : nil,
                locationFixCount: source == .location ? resolution.fixCount : nil,
                failureReason: failure?.reason ?? resolution.reason,
                failureAttemptCount: failure?.attemptCount,
                sourceLabel: nil,
                retryAvailable: lifecycle == .failed,
                lastAttemptAt: failure?.lastAttemptAt ?? resolution.lastAttemptAt
            ))
        }
        return items
    }

    static func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

private extension MobileSegmentResolutionState {
    var isLocalFacet: Bool {
        switch self {
        case .finalizedArtifact, .noArtifact, .failedToFinalize:
            true
        case .notDeclared, .unresolved, .removed:
            false
        }
    }
}
