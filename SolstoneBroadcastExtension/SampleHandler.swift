// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreMedia
import Foundation
import ReplayKit
import os

nonisolated private let screencastHandlerLog = Logger(subsystem: "app.solstone.swift", category: "screencast-extension")

/// Broadcast Upload Extension entry point.
///
/// `nonisolated` keeps ReplayKit sample delivery off the app's default main
/// actor. Durable App Group JSON is the only cross-process source of truth;
/// Darwin notifications only wake host reconciliation.
nonisolated final class SampleHandler: RPBroadcastSampleHandler {
    private static let handoffWaitSeconds: TimeInterval = 2

    private let writer = ScreencastBroadcastWriter()
    private let sessionID = UUID()
    private var rootURL: URL?
    private var handoff: MobileSegmentScreencastHandoffRecord?
    private var runtimeRevision: Int64 = 0
    private var startedAt: Date?
    private var shouldDropSamples = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let now = Date()
        self.startedAt = now
        self.shouldDropSamples = false
        do {
            let rootURL = try AppGroupContainer.rootURL()
            self.rootURL = rootURL
            try self.writeRuntime(state: .broadcastStarted, rootURL: rootURL, now: now)
            Self.postChanged()

            guard let handoff = self.waitForValidHandoff(rootURL: rootURL, deadline: now.addingTimeInterval(Self.handoffWaitSeconds)) else {
                let diagnostic = self.diagnostic(reason: .staleOrMissingPointer, message: "handoff_unavailable", endedAt: Date())
                self.writeDiagnostic(diagnostic, rootURL: rootURL)
                Self.postChanged()
                self.finishBroadcastWithError(Self.error("stale_or_missing_pointer"))
                return
            }

            try self.writer.open(rootURL: rootURL, handoff: handoff, now: Date())
            self.handoff = handoff
            try self.writeRuntime(state: .writerOpen, rootURL: rootURL, now: Date())
            Self.postChanged()
        } catch let appGroupError as AppGroupContainerError {
            screencastHandlerLog.error("app group unavailable: \(String(describing: appGroupError), privacy: .public)")
            self.finishBroadcastWithError(Self.error("app_group_unavailable"))
        } catch {
            if let rootURL = self.rootURL {
                let diagnostic = self.diagnostic(reason: .filesystemHandoffFailure, message: String(describing: error), endedAt: Date())
                self.writeDiagnostic(diagnostic, rootURL: rootURL)
                Self.postChanged()
            }
            screencastHandlerLog.error("broadcast start failed: \(String(describing: error), privacy: .public)")
            self.finishBroadcastWithError(Self.error("filesystem_handoff_failure"))
        }
    }

    override func broadcastPaused() {
        if let rootURL {
            try? self.writeRuntime(state: .writerOpen, rootURL: rootURL, now: Date())
        }
    }

    override func broadcastResumed() {
        if let rootURL {
            try? self.writeRuntime(state: .writerOpen, rootURL: rootURL, now: Date())
        }
    }

    override func broadcastFinished() {
        guard let rootURL else { return }
        let finishingAt = Date()
        try? self.writeRuntime(state: .finishing, rootURL: rootURL, now: finishingAt)
        Self.postChanged()

        let outcome = self.writer.finish(now: Date())
        switch outcome {
        case .completed:
            try? self.writeRuntime(state: .finalized, rootURL: rootURL, now: Date())
        case .noVideo, .finalizeTimeout, .writerFailure, .filesystemHandoffFailure:
            let reason = outcome.diagnosticReason ?? .writerFailure
            let diagnostic = self.diagnostic(reason: reason, message: Self.message(for: outcome), endedAt: Date())
            self.writeDiagnostic(diagnostic, rootURL: rootURL)
            try? self.writeRuntime(state: .failed, rootURL: rootURL, now: Date())
        }
        Self.postChanged()
    }

    override func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        with sampleBufferType: RPSampleBufferType
    ) {
        let kind = Self.sampleKind(from: sampleBufferType)
        guard MobileSegmentScreencastSamplePolicy.accepts(kind) else { return }
        let now = Date()
        if let rootURL {
            self.rotateIfNeeded(rootURL: rootURL, now: now)
        }
        guard !self.shouldDropSamples else { return }
        self.writer.appendVideo(sampleBuffer, now: now)
    }
}

