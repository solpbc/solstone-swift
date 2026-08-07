// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

@MainActor
final class WatchCaptureLifecycleSerializer {
    enum Intent: Equatable, Sendable {
        struct Terminal: Equatable, Sendable {
            let reason: WatchCaptureTerminalReason
            let disposition: WatchCaptureTerminalDisposition
            let livenessEvidence: WatchCaptureLivenessEvidence?
            let source: WatchCaptureSourceToken

            init(
                reason: WatchCaptureTerminalReason,
                disposition: WatchCaptureTerminalDisposition,
                livenessEvidence: WatchCaptureLivenessEvidence? = nil,
                source: WatchCaptureSourceToken
            ) {
                self.reason = reason
                self.disposition = disposition
                self.livenessEvidence = livenessEvidence
                self.source = source
            }
        }

        case reconcile
        case start
        case stop
        case rollover
        case terminal(Terminal)
    }

    enum AdmissionDecision: Sendable {
        case drop
        case enqueue
    }

    typealias Admission = @MainActor @Sendable (Intent) -> AdmissionDecision
    typealias Executor = @MainActor @Sendable (Intent) async -> Void

    private static let logger = Logger(subsystem: "app.solstone.swift", category: "watch-capture")

    private var admission: Admission?
    private var executor: Executor?
    private var pending: [Intent] = []
    private var current: Intent?
    private var pumpTask: Task<Void, Never>?
    private var settledWaiters: [CheckedContinuation<Void, Never>] = []

    func configure<Owner: AnyObject>(
        owner: Owner,
        admission: @escaping @MainActor @Sendable (Owner, Intent) -> AdmissionDecision,
        executor: @escaping @MainActor @Sendable (Owner, Intent) async -> Void
    ) {
        guard self.admission == nil, self.executor == nil else {
            Self.logger.error("lifecycle serializer configured more than once")
            return
        }
        self.admission = { [weak owner] intent in
            guard let owner else { return .drop }
            return admission(owner, intent)
        }
        self.executor = { [weak owner] intent in
            guard let owner else { return }
            await executor(owner, intent)
        }
    }

    func submit(_ intent: Intent) {
        guard let admission = self.admission, self.executor != nil else {
            Self.logger.error("lifecycle serializer submitted before configuration")
            return
        }

        guard !self.compact(intent) else {
            self.resumeSettledWaitersIfNeeded()
            return
        }

        switch admission(intent) {
        case .drop:
            self.resumeSettledWaitersIfNeeded()
        case .enqueue:
            self.pending.append(intent)
            self.startPumpIfNeeded()
        }
    }

    var isSettled: Bool {
        !self.isBusy
    }

    func settled() async {
        guard self.isBusy else { return }
        await withCheckedContinuation { continuation in
            self.settledWaiters.append(continuation)
            self.resumeSettledWaitersIfNeeded()
        }
    }

    private var isBusy: Bool {
        self.current != nil || !self.pending.isEmpty || self.pumpTask != nil
    }

    /// Reduces redundant intents. A Stop removes all pending Starts, then
    /// coalesces only with a Stop that still represents the latest stop intent.
    private func compact(_ intent: Intent) -> Bool {
        switch intent {
        case .start:
            for queued in self.pending.reversed() {
                if queued.isStop {
                    return false
                }
                if queued.isStart {
                    return true
                }
            }
            return self.current?.isStart == true

        case .stop:
            self.pending.removeAll(where: \.isStart)
            return self.current?.isStop == true || self.pending.contains(where: \.isStop)

        case .reconcile:
            return self.current?.isReconcile == true || self.pending.contains(where: \.isReconcile)

        case .rollover, .terminal:
            return false
        }
    }

    private func startPumpIfNeeded() {
        guard self.pumpTask == nil else { return }
        self.pumpTask = Task { [weak self] in
            await self?.runPump()
        }
    }

    private func runPump() async {
        while !self.pending.isEmpty {
            let intent = self.pending.removeFirst()
            self.current = intent
            if let executor = self.executor {
                await executor(intent)
            }
            self.current = nil
        }
        self.pumpTask = nil
        self.resumeSettledWaitersIfNeeded()
    }

    private func resumeSettledWaitersIfNeeded() {
        guard !self.isBusy else { return }
        let waiters = self.settledWaiters
        self.settledWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private extension WatchCaptureLifecycleSerializer.Intent {
    var isReconcile: Bool {
        if case .reconcile = self { return true }
        return false
    }

    var isStart: Bool {
        if case .start = self { return true }
        return false
    }

    var isStop: Bool {
        if case .stop = self { return true }
        return false
    }
}
