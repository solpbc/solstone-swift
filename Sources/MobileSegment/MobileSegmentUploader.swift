// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation
import Observation
import os

private let mobileSegmentUploadLog = Logger(subsystem: "app.solstone.swift", category: "mobile-segment")

@MainActor
@Observable
final class MobileSegmentUploader {
    private(set) var pendingCount = 0
    private(set) var failedCount = 0
    var lastUploadAt: Date?
    var lastError: String?
    private(set) var recentErrorCount = 0

    var inFlightCount: Int {
        self.schedulingSegmentIDs.count + self.transportInFlightSegmentIDs.count
    }

    @ObservationIgnored private let store: MobileSegmentStore
    @ObservationIgnored private let transport: ObserverUploader
    @ObservationIgnored private let clock: any ObserverClock
    @ObservationIgnored private var schedulingSegmentIDs: Set<UUID> = []
    @ObservationIgnored private var transportInFlightSegmentIDs: Set<UUID> = []

    init(
        transport: ObserverUploader,
        store: MobileSegmentStore = MobileSegmentStore(),
        clock: any ObserverClock = SystemObserverClock()
    ) {
        self.transport = transport
        self.store = store
        self.clock = clock
        try? self.store.ensureRoot()
        self.refreshCounts()
    }

    func openSegment(sources: Set<MobileSegmentSource>, startedAt: Date, sourceSetVersion: Int) throws -> UUID {
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

    func activeDirectory(segmentID: UUID) -> URL {
        self.store.segmentDirectoryURL(.active, segmentID: segmentID)
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

    func recordLocationFinalized(
        segmentID: UUID,
        batch: LocationSegmentBatch,
        endedAt: Date
    ) throws {
        let directory = self.activeDirectory(segmentID: segmentID)
        var manifest = try self.store.readManifest(in: directory)
        guard manifest.openedWithSources.contains(.location) else { return }

        guard !batch.fixes.isEmpty || !batch.visits.isEmpty else {
            let resolution = MobileSegmentSourceResolution(
                state: .noArtifact,
                startedAt: batch.segmentStart,
                endedAt: endedAt,
                durationS: TimeInterval(batch.coveredSeconds),
                reason: batch.gap ? "authorization_gap_only" : "location_no_fixes_or_visits",
                fixCount: 0
            )
            try self.store.writeOutcome(resolution, source: .location, manifest: &manifest, in: directory, now: endedAt)
            return
        }

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
            fixCount: frozen.fixCount
        )
        try self.store.writeOutcome(resolution, source: .location, manifest: &manifest, in: directory, now: endedAt)
    }

    func recordLocationFinalizeFailed(
        segmentID: UUID,
        startedAt: Date,
        endedAt: Date,
        reason: String
    ) throws {
        let directory = self.activeDirectory(segmentID: segmentID)
        var manifest = try self.store.readManifest(in: directory)
        guard manifest.openedWithSources.contains(.location) else { return }
        let resolution = MobileSegmentSourceResolution(
            state: .failedToFinalize,
            startedAt: startedAt,
            endedAt: endedAt,
            reason: reason,
            stage: "source-finalize",
            lastAttemptAt: endedAt
        )
        try self.store.writeOutcome(resolution, source: .location, manifest: &manifest, in: directory, now: endedAt)
    }

    func finalizeActiveSegment(segmentID: UUID, endedAt: Date) async {
        let directory = self.activeDirectory(segmentID: segmentID)
        do {
            var manifest = try self.store.readManifest(in: directory)
            manifest.endedAt = endedAt
            manifest.durationS = max(0, endedAt.timeIntervalSince(manifest.startedAt))
            manifest.day = Self.dayString(for: manifest.startedAt)
            manifest.segment = ChunkSidecar.segmentString(for: manifest.startedAt, durationSeconds: manifest.durationS ?? 0)
            manifest.updatedAt = endedAt

            for source in manifest.declaredSources where !manifest.resolution(for: source).state.isTerminal {
                let resolution = MobileSegmentSourceResolution(
                    state: .failedToFinalize,
                    reason: "missing outcome marker for \(source.rawValue)",
                    stage: "segment-finalize",
                    lastAttemptAt: endedAt
                )
                try self.store.writeOutcome(resolution, source: source, manifest: &manifest, in: directory, now: endedAt)
                manifest = try self.store.readManifest(in: directory)
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
                await self.scheduleUpload(segmentID: segmentID)
            }
        } catch {
            mobileSegmentUploadLog.error("mobile segment finalize failed \(segmentID.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
            self.lastError = String(describing: error)
        }
        self.refreshCounts()
    }

    func resumeFromDisk() async {
        do {
            try self.store.ensureRoot()
            try await self.reconcileActiveSegments()
            let pending = try self.store.list(.pending)
            for directory in pending {
                guard let segmentID = UUID(uuidString: directory.lastPathComponent) else { continue }
                await self.scheduleUpload(segmentID: segmentID)
            }
        } catch {
            self.lastError = String(describing: error)
            mobileSegmentUploadLog.error("mobile segment resume failed: \(String(describing: error), privacy: .public)")
        }
        self.refreshCounts()
    }

    func retryFailed() async {
        do {
            let failed = try self.store.list(.failed)
            for directory in failed {
                guard let segmentID = UUID(uuidString: directory.lastPathComponent) else { continue }
                var manifest = try self.store.readManifest(in: directory)
                guard !manifest.hasFinalizeFailure, manifest.hasArtifact else { continue }
                manifest.upload = .pending
                manifest.updatedAt = self.clock.now()
                try self.store.writeManifest(manifest, in: directory)
                _ = try self.store.move(segmentID: segmentID, from: .failed, to: .pending)
                await self.scheduleUpload(segmentID: segmentID)
            }
        } catch {
            self.lastError = String(describing: error)
            mobileSegmentUploadLog.error("mobile segment retry failed: \(String(describing: error), privacy: .public)")
        }
        self.refreshCounts()
    }

    func dropSegment(segmentID: UUID) {
        self.transport.cancelMobileSegmentUpload(segmentID: segmentID)
        self.transportInFlightSegmentIDs.remove(segmentID)
        self.schedulingSegmentIDs.remove(segmentID)
        if let found = self.store.findDirectory(segmentID: segmentID) {
            try? self.store.remove(found.url)
        }
        self.refreshCounts()
    }

    func redactLocationFacet(segmentID: UUID) async {
        guard let found = self.store.findDirectory(segmentID: segmentID) else { return }
        do {
            var manifest = try self.store.readManifest(in: found.url)
            guard manifest.location.state.isLocalLocationFacet else { return }
            self.store.removeIfExists(self.store.locationURL(in: found.url))
            let resolution = MobileSegmentSourceResolution(
                state: .removed,
                reason: "location_removed",
                lastAttemptAt: self.clock.now()
            )
            try self.store.writeOutcome(resolution, source: .location, manifest: &manifest, in: found.url, now: self.clock.now())
            if manifest.audio.state == .finalizedArtifact {
                manifest.upload = .pending
                try self.store.writeManifest(manifest, in: found.url)
                if found.lifecycle == .failed {
                    _ = try self.store.move(segmentID: segmentID, from: .failed, to: .pending)
                }
                await self.scheduleUpload(segmentID: segmentID)
            } else {
                try self.store.remove(found.url)
            }
        } catch {
            self.lastError = String(describing: error)
            mobileSegmentUploadLog.error("mobile segment location redaction failed \(segmentID.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        self.refreshCounts()
    }

    func deleteLocationLocalState() async {
        for lifecycle in [MobileSegmentLifecycle.pending, .failed] {
            guard let directories = try? self.store.list(lifecycle) else { continue }
            for directory in directories {
                guard let segmentID = UUID(uuidString: directory.lastPathComponent),
                      let manifest = try? self.store.readManifest(in: directory),
                      manifest.location.state.isLocalLocationFacet
                else { continue }
                if manifest.audio.state == .finalizedArtifact {
                    await self.redactLocationFacet(segmentID: segmentID)
                } else {
                    self.dropSegment(segmentID: segmentID)
                }
            }
        }
    }

    func onThisPhoneSnapshot(for source: MobileSegmentSource) -> OnThisPhoneSourceResult {
        do {
            var items: [OnThisPhoneItem] = []
            items.append(contentsOf: try self.onThisPhoneItems(source: source, lifecycle: .pending))
            items.append(contentsOf: try self.onThisPhoneItems(source: source, lifecycle: .failed))
            return .loaded(items: OnThisPhoneItemSort.newestFirst(items))
        } catch {
            mobileSegmentUploadLog.error("mobile segment on-this-phone snapshot failed: \(String(describing: error), privacy: .public)")
            return .failed
        }
    }

    func summary(for source: MobileSegmentSource) -> MobileSegmentSourceSummary {
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
        self.pendingCount = (try? self.store.list(.pending).count) ?? 0
        self.failedCount = (try? self.store.list(.failed).count) ?? 0
        self.lastUploadAt = self.transport.lastUploadAt
        self.lastError = self.lastError ?? self.transport.lastError
        self.recentErrorCount = self.transport.recentErrorCount
    }

    func migrateLegacyMobileItems(
        observerCacheRootURL: URL? = nil,
        locationCacheRootURL: URL? = nil
    ) async {
        let fileManager = FileManager.default
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        let observerRoot = observerCacheRootURL ?? caches?.appendingPathComponent("Observer", isDirectory: true)
        let locationRoot = locationCacheRootURL ?? caches?.appendingPathComponent("Location", isDirectory: true)

        if let observerRoot {
            await self.migrateLegacyObserverItems(root: observerRoot, fileManager: fileManager)
        }
        if let locationRoot {
            await self.migrateLegacyLocationItems(root: locationRoot, fileManager: fileManager)
        }
        await self.resumeFromDisk()
    }
}

private extension MobileSegmentUploader {
    func migrateLegacyObserverItems(root: URL, fileManager: FileManager) async {
        guard fileManager.fileExists(atPath: root.path),
              let sessions = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              )
        else { return }

        for sessionDirectory in sessions where self.isDirectory(sessionDirectory) {
            guard UUID(uuidString: sessionDirectory.lastPathComponent) != nil else { continue }
            for legacyState in ["in-progress", "pending", "failed"] {
                let directory = sessionDirectory.appendingPathComponent(legacyState, isDirectory: true)
                guard let entries = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for audioURL in entries where audioURL.pathExtension == "m4a" {
                    do {
                        try self.migrateLegacyAudioItem(audioURL: audioURL, legacyState: legacyState, fileManager: fileManager)
                    } catch {
                        mobileSegmentUploadLog.error("legacy mobile audio migration skipped \(audioURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                    }
                }
            }
        }
    }

    func migrateLegacyAudioItem(audioURL: URL, legacyState: String, fileManager: FileManager) throws {
        let chunkID = audioURL.deletingPathExtension().lastPathComponent
        let sessionID = audioURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        let sidecarURL = audioURL.deletingPathExtension().appendingPathExtension("json")
        let failureURL = audioURL.deletingPathExtension().appendingPathExtension("failure")
        let sidecar = try? JSONDecoder.observerSidecar.decode(ChunkSidecar.self, from: Data(contentsOf: sidecarURL))
        let startedAt = sidecar?.startedAt ?? self.fileDate(audioURL, fileManager: fileManager) ?? self.clock.now()
        let duration = max(sidecar?.durationS ?? 1, 1)
        let segmentID = self.legacySegmentID(kind: "audio", key: "\(sessionID):\(chunkID)")
        if self.hasDurableBundle(segmentID: segmentID, source: .audio) {
            try self.removeLegacyAudio(audioURL: audioURL, sidecarURL: sidecarURL, failureURL: failureURL, fileManager: fileManager)
            mobileSegmentUploadLog.info("legacy mobile audio already migrated \(chunkID, privacy: .public)")
            return
        }
        if let found = self.store.findDirectory(segmentID: segmentID) {
            mobileSegmentUploadLog.error("legacy mobile audio migration collision \(segmentID.uuidString, privacy: .public) lifecycle=\(found.lifecycle.rawValue, privacy: .public)")
            throw MobileSegmentStoreError.destinationCollision(segmentID: segmentID, lifecycle: found.lifecycle)
        }
        let lifecycle: MobileSegmentLifecycle = legacyState == "failed" ? .failed : .pending
        let activeDirectory = try self.createSingleSourceMigrationBundle(
            segmentID: segmentID,
            source: .audio,
            startedAt: startedAt,
            duration: duration,
            day: sidecar?.day ?? Self.dayString(for: startedAt),
            segment: sidecar?.segment ?? ChunkSidecar.segmentString(for: startedAt, durationSeconds: duration),
            lifecycle: lifecycle
        )
        let target = self.store.audioURL(in: activeDirectory)
        try self.store.copyOrReplaceItem(at: audioURL, to: target)
        var manifest = try self.store.readManifest(in: activeDirectory)
        let resolution = MobileSegmentSourceResolution(
            state: .finalizedArtifact,
            artifactFilename: target.lastPathComponent,
            bytes: self.store.fileSize(at: target),
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(duration),
            durationS: duration,
            mode: sidecar?.mode ?? .meeting
        )
        try self.store.writeOutcome(resolution, source: .audio, manifest: &manifest, in: activeDirectory, now: self.clock.now())
        try self.finishMigratedBundle(segmentID: segmentID, activeDirectory: activeDirectory, lifecycle: lifecycle, failureReason: legacyState == "failed" ? "legacy observer upload failed" : nil)
        try self.removeLegacyAudio(audioURL: audioURL, sidecarURL: sidecarURL, failureURL: failureURL, fileManager: fileManager)
        mobileSegmentUploadLog.info("legacy mobile audio migrated \(chunkID, privacy: .public)")
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
                do {
                    try self.migrateLegacyLocationItem(locationURL: locationURL, legacyState: legacyState, fileManager: fileManager)
                } catch {
                    mobileSegmentUploadLog.error("legacy location migration skipped \(locationURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    func migrateLegacyLocationItem(locationURL: URL, legacyState: String, fileManager: FileManager) throws {
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
        let lifecycle: MobileSegmentLifecycle = legacyState == "failed" ? .failed : .pending
        let activeDirectory = try self.createSingleSourceMigrationBundle(
            segmentID: segmentID,
            source: .location,
            startedAt: parsed.startedAt,
            duration: parsed.duration,
            day: parsed.day,
            segment: parsed.segment,
            lifecycle: lifecycle
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
        try self.finishMigratedBundle(segmentID: segmentID, activeDirectory: activeDirectory, lifecycle: lifecycle, failureReason: legacyState == "failed" ? "legacy location upload failed" : nil)
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
        lifecycle: MobileSegmentLifecycle,
        failureReason: String?
    ) throws {
        if let failureReason {
            try self.store.writeFailure(
                MobileSegmentFailureSidecar(
                    reason: failureReason,
                    httpStatus: nil,
                    transportError: nil,
                    attemptCount: 0,
                    stage: "legacy-migration",
                    lastAttemptAt: self.clock.now()
                ),
                in: activeDirectory
            )
        }
        _ = try self.store.move(segmentID: segmentID, from: .active, to: lifecycle)
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

    func removeLegacyAudio(audioURL: URL, sidecarURL: URL, failureURL: URL, fileManager: FileManager) throws {
        try fileManager.removeItem(at: audioURL)
        if fileManager.fileExists(atPath: sidecarURL.path) {
            try fileManager.removeItem(at: sidecarURL)
        }
        if fileManager.fileExists(atPath: failureURL.path) {
            try fileManager.removeItem(at: failureURL)
        }
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

    func scheduleUpload(segmentID: UUID) async {
        guard !self.schedulingSegmentIDs.contains(segmentID) else { return }
        guard !self.transport.isMobileSegmentUploading(segmentID: segmentID) else { return }
        self.schedulingSegmentIDs.insert(segmentID)
        defer { self.schedulingSegmentIDs.remove(segmentID) }

        let directory = self.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        guard self.store.fileExists(directory) else { return }

        do {
            var manifest = try self.store.readManifest(in: directory)
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
                try self.movePendingToFailed(
                    segmentID: segmentID,
                    reason: "missing terminal outcome marker",
                    failure: MobileSegmentFailureSidecar(
                        reason: "missing terminal outcome marker",
                        httpStatus: nil,
                        transportError: nil,
                        attemptCount: 0,
                        stage: "schedule-gate",
                        lastAttemptAt: self.clock.now()
                    )
                )
                return
            }
            guard manifest.hasArtifact, !manifest.hasFinalizeFailure else { return }
            let audioURL = manifest.audio.state == .finalizedArtifact
                ? self.store.audioURL(in: directory)
                : nil
            let locationData: Data?
            if manifest.location.state == .finalizedArtifact {
                locationData = try self.store.readData(at: self.store.locationURL(in: directory))
            } else {
                locationData = nil
            }
            guard audioURL != nil || locationData != nil else { return }
            let metadata = ObserverIngestMultipartMetadata(
                segment: manifest.segment ?? ChunkSidecar.segmentString(for: manifest.startedAt, durationSeconds: manifest.durationS ?? 0),
                day: manifest.day ?? Self.dayString(for: manifest.startedAt),
                startedAt: manifest.startedAt,
                durationS: manifest.durationS ?? max(0, (manifest.endedAt ?? self.clock.now()).timeIntervalSince(manifest.startedAt)),
                chunkIndex: nil,
                sessionID: nil,
                mode: manifest.audio.mode,
                segmentID: manifest.segmentID,
                sources: manifest.declaredSources
                    .filter { manifest.resolution(for: $0).state == .finalizedArtifact }
                    .map(\.rawValue)
            )
            let request = try self.transport.buildMobileSegmentRequestBody(
                segmentID: segmentID,
                metadata: metadata,
                audioURL: audioURL,
                locationJSONL: locationData
            )
            manifest.upload = .uploading
            manifest.updatedAt = self.clock.now()
            try self.store.writeManifest(manifest, in: directory)
            self.transportInFlightSegmentIDs.insert(segmentID)
            await self.transport.uploadMobileSegment(
                segmentID: segmentID,
                requestBodyURL: request.requestBodyURL,
                boundary: request.boundary,
                onComplete: { [weak self] result in
                    Task { @MainActor [weak self] in
                        await self?.handleTransportResult(result, segmentID: segmentID)
                    }
                }
            )
        } catch {
            self.lastError = String(describing: error)
            mobileSegmentUploadLog.error("mobile segment schedule failed \(segmentID.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
            try? self.movePendingToFailed(segmentID: segmentID, reason: String(describing: error), failure: nil)
        }
        self.refreshCounts()
    }

    func handleTransportResult(_ result: ObserverMobileSegmentTransportResult, segmentID: UUID) async {
        self.transportInFlightSegmentIDs.remove(segmentID)
        switch result {
        case .delivered:
            let directory = self.store.segmentDirectoryURL(.pending, segmentID: segmentID)
            do {
                try self.store.writeTombstone(segmentID: segmentID, kind: "uploaded", reason: "delivered", now: self.clock.now())
                try self.store.remove(directory)
                self.lastUploadAt = self.clock.now()
                self.lastError = nil
            } catch {
                self.lastError = String(describing: error)
            }
        case .failed(let failure):
            do {
                try self.movePendingToFailed(
                    segmentID: segmentID,
                    reason: failure.reason,
                    failure: MobileSegmentFailureSidecar(
                        reason: failure.reason,
                        httpStatus: failure.httpStatus,
                        transportError: failure.transportError,
                        attemptCount: failure.attemptCount,
                        stage: failure.stage,
                        lastAttemptAt: failure.lastAttemptAt
                    )
                )
            } catch {
                self.lastError = String(describing: error)
            }
        case .cancelled:
            break
        }
        self.refreshCounts()
    }

    func movePendingToFailed(segmentID: UUID, reason: String, failure: MobileSegmentFailureSidecar?) throws {
        let pendingDirectory = self.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        guard self.store.fileExists(pendingDirectory) else { return }
        var manifest = try self.store.readManifest(in: pendingDirectory)
        manifest.upload = .failed
        manifest.updatedAt = self.clock.now()
        try self.store.writeManifest(manifest, in: pendingDirectory)
        if let failure {
            try self.store.writeFailure(failure, in: pendingDirectory)
        } else {
            try self.store.writeFailure(
                MobileSegmentFailureSidecar(
                    reason: reason,
                    httpStatus: nil,
                    transportError: nil,
                    attemptCount: 0,
                    stage: "schedule",
                    lastAttemptAt: self.clock.now()
                ),
                in: pendingDirectory
            )
        }
        _ = try self.store.move(segmentID: segmentID, from: .pending, to: .failed)
    }

    func reconcileActiveSegments() async throws {
        let active = try self.store.list(.active)
        for directory in active {
            guard let segmentID = UUID(uuidString: directory.lastPathComponent) else { continue }
            var manifest = try self.store.readManifest(in: directory)
            let now = self.clock.now()
            for source in manifest.declaredSources {
                let resolution = manifest.resolution(for: source)
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
                            durationS: max(0, now.timeIntervalSince(manifest.startedAt)),
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
                    if self.store.fileExists(locationURL) {
                        let header = try? MobileSegmentLocationWriter.loadSnapshotHeader(from: self.store.readData(at: locationURL))
                        let finalized = MobileSegmentSourceResolution(
                            state: .finalizedArtifact,
                            artifactFilename: locationURL.lastPathComponent,
                            bytes: self.store.fileSize(at: locationURL),
                            startedAt: manifest.startedAt,
                            endedAt: now,
                            durationS: max(0, now.timeIntervalSince(manifest.startedAt)),
                            fixCount: header?.fixCount
                        )
                        try self.store.writeOutcome(finalized, source: .location, manifest: &manifest, in: directory, now: now)
                    } else {
                        let failed = MobileSegmentSourceResolution(
                            state: .failedToFinalize,
                            reason: "unclean relaunch unresolved source",
                            stage: "reconcile",
                            lastAttemptAt: now
                        )
                        try self.store.writeOutcome(failed, source: .location, manifest: &manifest, in: directory, now: now)
                    }
                }
                manifest = try self.store.readManifest(in: directory)
            }
            await self.finalizeActiveSegment(segmentID: segmentID, endedAt: now)
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
            let isUploading = lifecycle == .pending && self.transport.isMobileSegmentUploading(segmentID: segmentID)
            let failure = lifecycle == .failed ? self.store.loadFailure(in: directory) : nil
            let url: URL?
            let contentType: String?
            let filename: String?
            let bytes: Int64?
            switch source {
            case .audio:
                url = resolution.state == .finalizedArtifact ? self.store.audioURL(in: directory) : nil
                contentType = "audio/mp4"
                filename = "audio.m4a"
                bytes = url.flatMap { self.store.fileSize(at: $0) } ?? resolution.bytes
            case .location:
                url = resolution.state == .finalizedArtifact ? self.store.locationURL(in: directory) : nil
                contentType = "application/jsonl"
                filename = "location.jsonl"
                bytes = url.flatMap { self.store.fileSize(at: $0) } ?? resolution.bytes
            }
            items.append(OnThisPhoneItem(
                id: "mobile-segment:\(segmentID.uuidString):\(source.rawValue)",
                dropGroupID: "mobile-segment:\(segmentID.uuidString)",
                sourceKind: source == .audio ? .audio : .location,
                sendState: onThisPhoneSendState(location: lifecycle == .failed ? .failed : .pending, isActivelyUploading: isUploading),
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
                sourceLabel: source == .audio ? OnThisPhoneAudioSource.observer.sourceLabel : nil,
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

private extension JSONDecoder {
    static var observerSidecar: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension MobileSegmentResolutionState {
    var isLocalLocationFacet: Bool {
        switch self {
        case .finalizedArtifact, .noArtifact, .failedToFinalize:
            true
        case .notDeclared, .unresolved, .removed:
            false
        }
    }
}
