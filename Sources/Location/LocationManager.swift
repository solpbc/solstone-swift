// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

private let locationLog = Logger(subsystem: "app.solstone.swift", category: "location")

nonisolated struct LocationSession: Equatable, Sendable {
    let sessionID: UUID
    let startedAt: Date
    let currentSegmentIndex: Int
    let elapsed: TimeInterval
}

nonisolated enum LocationError: Equatable, Sendable {
    case unavailable(reason: String)
    case capabilityInsufficient

    var message: String {
        switch self {
        case .unavailable(let reason):
            reason
        case .capabilityInsufficient:
            LocationVocabulary.downgradeBody(tierLabel: LocationTier.defaultTier.label)
        }
    }
}

nonisolated enum LocationState: Equatable, Sendable {
    case idle
    case starting
    case active(LocationSession)
    case stopping
    case error(LocationError)
}

nonisolated enum LocationRecovery: Sendable, Equatable {
    case openSettings
    case matchToAllowed(suggestedTier: LocationTier)
}

@MainActor
@Observable
final class LocationManager {
    var state: LocationState = .idle
    var tier: LocationTier

    @ObservationIgnored private let provider: any LocationProviding
    @ObservationIgnored private let uploader: any LocationUploading
    @ObservationIgnored private let clock: any ObserverClock
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var segmentationTask: Task<Void, Never>?
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var currentSessionID: UUID?
    @ObservationIgnored private var sessionStartedAt: Date?
    @ObservationIgnored private var segmentStartedAt: Date?
    @ObservationIgnored private var currentSegmentIndex = 0
    @ObservationIgnored private var segmentFixes: [LocationFix] = []
    @ObservationIgnored private var segmentVisits: [LocationVisit] = []
    @ObservationIgnored private var segmentHasGap = false
    @ObservationIgnored private var hasRequestedAlwaysForCurrentStart = false
    private var lastCapability: LocationCapability

    private enum Key {
        static let enabled = "location.enabled"
        static let paused = "location.paused"
        static let tier = "location.tier"
    }

    init(
        provider: any LocationProviding = LiveLocationProvider(),
        uploader: any LocationUploading = LocationUploader(),
        clock: any ObserverClock = SystemObserverClock(),
        defaults: UserDefaults? = UserDefaults(suiteName: AppGroupContainer.identifier)
    ) {
        self.provider = provider
        self.uploader = uploader
        self.clock = clock
        self.defaults = defaults
        self.tier = Self.readTier(defaults: defaults)
        self.lastCapability = provider.currentCapability()
        self.provider.onAuthorizationChanged = { [weak self] capability in
            Task { @MainActor [weak self] in
                await self?.handleAuthorizationChanged(capability)
            }
        }
        self.provider.onFix = { [weak self] fix in
            Task { @MainActor [weak self] in
                self?.handleFix(fix)
            }
        }
        self.provider.onVisit = { [weak self] visit in
            Task { @MainActor [weak self] in
                self?.handleVisit(visit)
            }
        }
        self.provider.onGap = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.markGap()
            }
        }
    }

    var sourceState: SourceState {
        self.sourcePresentation.state
    }

    var sourceAttention: SourceAttention? {
        self.sourcePresentation.attention
    }

    var sharingGrant: LocationCapability {
        self.lastCapability
    }

    var recoveryActions: [LocationRecovery] {
        self.recoveryActions(for: self.effectiveCapability())
    }

    func start(tier: LocationTier) async {
        switch self.state {
        case .idle, .error:
            break
        case .starting, .active, .stopping:
            locationLog.info("location: start skipped while active")
            return
        }

        self.persistTier(tier)
        self.paused = false
        self.state = .starting
        self.hasRequestedAlwaysForCurrentStart = false
        await self.advanceStartFlow(with: self.provider.currentCapability())
    }

    func stop() async {
        switch self.state {
        case .idle:
            return
        case .starting, .active, .error:
            self.state = .stopping
        case .stopping:
            return
        }

        self.cancelTasks()
        await self.flushSegmentIfNeeded()
        await self.provider.stopObservation()
        await self.provider.endBackgroundSustain()
        self.resetRuntime()
        self.state = .idle
    }

    func stopForDelete() async {
        self.paused = false
        self.persistEnabled(false)
        self.persistPaused(false)
        await self.stop()
    }

    func pause() async {
        self.paused = true
        self.persistPaused(true)
        await self.stop()
    }

    func resume() async {
        self.paused = false
        self.persistPaused(false)
        await self.start(tier: self.tier)
    }

    func resumeIfEnabled() async {
        switch self.state {
        case .idle, .error:
            break
        case .starting, .active, .stopping:
            return
        }

        guard Self.readEnabled(defaults: self.defaults) else {
            self.paused = false
            self.state = .idle
            return
        }

        guard !Self.readPaused(defaults: self.defaults) else {
            self.paused = true
            self.state = .idle
            return
        }

        self.paused = false
        let capability = self.effectiveCapability()
        guard self.tier.isSatisfied(by: capability) else {
            self.state = .error(.capabilityInsufficient)
            return
        }
        await self.activateSessionIfAllowed(capability: capability)
    }

    func isAuthorizationSufficient(for tier: LocationTier) -> Bool {
        tier.isSatisfied(by: self.effectiveCapability())
    }

    func changeTier(_ tier: LocationTier) async {
        self.persistTier(tier)
        guard case .active = self.state else { return }
        if tier.isSatisfied(by: self.effectiveCapability()) {
            await self.restartObservationForCurrentTier()
        } else {
            self.markGap()
        }
    }

    func matchToAllowed() async {
        guard let suggested = LocationTier.matchToAllowed(for: self.effectiveCapability()) else { return }
        await self.changeTier(suggested)
        switch self.state {
        case .idle, .error, .starting:
            await self.advanceStartFlow(with: self.provider.currentCapability())
        case .active, .stopping:
            break
        }
    }
}

