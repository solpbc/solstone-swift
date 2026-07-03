// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

private let mobileSegmentEngineLog = Logger(subsystem: "app.solstone.swift", category: "mobile-segment-engine")

@MainActor
@Observable
final class MobileSegmentEngine {
    enum EngineState: Equatable, Sendable {
        case idle
        case open(segmentID: UUID, sources: Set<MobileSegmentSource>, startedAt: Date)
        case finalizing(
            segmentID: UUID,
            activeSegmentID: UUID?,
            activeSources: Set<MobileSegmentSource>,
            activeStartedAt: Date?,
            pendingNextSourceSet: Set<MobileSegmentSource>?
        )
    }

    var state: EngineState = .idle

    @ObservationIgnored private let uploader: MobileSegmentUploader
    @ObservationIgnored private let clock: any ObserverClock
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var locationLivenessTask: Task<Void, Never>?
    @ObservationIgnored private var sourceSetVersion = 0
    @ObservationIgnored private var audioMode: ObserverMode?
    @ObservationIgnored private var audioSegmentStartedAt: Date?
    @ObservationIgnored private var locationBuffer: LocationBuffer?
    @ObservationIgnored private var pendingBoundaryAt: Date?
    @ObservationIgnored private var pendingLocationStart: LocationStart?
    @ObservationIgnored private var pendingAudioStartContinuations: [CheckedContinuation<URL, any Error>] = []
    @ObservationIgnored private var screencastContinuationLease: MobileSegmentScreencastContinuationLease?
    @ObservationIgnored var rotateAudio: (@MainActor @Sendable (URL) async throws -> ObserverRecordedChunk?)?
    @ObservationIgnored var screencastRolloverHandler: (@MainActor @Sendable (MobileSegmentScreencastHandoffRecord) -> Void)?

    init(
        uploader: MobileSegmentUploader,
        clock: any ObserverClock = SystemObserverClock()
    ) {
        self.uploader = uploader
        self.clock = clock
    }

    func resumeFromDisk() async {
        await self.uploader.resumeFromDisk()
    }

    func startScreencast(at startedAt: Date) async throws -> MobileSegmentScreencastHandoffRecord {
        switch self.state {
        case .idle:
            let segmentID = try self.openSegment(sources: [.screencast], startedAt: startedAt)
            return self.screencastHandoff(segmentID: segmentID, sources: [.screencast], startedAt: startedAt)
        case .open(let segmentID, let sources, let segmentStartedAt):
            if sources.contains(.screencast) {
                return self.screencastHandoff(segmentID: segmentID, sources: sources, startedAt: segmentStartedAt)
            }
            let nextSources = sources.union([.screencast])
            try await self.boundary(to: nextSources, at: startedAt)
            guard case .open(let activeSegmentID, let activeSources, let activeStartedAt) = self.state,
                  activeSources.contains(.screencast) else {
                throw MobileSegmentEngineError.noActiveSegment
            }
            return self.screencastHandoff(segmentID: activeSegmentID, sources: activeSources, startedAt: activeStartedAt)
        case .finalizing(_, let activeSegmentID, let activeSources, let activeStartedAt, let pendingSources):
            let desiredSources = (pendingSources ?? activeSources).union([.screencast])
            self.coalesceFinalizingSources(desiredSources, at: startedAt)
            if activeSources.contains(.screencast),
               let activeSegmentID,
               let activeStartedAt {
                return self.screencastHandoff(segmentID: activeSegmentID, sources: activeSources, startedAt: activeStartedAt)
            }
            throw MobileSegmentEngineError.noActiveSegment
        }
    }

    func currentScreencastHandoff() -> MobileSegmentScreencastHandoffRecord? {
        guard self.currentSources.contains(.screencast),
              let segmentID = self.currentSegmentID,
              let startedAt = self.currentStartedAt else { return nil }
        return self.screencastHandoff(segmentID: segmentID, sources: self.currentSources, startedAt: startedAt)
    }

    func stopScreencast(at endedAt: Date) async throws {
        if case .finalizing(_, _, let activeSources, _, let pendingSources) = self.state {
            self.coalesceFinalizingSources((pendingSources ?? activeSources).subtracting([.screencast]), at: endedAt)
            return
        }
        guard case .open(_, let sources, _) = self.state,
              sources.contains(.screencast) else { return }
        try await self.boundary(to: sources.subtracting([.screencast]), at: endedAt)
    }