private extension SampleHandler {
    nonisolated func waitForValidHandoff(
        rootURL: URL,
        deadline: Date
    ) -> MobileSegmentScreencastHandoffRecord? {
        while Date() <= deadline {
            if let handoff = self.readHandoff(rootURL: rootURL),
               self.isValid(handoff: handoff) {
                return handoff
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    nonisolated func readHandoff(rootURL: URL) -> MobileSegmentScreencastHandoffRecord? {
        let url = MobileSegmentScreencastPaths.url(root: rootURL, relativePath: MobileSegmentScreencastPaths.handoffRelativePath())
        return try? MobileSegmentScreencastJSONStore.read(MobileSegmentScreencastHandoffRecord.self, from: url)
    }

    nonisolated func readContinuationLease(
        rootURL: URL,
        fromSegmentID: UUID
    ) -> MobileSegmentScreencastContinuationLease? {
        let url = MobileSegmentScreencastPaths.url(
            root: rootURL,
            relativePath: MobileSegmentScreencastPaths.continuationLeaseRelativePath(fromSegmentID: fromSegmentID)
        )
        return try? MobileSegmentScreencastJSONStore.read(MobileSegmentScreencastContinuationLease.self, from: url)
    }

    nonisolated func rotateIfNeeded(rootURL: URL, now: Date) {
        guard let current = self.handoff else { return }
        if let next = self.readHandoff(rootURL: rootURL),
           self.isValid(handoff: next),
           next.revision > current.revision,
           next.segmentID != current.segmentID {
            self.rotate(to: next, rootURL: rootURL, now: now)
            return
        }
        guard now >= current.rolloverAfter else { return }
        if let lease = self.readContinuationLease(rootURL: rootURL, fromSegmentID: current.segmentID),
           let next = self.handoff(from: lease, current: current, now: now) {
            self.rotate(to: next, rootURL: rootURL, now: now)
            return
        }
        let diagnostic = self.diagnostic(reason: .staleOrMissingPointer, message: "continuation_lease_unavailable", endedAt: now)
        self.writeDiagnostic(diagnostic, rootURL: rootURL)
        Self.postChanged()
        self.shouldDropSamples = true
        self.finishBroadcastWithError(Self.error("stale_or_missing_pointer"))
    }

    nonisolated func rotate(
        to next: MobileSegmentScreencastHandoffRecord,
        rootURL: URL,
        now: Date
    ) {
        let outcome = self.writer.finish(now: now)
        switch outcome {
        case .completed:
            try? self.writeRuntime(state: .finalized, rootURL: rootURL, now: now)
            Self.postChanged()
            do {
                try self.writer.open(rootURL: rootURL, handoff: next, now: now)
                self.handoff = next
                try self.writeRuntime(state: .writerOpen, rootURL: rootURL, now: now)
                Self.postChanged()
            } catch {
                let diagnostic = self.diagnostic(reason: .filesystemHandoffFailure, message: String(describing: error), endedAt: now)
                self.writeDiagnostic(diagnostic, rootURL: rootURL)
                Self.postChanged()
                self.shouldDropSamples = true
                self.finishBroadcastWithError(Self.error("filesystem_handoff_failure"))
            }
        case .noVideo, .finalizeTimeout, .writerFailure, .filesystemHandoffFailure:
            let reason = outcome.diagnosticReason ?? .writerFailure
            let diagnostic = self.diagnostic(reason: reason, message: Self.message(for: outcome), endedAt: now)
            self.writeDiagnostic(diagnostic, rootURL: rootURL)
            try? self.writeRuntime(state: .failed, rootURL: rootURL, now: now)
            Self.postChanged()
            self.shouldDropSamples = true
            self.finishBroadcastWithError(Self.error(reason.rawValue))
        }
    }

    nonisolated func handoff(
        from lease: MobileSegmentScreencastContinuationLease,
        current: MobileSegmentScreencastHandoffRecord,
        now: Date
    ) -> MobileSegmentScreencastHandoffRecord? {
        guard lease.fromSegmentID == current.segmentID,
              now >= lease.notBefore,
              now <= lease.expiresAt,
              lease.sourceSet.contains(.screencast) else {
            return nil
        }
        do {
            try MobileSegmentScreencastPaths.validateRelativePath(lease.segmentDirectoryRelativePath)
            try MobileSegmentScreencastPaths.validateRelativePath(lease.screenPartRelativePath)
            try MobileSegmentScreencastPaths.validateRelativePath(lease.screenFinalRelativePath)
        } catch {
            return nil
        }
        let currentSources = Set(current.sourceSet)
        guard currentSources.isSubset(of: Set(lease.sourceSet)) else { return nil }
        return MobileSegmentScreencastHandoffRecord(
            revision: max(lease.revision, current.revision + 1),
            eventID: UUID(),
            sessionID: current.sessionID,
            segmentID: lease.segmentID,
            sourceSetVersion: lease.sourceSetVersion,
            sourceSet: lease.sourceSet,
            startedAt: lease.startsAt,
            segmentDirectoryRelativePath: lease.segmentDirectoryRelativePath,
            screenPartRelativePath: lease.screenPartRelativePath,
            screenFinalRelativePath: lease.screenFinalRelativePath,
            desiredState: .writing,
            rolloverAfter: lease.rolloverAfter,
            lastHostUpdateAt: now
        )
    }

    nonisolated func isValid(handoff: MobileSegmentScreencastHandoffRecord) -> Bool {
        guard handoff.sessionID == self.sessionID,
              handoff.desiredState == .writing,
              handoff.sourceSet.contains(.screencast) else {
            return false
        }
        do {
            try MobileSegmentScreencastPaths.validateRelativePath(handoff.segmentDirectoryRelativePath)
            try MobileSegmentScreencastPaths.validateRelativePath(handoff.screenPartRelativePath)
            try MobileSegmentScreencastPaths.validateRelativePath(handoff.screenFinalRelativePath)
            return true
        } catch {
            return false
        }
    }

    nonisolated func writeRuntime(
        state: MobileSegmentScreencastRuntimeState,
        rootURL: URL,
        now: Date
    ) throws {
        self.runtimeRevision += 1
        let runtime = MobileSegmentScreencastRuntimeRecord(
            revision: self.runtimeRevision,
            sessionID: self.sessionID,
            state: state,
            startedAt: self.startedAt ?? now,
            lastSeenAt: now,
            currentSegmentID: self.handoff?.segmentID,
            currentHandoffRevision: self.handoff?.revision,
            acceptedFrameCount: self.writer.acceptedFrameCount,
            droppedFrameCount: self.writer.droppedFrameCount
        )
        let url = MobileSegmentScreencastPaths.url(root: rootURL, relativePath: MobileSegmentScreencastPaths.runtimeRelativePath())
        try MobileSegmentScreencastJSONStore.write(runtime, to: url)
    }

    nonisolated func diagnostic(
        reason: MobileSegmentScreencastDiagnosticReason,
        message: String,
        endedAt: Date
    ) -> MobileSegmentScreencastDiagnostic {
        MobileSegmentScreencastDiagnostic(
            sessionID: self.sessionID,
            segmentID: self.handoff?.segmentID,
            handoffRevision: self.handoff?.revision,
            reason: reason,
            message: message,
            startedAt: self.startedAt,
            endedAt: endedAt,
            acceptedFrameCount: self.writer.acceptedFrameCount,
            droppedFrameCount: self.writer.droppedFrameCount,
            createdAt: endedAt
        )
    }

    nonisolated func writeDiagnostic(
        _ diagnostic: MobileSegmentScreencastDiagnostic,
        rootURL: URL
    ) {
        let relativePath: String
        if let segmentID = diagnostic.segmentID {
            relativePath = MobileSegmentScreencastPaths.screenDiagnosticRelativePath(segmentID: segmentID)
        } else {
            relativePath = MobileSegmentScreencastPaths.runtimeDiagnosticRelativePath(sessionID: diagnostic.sessionID)
        }
        let url = MobileSegmentScreencastPaths.url(root: rootURL, relativePath: relativePath)
        do {
            try MobileSegmentScreencastJSONStore.write(diagnostic, to: url)
        } catch {
            screencastHandlerLog.error("diagnostic write failed: \(String(describing: error), privacy: .public)")
        }
    }

    nonisolated static func sampleKind(from sampleBufferType: RPSampleBufferType) -> MobileSegmentScreencastSampleKind {
        switch sampleBufferType {
        case .video:
            .video
        case .audioApp:
            .audioApp
        case .audioMic:
            .audioMic
        @unknown default:
            .unknown
        }
    }

    nonisolated static func postChanged() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(MobileSegmentScreencastNotifications.changed as CFString),
            nil,
            nil,
            true
        )
    }

    nonisolated static func error(_ reason: String) -> NSError {
        NSError(
            domain: "app.solstone.swift.screencast",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: reason]
        )
    }

    nonisolated static func message(for outcome: ScreencastBroadcastWriterOutcome) -> String {
        switch outcome {
        case .completed:
            "completed"
        case .noVideo:
            "no_video"
        case .finalizeTimeout:
            "finalize_timeout"
        case .writerFailure(let reason), .filesystemHandoffFailure(let reason):
            reason
        }
    }
}
