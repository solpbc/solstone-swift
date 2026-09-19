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

    @ObservationIgnored private let segmentUploader: MobileSegmentUploader
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
    @ObservationIgnored private var screencastSessionID: UUID?
    @ObservationIgnored private var screencastScheduleAnchorMs: Int64 = 0
    @ObservationIgnored private var screencastSchedulePeriodSeconds: Int = 300
    @ObservationIgnored var rotateAudio: (@MainActor @Sendable (URL) async throws -> ObserverRecordedChunk?)?
    @ObservationIgnored var screencastRolloverHandler: (@MainActor @Sendable (MobileSegmentScreencastHandoffRecord) -> Void)?

    var heldScreencastAdoptionSkipSegmentID: UUID? {
        guard self.currentSources.contains(.screencast),
              let sessionID = self.screencastSessionID else { return nil }
        let nowMs = Int64(self.clock.now().timeIntervalSince1970 * 1000)
        let k = MobileSegmentScreencastIdentity.windowIndex(
            nowMs: nowMs,
            scheduleAnchorMs: self.screencastScheduleAnchorMs,
            schedulePeriodSeconds: self.screencastSchedulePeriodSeconds
        )
        return MobileSegmentScreencastIdentity.segmentID(
            sessionID: sessionID,
            scheduleAnchorMs: self.screencastScheduleAnchorMs,
            windowIndex: k,
            schedulePeriodSeconds: self.screencastSchedulePeriodSeconds
        )
    }

    init(
        uploader: MobileSegmentUploader,
        clock: any ObserverClock = SystemObserverClock()
    ) {
        self.segmentUploader = uploader
        self.clock = clock
        uploader.heldScreencastAdoptionSkipSegmentID = { [weak self] in
            self?.heldScreencastAdoptionSkipSegmentID
        }
    }

    func resumeFromDisk() async {
        await self.segmentUploader.resumeFromDisk()
    }

    func startScreencast(at startedAt: Date, sessionID: UUID? = nil) async throws -> MobileSegmentScreencastHandoffRecord {
        let actualSessionID = sessionID ?? self.screencastSessionID ?? UUID()
        self.screencastSessionID = actualSessionID
        let anchorMs = Int64(startedAt.timeIntervalSince1970 * 1000)
        self.screencastScheduleAnchorMs = anchorMs
        self.screencastSchedulePeriodSeconds = 300

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

    func startAudio(mode: ObserverMode) async throws -> URL {
        self.audioMode = mode
        let now = self.clock.now()
        switch self.state {
        case .idle:
            let segmentID = try self.openSegment(sources: [.audio], startedAt: now)
            self.audioSegmentStartedAt = now
            return self.segmentUploader.activeAudioURL(segmentID: segmentID)
        case .open(_, let sources, _):
            if sources.contains(.audio), let segmentID = self.currentSegmentID {
                return self.segmentUploader.activeAudioURL(segmentID: segmentID)
            }
            try await self.boundary(to: sources.union([.audio]), at: now)
            guard let segmentID = self.currentSegmentID else {
                throw MobileSegmentEngineError.noActiveSegment
            }
            self.audioSegmentStartedAt = now
            return self.segmentUploader.activeAudioURL(segmentID: segmentID)
        case .finalizing(_, let activeSegmentID, let activeSources, _, let pendingSources):
            let desiredSources = (pendingSources ?? activeSources).union([.audio])
            self.coalesceFinalizingSources(desiredSources, at: now)
            if activeSources.contains(.audio), let activeSegmentID {
                self.audioSegmentStartedAt = self.audioSegmentStartedAt ?? now
                return self.segmentUploader.activeAudioURL(segmentID: activeSegmentID)
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
                    try self.segmentUploader.recordAudioFinalized(
                        segmentID: activeSegmentID,
                        finalized: finalized,
                        startedAt: startedAt,
                        endedAt: now,
                        mode: mode,
                        minimumDuration: minimumDuration
                    )
                } catch {
                    mobileSegmentEngineLog.error("audio stop resolution failed: \(String(describing: error), privacy: .public)")
                    try? self.segmentUploader.recordAudioFinalizeFailed(
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
        else {
            self.audioMode = nil
            self.audioSegmentStartedAt = nil
            self.failPendingAudioStarts(MobileSegmentEngineError.noActiveSegment)
            return
        }

        let now = self.clock.now()
        do {
            try self.segmentUploader.recordAudioFinalized(
                segmentID: segmentID,
                finalized: finalized,
                startedAt: startedAt,
                endedAt: now,
                mode: mode,
                minimumDuration: minimumDuration
            )
        } catch {
            mobileSegmentEngineLog.error("audio stop resolution failed: \(String(describing: error), privacy: .public)")
            try? self.segmentUploader.recordAudioFinalizeFailed(
                segmentID: segmentID,
                startedAt: startedAt,
                endedAt: now,
                mode: mode,
                reason: String(describing: error)
            )
        }

        self.audioMode = nil
        self.audioSegmentStartedAt = nil
        self.failPendingAudioStarts(MobileSegmentEngineError.noActiveSegment)
        let remainingSources = self.currentSources.subtracting([.audio])
        if case .open = self.state {
            if remainingSources.isEmpty {
                self.cancelTimer()
                self.state = .finalizing(
                    segmentID: segmentID,
                    activeSegmentID: nil,
                    activeSources: [],
                    activeStartedAt: nil,
                    pendingNextSourceSet: nil
                )
                await self.segmentUploader.finalizeActiveSegment(segmentID: segmentID, endedAt: now)
                self.state = .idle
                self.locationBuffer = nil
                self.pendingLocationStart = nil
                self.screencastSessionID = nil
                self.syncLocationLivenessTask()
            } else {
                do {
                    try await self.boundary(to: remainingSources, at: now)
                } catch {
                    self.lastError(error)
                }
            }
        }
    }

    func startLocation(tier: LocationTier, accuracy: LocationAccuracy, startedAt: Date? = nil) async {
        let startedAt = startedAt ?? self.clock.now()
        self.pendingLocationStart = LocationStart(tier: tier, accuracy: accuracy, startedAt: startedAt)
        do {
            switch self.state {
            case .idle:
                let segmentID = try self.openSegment(sources: [.location], startedAt: startedAt)
                self.locationBuffer = LocationBuffer(tier: tier, accuracy: accuracy, startedAt: startedAt)
                self.pendingLocationStart = nil
                self.syncLocationLiveState(now: startedAt)
                _ = segmentID
            case .open(let segmentID, let sources, _):
                if sources.contains(.location) {
                    if let buffer = self.locationBuffer {
                        self.locationBuffer = LocationBuffer(
                            tier: tier,
                            accuracy: accuracy,
                            startedAt: buffer.startedAt,
                            fixes: buffer.fixes,
                            visits: buffer.visits,
                            gap: buffer.gap
                        )
                    } else {
                        self.locationBuffer = LocationBuffer(tier: tier, accuracy: accuracy, startedAt: startedAt)
                    }
                    self.pendingLocationStart = nil
                    self.syncLocationLiveState(now: startedAt)
                    return
                }
                try await self.boundary(to: sources.union([.location]), at: startedAt)
                self.locationBuffer = LocationBuffer(tier: tier, accuracy: accuracy, startedAt: startedAt)
                self.pendingLocationStart = nil
                self.syncLocationLiveState(now: startedAt)
                _ = segmentID
            case .finalizing(_, _, let activeSources, _, let pendingSources):
                let desiredSources = (pendingSources ?? activeSources).union([.location])
                self.coalesceFinalizingSources(desiredSources, at: startedAt)
                if let buffer = self.locationBuffer {
                    self.locationBuffer = LocationBuffer(
                        tier: tier,
                        accuracy: accuracy,
                        startedAt: buffer.startedAt,
                        fixes: buffer.fixes,
                        visits: buffer.visits,
                        gap: buffer.gap
                    )
                } else {
                    self.locationBuffer = LocationBuffer(tier: tier, accuracy: accuracy, startedAt: startedAt)
                }
                if activeSources.contains(.location) {
                    self.pendingLocationStart = nil
                    self.syncLocationLiveState(now: startedAt)
                }
            }
        } catch {
            self.lastError(error)
        }
    }

    func updateLocation(tier: LocationTier, accuracy: LocationAccuracy) {
        if let buffer = self.locationBuffer {
            self.locationBuffer = LocationBuffer(
                tier: tier,
                accuracy: accuracy,
                startedAt: buffer.startedAt,
                fixes: buffer.fixes,
                visits: buffer.visits,
                gap: buffer.gap
            )
            self.syncLocationLiveState(now: self.clock.now())
        }
    }

    func stopLocation(at endedAt: Date? = nil) async {
        let endedAt = endedAt ?? self.clock.now()
        if case .finalizing(let segmentID, let activeSegmentID, let activeSources, let activeStartedAt, let pendingSources) = self.state {
            if activeSources.contains(.location), let activeSegmentID {
                let buffer = self.locationBuffer
                do {
                    try self.finalizeLocationIfNeeded(segmentID: activeSegmentID, endedAt: endedAt, buffer: buffer)
                } catch {
                    mobileSegmentEngineLog.error("location stop resolution failed: \(String(describing: error), privacy: .public)")
                }
            }
            self.locationBuffer = nil
            self.pendingLocationStart = nil
            self.syncLocationLivenessTask()
            self.coalesceFinalizingSources((pendingSources ?? activeSources).subtracting([.location]), at: endedAt)
            _ = segmentID
            _ = activeStartedAt
            return
        }

        guard case .open(let segmentID, let sources, _) = self.state,
              sources.contains(.location) else {
            self.locationBuffer = nil
            self.pendingLocationStart = nil
            self.syncLocationLivenessTask()
            return
        }

        let remainingSources = sources.subtracting([.location])
        if remainingSources.isEmpty {
            self.cancelTimer()
            let buffer = self.locationBuffer
            self.locationBuffer = nil
            self.pendingLocationStart = nil
            self.state = .finalizing(
                segmentID: segmentID,
                activeSegmentID: nil,
                activeSources: [],
                activeStartedAt: nil,
                pendingNextSourceSet: nil
            )
            self.syncLocationLivenessTask()
            do {
                try self.finalizeLocationIfNeeded(segmentID: segmentID, endedAt: endedAt, buffer: buffer)
            } catch {
                mobileSegmentEngineLog.error("location stop resolution failed: \(String(describing: error), privacy: .public)")
            }
            await self.segmentUploader.finalizeActiveSegment(segmentID: segmentID, endedAt: endedAt)
            self.state = .idle
            self.screencastSessionID = nil
        } else {
            do {
                try await self.boundary(to: remainingSources, at: endedAt)
            } catch {
                self.lastError(error)
            }
        }
    }

    func recordLocationFix(_ fix: LocationFix) {
        guard var buffer = self.locationBuffer else { return }
        buffer.fixes.append(fix)
        self.locationBuffer = buffer
        let now = self.clock.now()
        self.appendLocationLiveFix(fix, now: now)
    }

    func recordLocationVisit(_ visit: LocationVisit) {
        guard var buffer = self.locationBuffer else { return }
        buffer.visits.append(visit)
        self.locationBuffer = buffer
        let now = self.clock.now()
        self.appendLocationLiveVisit(visit, now: now)
    }

    func recordLocationGap() {
        guard var buffer = self.locationBuffer else { return }
        buffer.gap = true
        self.locationBuffer = buffer
        self.syncLocationLiveState(now: self.clock.now())
    }

    var currentSegmentID: UUID? {
        switch self.state {
        case .idle:
            nil
        case .open(let segmentID, _, _):
            segmentID
        case .finalizing(_, let activeSegmentID, _, _, _):
            activeSegmentID
        }
    }

    var currentSources: Set<MobileSegmentSource> {
        switch self.state {
        case .idle:
            []
        case .open(_, let sources, _):
            sources
        case .finalizing(_, _, let activeSources, _, let pendingSources):
            pendingSources ?? activeSources
        }
    }

    var currentStartedAt: Date? {
        switch self.state {
        case .idle:
            nil
        case .open(_, _, let startedAt):
            startedAt
        case .finalizing(_, _, _, let activeStartedAt, _):
            activeStartedAt
        }
    }

    private struct LocationLiveTarget {
        let segmentID: UUID
        let startedAt: Date
    }

    private var locationLiveTarget: LocationLiveTarget? {
        switch self.state {
        case .idle:
            return nil
        case .open(let segmentID, let sources, let startedAt):
            return sources.contains(.location) ? LocationLiveTarget(segmentID: segmentID, startedAt: startedAt) : nil
        case .finalizing(_, let activeSegmentID, let activeSources, let activeStartedAt, _):
            guard activeSources.contains(.location),
                  let activeSegmentID,
                  let activeStartedAt else { return nil }
            return LocationLiveTarget(segmentID: activeSegmentID, startedAt: activeStartedAt)
        }
    }

    private struct LocationBuffer {
        let tier: LocationTier
        let accuracy: LocationAccuracy
        let startedAt: Date
        var fixes: [LocationFix] = []
        var visits: [LocationVisit] = []
        var gap: Bool = false
    }

    private struct LocationStart {
        let tier: LocationTier
        let accuracy: LocationAccuracy
        let startedAt: Date
    }

    func openSegment(sources: Set<MobileSegmentSource>, startedAt: Date) throws -> UUID {
        let segmentID = try self.createSegment(sources: sources, startedAt: startedAt)
        self.activateSegment(segmentID: segmentID, sources: sources, startedAt: startedAt, startTimer: true)
        return segmentID
    }

    func createSegment(
        segmentID: UUID? = nil,
        sources: Set<MobileSegmentSource>,
        startedAt: Date
    ) throws -> UUID {
        self.sourceSetVersion += 1
        let actualSegmentID: UUID
        if let segmentID {
            actualSegmentID = segmentID
        } else if sources.contains(.screencast), let derived = self.screencastSegmentID(at: startedAt) {
            actualSegmentID = derived
        } else {
            actualSegmentID = UUID()
        }
        return try self.segmentUploader.openSegment(
            segmentID: actualSegmentID,
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
            self.resolvePendingAudioStarts(with: self.segmentUploader.activeAudioURL(segmentID: segmentID))
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
            let nextSegmentID: UUID?
            if nextSources.isEmpty {
                nextSegmentID = nil
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
                    self.pendingLocationStart = nil
                }
            } else if oldSources.contains(.location) {
                self.locationBuffer = nil
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
                    let nextAudioURL = self.segmentUploader.activeAudioURL(segmentID: nextSegmentID)
                    let finalized = try await self.rotateAudio?(nextAudioURL)
                    if let mode = oldAudioMode, let startedAt = oldAudioStartedAt {
                        try self.segmentUploader.recordAudioFinalized(
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
                        try? self.segmentUploader.recordAudioFinalizeFailed(
                            segmentID: segmentID,
                            startedAt: startedAt,
                            endedAt: now,
                            mode: mode,
                            reason: String(describing: error)
                        )
                    }
                }
            }

            if oldSources.contains(.location) {
                try self.finalizeLocationIfNeeded(segmentID: segmentID, endedAt: now, buffer: oldLocationBuffer)
            }

            await self.segmentUploader.finalizeActiveSegment(segmentID: segmentID, endedAt: now)

            let pendingNextSources = self.finalizingPendingSources(for: segmentID)
            let pendingAt = self.pendingBoundaryAt ?? now
            self.pendingBoundaryAt = nil

            if let nextSegmentID {
                if let pendingNextSources, pendingNextSources != nextSources {
                    self.activateSegment(
                        segmentID: nextSegmentID,
                        sources: nextSources,
                        startedAt: now,
                        startTimer: false,
                        preservePendingAudio: true,
                        preservePendingLocation: true
                    )
                    await self.performBoundary(
                        segmentID: nextSegmentID,
                        oldSources: nextSources,
                        nextSources: pendingNextSources,
                        at: pendingAt,
                        applyPendingFollowUp: false
                    )
                } else {
                    self.activateSegment(
                        segmentID: nextSegmentID,
                        sources: nextSources,
                        startedAt: now,
                        startTimer: true,
                        preservePendingAudio: true,
                        preservePendingLocation: true
                    )
                }
            } else if let pendingNextSources, !pendingNextSources.isEmpty {
                let openedID = try self.openSegment(sources: pendingNextSources, startedAt: pendingAt)
                if pendingNextSources.contains(.audio) {
                    self.resolvePendingAudioStarts(with: self.segmentUploader.activeAudioURL(segmentID: openedID))
                }
            } else {
                self.state = .idle
                self.locationBuffer = nil
                self.pendingLocationStart = nil
                self.screencastSessionID = nil
                self.failPendingAudioStarts(MobileSegmentEngineError.noActiveSegment)
                self.cancelTimer()
                self.syncLocationLivenessTask()
            }
        } catch {
            self.lastError(error)
            if case .finalizing(_, let activeSegmentID?, let activeSources, let activeStartedAt?, _) = self.state {
                self.activateSegment(segmentID: activeSegmentID, sources: activeSources, startedAt: activeStartedAt, startTimer: true)
            } else if case .open(let segmentID, let sources, let startedAt) = self.state {
                self.activateSegment(segmentID: segmentID, sources: sources, startedAt: startedAt, startTimer: true)
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

    private func finalizeLocationIfNeeded(segmentID: UUID, endedAt: Date, buffer: LocationBuffer?) throws {
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
        try self.segmentUploader.recordLocationFinalized(segmentID: segmentID, batch: batch, endedAt: endedAt, reason: nil)
    }

    func startTimer() {
        self.cancelTimer()
        self.timerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if self.currentSources.contains(.screencast) {
                    let now = self.clock.now()
                    let nowMs = Int64(now.timeIntervalSince1970 * 1000)
                    let k = MobileSegmentScreencastIdentity.windowIndex(
                        nowMs: nowMs,
                        scheduleAnchorMs: self.screencastScheduleAnchorMs,
                        schedulePeriodSeconds: self.screencastSchedulePeriodSeconds
                    )
                    let nextStart = MobileSegmentScreencastIdentity.windowStart(
                        scheduleAnchorMs: self.screencastScheduleAnchorMs,
                        windowIndex: k + 1,
                        schedulePeriodSeconds: self.screencastSchedulePeriodSeconds
                    )
                    let sleepSeconds = max(0.001, nextStart.timeIntervalSince(now))
                    try await self.clock.sleep(for: .seconds(sleepSeconds))
                } else {
                    try await self.clock.sleep(for: .seconds(MobileSegmentDuration.rotationCeiling))
                }
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard case .open(let segmentID, let sources, _) = self.state else { return }
            let now = self.clock.now()
            do {
                try await self.rollStableSegment(segmentID: segmentID, sources: sources, at: now)
                if sources.contains(.screencast),
                   let handoff = self.currentScreencastHandoff() {
                    self.screencastRolloverHandler?(handoff)
                }
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
            try self.segmentUploader.appendLocationLiveState(
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
            try self.segmentUploader.appendLocationLiveFix(segmentID: target.segmentID, fix: fix)
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
            try self.segmentUploader.appendLocationLiveVisit(segmentID: target.segmentID, visit: visit)
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

    private func writeLocationLiveness(target: LocationLiveTarget, buffer: LocationBuffer, now: Date) throws {
        try self.segmentUploader.writeLocationLiveness(
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
        let sessionID = self.screencastSessionID ?? UUID()
        self.screencastSessionID = sessionID
        return MobileSegmentScreencastHandoffRecord(
            revision: Int64(self.sourceSetVersion),
            eventID: UUID(),
            sessionID: sessionID,
            segmentID: segmentID,
            sourceSetVersion: self.sourceSetVersion,
            sourceSet: self.sortedSources(sources),
            startedAt: startedAt,
            segmentDirectoryRelativePath: MobileSegmentScreencastPaths.activeSegmentRelativeDirectory(segmentID: segmentID),
            screenPartRelativePath: MobileSegmentScreencastPaths.screenPartRelativePath(segmentID: segmentID),
            screenFinalRelativePath: MobileSegmentScreencastPaths.screenRelativePath(segmentID: segmentID),
            desiredState: .writing,
            scheduleAnchorMs: self.screencastScheduleAnchorMs,
            schedulePeriodSeconds: self.screencastSchedulePeriodSeconds,
            lastHostUpdateAt: self.clock.now()
        )
    }

    private func screencastSegmentID(at now: Date) -> UUID? {
        guard let sessionID = self.screencastSessionID else { return nil }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let k = MobileSegmentScreencastIdentity.windowIndex(
            nowMs: nowMs,
            scheduleAnchorMs: self.screencastScheduleAnchorMs,
            schedulePeriodSeconds: self.screencastSchedulePeriodSeconds
        )
        return MobileSegmentScreencastIdentity.segmentID(
            sessionID: sessionID,
            scheduleAnchorMs: self.screencastScheduleAnchorMs,
            windowIndex: k,
            schedulePeriodSeconds: self.screencastSchedulePeriodSeconds
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
