// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

private let screencastLog = Logger(subsystem: "app.solstone.swift", category: "screencast")

nonisolated enum ScreencastReconcileReason: String, Equatable, Sendable {
    case launch
    case foreground
    case darwinNotification
    case mobileSegmentResume
    case startingTimeout
}

nonisolated enum ScreencastAttention: String, Codable, Equatable, Sendable {
    case noVideo
    case finalizeFailed
    case staleOrMissingPointer
    case appGroupUnavailable
}

nonisolated enum ScreencastUnavailableReason: String, Codable, Equatable, Sendable {
    case appGroupUnavailable
    case extensionUnavailable
}

nonisolated struct ScreencastFilesystemState: Equatable, Sendable {
    let segmentID: UUID?
    let screenExists: Bool
    let partExists: Bool
    let hasFreshLiveness: Bool
    let terminalDiagnostic: MobileSegmentScreencastDiagnostic?

    init(
        segmentID: UUID?,
        screenExists: Bool,
        partExists: Bool,
        hasFreshLiveness: Bool,
        terminalDiagnostic: MobileSegmentScreencastDiagnostic?
    ) {
        self.segmentID = segmentID
        self.screenExists = screenExists
        self.partExists = partExists
        self.hasFreshLiveness = hasFreshLiveness
        self.terminalDiagnostic = terminalDiagnostic
    }

    static let empty = Self(
        segmentID: nil,
        screenExists: false,
        partExists: false,
        hasFreshLiveness: false,
        terminalDiagnostic: nil
    )
}

nonisolated struct ScreencastReconcileInput: Equatable, Sendable {
    let runtime: MobileSegmentScreencastRuntimeRecord?
    let handoff: MobileSegmentScreencastHandoffRecord?
    let continuationLease: MobileSegmentScreencastContinuationLease?
    let filesystem: ScreencastFilesystemState
    let engineSources: Set<MobileSegmentSource>
    let manifestResolution: MobileSegmentSourceResolution?
    let lastProcessedRuntimeRevision: Int64
    let lastProcessedHandoffRevision: Int64
    let now: Date

    init(
        runtime: MobileSegmentScreencastRuntimeRecord?,
        handoff: MobileSegmentScreencastHandoffRecord?,
        continuationLease: MobileSegmentScreencastContinuationLease?,
        filesystem: ScreencastFilesystemState,
        engineSources: Set<MobileSegmentSource>,
        manifestResolution: MobileSegmentSourceResolution?,
        lastProcessedRuntimeRevision: Int64,
        lastProcessedHandoffRevision: Int64,
        now: Date
    ) {
        self.runtime = runtime
        self.handoff = handoff
        self.continuationLease = continuationLease
        self.filesystem = filesystem
        self.engineSources = engineSources
        self.manifestResolution = manifestResolution
        self.lastProcessedRuntimeRevision = lastProcessedRuntimeRevision
        self.lastProcessedHandoffRevision = lastProcessedHandoffRevision
        self.now = now
    }
}

nonisolated enum ScreencastReconcileAction: Equatable, Sendable {
    case startBoundary(startedAt: Date, sessionID: UUID)
    case adoptLease(MobileSegmentScreencastContinuationLease, sessionID: UUID)
    case recordFinalized(segmentID: UUID)
    case recordNoArtifact(segmentID: UUID, reason: String)
    case recordFailed(segmentID: UUID, reason: String)
    case finalizeSegment(segmentID: UUID, endedAt: Date)
    case stopBoundary(endedAt: Date)
    case keepLivePart(segmentID: UUID)
    case surfaceAttention(MobileSegmentScreencastDiagnosticReason)
    case noOp
}

nonisolated enum ScreencastDiagnosticResolution: Equatable, Sendable {
    case noArtifact(reason: String)
    case failedToFinalize(reason: String)
    case runtimeAttention(MobileSegmentScreencastDiagnosticReason)
}

nonisolated enum ScreencastContinuationLeaseDecision: Equatable, Sendable {
    case future
    case valid(MobileSegmentScreencastContinuationLease)
    case failed(MobileSegmentScreencastDiagnosticReason)
}