private extension LocationManager {
    var sourcePresentation: (state: SourceState, attention: SourceAttention?) {
        switch self.state {
        case .idle:
            return self.paused ? (.paused, nil) : (.off, nil)
        case .starting:
            return (.enrolling, nil)
        case .active:
            return locationSourceState(effective: self.effectiveCapability(), tier: self.tier, paused: self.paused)
        case .stopping:
            return (.active, nil)
        case .error(let error):
            let mapped = locationSourceState(effective: self.effectiveCapability(), tier: self.tier, paused: self.paused)
            return (.needsAttention, mapped.1 ?? SourceAttention(message: error.message))
        }
    }

    static func readTier(defaults: UserDefaults?) -> LocationTier {
        guard let rawValue = defaults?.string(forKey: Key.tier),
              let tier = LocationTier(rawValue: rawValue)
        else {
            return .defaultTier
        }
        return tier
    }

    static func readEnabled(defaults: UserDefaults?) -> Bool {
        defaults?.bool(forKey: Key.enabled) ?? false
    }

    static func readPaused(defaults: UserDefaults?) -> Bool {
        defaults?.bool(forKey: Key.paused) ?? false
    }

    func persistTier(_ tier: LocationTier) {
        self.tier = tier
        self.defaults?.set(tier.rawValue, forKey: Key.tier)
    }

    func persistEnabled(_ enabled: Bool) {
        self.defaults?.set(enabled, forKey: Key.enabled)
    }

    func persistPaused(_ paused: Bool) {
        self.defaults?.set(paused, forKey: Key.paused)
    }

    func effectiveCapability() -> LocationCapability {
        self.provider.currentCapability()
    }

    func handleAuthorizationChanged(_ capability: LocationCapability) async {
        self.lastCapability = capability

        if case .active = self.state, !self.tier.isSatisfied(by: self.effectiveCapability()) {
            self.markGap()
        }

        switch self.state {
        case .starting:
            await self.advanceStartFlow(with: capability)
        case .error:
            if self.tier.isSatisfied(by: capability) {
                await self.activateSessionIfAllowed(capability: capability)
            }
        case .idle, .active, .stopping:
            break
        }
    }

    func advanceStartFlow(with capability: LocationCapability) async {
        switch capability {
        case .notDetermined:
            self.provider.requestWhenInUseAuthorization()
        case .servicesDisabled, .denied, .restricted:
            self.state = .error(.capabilityInsufficient)
        case .whenInUse:
            switch self.tier.requiredAuthorization {
            case .whenInUse:
                await self.activateSessionIfAllowed(capability: capability)
            case .always:
                if self.hasRequestedAlwaysForCurrentStart {
                    self.state = .error(.capabilityInsufficient)
                } else {
                    self.hasRequestedAlwaysForCurrentStart = true
                    self.provider.requestAlwaysAuthorization()
                }
            }
        case .always:
            await self.activateSessionIfAllowed(capability: capability)
        }
    }

