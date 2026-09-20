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
    private let workQueue = DispatchQueue(label: "app.solstone.swift.broadcast.work")
    private let sessionID = UUID()
    private let writer = ScreencastBroadcastWriter()
    private let audioWriter = ScreencastBroadcastAudioWriter()
    private var session: ScreencastBroadcastSession?
    private var timer: DispatchSourceTimer?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        self.workQueue.async {
            do {
                let rootURL = try AppGroupContainer.rootURL()
                let session = ScreencastBroadcastSession(
                    rootURL: rootURL,
                    writer: self.writer,
                    audioWriter: self.audioWriter,
                    clock: { Date() },
                    availableBytes: { url in
                        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                        return values?.volumeAvailableCapacityForImportantUsage
                    },
                    postChanged: {
                        Self.postChanged()
                    },
                    finishWithError: { [weak self] error in
                        self?.finishBroadcastWithError(error)
                    }
                )
                self.session = session
                session.broadcastStarted(sessionID: self.sessionID)

                let timer = DispatchSource.makeTimerSource(queue: self.workQueue)
                timer.schedule(
                    deadline: .now() + MobileSegmentScreencastLivenessPolicy.livenessRefreshIntervalSeconds,
                    repeating: MobileSegmentScreencastLivenessPolicy.livenessRefreshIntervalSeconds
                )
                timer.setEventHandler { [weak self] in
                    self?.session?.tick()
                }
                timer.resume()
                self.timer = timer
            } catch {
                screencastHandlerLog.error("broadcast start failed: \(String(describing: error), privacy: .public)")
                self.finishBroadcastWithError(Self.error(MobileSegmentScreencastDiagnosticReason.appGroupUnavailable.ownerSentence))
            }
        }
    }

    override func broadcastPaused() {
        self.workQueue.async {
            self.session?.tick()
        }
    }

    override func broadcastResumed() {
        self.workQueue.async {
            self.session?.tick()
        }
    }

    override func broadcastFinished() {
        self.workQueue.sync {
            self.timer?.cancel()
            self.timer = nil
            self.session?.broadcastFinished()
            self.session = nil
        }
    }

    override func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        with sampleBufferType: RPSampleBufferType
    ) {
        let kind = Self.sampleKind(from: sampleBufferType)
        guard MobileSegmentScreencastSamplePolicy.accepts(kind) else { return }
        self.workQueue.async {
            self.session?.processSampleBuffer(sampleBuffer, kind: kind)
        }
    }

    private static func sampleKind(from sampleBufferType: RPSampleBufferType) -> MobileSegmentScreencastSampleKind {
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

    private static func postChanged() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(MobileSegmentScreencastNotifications.changed as CFString),
            nil,
            nil,
            true
        )
    }

    private static func error(_ description: String) -> NSError {
        NSError(
            domain: "app.solstone.swift.broadcast",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}