    func prepareScreencastContinuationLease(
        rolloverAt: Date,
        expiresAt: Date
    ) async throws -> MobileSegmentScreencastContinuationLease? {
        let sources = self.currentSources
        guard sources.contains(.screencast),
              let fromSegmentID = self.currentSegmentID else { return nil }
        let sourceSet = self.sortedSources(sources)
        if let existing = self.screencastContinuationLease,
           existing.fromSegmentID == fromSegmentID,
           Set(existing.sourceSet) == sources {
            let refreshed = MobileSegmentScreencastContinuationLease(
                leaseID: existing.leaseID,
                revision: Int64(max(self.sourceSetVersion, existing.sourceSetVersion)),
                fromSegmentID: existing.fromSegmentID,
                segmentID: existing.segmentID,
                sourceSetVersion: max(self.sourceSetVersion, existing.sourceSetVersion),
                sourceSet: sourceSet,
                notBefore: rolloverAt,
                startsAt: rolloverAt,
                rolloverAfter: rolloverAt.addingTimeInterval(MobileSegmentDuration.rotationCeiling),
                expiresAt: expiresAt,
                issuedAt: self.clock.now(),
                segmentDirectoryRelativePath: existing.segmentDirectoryRelativePath,
                screenPartRelativePath: existing.screenPartRelativePath,
                screenFinalRelativePath: existing.screenFinalRelativePath
            )
            self.screencastContinuationLease = refreshed
            return refreshed
        }
        let segmentID = try self.createSegment(sources: sources, startedAt: rolloverAt)
        let lease = MobileSegmentScreencastContinuationLease(
            leaseID: UUID(),
            revision: Int64(self.sourceSetVersion),
            fromSegmentID: fromSegmentID,
            segmentID: segmentID,
            sourceSetVersion: self.sourceSetVersion,
            sourceSet: sourceSet,
            notBefore: rolloverAt,
            startsAt: rolloverAt,
            rolloverAfter: rolloverAt.addingTimeInterval(MobileSegmentDuration.rotationCeiling),
            expiresAt: expiresAt,
            issuedAt: self.clock.now(),
            segmentDirectoryRelativePath: MobileSegmentScreencastPaths.activeSegmentRelativeDirectory(segmentID: segmentID),
            screenPartRelativePath: MobileSegmentScreencastPaths.screenPartRelativePath(segmentID: segmentID),
            screenFinalRelativePath: MobileSegmentScreencastPaths.screenRelativePath(segmentID: segmentID)
        )
        self.screencastContinuationLease = lease
        return lease
    }

    func adoptScreencastContinuationLease(
        _ lease: MobileSegmentScreencastContinuationLease
    ) async throws -> MobileSegmentScreencastHandoffRecord {
        let sources = Set(lease.sourceSet)
        guard sources.contains(.screencast) else {
            throw MobileSegmentEngineError.noActiveSegment
        }
        if self.currentSegmentID == lease.segmentID,
           self.currentSources == sources,
           let startedAt = self.currentStartedAt {
            return self.screencastHandoff(segmentID: lease.segmentID, sources: sources, startedAt: startedAt)
        }
        try self.uploader.adoptActiveSegment(
            segmentID: lease.segmentID,
            sources: sources,
            startedAt: lease.startsAt,
            sourceSetVersion: lease.sourceSetVersion
        )
        self.sourceSetVersion = max(self.sourceSetVersion, lease.sourceSetVersion)
        if sources.contains(.audio) {
            self.audioSegmentStartedAt = lease.startsAt
        }
        if sources.contains(.location), let buffer = self.locationBuffer {
            self.locationBuffer = LocationBuffer(
                tier: buffer.tier,
                accuracy: buffer.accuracy,
                startedAt: lease.startsAt
            )
        }
        self.screencastContinuationLease = nil
        self.activateSegment(segmentID: lease.segmentID, sources: sources, startedAt: lease.startsAt, startTimer: true)
        return self.screencastHandoff(segmentID: lease.segmentID, sources: sources, startedAt: lease.startsAt)
    }

