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
    case livenessWatchdog
}

nonisolated enum ScreencastScenePhase: String, Equatable, Sendable {
    case active
    case inactive
    case background
}

nonisolated enum ScreencastLivenessScanResult: Equatable, Sendable {
    case listingFailed
    case observed(
        newestLastSeenAt: Date?,
        hasSessionUndecodableLiveness: Bool,
        hasFreshLiveness: Bool
    )
}

nonisolated func scanActiveLiveness(
    root: URL,
    sessionID: UUID,
    candidateSegmentIDs: Set<UUID>,
    now: Date
) -> ScreencastLivenessScanResult {
    let activeDirectory = root
        .appendingPathComponent(MobileSegmentScreencastPaths.mobileSegmentDirectoryName, isDirectory: true)
        .appendingPathComponent("active", isDirectory: true)

    guard FileManager.default.fileExists(atPath: activeDirectory.path) else {
        return .observed(newestLastSeenAt: nil, hasSessionUndecodableLiveness: false, hasFreshLiveness: false)
    }

    let contents: [URL]
    do {
        contents = try FileManager.default.contentsOfDirectory(
            at: activeDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
    } catch {
        return .listingFailed
    }

    var newestLastSeenAt: Date?
    var hasSessionUndecodableLiveness = false
    var hasFreshLiveness = false

    for item in contents {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else {
            continue
        }
        let segmentID = UUID(uuidString: item.lastPathComponent)
        let liveURL = item.appendingPathComponent(MobileSegmentScreencastPaths.screenLivenessFilename, isDirectory: false)
        guard FileManager.default.fileExists(atPath: liveURL.path) else {
            continue
        }
        if let liveness = try? MobileSegmentScreencastJSONStore.read(MobileSegmentScreencastSegmentLiveness.self, from: liveURL) {
            if liveness.sessionID == sessionID {
                if let currentNewest = newestLastSeenAt {
                    newestLastSeenAt = max(currentNewest, liveness.lastSeenAt)
                } else {
                    newestLastSeenAt = liveness.lastSeenAt
                }
                if MobileSegmentScreencastLivenessPolicy.isFresh(lastSeenAt: liveness.lastSeenAt, now: now) {
                    hasFreshLiveness = true
                }
            }
        } else {
            if let segmentID, candidateSegmentIDs.contains(segmentID) {
                hasSessionUndecodableLiveness = true
            }
        }
    }

    return .observed(
        newestLastSeenAt: newestLastSeenAt,
        hasSessionUndecodableLiveness: hasSessionUndecodableLiveness,
        hasFreshLiveness: hasFreshLiveness
    )
}

nonisolated func isDeadShapedDisk(
    runtime: MobileSegmentScreencastRuntimeRecord?,
    diagnostic: MobileSegmentScreencastDiagnostic?,
    scanResult: ScreencastLivenessScanResult,
    now: Date
) -> Bool {
    guard let runtime else { return false }
    switch runtime.state {
    case .broadcastStarted, .writerOpen, .finishing, .finalized:
        // A finalized runtime is an ended session. When the uploader's pre-pass has already
        // resolved its last window, the derivation has nothing left to act on, so the hold
        // on screencast must be dropped here or the app reads on forever.
        break
    case .failed:
        return false
    }
    if diagnostic != nil {
        return false
    }
    let threshold = MobileSegmentScreencastLivenessPolicy.livenessRefreshIntervalSeconds + MobileSegmentScreencastLivenessPolicy.livenessStaleWindowSeconds
    guard now.timeIntervalSince(runtime.lastSeenAt) >= threshold else {
        return false
    }
    guard case .observed(_, let hasSessionUndecodableLiveness, let hasFreshLiveness) = scanResult else {
        return false
    }
    return !hasSessionUndecodableLiveness && !hasFreshLiveness
}

nonisolated func isDeadScreencastSession(
    runtime: MobileSegmentScreencastRuntimeRecord?,
    diagnostic: MobileSegmentScreencastDiagnostic?,
    scanResult: ScreencastLivenessScanResult,
    engineSources: Set<MobileSegmentSource>,
    managerState: ScreencastManager.State,
    now: Date
) -> Bool {
    guard isDeadShapedDisk(runtime: runtime, diagnostic: diagnostic, scanResult: scanResult, now: now) else {
        return false
    }
    let isActive = engineSources.contains(.screencast) || {
        if case .active = managerState { return true }
        return false
    }()
    return isActive
}

nonisolated enum ScreencastAttention: String, Codable, Equatable, Sendable {
    case storageLow
    case noVideo
    case finalizeFailed
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
    let filesystem: ScreencastFilesystemState
    let engineSources: Set<MobileSegmentSource>
    let manifestResolution: MobileSegmentSourceResolution?
    let lastProcessedRuntimeRevision: Int64
    let lastProcessedHandoffRevision: Int64
    let lastSessionID: UUID?
    let now: Date

    init(
        runtime: MobileSegmentScreencastRuntimeRecord?,
        handoff: MobileSegmentScreencastHandoffRecord?,
        filesystem: ScreencastFilesystemState,
        engineSources: Set<MobileSegmentSource>,
        manifestResolution: MobileSegmentSourceResolution?,
        lastProcessedRuntimeRevision: Int64,
        lastProcessedHandoffRevision: Int64,
        lastSessionID: UUID? = nil,
        now: Date
    ) {
        self.runtime = runtime
        self.handoff = handoff
        self.filesystem = filesystem
        self.engineSources = engineSources
        self.manifestResolution = manifestResolution
        self.lastProcessedRuntimeRevision = lastProcessedRuntimeRevision
        self.lastProcessedHandoffRevision = lastProcessedHandoffRevision
        self.lastSessionID = lastSessionID
        self.now = now
    }
}

nonisolated enum ScreencastReconcileAction: Equatable, Sendable {
    case startBoundary(startedAt: Date, sessionID: UUID)
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

nonisolated func deriveScreencastReconcileActions(input: ScreencastReconcileInput) -> [ScreencastReconcileAction] {
    let currentSessionID = input.runtime?.sessionID ?? input.handoff?.sessionID
    let handoff = (input.runtime != nil && input.handoff?.sessionID != input.runtime?.sessionID) ? nil : input.handoff
    let terminalDiagnostic = (currentSessionID != nil && input.filesystem.terminalDiagnostic?.sessionID != currentSessionID)
        ? nil
        : input.filesystem.terminalDiagnostic

    let terminalSegmentID = terminalDiagnostic?.segmentID
        ?? input.runtime?.currentSegmentID
        ?? handoff?.segmentID

    if terminalSegmentID != nil && input.manifestResolution?.state.isTerminal == true {
        return [.noOp]
    }

    if let segmentID = terminalSegmentID {
        if input.filesystem.screenExists {
            return terminalActions(
                primary: .recordFinalized(segmentID: segmentID),
                engineSources: input.engineSources,
                boundaryAt: input.now
            )
        }

        if let terminalDiagnostic {
            switch screencastDiagnosticResolution(for: terminalDiagnostic.reason, hasSegment: true) {
            case .noArtifact(let reason):
                var actions = terminalActions(
                    primary: .recordNoArtifact(segmentID: segmentID, reason: reason),
                    engineSources: input.engineSources,
                    boundaryAt: input.now
                )
                if terminalDiagnostic.reason == .storageLow {
                    actions.append(.surfaceAttention(.storageLow))
                }
                return actions
            case .failedToFinalize(let reason):
                var actions = terminalActions(
                    primary: .recordFailed(segmentID: segmentID, reason: reason),
                    engineSources: input.engineSources,
                    boundaryAt: input.now
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
        let isSameSession = (input.lastSessionID != nil && runtime.sessionID == input.lastSessionID)
        if isSameSession,
           runtime.revision <= input.lastProcessedRuntimeRevision,
           handoff?.revision ?? 0 <= input.lastProcessedHandoffRevision {
            return [.noOp]
        }
        if !input.engineSources.contains(.screencast) {
            return [.startBoundary(startedAt: runtime.startedAt, sessionID: runtime.sessionID)]
        }
        if input.lastSessionID != nil, !isSameSession {
            return [
                .stopBoundary(endedAt: runtime.startedAt),
                .startBoundary(startedAt: runtime.startedAt, sessionID: runtime.sessionID),
            ]
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
                boundaryAt: input.now
            )
        }
        return [.noOp]
    case .failed:
        if let terminalDiagnostic {
            return [.surfaceAttention(terminalDiagnostic.reason)]
        }
        return [.surfaceAttention(.writerFailure)]
    }
}

nonisolated func screencastDiagnosticResolution(
    for reason: MobileSegmentScreencastDiagnosticReason,
    hasSegment: Bool
) -> ScreencastDiagnosticResolution {
    switch reason {
    case .storageLow:
        hasSegment ? .noArtifact(reason: reason.rawValue) : .runtimeAttention(reason)
    case .noVideo:
        hasSegment ? .noArtifact(reason: reason.rawValue) : .runtimeAttention(reason)
    case .finalizeTimeout, .writerFailure, .filesystemHandoffFailure:
        hasSegment ? .failedToFinalize(reason: reason.rawValue) : .runtimeAttention(reason)
    case .appGroupUnavailable:
        .runtimeAttention(reason)
    }
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
    var screencastRolloverHandler: (@MainActor @Sendable (MobileSegmentScreencastHandoffRecord) -> Bool)? { get set }
    func startScreencast(at startedAt: Date, sessionID: UUID?) async throws -> MobileSegmentScreencastHandoffRecord
    func stopScreencast(at endedAt: Date) async throws
    func currentScreencastHandoff() -> MobileSegmentScreencastHandoffRecord?
}

extension ScreencastEngineDriving {
    func startScreencast(at startedAt: Date) async throws -> MobileSegmentScreencastHandoffRecord {
        try await self.startScreencast(at: startedAt, sessionID: nil)
    }
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
    func reconcileActiveSegments() async throws
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
    @ObservationIgnored private let segmentUploader: any ScreencastFacetResolving
    @ObservationIgnored private let clock: any ObserverClock
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let rootURLProvider: () throws -> URL
    @ObservationIgnored private let darwin: any ScreencastDarwinNotifying
    @ObservationIgnored private var startingTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?
    @ObservationIgnored private var scenePhase: ScreencastScenePhase = .inactive
    @ObservationIgnored private let sessionLivenessScanner: (@MainActor @Sendable (URL, UUID, Set<UUID>, Date) -> ScreencastLivenessScanResult)?

    private enum Key {
        static let lastProcessedRuntimeRevision = "screencast.lastProcessedRuntimeRevision"
        static let lastProcessedHandoffRevision = "screencast.lastProcessedHandoffRevision"
        static let lastSessionID = "screencast.lastSessionID"
        static let enrolled = "screencast.enrolled"
        static let startingDeadline = "screencast.startingDeadline"
        static let lastAttentionReason = "screencast.lastAttentionReason"
        static let lastAttentionAt = "screencast.lastAttentionAt"
        static let systemEndedAt = "screencast.systemEndedAt"
    }

    var isEnrolled: Bool {
        self.defaults?.bool(forKey: Key.enrolled) ?? false
    }

    var systemEndedAt: Date? {
        self.defaults?.object(forKey: Key.systemEndedAt) as? Date
    }

    private func persistEnrolled() {
        self.defaults?.set(true, forKey: Key.enrolled)
    }

    private func persistSystemEnded(at date: Date) {
        self.defaults?.set(date, forKey: Key.systemEndedAt)
    }

    func clearSystemEnded() {
        self.defaults?.removeObject(forKey: Key.systemEndedAt)
    }

    nonisolated static let startingTimeoutSeconds: TimeInterval = 20
    nonisolated static let systemEndedVisibleWindowSeconds: TimeInterval = 12 * 3600

    convenience init(
        clock: any ObserverClock = SystemObserverClock(),
        defaults: UserDefaults? = UserDefaults(suiteName: AppGroupContainer.identifier),
        rootURLProvider: @escaping () throws -> URL = { try AppGroupContainer.rootURL() },
        darwin: any ScreencastDarwinNotifying = ScreencastDarwinNotificationCenter(),
        sessionLivenessScanner: (@MainActor @Sendable (URL, UUID, Set<UUID>, Date) -> ScreencastLivenessScanResult)? = nil
    ) {
        let uploader = MobileSegmentUploader(clock: clock)
        let engine = MobileSegmentEngine(uploader: uploader, clock: clock)
        self.init(
            engine: engine,
            uploader: uploader,
            clock: clock,
            defaults: defaults,
            rootURLProvider: rootURLProvider,
            darwin: darwin,
            sessionLivenessScanner: sessionLivenessScanner
        )
    }

    init(
        engine: any ScreencastEngineDriving,
        uploader: any ScreencastFacetResolving,
        clock: any ObserverClock = SystemObserverClock(),
        defaults: UserDefaults? = UserDefaults(suiteName: AppGroupContainer.identifier),
        rootURLProvider: @escaping () throws -> URL = { try AppGroupContainer.rootURL() },
        darwin: any ScreencastDarwinNotifying = ScreencastDarwinNotificationCenter(),
        sessionLivenessScanner: (@MainActor @Sendable (URL, UUID, Set<UUID>, Date) -> ScreencastLivenessScanResult)? = nil
    ) {
        self.engine = engine
        self.segmentUploader = uploader
        self.clock = clock
        self.defaults = defaults
        self.rootURLProvider = rootURLProvider
        self.darwin = darwin
        self.sessionLivenessScanner = sessionLivenessScanner
        self.restoreStartingState()
        if self.defaults?.object(forKey: Key.lastSessionID) != nil {
            self.persistEnrolled()
        }
        self.engine.screencastRolloverHandler = { [weak self] handoff in
            self?.publishRolloverHandoff(handoff) ?? false
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
    }

    func prepareForBackground() async {
        guard case .active = self.state else { return }
    }

    func receiveScenePhase(_ phase: ScreencastScenePhase) {
        self.scenePhase = phase
        self.syncWatchdog()
    }

    func syncWatchdog() {
        let shouldRun: Bool = {
            guard self.scenePhase == .active else { return false }
            if case .active = self.state { return true }
            return false
        }()

        if shouldRun {
            guard self.watchdogTask == nil else { return }
            self.watchdogTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    do {
                        try await self.clock.sleep(for: .seconds(MobileSegmentScreencastLivenessPolicy.livenessStaleWindowSeconds))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    guard case .active = self.state, self.scenePhase == .active else { return }

                    let isDead = self.evaluateDeadnessPredicate()
                    if isDead {
                        await self.reconcileScreencast(reason: .livenessWatchdog)
                        return
                    }
                }
            }
        } else {
            self.watchdogTask?.cancel()
            self.watchdogTask = nil
        }
    }

    func evaluateDeadnessPredicate() -> Bool {
        guard let root = try? self.rootURLProvider() else { return false }
        let runtime = self.readRuntime(root: root)
        guard let runtime else { return false }
        let handoff = self.readHandoff(root: root)
        let diagnostic = self.readDiagnostic(root: root, runtime: runtime, handoff: handoff)

        var candidateSegmentIDs: Set<UUID> = []
        if let seg = runtime.currentSegmentID { candidateSegmentIDs.insert(seg) }
        if let seg = handoff?.segmentID { candidateSegmentIDs.insert(seg) }
        if let seg = diagnostic?.segmentID { candidateSegmentIDs.insert(seg) }

        let scanResult = self.performScanActiveLiveness(
            root: root,
            sessionID: runtime.sessionID,
            candidateSegmentIDs: candidateSegmentIDs
        )

        return isDeadScreencastSession(
            runtime: runtime,
            diagnostic: diagnostic,
            scanResult: scanResult,
            engineSources: self.engine.currentScreencastSources,
            managerState: self.state,
            now: self.clock.now()
        )
    }

    func performScanActiveLiveness(
        root: URL,
        sessionID: UUID,
        candidateSegmentIDs: Set<UUID>
    ) -> ScreencastLivenessScanResult {
        let now = self.clock.now()
        if let custom = self.sessionLivenessScanner {
            return custom(root, sessionID, candidateSegmentIDs, now)
        }
        return scanActiveLiveness(root: root, sessionID: sessionID, candidateSegmentIDs: candidateSegmentIDs, now: now)
    }

    func notePickerWillOpen() {
        if case .active = self.state {
            return
        }
        self.beginStarting()
    }

    func beginStarting() {
        self.clearSystemEnded()
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

    func concludeDeadScreencastSession(
        sessionID: UUID,
        runtime: MobileSegmentScreencastRuntimeRecord?,
        handoff: MobileSegmentScreencastHandoffRecord?,
        scanResult: ScreencastLivenessScanResult
    ) async {
        let now = self.clock.now()
        do {
            try await self.engine.stopScreencast(at: now)
        } catch {
            screencastLog.error("screencast dead session stop failed: \(String(describing: error), privacy: .public)")
        }

        switch self.state {
        case .needsAttention, .unavailable:
            break
        case .starting:
            break
        case .off, .active:
            self.state = .off
            // A session that finished on its own terms (an owner's stop, or the system's at lock)
            // just reads off. The ended line is for a session that died without finishing.
            if runtime?.state != .finalized {
                self.persistSystemEnded(at: now)
            }
        }

        let newestLiveness = if case .observed(let newest, _, _) = scanResult { newest } else { nil as Date? }
        let ageStr = newestLiveness.map { "\($0) age=\(now.timeIntervalSince($0))s" } ?? "none"
        let lastSeenStr = runtime.map { "\($0.lastSeenAt)" } ?? "none"
        screencastLog.info("screencast dead session concluded session=\(sessionID.uuidString, privacy: .public) newestLiveness=\(ageStr, privacy: .public) runtimeLastSeen=\(lastSeenStr, privacy: .public)")

        self.persistProcessed(runtime: runtime, handoff: handoff)
        self.syncWatchdog()
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
            self.syncWatchdog()
            return
        }

        do {
            try await self.segmentUploader.reconcileActiveSegments()
        } catch {
            screencastLog.error("screencast active segment reconcile failed: \(String(describing: error), privacy: .public)")
        }

        let runtime = self.readRuntime(root: root)
        if reason == .startingTimeout || reason == .foreground,
           runtime == nil,
           case .starting = self.state {
            self.cancelStarting()
            self.syncWatchdog()
            return
        }

        let handoff = self.readHandoff(root: root)
        let diagnostic = self.readDiagnostic(root: root, runtime: runtime, handoff: handoff)

        let scanResult: ScreencastLivenessScanResult? = {
            guard let currentSessionID = runtime?.sessionID ?? handoff?.sessionID else { return nil }
            var candidateSegmentIDs: Set<UUID> = []
            if let seg = runtime?.currentSegmentID { candidateSegmentIDs.insert(seg) }
            if let seg = handoff?.segmentID { candidateSegmentIDs.insert(seg) }
            if let seg = diagnostic?.segmentID { candidateSegmentIDs.insert(seg) }
            return self.performScanActiveLiveness(
                root: root,
                sessionID: currentSessionID,
                candidateSegmentIDs: candidateSegmentIDs
            )
        }()

        if let currentSessionID = runtime?.sessionID ?? handoff?.sessionID,
           let scanResult {
            if isDeadScreencastSession(
                runtime: runtime,
                diagnostic: diagnostic,
                scanResult: scanResult,
                engineSources: self.engine.currentScreencastSources,
                managerState: self.state,
                now: self.clock.now()
            ) {
                await self.concludeDeadScreencastSession(
                    sessionID: currentSessionID,
                    runtime: runtime,
                    handoff: handoff,
                    scanResult: scanResult
                )
                return
            }
        }

        let filesystem = self.filesystemState(root: root, runtime: runtime, handoff: handoff, diagnostic: diagnostic)
        let manifestResolution = filesystem.segmentID.flatMap {
            self.segmentUploader.screencastResolution(segmentID: $0)
        }
        let lastSessionID = self.defaults?.string(forKey: Key.lastSessionID).flatMap(UUID.init)
        let input = ScreencastReconcileInput(
            runtime: runtime,
            handoff: handoff,
            filesystem: filesystem,
            engineSources: self.engine.currentScreencastSources,
            manifestResolution: manifestResolution,
            lastProcessedRuntimeRevision: self.readRevision(Key.lastProcessedRuntimeRevision),
            lastProcessedHandoffRevision: self.readRevision(Key.lastProcessedHandoffRevision),
            lastSessionID: lastSessionID,
            now: self.clock.now()
        )

        var actions = deriveScreencastReconcileActions(input: input)

        if let scanResult,
           isDeadShapedDisk(
            runtime: runtime,
            diagnostic: diagnostic,
            scanResult: scanResult,
            now: self.clock.now()
        ) {
            actions.removeAll { action in
                if case .startBoundary = action { return true }
                return false
            }
        }

        do {
            try await self.apply(actions: actions, root: root, runtime: runtime, handoff: handoff, diagnostic: diagnostic)
            self.persistProcessed(runtime: runtime, handoff: handoff)
        } catch {
            screencastLog.error("screencast reconcile failed: \(String(describing: error), privacy: .public)")
            self.persistAttention(.finalizeFailed)
            self.state = .needsAttention(.finalizeFailed)
        }
        self.syncWatchdog()
    }
}

extension ScreencastManager {
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

    func readDiagnostic(
        root: URL,
        runtime: MobileSegmentScreencastRuntimeRecord?,
        handoff: MobileSegmentScreencastHandoffRecord?
    ) -> MobileSegmentScreencastDiagnostic? {
        let currentSessionID = runtime?.sessionID ?? handoff?.sessionID
        let currentHandoff = (runtime != nil && handoff?.sessionID != runtime?.sessionID) ? nil : handoff

        var candidateIDs: [UUID] = []
        if let runtimeSegmentID = runtime?.currentSegmentID {
            candidateIDs.append(runtimeSegmentID)
        }
        if let handoffSegmentID = currentHandoff?.segmentID {
            candidateIDs.append(handoffSegmentID)
        }

        for segmentID in candidateIDs {
            let segmentDiagnostic = MobileSegmentScreencastPaths.url(
                root: root,
                relativePath: MobileSegmentScreencastPaths.screenDiagnosticRelativePath(segmentID: segmentID)
            )
            if let diagnostic = try? MobileSegmentScreencastJSONStore.read(MobileSegmentScreencastDiagnostic.self, from: segmentDiagnostic) {
                if currentSessionID == nil || diagnostic.sessionID == currentSessionID {
                    return diagnostic
                }
            }
        }
        guard let sessionID = currentSessionID else { return nil }
        let runtimeDiagnostic = MobileSegmentScreencastPaths.url(
            root: root,
            relativePath: MobileSegmentScreencastPaths.runtimeDiagnosticRelativePath(sessionID: sessionID)
        )
        if let diagnostic = try? MobileSegmentScreencastJSONStore.read(MobileSegmentScreencastDiagnostic.self, from: runtimeDiagnostic) {
            if diagnostic.sessionID == sessionID {
                return diagnostic
            }
        }
        return nil
    }

    func filesystemState(
        root: URL,
        runtime: MobileSegmentScreencastRuntimeRecord?,
        handoff: MobileSegmentScreencastHandoffRecord?,
        diagnostic: MobileSegmentScreencastDiagnostic?
    ) -> ScreencastFilesystemState {
        let currentSessionID = runtime?.sessionID ?? handoff?.sessionID
        let currentHandoff = (runtime != nil && handoff?.sessionID != runtime?.sessionID) ? nil : handoff
        let currentDiagnostic = (currentSessionID != nil && diagnostic?.sessionID != currentSessionID) ? nil : diagnostic

        let segmentID = currentDiagnostic?.segmentID
            ?? runtime?.currentSegmentID
            ?? currentHandoff?.segmentID
        guard let segmentID else {
            return ScreencastFilesystemState(
                segmentID: nil,
                screenExists: false,
                partExists: false,
                hasFreshLiveness: false,
                terminalDiagnostic: currentDiagnostic
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
                && (currentSessionID == nil || $0.sessionID == currentSessionID)
                && MobileSegmentScreencastLivenessPolicy.isFresh(lastSeenAt: $0.lastSeenAt, now: self.clock.now())
        } ?? false
        return ScreencastFilesystemState(
            segmentID: segmentID,
            screenExists: FileManager.default.fileExists(atPath: screenURL.path),
            partExists: FileManager.default.fileExists(atPath: partURL.path),
            hasFreshLiveness: hasFreshLiveness,
            terminalDiagnostic: currentDiagnostic
        )
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
                let handoff = try await self.engine.startScreencast(at: startedAt, sessionID: sessionID)
                let published = self.handoff(handoff, sessionID: sessionID, now: self.clock.now())
                try self.writeHandoff(published, root: root)
                self.darwin.postChanged()
                currentHandoff = published
                self.defaults?.set(sessionID.uuidString, forKey: Key.lastSessionID)
                self.persistEnrolled()
                self.clearStarting()
                self.clearSystemEnded()
                self.state = .active(sessionID: sessionID, segmentID: published.segmentID, startedAt: published.startedAt)
            case .recordFinalized(let segmentID):
                let artifactURL = MobileSegmentScreencastPaths.url(
                    root: root,
                    relativePath: currentHandoff?.screenFinalRelativePath ?? MobileSegmentScreencastPaths.screenRelativePath(segmentID: segmentID)
                )
                let startedAt = currentHandoff?.startedAt ?? runtime?.startedAt ?? self.clock.now()
                let endedAt = diagnostic?.endedAt ?? runtime?.lastSeenAt ?? self.clock.now()
                try self.segmentUploader.recordScreencastFinalized(
                    segmentID: segmentID,
                    artifactURL: artifactURL,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    durationS: min(endedAt.timeIntervalSince(startedAt), MobileSegmentDuration.rotationCeiling)
                )
            case .recordNoArtifact(let segmentID, let reason):
                let startedAt = currentHandoff?.startedAt ?? runtime?.startedAt ?? self.clock.now()
                let endedAt = diagnostic?.endedAt ?? runtime?.lastSeenAt ?? self.clock.now()
                try self.segmentUploader.recordScreencastNoArtifact(
                    segmentID: segmentID,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    durationS: endedAt.timeIntervalSince(startedAt),
                    reason: reason
                )
            case .recordFailed(let segmentID, let reason):
                let startedAt = currentHandoff?.startedAt ?? runtime?.startedAt ?? self.clock.now()
                let endedAt = diagnostic?.endedAt ?? runtime?.lastSeenAt ?? self.clock.now()
                try self.segmentUploader.recordScreencastFinalizeFailed(
                    segmentID: segmentID,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    reason: reason
                )
            case .finalizeSegment(let segmentID, let endedAt):
                await self.segmentUploader.finalizeActiveSegment(segmentID: segmentID, endedAt: endedAt)
            case .stopBoundary(let endedAt):
                try await self.engine.stopScreencast(at: endedAt)
                if case .needsAttention = self.state {
                    break
                }
                self.clearStarting()
                self.state = .off
            case .keepLivePart(let segmentID):
                guard let runtime else { break }
                self.persistEnrolled()
                self.clearStarting()
                self.clearSystemEnded()
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

    @discardableResult
    func publishRolloverHandoff(_ handoff: MobileSegmentScreencastHandoffRecord) -> Bool {
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
            let onDisk = self.readHandoff(root: root)
            guard let onDisk, onDisk.revision == published.revision else {
                return false
            }
            self.darwin.postChanged()
            self.persistEnrolled()
            self.clearSystemEnded()
            self.state = .active(sessionID: sessionID, segmentID: published.segmentID, startedAt: published.startedAt)
            self.syncWatchdog()
            return true
        } catch {
            screencastLog.error("screencast rollover handoff publish failed: \(String(describing: error), privacy: .public)")
            return false
        }
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
            scheduleAnchorMs: record.scheduleAnchorMs,
            schedulePeriodSeconds: record.schedulePeriodSeconds,
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
        if let handoff, (runtime == nil || handoff.sessionID == runtime?.sessionID) {
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
    boundaryAt: Date
) -> [ScreencastReconcileAction] {
    if engineSources.contains(.screencast) {
        return [primary, .stopBoundary(endedAt: boundaryAt)]
    }
    return [primary]
}

private nonisolated func screencastAttention(
    for reason: MobileSegmentScreencastDiagnosticReason
) -> ScreencastAttention {
    switch reason {
    case .storageLow:
        .storageLow
    case .noVideo:
        .noVideo
    case .appGroupUnavailable:
        .appGroupUnavailable
    case .finalizeTimeout, .writerFailure, .filesystemHandoffFailure:
        .finalizeFailed
    }
}
