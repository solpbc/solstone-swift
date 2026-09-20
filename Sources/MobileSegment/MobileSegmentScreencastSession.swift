// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreMedia
import Foundation
import os

nonisolated private let screencastSessionLog = Logger(subsystem: "app.solstone.swift", category: "screencast-session")

nonisolated protocol ScreencastBroadcastWriting: AnyObject, Sendable {
    var acceptedFrameCount: Int { get }
    var droppedFrameCount: Int { get }
    func open(rootURL: URL, handoff: MobileSegmentScreencastHandoffRecord, now: Date) throws
    func appendVideo(_ sampleBuffer: CMSampleBuffer, now: Date)
    func finish(now: Date) -> ScreencastBroadcastWriterOutcome
    func writeLiveness(now: Date, force: Bool) throws
}

nonisolated protocol ScreencastBroadcastAudioWriting: AnyObject, Sendable {
    func open(rootURL: URL, handoff: MobileSegmentScreencastHandoffRecord, now: Date) throws
    func appendAudio(_ sampleBuffer: CMSampleBuffer, now: Date) throws
    func finish(now: Date)
}

nonisolated final class ScreencastBroadcastSession: @unchecked Sendable {
    private let clock: @Sendable () -> Date
    private let availableBytes: @Sendable (URL) -> Int64?
    private let rootURL: URL
    private let writer: any ScreencastBroadcastWriting
    private let audioWriter: any ScreencastBroadcastAudioWriting
    private let postChangedHook: @Sendable () -> Void
    private let finishWithErrorHook: @Sendable (NSError) -> Void

    private var sessionID: UUID?
    private var broadcastStartedAt: Date?
    private var isWaitingForHandoff: Bool = false
    private var isAudioOpenForCurrentWindow: Bool = false
    private var isAudioStoppedForWindow: Bool = false
    private(set) var currentHandoff: MobileSegmentScreencastHandoffRecord?
    private(set) var currentSidecar: MobileSegmentScreencastWindowSidecar?
    private(set) var currentWindowIndex: Int = 0
    private(set) var scheduleAnchorMs: Int64 = 0
    private(set) var schedulePeriodSeconds: Int = 300
    private(set) var isBroadcastActive: Bool = false
    private(set) var shouldDropSamples: Bool = false

    init(
        rootURL: URL,
        writer: any ScreencastBroadcastWriting,
        audioWriter: any ScreencastBroadcastAudioWriting = ScreencastBroadcastAudioWriter(),
        clock: @escaping @Sendable () -> Date = { Date() },
        availableBytes: @escaping @Sendable (URL) -> Int64? = { url in
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage
        },
        postChanged: @escaping @Sendable () -> Void = {},
        finishWithError: @escaping @Sendable (NSError) -> Void = { _ in }
    ) {
        self.rootURL = rootURL
        self.writer = writer
        self.audioWriter = audioWriter
        self.clock = clock
        self.availableBytes = availableBytes
        self.postChangedHook = postChanged
        self.finishWithErrorHook = finishWithError
    }

    func broadcastStarted(sessionID: UUID) {
        self.sessionID = sessionID
        self.shouldDropSamples = false
        self.isAudioOpenForCurrentWindow = false
        self.isAudioStoppedForWindow = false
        let now = self.clock()
        self.broadcastStartedAt = now
        self.isBroadcastActive = true

        self.writeRuntime(state: .broadcastStarted, sessionID: sessionID, segmentID: nil, revision: nil, now: now)
        self.postChangedHook()

        if let free = self.availableBytes(self.rootURL), free < MobileSegmentScreencastStoragePolicy.minimumFreeBytes {
            self.failWithStorageLow(sessionID: sessionID, now: now)
            return
        }

        if let handoff = self.readHandoff(), handoff.sessionID == sessionID {
            self.isWaitingForHandoff = false
            self.adoptInitialHandoff(handoff, now: now)
        } else {
            self.isWaitingForHandoff = true
        }
    }

    func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, kind: MobileSegmentScreencastSampleKind) {
        guard self.isBroadcastActive, !self.shouldDropSamples, let sessionID = self.sessionID else { return }

        if self.isWaitingForHandoff {
            let now = self.clock()
            self.isWaitingForHandoff = false
            if let handoff = self.readHandoff(), handoff.sessionID == sessionID {
                self.adoptInitialHandoff(handoff, now: now)
            } else {
                let handoff = self.selfMintHandoff(sessionID: sessionID, now: now)
                self.adoptInitialHandoff(handoff, now: now)
            }
        }

        self.tick()
        guard !self.shouldDropSamples else { return }

        let now = self.clock()
        switch kind {
        case .video:
            self.writer.appendVideo(sampleBuffer, now: now)
            self.currentSidecar?.acceptedFrameCount = self.writer.acceptedFrameCount
            self.currentSidecar?.droppedFrameCount = self.writer.droppedFrameCount
        case .audioMic:
            guard !self.isAudioStoppedForWindow, let handoff = self.currentHandoff else { return }
            if !self.isAudioOpenForCurrentWindow {
                do {
                    try self.audioWriter.open(rootURL: self.rootURL, handoff: handoff, now: now)
                    self.isAudioOpenForCurrentWindow = true
                } catch {
                    screencastSessionLog.error("failed to open audio writer: \(String(describing: error), privacy: .public)")
                    self.isAudioStoppedForWindow = true
                    return
                }
            }
            do {
                try self.audioWriter.appendAudio(sampleBuffer, now: now)
            } catch {
                screencastSessionLog.error("failed to append audio sample: \(String(describing: error), privacy: .public)")
                self.isAudioStoppedForWindow = true
            }
        case .audioApp, .unknown:
            return
        }
    }

    func tick() {
        guard self.isBroadcastActive, !self.shouldDropSamples, let sessionID = self.sessionID else { return }
        let now = self.clock()
        let nowMs = MobileSegmentScreencastIdentity.nowMs(from: now)

        if self.isWaitingForHandoff {
            if let stored = self.readHandoff(), stored.sessionID == sessionID {
                self.isWaitingForHandoff = false
                self.adoptInitialHandoff(stored, now: now)
            } else if now.timeIntervalSince(self.broadcastStartedAt ?? now) >= 2.0 {
                self.isWaitingForHandoff = false
                let handoff = self.selfMintHandoff(sessionID: sessionID, now: now)
                self.adoptInitialHandoff(handoff, now: now)
            }
            return
        }

        // 1. Heartbeat liveness
        do {
            try self.writer.writeLiveness(now: now, force: false)
        } catch {
            screencastSessionLog.error("heartbeat liveness write failed: \(String(describing: error), privacy: .public)")
            self.closeCurrentSidecar(now: now)
            _ = self.finishAudioThenScreen(now: now)
            self.failWithDiagnostic(
                reason: .appGroupUnavailable,
                message: "heartbeat_liveness_write_failed",
                sessionID: sessionID,
                segmentID: self.currentHandoff?.segmentID,
                revision: self.currentHandoff?.revision,
                now: now
            )
            return
        }

        // 2. Check for newer start record for this session
        if let storedHandoff = self.readHandoff(),
           storedHandoff.sessionID == sessionID,
           let current = self.currentHandoff,
           storedHandoff.revision > current.revision {
            if storedHandoff.scheduleAnchorMs != self.scheduleAnchorMs {
                self.closeCurrentSidecar(now: now)
                _ = self.finishAudioThenScreen(now: now)

                self.scheduleAnchorMs = storedHandoff.scheduleAnchorMs
                self.schedulePeriodSeconds = storedHandoff.schedulePeriodSeconds
                let liveWindowIndex = MobileSegmentScreencastIdentity.windowIndex(
                    nowMs: nowMs,
                    scheduleAnchorMs: storedHandoff.scheduleAnchorMs,
                    schedulePeriodSeconds: storedHandoff.schedulePeriodSeconds
                )
                let liveSegmentID = MobileSegmentScreencastIdentity.segmentID(
                    sessionID: sessionID,
                    scheduleAnchorMs: storedHandoff.scheduleAnchorMs,
                    windowIndex: liveWindowIndex,
                    schedulePeriodSeconds: storedHandoff.schedulePeriodSeconds
                )
                let liveWindowStart = MobileSegmentScreencastIdentity.windowStart(
                    scheduleAnchorMs: storedHandoff.scheduleAnchorMs,
                    windowIndex: liveWindowIndex,
                    schedulePeriodSeconds: storedHandoff.schedulePeriodSeconds
                )
                let derivedHandoff = MobileSegmentScreencastHandoffRecord(
                    schemaVersion: storedHandoff.schemaVersion,
                    revision: storedHandoff.revision,
                    eventID: storedHandoff.eventID,
                    sessionID: sessionID,
                    segmentID: liveSegmentID,
                    sourceSetVersion: storedHandoff.sourceSetVersion,
                    sourceSet: storedHandoff.sourceSet,
                    startedAt: liveWindowStart,
                    segmentDirectoryRelativePath: MobileSegmentScreencastPaths.activeSegmentRelativeDirectory(segmentID: liveSegmentID),
                    screenPartRelativePath: MobileSegmentScreencastPaths.screenPartRelativePath(segmentID: liveSegmentID),
                    screenFinalRelativePath: MobileSegmentScreencastPaths.screenRelativePath(segmentID: liveSegmentID),
                    desiredState: storedHandoff.desiredState,
                    scheduleAnchorMs: storedHandoff.scheduleAnchorMs,
                    schedulePeriodSeconds: storedHandoff.schedulePeriodSeconds,
                    lastHostUpdateAt: storedHandoff.lastHostUpdateAt
                )
                self.currentWindowIndex = liveWindowIndex
                self.currentHandoff = derivedHandoff

                do {
                    try self.openWindow(index: liveWindowIndex, handoff: derivedHandoff, now: now)
                    self.writeRuntime(state: .writerOpen, sessionID: sessionID, segmentID: liveSegmentID, revision: storedHandoff.revision, now: now)
                    self.postChangedHook()
                } catch {
                    screencastSessionLog.error("failed to open superseding window: \(String(describing: error), privacy: .public)")
                    self.failWithDiagnostic(
                        reason: .writerFailure,
                        message: String(describing: error),
                        sessionID: sessionID,
                        segmentID: liveSegmentID,
                        revision: storedHandoff.revision,
                        now: now
                    )
                }
                return
            } else {
                let updatedHandoff = MobileSegmentScreencastHandoffRecord(
                    schemaVersion: current.schemaVersion,
                    revision: storedHandoff.revision,
                    eventID: storedHandoff.eventID,
                    sessionID: current.sessionID,
                    segmentID: current.segmentID,
                    sourceSetVersion: storedHandoff.sourceSetVersion,
                    sourceSet: storedHandoff.sourceSet,
                    startedAt: current.startedAt,
                    segmentDirectoryRelativePath: current.segmentDirectoryRelativePath,
                    screenPartRelativePath: current.screenPartRelativePath,
                    screenFinalRelativePath: current.screenFinalRelativePath,
                    desiredState: storedHandoff.desiredState,
                    scheduleAnchorMs: current.scheduleAnchorMs,
                    schedulePeriodSeconds: current.schedulePeriodSeconds,
                    lastHostUpdateAt: storedHandoff.lastHostUpdateAt
                )
                self.currentHandoff = updatedHandoff
            }
        }

        // 3. Check schedule rollover
        let targetIndex = MobileSegmentScreencastIdentity.windowIndex(
            nowMs: nowMs,
            scheduleAnchorMs: self.scheduleAnchorMs,
            schedulePeriodSeconds: self.schedulePeriodSeconds
        )
        if targetIndex > self.currentWindowIndex {
            self.rotate(toWindowIndex: targetIndex, now: now)
        }
    }

    func broadcastFinished() {
        guard self.isBroadcastActive else { return }
        self.isBroadcastActive = false
        let now = self.clock()
        guard let sessionID = self.sessionID else { return }

        self.closeCurrentSidecar(now: now)
        let outcome = self.finishAudioThenScreen(now: now)

        switch outcome {
        case .completed, .noVideo:
            self.writeRuntime(
                state: .finalized,
                sessionID: sessionID,
                segmentID: self.currentHandoff?.segmentID,
                revision: self.currentHandoff?.revision,
                now: now
            )
        case .finalizeTimeout:
            self.failWithDiagnostic(
                reason: .finalizeTimeout,
                message: "finalize_timeout",
                sessionID: sessionID,
                segmentID: self.currentHandoff?.segmentID,
                revision: self.currentHandoff?.revision,
                now: now
            )
        case .writerFailure(let msg):
            self.failWithDiagnostic(
                reason: .writerFailure,
                message: msg,
                sessionID: sessionID,
                segmentID: self.currentHandoff?.segmentID,
                revision: self.currentHandoff?.revision,
                now: now
            )
        case .filesystemHandoffFailure(let msg):
            self.failWithDiagnostic(
                reason: .filesystemHandoffFailure,
                message: msg,
                sessionID: sessionID,
                segmentID: self.currentHandoff?.segmentID,
                revision: self.currentHandoff?.revision,
                now: now
            )
        }

        self.postChangedHook()
    }

    private func adoptInitialHandoff(_ handoff: MobileSegmentScreencastHandoffRecord, now: Date) {
        let nowMs = MobileSegmentScreencastIdentity.nowMs(from: now)
        let liveWindowIndex = MobileSegmentScreencastIdentity.windowIndex(
            nowMs: nowMs,
            scheduleAnchorMs: handoff.scheduleAnchorMs,
            schedulePeriodSeconds: handoff.schedulePeriodSeconds
        )
        let liveSegmentID = MobileSegmentScreencastIdentity.segmentID(
            sessionID: handoff.sessionID,
            scheduleAnchorMs: handoff.scheduleAnchorMs,
            windowIndex: liveWindowIndex,
            schedulePeriodSeconds: handoff.schedulePeriodSeconds
        )
        let liveWindowStart = MobileSegmentScreencastIdentity.windowStart(
            scheduleAnchorMs: handoff.scheduleAnchorMs,
            windowIndex: liveWindowIndex,
            schedulePeriodSeconds: handoff.schedulePeriodSeconds
        )
        let derivedHandoff = MobileSegmentScreencastHandoffRecord(
            schemaVersion: handoff.schemaVersion,
            revision: handoff.revision,
            eventID: handoff.eventID,
            sessionID: handoff.sessionID,
            segmentID: liveSegmentID,
            sourceSetVersion: handoff.sourceSetVersion,
            sourceSet: handoff.sourceSet,
            startedAt: liveWindowStart,
            segmentDirectoryRelativePath: MobileSegmentScreencastPaths.activeSegmentRelativeDirectory(segmentID: liveSegmentID),
            screenPartRelativePath: MobileSegmentScreencastPaths.screenPartRelativePath(segmentID: liveSegmentID),
            screenFinalRelativePath: MobileSegmentScreencastPaths.screenRelativePath(segmentID: liveSegmentID),
            desiredState: handoff.desiredState,
            scheduleAnchorMs: handoff.scheduleAnchorMs,
            schedulePeriodSeconds: handoff.schedulePeriodSeconds,
            lastHostUpdateAt: handoff.lastHostUpdateAt
        )

        self.currentHandoff = derivedHandoff
        self.scheduleAnchorMs = handoff.scheduleAnchorMs
        self.schedulePeriodSeconds = handoff.schedulePeriodSeconds
        self.currentWindowIndex = liveWindowIndex

        do {
            try self.openWindow(index: liveWindowIndex, handoff: derivedHandoff, now: now)
            self.writeRuntime(state: .writerOpen, sessionID: handoff.sessionID, segmentID: liveSegmentID, revision: handoff.revision, now: now)
            self.postChangedHook()
        } catch {
            screencastSessionLog.error("failed to open initial window: \(String(describing: error), privacy: .public)")
            self.failWithDiagnostic(
                reason: .writerFailure,
                message: String(describing: error),
                sessionID: handoff.sessionID,
                segmentID: liveSegmentID,
                revision: handoff.revision,
                now: now
            )
        }
    }

    private func rotate(toWindowIndex: Int, now: Date) {
        guard let sessionID = self.sessionID else { return }

        // Storage check at boundary before opening next window
        if let free = self.availableBytes(self.rootURL), free < MobileSegmentScreencastStoragePolicy.minimumFreeBytes {
            self.closeCurrentSidecar(now: now)
            _ = self.finishAudioThenScreen(now: now)
            self.failWithStorageLow(sessionID: sessionID, now: now)
            return
        }

        self.closeCurrentSidecar(now: now)
        let outcome = self.finishAudioThenScreen(now: now)
        switch outcome {
        case .completed, .noVideo:
            break
        case .finalizeTimeout:
            self.failWithDiagnostic(
                reason: .finalizeTimeout,
                message: "finalize_timeout",
                sessionID: sessionID,
                segmentID: self.currentHandoff?.segmentID,
                revision: self.currentHandoff?.revision,
                now: now
            )
            return
        case .writerFailure(let msg):
            self.failWithDiagnostic(
                reason: .writerFailure,
                message: msg,
                sessionID: sessionID,
                segmentID: self.currentHandoff?.segmentID,
                revision: self.currentHandoff?.revision,
                now: now
            )
            return
        case .filesystemHandoffFailure(let msg):
            self.failWithDiagnostic(
                reason: .filesystemHandoffFailure,
                message: msg,
                sessionID: sessionID,
                segmentID: self.currentHandoff?.segmentID,
                revision: self.currentHandoff?.revision,
                now: now
            )
            return
        }

        let nextSegmentID = MobileSegmentScreencastIdentity.segmentID(
            sessionID: sessionID,
            scheduleAnchorMs: self.scheduleAnchorMs,
            windowIndex: toWindowIndex,
            schedulePeriodSeconds: self.schedulePeriodSeconds
        )
        let nextHandoff = MobileSegmentScreencastHandoffRecord(
            revision: self.currentHandoff?.revision ?? 1,
            eventID: UUID(),
            sessionID: sessionID,
            segmentID: nextSegmentID,
            sourceSetVersion: self.currentHandoff?.sourceSetVersion ?? 1,
            sourceSet: self.currentHandoff?.sourceSet ?? [.screencast],
            startedAt: MobileSegmentScreencastIdentity.windowStart(
                scheduleAnchorMs: self.scheduleAnchorMs,
                windowIndex: toWindowIndex,
                schedulePeriodSeconds: self.schedulePeriodSeconds
            ),
            segmentDirectoryRelativePath: MobileSegmentScreencastPaths.activeSegmentRelativeDirectory(segmentID: nextSegmentID),
            screenPartRelativePath: MobileSegmentScreencastPaths.screenPartRelativePath(segmentID: nextSegmentID),
            screenFinalRelativePath: MobileSegmentScreencastPaths.screenRelativePath(segmentID: nextSegmentID),
            desiredState: .writing,
            scheduleAnchorMs: self.scheduleAnchorMs,
            schedulePeriodSeconds: self.schedulePeriodSeconds,
            lastHostUpdateAt: now
        )

        do {
            try self.openWindow(index: toWindowIndex, handoff: nextHandoff, now: now)
            self.currentWindowIndex = toWindowIndex
            self.currentHandoff = nextHandoff
            self.writeRuntime(state: .writerOpen, sessionID: sessionID, segmentID: nextSegmentID, revision: nextHandoff.revision, now: now)
            self.postChangedHook()
        } catch {
            screencastSessionLog.error("failed to open rotated window: \(String(describing: error), privacy: .public)")
            self.failWithDiagnostic(
                reason: .writerFailure,
                message: String(describing: error),
                sessionID: sessionID,
                segmentID: nextSegmentID,
                revision: nextHandoff.revision,
                now: now
            )
        }
    }

    private func openWindow(index: Int, handoff: MobileSegmentScreencastHandoffRecord, now: Date) throws {
        self.isAudioOpenForCurrentWindow = false
        self.isAudioStoppedForWindow = false
        let segmentDir = MobileSegmentScreencastPaths.url(root: self.rootURL, relativePath: handoff.segmentDirectoryRelativePath)
        try FileManager.default.createDirectory(at: segmentDir, withIntermediateDirectories: true)

        let sidecar = MobileSegmentScreencastWindowSidecar(
            sessionID: handoff.sessionID,
            revision: handoff.revision,
            windowIndex: index,
            startedAt: handoff.startedAt
        )
        let sidecarURL = MobileSegmentScreencastPaths.screenWindowURL(inSegmentDirectory: segmentDir)
        try MobileSegmentScreencastJSONStore.write(sidecar, to: sidecarURL)
        self.currentSidecar = sidecar

        try self.writer.open(rootURL: self.rootURL, handoff: handoff, now: now)
    }

    private func finishAudioThenScreen(now: Date) -> ScreencastBroadcastWriterOutcome {
        if self.isAudioOpenForCurrentWindow {
            self.audioWriter.finish(now: now)
            self.isAudioOpenForCurrentWindow = false
        }
        self.isAudioStoppedForWindow = false
        return self.writer.finish(now: now)
    }

    private func closeCurrentSidecar(now: Date) {
        guard var sidecar = self.currentSidecar, let currentHandoff = self.currentHandoff else { return }
        sidecar.endedAt = now
        sidecar.acceptedFrameCount = self.writer.acceptedFrameCount
        sidecar.droppedFrameCount = self.writer.droppedFrameCount
        let segmentDir = MobileSegmentScreencastPaths.url(root: self.rootURL, relativePath: currentHandoff.segmentDirectoryRelativePath)
        let sidecarURL = MobileSegmentScreencastPaths.screenWindowURL(inSegmentDirectory: segmentDir)
        try? MobileSegmentScreencastJSONStore.write(sidecar, to: sidecarURL)
        self.currentSidecar = sidecar
    }

    private func selfMintHandoff(sessionID: UUID, now: Date) -> MobileSegmentScreencastHandoffRecord {
        let anchorMs = MobileSegmentScreencastIdentity.nowMs(from: now)
        let window0Start = MobileSegmentScreencastIdentity.windowStart(scheduleAnchorMs: anchorMs, windowIndex: 0, schedulePeriodSeconds: 300)
        let segmentID = MobileSegmentScreencastIdentity.segmentID(
            sessionID: sessionID,
            scheduleAnchorMs: anchorMs,
            windowIndex: 0,
            schedulePeriodSeconds: 300
        )
        return MobileSegmentScreencastHandoffRecord(
            revision: 1,
            eventID: UUID(),
            sessionID: sessionID,
            segmentID: segmentID,
            sourceSetVersion: 1,
            sourceSet: [.screencast],
            startedAt: window0Start,
            segmentDirectoryRelativePath: MobileSegmentScreencastPaths.activeSegmentRelativeDirectory(segmentID: segmentID),
            screenPartRelativePath: MobileSegmentScreencastPaths.screenPartRelativePath(segmentID: segmentID),
            screenFinalRelativePath: MobileSegmentScreencastPaths.screenRelativePath(segmentID: segmentID),
            desiredState: .writing,
            scheduleAnchorMs: anchorMs,
            schedulePeriodSeconds: 300,
            lastHostUpdateAt: now
        )
    }

    private func readHandoff() -> MobileSegmentScreencastHandoffRecord? {
        let url = MobileSegmentScreencastPaths.url(
            root: self.rootURL,
            relativePath: MobileSegmentScreencastPaths.handoffRelativePath()
        )
        return try? MobileSegmentScreencastJSONStore.read(MobileSegmentScreencastHandoffRecord.self, from: url)
    }

    private func writeRuntime(
        state: MobileSegmentScreencastRuntimeState,
        sessionID: UUID,
        segmentID: UUID?,
        revision: Int64?,
        now: Date
    ) {
        let record = MobileSegmentScreencastRuntimeRecord(
            revision: (revision ?? 0) + 1,
            sessionID: sessionID,
            state: state,
            startedAt: self.currentHandoff?.startedAt ?? now,
            lastSeenAt: now,
            currentSegmentID: segmentID,
            currentHandoffRevision: revision,
            acceptedFrameCount: self.writer.acceptedFrameCount,
            droppedFrameCount: self.writer.droppedFrameCount
        )
        let url = MobileSegmentScreencastPaths.url(
            root: self.rootURL,
            relativePath: MobileSegmentScreencastPaths.runtimeRelativePath()
        )
        try? MobileSegmentScreencastJSONStore.write(record, to: url)
    }

    private func failWithStorageLow(sessionID: UUID, now: Date) {
        self.shouldDropSamples = true
        self.isBroadcastActive = false
        let diagnostic = MobileSegmentScreencastDiagnostic(
            sessionID: sessionID,
            segmentID: self.currentHandoff?.segmentID,
            handoffRevision: self.currentHandoff?.revision,
            reason: .storageLow,
            message: "storage_low",
            startedAt: self.currentHandoff?.startedAt ?? now,
            endedAt: now,
            acceptedFrameCount: self.writer.acceptedFrameCount,
            droppedFrameCount: self.writer.droppedFrameCount,
            createdAt: now
        )
        let runtimeDiagnosticURL = MobileSegmentScreencastPaths.url(
            root: self.rootURL,
            relativePath: MobileSegmentScreencastPaths.runtimeDiagnosticRelativePath(sessionID: sessionID)
        )
        try? MobileSegmentScreencastJSONStore.write(diagnostic, to: runtimeDiagnosticURL)
        self.writeRuntime(state: .failed, sessionID: sessionID, segmentID: self.currentHandoff?.segmentID, revision: self.currentHandoff?.revision, now: now)
        self.postChangedHook()

        let error = MobileSegmentScreencastStopPolicy.stopError(for: .storageLow)
        self.finishWithErrorHook(error)
    }

    private func failWithDiagnostic(
        reason: MobileSegmentScreencastDiagnosticReason,
        message: String,
        sessionID: UUID,
        segmentID: UUID?,
        revision: Int64?,
        now: Date
    ) {
        self.shouldDropSamples = true
        self.isBroadcastActive = false
        let diagnostic = MobileSegmentScreencastDiagnostic(
            sessionID: sessionID,
            segmentID: segmentID,
            handoffRevision: revision,
            reason: reason,
            message: message,
            startedAt: self.currentHandoff?.startedAt ?? now,
            endedAt: now,
            acceptedFrameCount: self.writer.acceptedFrameCount,
            droppedFrameCount: self.writer.droppedFrameCount,
            createdAt: now
        )
        if let segmentID {
            let segDir = MobileSegmentScreencastPaths.url(
                root: self.rootURL,
                relativePath: MobileSegmentScreencastPaths.activeSegmentRelativeDirectory(segmentID: segmentID)
            )
            let segDiagURL = MobileSegmentScreencastPaths.screenDiagnosticURL(inSegmentDirectory: segDir)
            try? MobileSegmentScreencastJSONStore.write(diagnostic, to: segDiagURL)
        }
        let runtimeDiagnosticURL = MobileSegmentScreencastPaths.url(
            root: self.rootURL,
            relativePath: MobileSegmentScreencastPaths.runtimeDiagnosticRelativePath(sessionID: sessionID)
        )
        try? MobileSegmentScreencastJSONStore.write(diagnostic, to: runtimeDiagnosticURL)
        self.writeRuntime(state: .failed, sessionID: sessionID, segmentID: segmentID, revision: revision, now: now)
        self.postChangedHook()

        if MobileSegmentScreencastStopPolicy.shouldErrorExit(for: reason) {
            let error = MobileSegmentScreencastStopPolicy.stopError(for: reason)
            self.finishWithErrorHook(error)
        }
    }
}