    func startAudio(mode: ObserverMode) async throws -> URL {
        self.audioMode = mode
        let now = self.clock.now()
        switch self.state {
        case .idle:
            let segmentID = try self.openSegment(sources: [.audio], startedAt: now)
            self.audioSegmentStartedAt = now
            return self.uploader.activeAudioURL(segmentID: segmentID)
        case .open(_, let sources, _):
            if sources.contains(.audio), let segmentID = self.currentSegmentID {
                return self.uploader.activeAudioURL(segmentID: segmentID)
            }
            try await self.boundary(to: sources.union([.audio]), at: now)
            guard let segmentID = self.currentSegmentID else {
                throw MobileSegmentEngineError.noActiveSegment
            }
            self.audioSegmentStartedAt = now
            return self.uploader.activeAudioURL(segmentID: segmentID)
        case .finalizing(_, let activeSegmentID, let activeSources, _, let pendingSources):
            let desiredSources = (pendingSources ?? activeSources).union([.audio])
            self.coalesceFinalizingSources(desiredSources, at: now)
            if activeSources.contains(.audio), let activeSegmentID {
                self.audioSegmentStartedAt = self.audioSegmentStartedAt ?? now
                return self.uploader.activeAudioURL(segmentID: activeSegmentID)
            }
            return try await withCheckedThrowingContinuation { continuation in
                self.pendingAudioStartContinuations.append(continuation)
            }
        }
    }

    func stopAudio(finalized: ObserverRecordedChunk?, minimumDuration: TimeInterval = 0.1) async {
        if case .finalizing(_, let activeSegmentID, let activeSources, _, let pendingSources) = self.state {
            let now = self.clock.now()
            if activeSources.contains(.audio),
               let activeSegmentID,
               let mode = self.audioMode,
               let startedAt = self.audioSegmentStartedAt {
                do {
                    try self.uploader.recordAudioFinalized(
                        segmentID: activeSegmentID,
                        finalized: finalized,
                        startedAt: startedAt,
                        endedAt: now,
                        mode: mode,
                        minimumDuration: minimumDuration
                    )
                } catch {
                    mobileSegmentEngineLog.error("audio stop resolution failed: \(String(describing: error), privacy: .public)")
                    try? self.uploader.recordAudioFinalizeFailed(
                        segmentID: activeSegmentID,
                        startedAt: startedAt,
                        endedAt: now,
                        mode: mode,
                        reason: String(describing: error)
                    )
                }
            }
            self.audioMode = nil
            self.audioSegmentStartedAt = nil
            self.failPendingAudioStarts(MobileSegmentEngineError.noActiveSegment)
            self.coalesceFinalizingSources((pendingSources ?? activeSources).subtracting([.audio]), at: now)
            return
        }

        guard let segmentID = self.currentSegmentID,
              let mode = self.audioMode,
              let startedAt = self.audioSegmentStartedAt
        else { return }
        let now = self.clock.now()
        do {
            try self.uploader.recordAudioFinalized(
                segmentID: segmentID,
                finalized: finalized,
                startedAt: startedAt,
                endedAt: now,
                mode: mode,
                minimumDuration: minimumDuration
            )
            self.audioMode = nil
            self.audioSegmentStartedAt = nil
            if case .open(_, let sources, _) = self.state {
                await self.finishCurrentAndMaybeOpenNext(nextSources: sources.subtracting([.audio]), at: now)
            }
        } catch {
            mobileSegmentEngineLog.error("audio stop resolution failed: \(String(describing: error), privacy: .public)")
            try? self.uploader.recordAudioFinalizeFailed(
                segmentID: segmentID,
                startedAt: startedAt,
                endedAt: now,
                mode: mode,
                reason: String(describing: error)
            )
            self.audioMode = nil
            self.audioSegmentStartedAt = nil
            await self.finishCurrentAndMaybeOpenNext(nextSources: self.currentSources.subtracting([.audio]), at: now)
        }
    }