nonisolated func deriveScreencastReconcileActions(input: ScreencastReconcileInput) -> [ScreencastReconcileAction] {
    if input.manifestResolution?.state.isTerminal == true {
        return [.noOp]
    }

    let terminalDiagnostic = input.filesystem.terminalDiagnostic
    let terminalSegmentID = terminalDiagnostic?.segmentID
        ?? input.filesystem.segmentID
        ?? input.runtime?.currentSegmentID
        ?? input.handoff?.segmentID

    if let lease = input.continuationLease,
       let sessionID = input.runtime?.sessionID ?? input.handoff?.sessionID,
       input.filesystem.segmentID == lease.fromSegmentID,
       input.filesystem.screenExists {
        switch evaluateScreencastContinuationLease(
            lease,
            currentHandoff: input.handoff?.segmentID == lease.fromSegmentID ? input.handoff : nil,
            currentSegmentID: lease.fromSegmentID,
            now: input.now
        ) {
        case .valid(let validLease):
            let endedAt = terminalDiagnostic?.endedAt ?? input.runtime?.lastSeenAt ?? input.now
            return [
                .adoptLease(validLease, sessionID: sessionID),
                .recordFinalized(segmentID: validLease.fromSegmentID),
                .finalizeSegment(segmentID: validLease.fromSegmentID, endedAt: endedAt),
            ]
        case .failed(let reason):
            return [.surfaceAttention(reason)]
        case .future:
            return [.noOp]
        }
    }

    if let handoff = input.handoff,
       input.filesystem.partExists,
       input.filesystem.hasFreshLiveness,
       input.now >= handoff.rolloverAfter {
        switch evaluateScreencastContinuationLease(
            input.continuationLease,
            currentHandoff: handoff,
            currentSegmentID: handoff.segmentID,
            now: input.now
        ) {
        case .failed(let reason):
            return [.surfaceAttention(reason)]
        case .future, .valid:
            break
        }
    }

    if let segmentID = terminalSegmentID {
        if input.filesystem.screenExists {
            return terminalActions(
                primary: .recordFinalized(segmentID: segmentID),
                engineSources: input.engineSources,
                endedAt: terminalDiagnostic?.endedAt ?? input.runtime?.lastSeenAt ?? input.now
            )
        }

        if let terminalDiagnostic {
            switch screencastDiagnosticResolution(for: terminalDiagnostic.reason, hasSegment: true) {
            case .noArtifact(let reason):
                return terminalActions(
                    primary: .recordNoArtifact(segmentID: segmentID, reason: reason),
                    engineSources: input.engineSources,
                    endedAt: terminalDiagnostic.endedAt
                )
            case .failedToFinalize(let reason):
                var actions = terminalActions(
                    primary: .recordFailed(segmentID: segmentID, reason: reason),
                    engineSources: input.engineSources,
                    endedAt: terminalDiagnostic.endedAt
                )
                actions.append(.surfaceAttention(terminalDiagnostic.reason))
                return actions
            case .runtimeAttention(let reason):
                return [.surfaceAttention(reason)]
            }
        }

        if input.filesystem.partExists, input.filesystem.hasFreshLiveness {
            return [.keepLivePart(segmentID: segmentID)]
        }
    } else if let terminalDiagnostic {
        return [.surfaceAttention(terminalDiagnostic.reason)]
    }

    guard let runtime = input.runtime else {
        return [.noOp]
    }

    switch runtime.state {
    case .broadcastStarted, .writerOpen:
        if runtime.revision <= input.lastProcessedRuntimeRevision,
           input.handoff?.revision ?? 0 <= input.lastProcessedHandoffRevision {
            return [.noOp]
        }
        if !input.engineSources.contains(.screencast) {
            return [.startBoundary(startedAt: runtime.startedAt, sessionID: runtime.sessionID)]
        }
        return [.noOp]
    case .finishing:
        if let segmentID = terminalSegmentID, input.filesystem.partExists, input.filesystem.hasFreshLiveness {
            return [.keepLivePart(segmentID: segmentID)]
        }
        return [.noOp]
    case .finalized:
        if let segmentID = terminalSegmentID, input.filesystem.screenExists {
            return terminalActions(
                primary: .recordFinalized(segmentID: segmentID),
                engineSources: input.engineSources,
                endedAt: runtime.lastSeenAt
            )
        }
        return [.noOp]
    case .failed:
        if let terminalDiagnostic {
            return [.surfaceAttention(terminalDiagnostic.reason)]
        }
        return [.noOp]
    }
}

nonisolated func screencastDiagnosticResolution(
    for reason: MobileSegmentScreencastDiagnosticReason,
    hasSegment: Bool
) -> ScreencastDiagnosticResolution {
    switch reason {
    case .noVideo:
        hasSegment ? .noArtifact(reason: reason.rawValue) : .runtimeAttention(reason)
    case .finalizeTimeout, .writerFailure, .staleOrMissingPointer, .filesystemHandoffFailure:
        hasSegment ? .failedToFinalize(reason: reason.rawValue) : .runtimeAttention(reason)
    case .appGroupUnavailable:
        .runtimeAttention(reason)
    }
}