    func activateSessionIfAllowed(capability: LocationCapability) async {
        guard self.tier.isSatisfied(by: capability) else {
            self.state = .error(.capabilityInsufficient)
            return
        }

        do {
            if self.tier.requiredAuthorization == .always {
                await self.provider.beginBackgroundSustain()
            }
            try await self.provider.startObservation(modes: self.tier.modes)
            let sessionID = UUID()
            let startedAt = self.clock.now()
            self.currentSessionID = sessionID
            self.sessionStartedAt = startedAt
            self.segmentStartedAt = startedAt
            self.currentSegmentIndex = 0
            self.segmentFixes = []
            self.segmentVisits = []
            self.segmentHasGap = false
            self.state = .active(LocationSession(
                sessionID: sessionID,
                startedAt: startedAt,
                currentSegmentIndex: 0,
                elapsed: 0
            ))
            self.persistEnabled(true)
            self.persistPaused(false)
            self.startSegmentationTask()
        } catch {
            self.state = .error(.unavailable(reason: String(describing: error)))
        }
    }

    func restartObservationForCurrentTier() async {
        await self.provider.stopObservation()
        if self.tier.requiredAuthorization == .always {
            await self.provider.beginBackgroundSustain()
        } else {
            await self.provider.endBackgroundSustain()
        }
        do {
            try await self.provider.startObservation(modes: self.tier.modes)
        } catch {
            self.state = .error(.unavailable(reason: String(describing: error)))
        }
    }

    func startSegmentationTask() {
        self.segmentationTask?.cancel()
        self.segmentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await self.clock.sleep(for: .seconds(300))
                } catch {
                    return
                }
                guard case .active = self.state else { return }
                await self.enqueueCurrentSegment()
            }
        }
    }

    func enqueueCurrentSegment() async {
        guard let segmentStartedAt else { return }

        let now = self.clock.now()
        if self.segmentFixes.isEmpty && self.segmentVisits.isEmpty && !self.segmentHasGap {
            locationLog.notice("location: empty segment skipped")
            self.segmentStartedAt = now
            return
        }

        let batch = LocationSegmentBatch(
            tier: self.tier,
            accuracy: self.currentAccuracy(),
            segmentStart: segmentStartedAt,
            coveredSeconds: max(0, Int(now.timeIntervalSince(segmentStartedAt))),
            fixes: self.segmentFixes,
            visits: self.segmentVisits,
            gap: self.segmentHasGap
        )
        await self.uploader.enqueue(batch)
        self.currentSegmentIndex += 1
        self.segmentStartedAt = now
        self.segmentFixes = []
        self.segmentVisits = []
        self.segmentHasGap = false
        await self.updateActiveSessionElapsed(now: now)
    }

    func flushSegmentIfNeeded() async {
        // enqueueCurrentSegment self-guards nil and empty segments.
        await self.enqueueCurrentSegment()
    }

    func updateActiveSessionElapsed(now: Date) async {
        guard case .active(let session) = self.state else { return }
        self.state = .active(LocationSession(
            sessionID: session.sessionID,
            startedAt: session.startedAt,
            currentSegmentIndex: self.currentSegmentIndex,
            elapsed: now.timeIntervalSince(session.startedAt)
        ))
    }

    func handleFix(_ fix: LocationFix) {
        guard case .active = self.state else { return }
        self.segmentFixes.append(fix)
    }

    func handleVisit(_ visit: LocationVisit) {
        guard case .active = self.state else { return }
        self.segmentVisits.append(visit)
    }

    func markGap() {
        if case .active = self.state {
            self.segmentHasGap = true
        }
    }

    func recoveryActions(for capability: LocationCapability) -> [LocationRecovery] {
        if self.paused {
            return []
        }
        if self.tier.isSatisfied(by: capability) {
            return []
        }

        switch capability {
        case .restricted:
            return []
        case .denied, .servicesDisabled:
            return [.openSettings]
        case .notDetermined, .whenInUse, .always:
            if let suggested = LocationTier.matchToAllowed(for: capability) {
                return [.openSettings, .matchToAllowed(suggestedTier: suggested)]
            }
            return [.openSettings]
        }
    }

    func currentAccuracy() -> LocationAccuracy {
        switch self.provider.currentCapability() {
        case .whenInUse(let accuracy), .always(let accuracy):
            accuracy
        case .notDetermined, .servicesDisabled, .denied, .restricted:
            .reduced
        }
    }

    func cancelTasks() {
        self.segmentationTask?.cancel()
        self.segmentationTask = nil
    }

    func resetRuntime() {
        self.currentSessionID = nil
        self.sessionStartedAt = nil
        self.segmentStartedAt = nil
        self.currentSegmentIndex = 0
        self.segmentFixes = []
        self.segmentVisits = []
        self.segmentHasGap = false
        self.hasRequestedAlwaysForCurrentStart = false
    }
}