    func startLocation(tier: LocationTier, accuracy: LocationAccuracy) async {
        let now = self.clock.now()
        switch self.state {
        case .idle:
            do {
                _ = try self.openSegment(sources: [.location], startedAt: now)
                self.locationBuffer = LocationBuffer(tier: tier, accuracy: accuracy, startedAt: now)
                self.syncLocationLiveState(now: now)
            } catch {
                self.lastError(error)
            }
        case .open(_, let sources, _):
            guard !sources.contains(.location) else {
                self.locationBuffer = self.locationBuffer ?? LocationBuffer(tier: tier, accuracy: accuracy, startedAt: now)
                self.syncLocationLiveState(now: now)
                return
            }
            do {
                try await self.boundary(to: sources.union([.location]), at: now)
                self.locationBuffer = LocationBuffer(tier: tier, accuracy: accuracy, startedAt: now)
                self.syncLocationLiveState(now: now)
            } catch {
                self.lastError(error)
            }
        case .finalizing(_, _, let activeSources, _, let pendingSources):
            let desiredSources = (pendingSources ?? activeSources).union([.location])
            self.coalesceFinalizingSources(desiredSources, at: now)
            if activeSources.contains(.location) {
                self.locationBuffer = self.locationBuffer ?? LocationBuffer(tier: tier, accuracy: accuracy, startedAt: now)
            } else {
                self.pendingLocationStart = LocationStart(tier: tier, accuracy: accuracy, startedAt: now)
                if var buffer = self.locationBuffer {
                    buffer.tier = tier
                    buffer.accuracy = accuracy
                    self.locationBuffer = buffer
                } else {
                    self.locationBuffer = LocationBuffer(tier: tier, accuracy: accuracy, startedAt: now)
                }
            }
            self.syncLocationLiveState(now: now)
        }
    }

    func stopLocation() async {
        let now = self.clock.now()
        if case .finalizing(_, _, let activeSources, _, let pendingSources) = self.state {
            self.coalesceFinalizingSources((pendingSources ?? activeSources).subtracting([.location]), at: now)
            if !activeSources.contains(.location) {
                self.pendingLocationStart = nil
                self.locationBuffer = nil
            }
            self.syncLocationLivenessTask()
            return
        }
        guard case .open(_, let sources, _) = self.state,
              sources.contains(.location)
        else {
            self.locationBuffer = nil
            self.syncLocationLivenessTask()
            return
        }
        await self.finishCurrentAndMaybeOpenNext(nextSources: sources.subtracting([.location]), at: now)
        self.locationBuffer = nil
        self.syncLocationLivenessTask()
    }

    func updateLocation(tier: LocationTier, accuracy: LocationAccuracy) {
        if var buffer = self.locationBuffer {
            buffer.tier = tier
            buffer.accuracy = accuracy
            self.locationBuffer = buffer
            self.syncLocationLiveState(now: self.clock.now())
        }
    }

    func recordLocationFix(_ fix: LocationFix) {
        guard var buffer = self.locationBuffer else { return }
        buffer.fixes.append(fix)
        self.locationBuffer = buffer
        self.appendLocationLiveFix(fix, now: self.clock.now())
    }

    func recordLocationVisit(_ visit: LocationVisit) {
        guard var buffer = self.locationBuffer else { return }
        buffer.visits.append(visit)
        self.locationBuffer = buffer
        self.appendLocationLiveVisit(visit, now: self.clock.now())
    }

    func recordLocationGap() {
        guard var buffer = self.locationBuffer else { return }
        buffer.gap = true
        self.locationBuffer = buffer
        self.syncLocationLiveState(now: self.clock.now())
    }
}

private extension MobileSegmentEngine {
    struct LocationBuffer: Sendable, Equatable {
        var tier: LocationTier
        var accuracy: LocationAccuracy
        let startedAt: Date
        var fixes: [LocationFix] = []
        var visits: [LocationVisit] = []
        var gap = false
    }

    struct LocationStart: Sendable, Equatable {
        var tier: LocationTier
        var accuracy: LocationAccuracy
        let startedAt: Date
    }

    struct LocationLiveTarget: Sendable, Equatable {
        let segmentID: UUID
    }

    var currentSegmentID: UUID? {
        switch self.state {
        case .open(let segmentID, _, _):
            segmentID
        case .finalizing(_, let activeSegmentID, _, _, _):
            activeSegmentID
        case .idle:
            nil
        }
    }

    var currentSources: Set<MobileSegmentSource> {
        switch self.state {
        case .open(_, let sources, _):
            sources
        case .finalizing(_, _, let activeSources, _, let pendingSources):
            pendingSources ?? activeSources
        case .idle:
            []
        }
    }

    var currentStartedAt: Date? {
        switch self.state {
        case .open(_, _, let startedAt):
            startedAt
        case .finalizing(_, _, _, let activeStartedAt, _):
            activeStartedAt
        case .idle:
            nil
        }
    }