nonisolated func evaluateScreencastContinuationLease(
    _ lease: MobileSegmentScreencastContinuationLease?,
    currentHandoff: MobileSegmentScreencastHandoffRecord?,
    currentSegmentID: UUID?,
    now: Date
) -> ScreencastContinuationLeaseDecision {
    guard let lease else {
        return .failed(.staleOrMissingPointer)
    }
    if now < lease.notBefore {
        return .future
    }
    if now > lease.expiresAt {
        return .failed(.staleOrMissingPointer)
    }
    guard let currentSegmentID, lease.fromSegmentID == currentSegmentID else {
        return .failed(.staleOrMissingPointer)
    }
    guard lease.sourceSet.contains(.screencast) else {
        return .failed(.staleOrMissingPointer)
    }
    guard validateLeasePaths(lease) else {
        return .failed(.staleOrMissingPointer)
    }
    if let currentHandoff {
        let handoffSources = Set(currentHandoff.sourceSet)
        let leaseSources = Set(lease.sourceSet)
        guard currentHandoff.segmentID == lease.fromSegmentID,
              handoffSources.isSubset(of: leaseSources)
        else {
            return .failed(.staleOrMissingPointer)
        }
    }
    return .valid(lease)
}

@MainActor
protocol ScreencastDarwinNotifying: AnyObject {
    func start(handler: @escaping @MainActor @Sendable () -> Void)
    func stop()
    func postChanged()
}

@MainActor
final class ScreencastDarwinNotificationCenter: ScreencastDarwinNotifying {
    static let notificationName = MobileSegmentScreencastNotifications.changed

    private var callbackBox: ScreencastDarwinCallbackBox?

    func start(handler: @escaping @MainActor @Sendable () -> Void) {
        self.stop()
        let box = ScreencastDarwinCallbackBox(handler: handler)
        self.callbackBox = box
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(box).toOpaque(),
            screencastDarwinCallback,
            Self.notificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    func stop() {
        guard let callbackBox else { return }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(callbackBox).toOpaque(),
            CFNotificationName(Self.notificationName as CFString),
            nil
        )
        self.callbackBox = nil
    }

    func postChanged() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Self.notificationName as CFString),
            nil,
            nil,
            true
        )
    }
}

@MainActor
protocol ScreencastEngineDriving: AnyObject {
    var currentScreencastSources: Set<MobileSegmentSource> { get }
    var screencastRolloverHandler: (@MainActor @Sendable (MobileSegmentScreencastHandoffRecord) -> Void)? { get set }
    func startScreencast(at startedAt: Date) async throws -> MobileSegmentScreencastHandoffRecord
    func stopScreencast(at endedAt: Date) async throws
    func currentScreencastHandoff() -> MobileSegmentScreencastHandoffRecord?
    func prepareScreencastContinuationLease(
        rolloverAt: Date,
        expiresAt: Date
    ) async throws -> MobileSegmentScreencastContinuationLease?
    func adoptScreencastContinuationLease(
        _ lease: MobileSegmentScreencastContinuationLease
    ) async throws -> MobileSegmentScreencastHandoffRecord
}

@MainActor
protocol ScreencastFacetResolving: AnyObject {
    func recordScreencastFinalized(
        segmentID: UUID,
        artifactURL: URL,
        startedAt: Date,
        endedAt: Date,
        durationS: TimeInterval?
    ) throws
    func recordScreencastNoArtifact(
        segmentID: UUID,
        startedAt: Date,
        endedAt: Date,
        durationS: TimeInterval?,
        reason: String
    ) throws
    func recordScreencastFinalizeFailed(
        segmentID: UUID,
        startedAt: Date,
        endedAt: Date,
        reason: String
    ) throws
    func screencastResolution(segmentID: UUID) -> MobileSegmentSourceResolution?
    func finalizeActiveSegment(segmentID: UUID, endedAt: Date) async
}

extension MobileSegmentEngine: ScreencastEngineDriving {
    var currentScreencastSources: Set<MobileSegmentSource> {
        switch self.state {
        case .idle:
            []
        case .open(_, let sources, _):
            sources
        case .finalizing(_, _, let activeSources, _, let pendingSources):
            pendingSources ?? activeSources
        }
    }
}

extension MobileSegmentUploader: ScreencastFacetResolving {}

@MainActor
@Observable
final class ScreencastManager {
    nonisolated enum State: Equatable, Sendable {
        case off
        case starting(startedAt: Date, deadline: Date)
        case active(sessionID: UUID, segmentID: UUID, startedAt: Date)
        case needsAttention(ScreencastAttention)
        case unavailable(ScreencastUnavailableReason)
    }

    var state: State = .off

    @ObservationIgnored private let engine: any ScreencastEngineDriving
    @ObservationIgnored private let uploader: any ScreencastFacetResolving
    @ObservationIgnored private let clock: any ObserverClock
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let rootURLProvider: () throws -> URL
    @ObservationIgnored private let darwin: any ScreencastDarwinNotifying
    @ObservationIgnored private var startingTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var leaseRefreshTask: Task<Void, Never>?

    private enum Key {
        static let lastProcessedRuntimeRevision = "screencast.lastProcessedRuntimeRevision"
        static let lastProcessedHandoffRevision = "screencast.lastProcessedHandoffRevision"
        static let lastSessionID = "screencast.lastSessionID"
        static let startingDeadline = "screencast.startingDeadline"
        static let lastAttentionReason = "screencast.lastAttentionReason"
        static let lastAttentionAt = "screencast.lastAttentionAt"
    }

