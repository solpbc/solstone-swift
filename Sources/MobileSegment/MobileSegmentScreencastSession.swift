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

nonisolated final class ScreencastBroadcastSession: @unchecked Sendable {
    private let clock: @Sendable () -> Date
    private let availableBytes: @Sendable (URL) -> Int64?
    private let rootURL: URL
    private let writer: any ScreencastBroadcastWriting
    private let postChangedHook: @Sendable () -> Void
    private let finishWithErrorHook: @Sendable (NSError) -> Void

    private var sessionID: UUID?
    private var broadcastStartedAt: Date?
    private var isWaitingForHandoff: Bool = false
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
        self.clock = clock
        self.availableBytes = availableBytes
        self.postChangedHook = postChanged
        self.finishWithErrorHook = finishWithError
    }

    func broadcastStarted(sessionID: UUID) {
        self.sessionID = sessionID
        self.shouldDropSamples = false
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

    func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
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
        self.writer.appendVideo(sampleBuffer, now: now)
        self.currentSidecar?.acceptedFrameCount = self.writer.acceptedFrameCount
        self.currentSidecar?.droppedFrameCount = self.writer.droppedFrameCount
    }

    func tick() {
        guard self.isBroadcastActive, !self.shouldDropSamples, let sessionID = self.sessionID else { return }
        let now = self.clock()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

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
            _ = self.writer.finish(now: now)
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
            self.closeCurrentSidecar(now: now)
            _ = self.writer.finish(now: now)

            self.currentHandoff = storedHandoff
            self.scheduleAnchorMs = storedHandoff.scheduleAnchorMs
            self.schedulePeriodSeconds = storedHandoff.schedulePeriodSeconds
            self.currentWindowIndex = 0

            do {
                try self.openWindow(index: 0, handoff: storedHandoff, now: now)
                self.writeRuntime(state: .writerOpen, sessionID: sessionID, segmentID: storedHandoff.segmentID, revision: storedHandoff.revision, now: now)
                self.postChangedHook()
            } catch {
                screencastSessionLog.error("failed to open superseding window: \(String(describing: error), privacy: .public)")
                self.failWithDiagnostic(
                    reason: .writerFailure,
                    message: String(describing: error),
                    sessionID: sessionID,
                    segmentID: storedHandoff.segmentID,
                    revision: storedHandoff.revision,
                    now: now
                )
            }
            return
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
        let outcome = self.writer.finish(now: now)

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
        self.currentHandoff = handoff
        self.scheduleAnchorMs = handoff.scheduleAnchorMs
        self.schedulePeriodSeconds = handoff.schedulePeriodSeconds
        self.currentWindowIndex = 0

        do {
            try self.openWindow(index: 0, handoff: handoff, now: now)
            self.writeRuntime(state: .writerOpen, sessionID: handoff.sessionID, segmentID: handoff.segmentID, revision: handoff.revision, now: now)
            self.postChangedHook()
        } catch {
            screencastSessionLog.error("failed to open initial window: \(String(describing: error), privacy: .public)")
            self.failWithDiagnostic(
                reason: .writerFailure,
                message: String(describing: error),
                sessionID: handoff.sessionID,
                segmentID: handoff.segmentID,
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
            _ = self.writer.finish(now: now)
            self.failWithStorageLow(sessionID: sessionID, now: now)
            return
        }

        self.closeCurrentSidecar(now: now)
        let outcome = self.writer.finish(now: now)
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
        let anchorMs = Int64(now.timeIntervalSince1970 * 1000)
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
            startedAt: now,
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