    var locationLiveTarget: LocationLiveTarget? {
        switch self.state {
        case .open(let segmentID, let sources, _) where sources.contains(.location):
            LocationLiveTarget(segmentID: segmentID)
        case .finalizing(_, let activeSegmentID?, let activeSources, _?, _) where activeSources.contains(.location):
            LocationLiveTarget(segmentID: activeSegmentID)
        default:
            nil
        }
    }

    func openSegment(sources: Set<MobileSegmentSource>, startedAt: Date) throws -> UUID {
        let segmentID = try self.createSegment(sources: sources, startedAt: startedAt)
        self.activateSegment(segmentID: segmentID, sources: sources, startedAt: startedAt, startTimer: true)
        return segmentID
    }

    func createSegment(sources: Set<MobileSegmentSource>, startedAt: Date) throws -> UUID {
        self.sourceSetVersion += 1
        return try self.uploader.openSegment(
            sources: sources,
            startedAt: startedAt,
            sourceSetVersion: self.sourceSetVersion
        )
    }

    func activateSegment(
        segmentID: UUID,
        sources: Set<MobileSegmentSource>,
        startedAt: Date,
        startTimer shouldStartTimer: Bool,
        preservePendingAudio: Bool = false,
        preservePendingLocation: Bool = false
    ) {
        self.state = .open(segmentID: segmentID, sources: sources, startedAt: startedAt)
        if sources.contains(.audio) {
            self.audioSegmentStartedAt = self.audioSegmentStartedAt ?? startedAt
            self.resolvePendingAudioStarts(with: self.uploader.activeAudioURL(segmentID: segmentID))
        } else if !preservePendingAudio {
            self.failPendingAudioStarts(MobileSegmentEngineError.noActiveSegment)
        }
        if sources.contains(.location), self.locationBuffer == nil, let pendingLocationStart {
            self.locationBuffer = LocationBuffer(
                tier: pendingLocationStart.tier,
                accuracy: pendingLocationStart.accuracy,
                startedAt: pendingLocationStart.startedAt
            )
        }
        if !sources.contains(.location), !preservePendingLocation {
            self.locationBuffer = nil
            self.pendingLocationStart = nil
        }
        if shouldStartTimer {
            self.startTimer()
        }
        if sources.contains(.location) {
            self.syncLocationLiveState(now: self.clock.now())
        } else {
            self.syncLocationLivenessTask()
        }
    }

    func boundary(to nextSources: Set<MobileSegmentSource>, at now: Date) async throws {
        if case .finalizing = self.state {
            self.coalesceFinalizingSources(nextSources, at: now)
            return
        }
        guard case .open(let segmentID, let oldSources, _) = self.state else { return }
        await self.performBoundary(segmentID: segmentID, oldSources: oldSources, nextSources: nextSources, at: now, applyPendingFollowUp: true)
    }

    func rollStableSegment(segmentID: UUID, sources: Set<MobileSegmentSource>, at now: Date) async throws {
        await self.performBoundary(segmentID: segmentID, oldSources: sources, nextSources: sources, at: now, applyPendingFollowUp: true)
    }

    func finishCurrentAndMaybeOpenNext(nextSources: Set<MobileSegmentSource>, at now: Date) async {
        if case .finalizing = self.state {
            self.coalesceFinalizingSources(nextSources, at: now)
            return
        }
        guard case .open(let segmentID, let oldSources, _) = self.state else { return }
        await self.performBoundary(segmentID: segmentID, oldSources: oldSources, nextSources: nextSources, at: now, applyPendingFollowUp: true)
    }