    static let startingTimeoutSeconds: TimeInterval = 20
    static let leaseRefreshSeconds: TimeInterval = 30
    static let leaseExpirySeconds: TimeInterval = 30

    convenience init(
        clock: any ObserverClock = SystemObserverClock(),
        defaults: UserDefaults? = UserDefaults(suiteName: AppGroupContainer.identifier),
        rootURLProvider: @escaping () throws -> URL = { try AppGroupContainer.rootURL() },
        darwin: any ScreencastDarwinNotifying = ScreencastDarwinNotificationCenter()
    ) {
        let uploader = MobileSegmentUploader(transport: ObserverUploader(), clock: clock)
        let engine = MobileSegmentEngine(uploader: uploader, clock: clock)
        self.init(
            engine: engine,
            uploader: uploader,
            clock: clock,
            defaults: defaults,
            rootURLProvider: rootURLProvider,
            darwin: darwin
        )
    }

    init(
        engine: any ScreencastEngineDriving,
        uploader: any ScreencastFacetResolving,
        clock: any ObserverClock = SystemObserverClock(),
        defaults: UserDefaults? = UserDefaults(suiteName: AppGroupContainer.identifier),
        rootURLProvider: @escaping () throws -> URL = { try AppGroupContainer.rootURL() },
        darwin: any ScreencastDarwinNotifying = ScreencastDarwinNotificationCenter()
    ) {
        self.engine = engine
        self.uploader = uploader
        self.clock = clock
        self.defaults = defaults
        self.rootURLProvider = rootURLProvider
        self.darwin = darwin
        self.restoreStartingState()
        self.engine.screencastRolloverHandler = { [weak self] handoff in
            self?.publishRolloverHandoff(handoff)
        }
    }

    func startObservingDarwin() {
        self.darwin.start { [weak self] in
            Task { @MainActor [weak self] in
                await self?.reconcileScreencast(reason: .darwinNotification)
            }
        }
    }

    func stopObservingDarwin() {
        self.darwin.stop()
        self.stopLeaseRefreshTask()
    }

    func prepareForBackground() async {
        guard case .active = self.state else { return }
        do {
            let root = try self.rootURLProvider()
            try await self.publishContinuationLease(root: root)
        } catch {
            screencastLog.error("screencast background lease publish failed: \(String(describing: error), privacy: .public)")
        }
    }

    func beginStarting() {
        let startedAt = self.clock.now()
        let deadline = startedAt.addingTimeInterval(Self.startingTimeoutSeconds)
        self.state = .starting(startedAt: startedAt, deadline: deadline)
        self.defaults?.set(deadline, forKey: Key.startingDeadline)
        self.startStartingTimeoutTask(until: deadline)
    }

    func cancelStarting() {
        guard case .starting = self.state else { return }
        self.clearStarting()
        self.state = .off
    }

    func markExtensionUnavailable() {
        self.clearStarting()
        self.state = .unavailable(.extensionUnavailable)
    }

    func reconcileScreencast(reason: ScreencastReconcileReason) async {
        let root: URL
        do {
            root = try self.rootURLProvider()
        } catch {
            screencastLog.error("screencast app group unavailable: \(String(describing: error), privacy: .public)")
            self.persistAttention(.appGroupUnavailable)
            self.clearStarting()
            self.state = .unavailable(.appGroupUnavailable)
            return
        }

        let runtime = self.readRuntime(root: root)
        if reason == .startingTimeout,
           runtime == nil,
           case .starting = self.state {
            self.clearStarting()
            self.state = .off
            return
        }

        let handoff = self.readHandoff(root: root)
        let continuationLease = self.readContinuationLease(root: root, runtime: runtime, handoff: handoff)
        let diagnostic = self.readDiagnostic(root: root, runtime: runtime, handoff: handoff, lease: continuationLease)
        let filesystem = self.filesystemState(root: root, runtime: runtime, handoff: handoff, lease: continuationLease, diagnostic: diagnostic)
        let manifestResolution = filesystem.segmentID.flatMap {
            self.uploader.screencastResolution(segmentID: $0)
        }
        let input = ScreencastReconcileInput(
            runtime: runtime,
            handoff: handoff,
            continuationLease: continuationLease,
            filesystem: filesystem,
            engineSources: self.engine.currentScreencastSources,
            manifestResolution: manifestResolution,
            lastProcessedRuntimeRevision: self.readRevision(Key.lastProcessedRuntimeRevision),
            lastProcessedHandoffRevision: self.readRevision(Key.lastProcessedHandoffRevision),
            now: self.clock.now()
        )

        let actions = deriveScreencastReconcileActions(input: input)
        do {
            try await self.apply(actions: actions, root: root, runtime: runtime, handoff: handoff, diagnostic: diagnostic)
            if case .active = self.state {
                try await self.publishContinuationLease(root: root)
                self.startLeaseRefreshTask()
            } else {
                self.stopLeaseRefreshTask()
            }
            self.persistProcessed(runtime: runtime, handoff: handoff)
        } catch {
            screencastLog.error("screencast reconcile failed: \(String(describing: error), privacy: .public)")
            self.persistAttention(.finalizeFailed)
            self.state = .needsAttention(.finalizeFailed)
        }
    }
}