    func performBoundary(
        segmentID: UUID,
        oldSources: Set<MobileSegmentSource>,
        nextSources: Set<MobileSegmentSource>,
        at now: Date,
        applyPendingFollowUp: Bool
    ) async {
        self.cancelTimer()
        self.pendingBoundaryAt = nil
        do {
            let oldAudioStartedAt = self.audioSegmentStartedAt
            let oldAudioMode = self.audioMode
            let oldLocationBuffer = oldSources.contains(.location) ? self.locationBuffer : nil
            let preparedLease = self.consumePreparedScreencastLease(
                fromSegmentID: segmentID,
                sources: nextSources,
                at: now
            )
            let nextSegmentID: UUID?
            if nextSources.isEmpty {
                nextSegmentID = nil
            } else if let preparedLease {
                nextSegmentID = preparedLease.segmentID
            } else {
                nextSegmentID = try self.createSegment(sources: nextSources, startedAt: now)
            }

            if nextSources.contains(.audio) {
                self.audioSegmentStartedAt = now
            } else if !oldSources.contains(.audio) {
                self.audioSegmentStartedAt = nil
                self.audioMode = nil
            }

            if nextSources.contains(.location) {
                if oldSources.contains(.location), let oldLocationBuffer {
                    self.locationBuffer = LocationBuffer(tier: oldLocationBuffer.tier, accuracy: oldLocationBuffer.accuracy, startedAt: now)
                    self.pendingLocationStart = nil
                } else if self.locationBuffer == nil, let pendingLocationStart {
                    self.locationBuffer = LocationBuffer(
                        tier: pendingLocationStart.tier,
                        accuracy: pendingLocationStart.accuracy,
                        startedAt: pendingLocationStart.startedAt
                    )
                }
            } else if !oldSources.contains(.location) {
                self.locationBuffer = nil
                self.pendingLocationStart = nil
            }

            self.state = .finalizing(
                segmentID: segmentID,
                activeSegmentID: nextSegmentID,
                activeSources: nextSources,
                activeStartedAt: nextSegmentID == nil ? nil : now,
                pendingNextSourceSet: nil
            )
            if nextSources.contains(.location) {
                self.syncLocationLiveState(now: now)
            } else {
                self.syncLocationLivenessTask()
            }

            if oldSources.contains(.audio), nextSources.contains(.audio), let nextSegmentID {
                do {
                    let nextAudioURL = self.uploader.activeAudioURL(segmentID: nextSegmentID)
                    let finalized = try await self.rotateAudio?(nextAudioURL)
                    if let mode = oldAudioMode, let startedAt = oldAudioStartedAt {
                        try self.uploader.recordAudioFinalized(
                            segmentID: segmentID,
                            finalized: finalized,
                            startedAt: startedAt,
                            endedAt: now,
                            mode: mode,
                            minimumDuration: 0.1
                        )
                    }
                } catch {
                    if let mode = oldAudioMode, let startedAt = oldAudioStartedAt {
                        try? self.uploader.recordAudioFinalizeFailed(
                            segmentID: segmentID,
                            startedAt: startedAt,
                            endedAt: now,
                            mode: mode,
                            reason: String(describing: error)
                        )
                    }
                    self.lastError(error)
                }
            }

            if oldSources.contains(.location) {
                do {
                    try self.finalizeLocationIfNeeded(segmentID: segmentID, endedAt: now, buffer: oldLocationBuffer)
                } catch {
                    try? self.uploader.recordLocationFinalizeRemoved(
                        segmentID: segmentID,
                        endedAt: now,
                        reason: String(describing: error)
                    )
                    self.lastError(error)
                }
            }

            await self.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: now)
            let pendingNextSources = self.finalizingPendingSources(for: segmentID)
            let pendingAt = self.pendingBoundaryAt ?? self.clock.now()
            self.pendingBoundaryAt = nil

            if let nextSegmentID {
                let shouldFollowUp = applyPendingFollowUp && pendingNextSources != nil && pendingNextSources != nextSources
                self.activateSegment(
                    segmentID: nextSegmentID,
                    sources: nextSources,
                    startedAt: now,
                    startTimer: false,
                    preservePendingAudio: shouldFollowUp && pendingNextSources?.contains(.audio) == true,
                    preservePendingLocation: shouldFollowUp && pendingNextSources?.contains(.location) == true
                )
                if shouldFollowUp, let pendingNextSources {
                    await self.performBoundary(
                        segmentID: nextSegmentID,
                        oldSources: nextSources,
                        nextSources: pendingNextSources,
                        at: pendingAt,
                        applyPendingFollowUp: false
                    )
                } else {
                    self.startTimer()
                }
                if oldSources.contains(.screencast), nextSources.contains(.screencast) {
                    self.screencastRolloverHandler?(
                        self.screencastHandoff(segmentID: nextSegmentID, sources: nextSources, startedAt: now)
                    )
                }
            } else if let pendingNextSources, !pendingNextSources.isEmpty {
                let openedID = try self.openSegment(sources: pendingNextSources, startedAt: pendingAt)
                if pendingNextSources.contains(.audio) {
                    self.resolvePendingAudioStarts(with: self.uploader.activeAudioURL(segmentID: openedID))
                }
            } else {
                self.state = .idle
                self.locationBuffer = nil
                self.pendingLocationStart = nil
                self.failPendingAudioStarts(MobileSegmentEngineError.noActiveSegment)
                self.cancelTimer()
                self.syncLocationLivenessTask()
            }
        } catch {
            self.lastError(error)
            if case .finalizing(_, let activeSegmentID?, let activeSources, let activeStartedAt?, _) = self.state {
                self.activateSegment(segmentID: activeSegmentID, sources: activeSources, startedAt: activeStartedAt, startTimer: true)
            } else {
                self.state = .idle
                self.failPendingAudioStarts(MobileSegmentEngineError.noActiveSegment)
                self.syncLocationLivenessTask()
            }
        }
    }

    func coalesceFinalizingSources(_ sources: Set<MobileSegmentSource>, at now: Date) {
        guard case .finalizing(let segmentID, let activeSegmentID, let activeSources, let activeStartedAt, _) = self.state else { return }
        if self.pendingBoundaryAt == nil {
            self.pendingBoundaryAt = now
        }
        self.state = .finalizing(
            segmentID: segmentID,
            activeSegmentID: activeSegmentID,
            activeSources: activeSources,
            activeStartedAt: activeStartedAt,
            pendingNextSourceSet: sources
        )
    }

    func finalizingPendingSources(for segmentID: UUID) -> Set<MobileSegmentSource>? {
        guard case .finalizing(let currentSegmentID, _, _, _, let pendingNextSourceSet) = self.state,
              currentSegmentID == segmentID
        else { return nil }
        return pendingNextSourceSet
    }

    func consumePreparedScreencastLease(
        fromSegmentID: UUID,
        sources: Set<MobileSegmentSource>,
        at now: Date
    ) -> MobileSegmentScreencastContinuationLease? {
        guard sources.contains(.screencast),
              let lease = self.screencastContinuationLease,
              lease.fromSegmentID == fromSegmentID,
              Set(lease.sourceSet) == sources,
              now >= lease.notBefore,
              now <= lease.expiresAt
        else { return nil }
        self.sourceSetVersion = max(self.sourceSetVersion, lease.sourceSetVersion)
        self.screencastContinuationLease = nil
        return lease
    }

    func resolvePendingAudioStarts(with url: URL) {
        let continuations = self.pendingAudioStartContinuations
        self.pendingAudioStartContinuations = []
        for continuation in continuations {
            continuation.resume(returning: url)
        }
    }

    func failPendingAudioStarts(_ error: any Error) {
        let continuations = self.pendingAudioStartContinuations
        self.pendingAudioStartContinuations = []
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    func finalizeLocationIfNeeded(segmentID: UUID, endedAt: Date, buffer: LocationBuffer?) throws {
        guard let buffer else { return }
        let batch = LocationSegmentBatch(
            tier: buffer.tier,
            accuracy: buffer.accuracy,
            segmentStart: buffer.startedAt,
            coveredSeconds: max(0, Int(endedAt.timeIntervalSince(buffer.startedAt).rounded())),
            fixes: buffer.fixes,
            visits: buffer.visits,
            gap: buffer.gap
        )
        try self.uploader.recordLocationFinalized(segmentID: segmentID, batch: batch, endedAt: endedAt)
    }

    func startTimer() {
        self.cancelTimer()
        self.timerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(for: .seconds(MobileSegmentDuration.rotationCeiling))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard !self.currentSources.isEmpty else { return }
            let sources = self.currentSources
            let now = self.clock.now()
            do {
                try await self.boundary(to: sources, at: now)
            } catch {
                self.lastError(error)
            }
        }
    }

    func cancelTimer() {
        self.timerTask?.cancel()
        self.timerTask = nil
    }

    func syncLocationLiveState(now: Date) {
        guard let target = self.locationLiveTarget,
              let buffer = self.locationBuffer
        else {
            self.syncLocationLivenessTask()
            return
        }
        do {
            try self.uploader.appendLocationLiveState(
                segmentID: target.segmentID,
                segmentStart: buffer.startedAt,
                tier: buffer.tier,
                accuracy: buffer.accuracy,
                gap: buffer.gap,
                recordedAt: now
            )
            try self.writeLocationLiveness(target: target, buffer: buffer, now: now)
        } catch {
            mobileSegmentEngineLog.error("location live state write failed segment=\(target.segmentID.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        self.syncLocationLivenessTask()
    }

    func appendLocationLiveFix(_ fix: LocationFix, now: Date) {
        guard let target = self.locationLiveTarget,
              let buffer = self.locationBuffer
        else {
            self.syncLocationLivenessTask()
            return
        }
        do {
            try self.uploader.appendLocationLiveFix(segmentID: target.segmentID, fix: fix)
            try self.writeLocationLiveness(target: target, buffer: buffer, now: now)
        } catch {
            mobileSegmentEngineLog.error("location live fix write failed segment=\(target.segmentID.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        self.syncLocationLivenessTask()
    }

    func appendLocationLiveVisit(_ visit: LocationVisit, now: Date) {
        guard let target = self.locationLiveTarget,
              let buffer = self.locationBuffer
        else {
            self.syncLocationLivenessTask()
            return
        }
        do {
            try self.uploader.appendLocationLiveVisit(segmentID: target.segmentID, visit: visit)
            try self.writeLocationLiveness(target: target, buffer: buffer, now: now)
        } catch {
            mobileSegmentEngineLog.error("location live visit write failed segment=\(target.segmentID.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        self.syncLocationLivenessTask()
    }

    func refreshLocationLiveness(now: Date) {
        guard let target = self.locationLiveTarget,
              let buffer = self.locationBuffer
        else {
            self.syncLocationLivenessTask()
            return
        }
        do {
            try self.writeLocationLiveness(target: target, buffer: buffer, now: now)
        } catch {
            mobileSegmentEngineLog.error("location liveness refresh failed segment=\(target.segmentID.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    func writeLocationLiveness(target: LocationLiveTarget, buffer: LocationBuffer, now: Date) throws {
        try self.uploader.writeLocationLiveness(
            segmentID: target.segmentID,
            sourceSetVersion: self.sourceSetVersion,
            lastSeenAt: now,
            fixCount: buffer.fixes.count,
            visitCount: buffer.visits.count,
            gap: buffer.gap
        )
    }

    func syncLocationLivenessTask() {
        guard self.locationLiveTarget != nil, self.locationBuffer != nil else {
            self.cancelLocationLivenessTask()
            return
        }
        guard self.locationLivenessTask == nil else { return }
        self.locationLivenessTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await self.clock.sleep(
                        for: .seconds(Int64(MobileSegmentLocationLivenessPolicy.livenessRefreshIntervalSeconds))
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard self.locationLiveTarget != nil, self.locationBuffer != nil else {
                    self.locationLivenessTask = nil
                    return
                }
                self.refreshLocationLiveness(now: self.clock.now())
            }
        }
    }

    func cancelLocationLivenessTask() {
        self.locationLivenessTask?.cancel()
        self.locationLivenessTask = nil
    }

    func screencastHandoff(
        segmentID: UUID,
        sources: Set<MobileSegmentSource>,
        startedAt: Date
    ) -> MobileSegmentScreencastHandoffRecord {
        MobileSegmentScreencastHandoffRecord(
            revision: Int64(self.sourceSetVersion),
            eventID: UUID(),
            sessionID: UUID(),
            segmentID: segmentID,
            sourceSetVersion: self.sourceSetVersion,
            sourceSet: self.sortedSources(sources),
            startedAt: startedAt,
            segmentDirectoryRelativePath: MobileSegmentScreencastPaths.activeSegmentRelativeDirectory(segmentID: segmentID),
            screenPartRelativePath: MobileSegmentScreencastPaths.screenPartRelativePath(segmentID: segmentID),
            screenFinalRelativePath: MobileSegmentScreencastPaths.screenRelativePath(segmentID: segmentID),
            desiredState: .writing,
            rolloverAfter: startedAt.addingTimeInterval(MobileSegmentDuration.rotationCeiling),
            lastHostUpdateAt: self.clock.now()
        )
    }

    func sortedSources(_ sources: Set<MobileSegmentSource>) -> [MobileSegmentSource] {
        sources.sorted { $0.rawValue < $1.rawValue }
    }

    func lastError(_ error: any Error) {
        mobileSegmentEngineLog.error("mobile segment engine failed: \(String(describing: error), privacy: .public)")
    }
}

enum MobileSegmentEngineError: Error {
    case noActiveSegment
    case finalizing
}