private extension ScreencastManager {
    func restoreStartingState() {
        guard let deadline = self.defaults?.object(forKey: Key.startingDeadline) as? Date else { return }
        let now = self.clock.now()
        if deadline > now {
            self.state = .starting(
                startedAt: deadline.addingTimeInterval(-Self.startingTimeoutSeconds),
                deadline: deadline
            )
            self.startStartingTimeoutTask(until: deadline)
        } else {
            self.defaults?.removeObject(forKey: Key.startingDeadline)
            self.state = .off
        }
    }

    func startStartingTimeoutTask(until deadline: Date) {
        self.startingTimeoutTask?.cancel()
        let delay = max(0, deadline.timeIntervalSince(self.clock.now()))
        self.startingTimeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(for: .milliseconds(Int(delay * 1_000)))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self.reconcileScreencast(reason: .startingTimeout)
        }
    }
    func clearStarting() {
        self.startingTimeoutTask?.cancel()
        self.startingTimeoutTask = nil
        self.defaults?.removeObject(forKey: Key.startingDeadline)
    }

    func readRuntime(root: URL) -> MobileSegmentScreencastRuntimeRecord? {
        let url = MobileSegmentScreencastPaths.url(root: root, relativePath: MobileSegmentScreencastPaths.runtimeRelativePath())
        return try? MobileSegmentScreencastJSONStore.read(MobileSegmentScreencastRuntimeRecord.self, from: url)
    }

    func readHandoff(root: URL) -> MobileSegmentScreencastHandoffRecord? {
        let url = MobileSegmentScreencastPaths.url(root: root, relativePath: MobileSegmentScreencastPaths.handoffRelativePath())
        return try? MobileSegmentScreencastJSONStore.read(MobileSegmentScreencastHandoffRecord.self, from: url)
    }

    func readContinuationLease(
        root: URL,
        runtime: MobileSegmentScreencastRuntimeRecord?,
        handoff: MobileSegmentScreencastHandoffRecord?
    ) -> MobileSegmentScreencastContinuationLease? {
        var candidateIDs: [UUID] = []
        if let runtimeSegmentID = runtime?.currentSegmentID {
            candidateIDs.append(runtimeSegmentID)
        }
        if let handoffSegmentID = handoff?.segmentID {
            candidateIDs.append(handoffSegmentID)
        }
        for segmentID in candidateIDs {
            if let direct = self.readContinuationLease(root: root, fromSegmentID: segmentID) {
                return direct
            }
        }
        let leasesDirectory = MobileSegmentScreencastPaths.url(
            root: root,
            relativePath: "\(MobileSegmentScreencastPaths.mobileSegmentDirectoryName)/screencast/leases"
        )
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: leasesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var decoded: [MobileSegmentScreencastContinuationLease] = []
        for url in urls {
            if let lease = try? MobileSegmentScreencastJSONStore.read(MobileSegmentScreencastContinuationLease.self, from: url) {
                decoded.append(lease)
            }
        }
        return decoded
            .filter { lease in
                candidateIDs.contains(lease.segmentID) || candidateIDs.contains(lease.fromSegmentID)
            }
            .sorted { $0.revision > $1.revision }
            .first
    }

    func readContinuationLease(root: URL, fromSegmentID: UUID) -> MobileSegmentScreencastContinuationLease? {
        let url = MobileSegmentScreencastPaths.url(
            root: root,
            relativePath: MobileSegmentScreencastPaths.continuationLeaseRelativePath(fromSegmentID: fromSegmentID)
        )
        return try? MobileSegmentScreencastJSONStore.read(MobileSegmentScreencastContinuationLease.self, from: url)
    }

    func readDiagnostic(
        root: URL,
        runtime: MobileSegmentScreencastRuntimeRecord?,
        handoff: MobileSegmentScreencastHandoffRecord?,
        lease: MobileSegmentScreencastContinuationLease?
    ) -> MobileSegmentScreencastDiagnostic? {
        var candidateIDs: [UUID] = []
        if let leaseFromSegmentID = lease?.fromSegmentID {
            candidateIDs.append(leaseFromSegmentID)
        }
        if let runtimeSegmentID = runtime?.currentSegmentID {
            candidateIDs.append(runtimeSegmentID)
        }
        if let handoffSegmentID = handoff?.segmentID {
            candidateIDs.append(handoffSegmentID)
        }

        for segmentID in candidateIDs {
            let segmentDiagnostic = MobileSegmentScreencastPaths.url(
                root: root,
                relativePath: MobileSegmentScreencastPaths.screenDiagnosticRelativePath(segmentID: segmentID)
            )
            if let diagnostic = try? MobileSegmentScreencastJSONStore.read(MobileSegmentScreencastDiagnostic.self, from: segmentDiagnostic) {
                return diagnostic
            }
        }
        guard let sessionID = runtime?.sessionID ?? handoff?.sessionID else { return nil }
        let runtimeDiagnostic = MobileSegmentScreencastPaths.url(
            root: root,
            relativePath: MobileSegmentScreencastPaths.runtimeDiagnosticRelativePath(sessionID: sessionID)
        )
        return try? MobileSegmentScreencastJSONStore.read(MobileSegmentScreencastDiagnostic.self, from: runtimeDiagnostic)
    }

    func filesystemState(
        root: URL,
        runtime: MobileSegmentScreencastRuntimeRecord?,
        handoff: MobileSegmentScreencastHandoffRecord?,
        lease: MobileSegmentScreencastContinuationLease?,
        diagnostic: MobileSegmentScreencastDiagnostic?
    ) -> ScreencastFilesystemState {
        let segmentID = diagnostic?.segmentID
            ?? self.leaseBackedClosingSegmentID(root: root, lease: lease)
            ?? runtime?.currentSegmentID
            ?? handoff?.segmentID
        guard let segmentID else {
            return ScreencastFilesystemState(
                segmentID: nil,
                screenExists: false,
                partExists: false,
                hasFreshLiveness: false,
                terminalDiagnostic: diagnostic
            )
        }
        let screenURL = MobileSegmentScreencastPaths.url(
            root: root,
            relativePath: MobileSegmentScreencastPaths.screenRelativePath(segmentID: segmentID)
        )
        let partURL = MobileSegmentScreencastPaths.url(
            root: root,
            relativePath: MobileSegmentScreencastPaths.screenPartRelativePath(segmentID: segmentID)
        )
        let livenessURL = MobileSegmentScreencastPaths.url(
            root: root,
            relativePath: MobileSegmentScreencastPaths.screenLivenessRelativePath(segmentID: segmentID)
        )
        let liveness = try? MobileSegmentScreencastJSONStore.read(MobileSegmentScreencastSegmentLiveness.self, from: livenessURL)
        let hasFreshLiveness = liveness.map {
            $0.segmentID == segmentID
                && MobileSegmentScreencastLivenessPolicy.isFresh(lastSeenAt: $0.lastSeenAt, now: self.clock.now())
        } ?? false
        return ScreencastFilesystemState(
            segmentID: segmentID,
            screenExists: FileManager.default.fileExists(atPath: screenURL.path),
            partExists: FileManager.default.fileExists(atPath: partURL.path),
            hasFreshLiveness: hasFreshLiveness,
            terminalDiagnostic: diagnostic
        )
    }

    func leaseBackedClosingSegmentID(
        root: URL,
        lease: MobileSegmentScreencastContinuationLease?
    ) -> UUID? {
        guard let lease else { return nil }
        let screenURL = MobileSegmentScreencastPaths.url(
            root: root,
            relativePath: MobileSegmentScreencastPaths.screenRelativePath(segmentID: lease.fromSegmentID)
        )
        let partURL = MobileSegmentScreencastPaths.url(
            root: root,
            relativePath: MobileSegmentScreencastPaths.screenPartRelativePath(segmentID: lease.fromSegmentID)
        )
        let diagnosticURL = MobileSegmentScreencastPaths.url(
            root: root,
            relativePath: MobileSegmentScreencastPaths.screenDiagnosticRelativePath(segmentID: lease.fromSegmentID)
        )
        guard FileManager.default.fileExists(atPath: screenURL.path)
            || FileManager.default.fileExists(atPath: partURL.path)
            || FileManager.default.fileExists(atPath: diagnosticURL.path)
        else { return nil }
        return lease.fromSegmentID
    }

    func apply(
        actions: [ScreencastReconcileAction],
        root: URL,
        runtime: MobileSegmentScreencastRuntimeRecord?,
        handoff: MobileSegmentScreencastHandoffRecord?,
        diagnostic: MobileSegmentScreencastDiagnostic?
    ) async throws {
        guard !(actions.count == 1 && actions.first == .noOp) else { return }
        var currentHandoff = handoff
        for action in actions {
            switch action {
            case .startBoundary(let startedAt, let sessionID):
                let handoff = try await self.engine.startScreencast(at: startedAt)
                let published = self.handoff(handoff, sessionID: sessionID, now: self.clock.now())
                try self.writeHandoff(published, root: root)
                self.darwin.postChanged()
                currentHandoff = published
                self.defaults?.set(sessionID.uuidString, forKey: Key.lastSessionID)
                self.clearStarting()
                self.state = .active(sessionID: sessionID, segmentID: published.segmentID, startedAt: published.startedAt)
            case .adoptLease(let lease, let sessionID):
                let handoff = try await self.engine.adoptScreencastContinuationLease(lease)
                let published = self.handoff(handoff, sessionID: sessionID, now: self.clock.now())
                try self.writeHandoff(published, root: root)
                self.darwin.postChanged()
                currentHandoff = currentHandoff?.segmentID == lease.fromSegmentID ? currentHandoff : nil
                self.defaults?.set(sessionID.uuidString, forKey: Key.lastSessionID)
                self.clearStarting()
                self.state = .active(sessionID: sessionID, segmentID: published.segmentID, startedAt: published.startedAt)
            case .recordFinalized(let segmentID):
                let artifactURL = MobileSegmentScreencastPaths.url(
                    root: root,
                    relativePath: currentHandoff?.screenFinalRelativePath ?? MobileSegmentScreencastPaths.screenRelativePath(segmentID: segmentID)
                )
                let startedAt = currentHandoff?.startedAt ?? runtime?.startedAt ?? self.clock.now()
                let endedAt = diagnostic?.endedAt ?? runtime?.lastSeenAt ?? self.clock.now()
                try self.uploader.recordScreencastFinalized(
                    segmentID: segmentID,
                    artifactURL: artifactURL,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    durationS: min(endedAt.timeIntervalSince(startedAt), MobileSegmentDuration.rotationCeiling)
                )
            case .recordNoArtifact(let segmentID, let reason):
                let startedAt = currentHandoff?.startedAt ?? runtime?.startedAt ?? self.clock.now()
                let endedAt = diagnostic?.endedAt ?? runtime?.lastSeenAt ?? self.clock.now()
                try self.uploader.recordScreencastNoArtifact(
                    segmentID: segmentID,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    durationS: endedAt.timeIntervalSince(startedAt),
                    reason: reason
                )
            case .recordFailed(let segmentID, let reason):
                let startedAt = currentHandoff?.startedAt ?? runtime?.startedAt ?? self.clock.now()
                let endedAt = diagnostic?.endedAt ?? runtime?.lastSeenAt ?? self.clock.now()
                try self.uploader.recordScreencastFinalizeFailed(
                    segmentID: segmentID,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    reason: reason
                )
            case .finalizeSegment(let segmentID, let endedAt):
                await self.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: endedAt)
            case .stopBoundary(let endedAt):
                try await self.engine.stopScreencast(at: endedAt)
                if case .needsAttention = self.state {
                    break
                }
                self.clearStarting()
                self.state = .off
            case .keepLivePart(let segmentID):
                guard let runtime else { break }
                self.clearStarting()
                self.state = .active(sessionID: runtime.sessionID, segmentID: segmentID, startedAt: runtime.startedAt)
            case .surfaceAttention(let reason):
                let attention = screencastAttention(for: reason)
                self.persistAttention(attention)
                self.clearStarting()
                self.state = .needsAttention(attention)
            case .noOp:
                break
            }
        }
    }

    func writeHandoff(_ handoff: MobileSegmentScreencastHandoffRecord, root: URL) throws {
        let url = MobileSegmentScreencastPaths.url(root: root, relativePath: MobileSegmentScreencastPaths.handoffRelativePath())
        try MobileSegmentScreencastJSONStore.write(handoff, to: url)
    }

    func publishRolloverHandoff(_ handoff: MobileSegmentScreencastHandoffRecord) {
        do {
            let root = try self.rootURLProvider()
            let current = self.readHandoff(root: root)
            let sessionID: UUID
            if let current {
                sessionID = current.sessionID
            } else if case .active(let activeSessionID, _, _) = self.state {
                sessionID = activeSessionID
            } else {
                sessionID = handoff.sessionID
            }
            let published = self.handoff(
                handoff,
                sessionID: sessionID,
                minimumRevision: max(current?.revision ?? 0, self.readRevision(Key.lastProcessedHandoffRevision)) + 1,
                now: self.clock.now()
            )
            try self.writeHandoff(published, root: root)
            self.darwin.postChanged()
            self.state = .active(sessionID: sessionID, segmentID: published.segmentID, startedAt: published.startedAt)
            self.startLeaseRefreshTask()
        } catch {
            screencastLog.error("screencast rollover handoff publish failed: \(String(describing: error), privacy: .public)")
        }
    }

    func publishContinuationLease(root: URL) async throws {
        guard let handoff = self.engine.currentScreencastHandoff() else { return }
        let lease = try await self.engine.prepareScreencastContinuationLease(
            rolloverAt: handoff.rolloverAfter,
            expiresAt: handoff.rolloverAfter.addingTimeInterval(Self.leaseExpirySeconds)
        )
        guard let lease else { return }
        let url = MobileSegmentScreencastPaths.url(
            root: root,
            relativePath: MobileSegmentScreencastPaths.continuationLeaseRelativePath(fromSegmentID: lease.fromSegmentID)
        )
        try MobileSegmentScreencastJSONStore.write(lease, to: url)
    }

    func startLeaseRefreshTask() {
        guard self.leaseRefreshTask == nil else { return }
        self.leaseRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await self.clock.sleep(for: .seconds(Int(Self.leaseRefreshSeconds)))
                    guard !Task.isCancelled else { return }
                    guard case .active = self.state else {
                        self.stopLeaseRefreshTask()
                        return
                    }
                    let root = try self.rootURLProvider()
                    try await self.publishContinuationLease(root: root)
                } catch {
                    if !Task.isCancelled {
                        screencastLog.error("screencast lease refresh failed: \(String(describing: error), privacy: .public)")
                    }
                    return
                }
            }
        }
    }

    func stopLeaseRefreshTask() {
        self.leaseRefreshTask?.cancel()
        self.leaseRefreshTask = nil
    }

    func handoff(
        _ record: MobileSegmentScreencastHandoffRecord,
        sessionID: UUID,
        now: Date
    ) -> MobileSegmentScreencastHandoffRecord {
        self.handoff(record, sessionID: sessionID, minimumRevision: self.readRevision(Key.lastProcessedHandoffRevision) + 1, now: now)
    }

    func handoff(
        _ record: MobileSegmentScreencastHandoffRecord,
        sessionID: UUID,
        minimumRevision: Int64,
        now: Date
    ) -> MobileSegmentScreencastHandoffRecord {
        MobileSegmentScreencastHandoffRecord(
            revision: max(record.revision, minimumRevision),
            eventID: UUID(),
            sessionID: sessionID,
            segmentID: record.segmentID,
            sourceSetVersion: record.sourceSetVersion,
            sourceSet: record.sourceSet.sorted { $0.rawValue < $1.rawValue },
            startedAt: record.startedAt,
            segmentDirectoryRelativePath: record.segmentDirectoryRelativePath,
            screenPartRelativePath: record.screenPartRelativePath,
            screenFinalRelativePath: record.screenFinalRelativePath,
            desiredState: .writing,
            rolloverAfter: record.rolloverAfter,
            lastHostUpdateAt: now
        )
    }


    func persistProcessed(
        runtime: MobileSegmentScreencastRuntimeRecord?,
        handoff: MobileSegmentScreencastHandoffRecord?
    ) {
        if let runtime {
            self.defaults?.set(runtime.revision, forKey: Key.lastProcessedRuntimeRevision)
        }
        if let handoff {
            self.defaults?.set(handoff.revision, forKey: Key.lastProcessedHandoffRevision)
        }
    }

    func readRevision(_ key: String) -> Int64 {
        Int64(self.defaults?.integer(forKey: key) ?? 0)
    }

    func persistAttention(_ attention: ScreencastAttention) {
        self.defaults?.set(attention.rawValue, forKey: Key.lastAttentionReason)
        self.defaults?.set(self.clock.now(), forKey: Key.lastAttentionAt)
    }
}

private final class ScreencastDarwinCallbackBox {
    let handler: @MainActor @Sendable () -> Void

    init(handler: @escaping @MainActor @Sendable () -> Void) {
        self.handler = handler
    }

    @MainActor
    func notify() {
        self.handler()
    }
}

private let screencastDarwinCallback: CFNotificationCallback = { _, observer, _, _, _ in
    guard let observer else { return }
    let box = Unmanaged<ScreencastDarwinCallbackBox>.fromOpaque(observer).takeUnretainedValue()
    Task { @MainActor in
        box.notify()
    }
}

private nonisolated func terminalActions(
    primary: ScreencastReconcileAction,
    engineSources: Set<MobileSegmentSource>,
    endedAt: Date
) -> [ScreencastReconcileAction] {
    if engineSources.contains(.screencast) {
        return [primary, .stopBoundary(endedAt: endedAt)]
    }
    return [primary]
}

private nonisolated func validateLeasePaths(_ lease: MobileSegmentScreencastContinuationLease) -> Bool {
    do {
        try MobileSegmentScreencastPaths.validateRelativePath(lease.segmentDirectoryRelativePath)
        try MobileSegmentScreencastPaths.validateRelativePath(lease.screenPartRelativePath)
        try MobileSegmentScreencastPaths.validateRelativePath(lease.screenFinalRelativePath)
        return true
    } catch {
        return false
    }
}

private nonisolated func screencastAttention(
    for reason: MobileSegmentScreencastDiagnosticReason
) -> ScreencastAttention {
    switch reason {
    case .noVideo:
        .noVideo
    case .appGroupUnavailable:
        .appGroupUnavailable
    case .staleOrMissingPointer:
        .staleOrMissingPointer
    case .finalizeTimeout, .writerFailure, .filesystemHandoffFailure:
        .finalizeFailed
    }
}
