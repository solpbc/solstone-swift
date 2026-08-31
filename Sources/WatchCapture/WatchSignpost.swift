// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

nonisolated enum RelayTrigger: String, CaseIterable, Sendable {
    case launchReconciliation
    case segmentFinalization
    case connectivityActivation
    case connectivityReachability
    case durableACK
    case testDirect
}

nonisolated enum RelayResult: String, CaseIterable, Sendable {
    case completed
    case partial
    case failed
}

nonisolated enum RelayActivation: String, CaseIterable, Sendable {
    case activated
    case notActivated
}

nonisolated enum WorkloadBand: String, CaseIterable, Sendable {
    case unknown
    case notSampled
    case empty
    case small
    case medium
    case large

    static func band(for count: Int?) -> WorkloadBand {
        guard let count else { return .unknown }
        switch count {
        case ..<0:
            return .unknown
        case 0:
            return .empty
        case 1...25:
            return .small
        case 26...200:
            return .medium
        default:
            return .large
        }
    }
}

nonisolated enum WatchSignpostBoundary: CaseIterable, Sendable {
    case bootstrap
    case complicationSnapshot
    case reconciliation
    case sessionRecord
    case sessionHistory
    case manifestScan
    case relayCountRefresh
    case diagnosticsCollection
    case statusPublication
    case relayHandoff
    case applicationContextPrimary
    case applicationContextFallback
    case relayDrain
    case relayCleanupScan
    case relayQueueReconciliation
    case relaySegmentTransition
    case relayBundleWrite
    case relayAttemptPersistence
    case relayDiagnosticsPersistence
    case relayTransferEnqueue
    case diagnosticsManifestFacts
    case diagnosticsPerItemFacts
    case diagnosticsChangedWitnessRevalidation
    case diagnosticsHistorySummaryRead
    case diagnosticsPayloadAssembly
    case diagnosticsFirstEncode
    case diagnosticsCompactionEncode
    case storageActorFileOperation
    case storageActorManifestWrite
    case capturePreparation
    case captureFinalization
    case locationLogAppend
    case locationLogReconciliation

    var name: StaticString {
        switch self {
        case .bootstrap:
            "watch.bootstrap"
        case .complicationSnapshot:
            "watch.complication_snapshot"
        case .reconciliation:
            "watch.reconciliation"
        case .sessionRecord:
            "watch.session_record"
        case .sessionHistory:
            "watch.session_history"
        case .manifestScan:
            "watch.manifest_scan"
        case .relayCountRefresh:
            "watch.relay_count_refresh"
        case .diagnosticsCollection:
            "watch.diagnostics_collection"
        case .statusPublication:
            "watch.status_publication"
        case .relayHandoff:
            "watch.relay_handoff"
        case .applicationContextPrimary:
            "watch.application_context_primary"
        case .applicationContextFallback:
            "watch.application_context_fallback"
        case .relayDrain:
            "watch.relay_drain"
        case .relayCleanupScan:
            "watch.relay_cleanup_scan"
        case .relayQueueReconciliation:
            "watch.relay_queue_reconciliation"
        case .relaySegmentTransition:
            "watch.relay_segment_transition"
        case .relayBundleWrite:
            "watch.relay_bundle_write"
        case .relayAttemptPersistence:
            "watch.relay_attempt_persistence"
        case .relayDiagnosticsPersistence:
            "watch.relay_diagnostics_persistence"
        case .relayTransferEnqueue:
            "watch.relay_transfer_enqueue"
        case .diagnosticsManifestFacts:
            "watch.diagnostics_manifest_facts"
        case .diagnosticsPerItemFacts:
            "watch.diagnostics_per_item_facts"
        case .diagnosticsChangedWitnessRevalidation:
            "watch.diagnostics_changed_witness_revalidation"
        case .diagnosticsHistorySummaryRead:
            "watch.diagnostics_history_summary_read"
        case .diagnosticsPayloadAssembly:
            "watch.diagnostics_payload_assembly"
        case .diagnosticsFirstEncode:
            "watch.diagnostics_first_encode"
        case .diagnosticsCompactionEncode:
            "watch.diagnostics_compaction_encode"
        case .storageActorFileOperation:
            "watch.storage_actor_file_operation"
        case .storageActorManifestWrite:
            "watch.storage_actor_manifest_write"
        case .capturePreparation:
            "watch.capture_preparation"
        case .captureFinalization:
            "watch.capture_finalization"
        case .locationLogAppend:
            "watch.location_log_append"
        case .locationLogReconciliation:
            "watch.location_log_reconciliation"
        }
    }
}

nonisolated struct WatchSignpostFields: Equatable, Sendable {
    var trigger: RelayTrigger?
    var result: RelayResult?
    var activation: RelayActivation?
    var entryWorkload: WorkloadBand?
    var refreshedWorkload: WorkloadBand?
    var transferCandidateCount: Int?
    var failureCount: Int?
    var usedFallback: Bool?
    var retainedObservationCount: Int?
    var encodedByteCount: Int?

    init(
        trigger: RelayTrigger? = nil,
        result: RelayResult? = nil,
        activation: RelayActivation? = nil,
        entryWorkload: WorkloadBand? = nil,
        refreshedWorkload: WorkloadBand? = nil,
        transferCandidateCount: Int? = nil,
        failureCount: Int? = nil,
        usedFallback: Bool? = nil,
        retainedObservationCount: Int? = nil,
        encodedByteCount: Int? = nil
    ) {
        self.trigger = trigger
        self.result = result
        self.activation = activation
        self.entryWorkload = entryWorkload
        self.refreshedWorkload = refreshedWorkload
        self.transferCandidateCount = transferCandidateCount
        self.failureCount = failureCount
        self.usedFallback = usedFallback
        self.retainedObservationCount = retainedObservationCount
        self.encodedByteCount = encodedByteCount
    }
}

@MainActor
final class WatchSignpostInvocation {
    let boundary: WatchSignpostBoundary

    init(boundary: WatchSignpostBoundary) {
        self.boundary = boundary
    }
}

@MainActor
protocol WatchSignpostIntervalSink: AnyObject {
    var isEnabled: Bool { get }

    func begin(
        _ boundary: WatchSignpostBoundary,
        fields: WatchSignpostFields
    ) -> WatchSignpostInvocation

    func end(
        _ invocation: WatchSignpostInvocation,
        fields: WatchSignpostFields
    )
}

@MainActor
protocol WatchSignposting: AnyObject {
    func begin(
        _ boundary: WatchSignpostBoundary,
        fields: @escaping @MainActor () -> WatchSignpostFields
    ) -> WatchSignpostInvocation?

    func end(
        _ invocation: WatchSignpostInvocation?,
        fields: WatchSignpostFields
    )
}

@MainActor
extension WatchSignposting {
    func begin(_ boundary: WatchSignpostBoundary) -> WatchSignpostInvocation? {
        self.begin(boundary) { WatchSignpostFields() }
    }

    func begin(
        _ boundary: WatchSignpostBoundary,
        fields: @autoclosure @escaping @MainActor () -> WatchSignpostFields
    ) -> WatchSignpostInvocation? {
        self.begin(boundary, fields: fields)
    }

    func end(_ invocation: WatchSignpostInvocation?) {
        self.end(invocation, fields: WatchSignpostFields())
    }
}

@MainActor
final class WatchSignposter: WatchSignposting {
    private let sink: any WatchSignpostIntervalSink

    init(sink: any WatchSignpostIntervalSink) {
        self.sink = sink
    }

    func begin(
        _ boundary: WatchSignpostBoundary,
        fields: @escaping @MainActor () -> WatchSignpostFields
    ) -> WatchSignpostInvocation? {
        guard self.sink.isEnabled else { return nil }
        return self.sink.begin(boundary, fields: fields())
    }

    func end(
        _ invocation: WatchSignpostInvocation?,
        fields: WatchSignpostFields = WatchSignpostFields()
    ) {
        guard let invocation else { return }
        self.sink.end(invocation, fields: fields)
    }
}

@MainActor
enum WatchSignpost {
    private static let liveSignposter = WatchSignposter(sink: LiveWatchSignpostIntervalSink())

    static var live: any WatchSignposting { Self.liveSignposter }

    static func begin(
        _ boundary: WatchSignpostBoundary,
        fields: WatchSignpostFields = WatchSignpostFields()
    ) -> WatchSignpostInvocation? {
        Self.liveSignposter.begin(boundary) { fields }
    }

    static func end(
        _ invocation: WatchSignpostInvocation?,
        fields: WatchSignpostFields = WatchSignpostFields()
    ) {
        Self.liveSignposter.end(invocation, fields: fields)
    }
}

@MainActor
final class LiveWatchSignpostIntervalSink: WatchSignpostIntervalSink {
    private let signposter = OSSignposter(logHandle: OSLog(subsystem: "app.solstone.swift", category: "watch-signpost"))
    private var states: [ObjectIdentifier: OSSignpostIntervalState] = [:]

    var isEnabled: Bool { self.signposter.isEnabled }

    func begin(
        _ boundary: WatchSignpostBoundary,
        fields: WatchSignpostFields
    ) -> WatchSignpostInvocation {
        let invocation = WatchSignpostInvocation(boundary: boundary)
        let state = self.signposter.beginInterval(boundary.name, "\(self.description(fields), privacy: .public)")
        self.states[ObjectIdentifier(invocation)] = state
        return invocation
    }

    func end(
        _ invocation: WatchSignpostInvocation,
        fields: WatchSignpostFields
    ) {
        guard let state = self.states.removeValue(forKey: ObjectIdentifier(invocation)) else { return }
        self.signposter.endInterval(invocation.boundary.name, state, "\(self.description(fields), privacy: .public)")
    }

    private func description(_ fields: WatchSignpostFields) -> String {
        var parts: [String] = []
        if let trigger = fields.trigger { parts.append("trigger=\(trigger.rawValue)") }
        if let result = fields.result { parts.append("result=\(result.rawValue)") }
        if let activation = fields.activation { parts.append("activation=\(activation.rawValue)") }
        if let entryWorkload = fields.entryWorkload { parts.append("entryWorkload=\(entryWorkload.rawValue)") }
        if let refreshedWorkload = fields.refreshedWorkload { parts.append("refreshedWorkload=\(refreshedWorkload.rawValue)") }
        if let transferCandidateCount = fields.transferCandidateCount { parts.append("transferCandidateCount=\(transferCandidateCount)") }
        if let failureCount = fields.failureCount { parts.append("failureCount=\(failureCount)") }
        if let usedFallback = fields.usedFallback { parts.append("usedFallback=\(usedFallback)") }
        if let retainedObservationCount = fields.retainedObservationCount { parts.append("retainedObservationCount=\(retainedObservationCount)") }
        if let encodedByteCount = fields.encodedByteCount { parts.append("encodedByteCount=\(encodedByteCount)") }
        return parts.joined(separator: " ")
    }
}

@MainActor
final class NoOpWatchSignpostIntervalSink: WatchSignpostIntervalSink {
    let isEnabled = false

    func begin(
        _ boundary: WatchSignpostBoundary,
        fields: WatchSignpostFields
    ) -> WatchSignpostInvocation {
        fatalError("disabled watch signpost sink must not begin")
    }

    func end(
        _ invocation: WatchSignpostInvocation,
        fields: WatchSignpostFields
    ) {}
}

/// Actor-local signposting for serialized watch storage operations. This is deliberately
/// separate from `WatchSignposter`: storage work never needs a MainActor instrumentation hop.
nonisolated struct WatchStorageSignpostInvocation: Sendable {
    let boundary: WatchSignpostBoundary
    let state: OSSignpostIntervalState?
}

nonisolated protocol WatchStorageSignpostIntervalSink: Sendable {
    var isEnabled: Bool { get }

    func begin(_ boundary: WatchSignpostBoundary) -> WatchStorageSignpostInvocation
    func end(_ invocation: WatchStorageSignpostInvocation)
}

nonisolated struct WatchStorageSignposter: Sendable {
    private let sink: any WatchStorageSignpostIntervalSink

    init() {
        self.sink = LiveWatchStorageSignpostIntervalSink()
    }

    init(sink: any WatchStorageSignpostIntervalSink) {
        self.sink = sink
    }

    func begin(_ boundary: WatchSignpostBoundary) -> WatchStorageSignpostInvocation? {
        // Keep the disabled path allocation-free: no interval state or operation fields exist
        // until the OS signposter (or an injected test sink) has enabled instrumentation.
        guard self.sink.isEnabled else { return nil }
        return self.sink.begin(boundary)
    }

    func end(_ invocation: WatchStorageSignpostInvocation?) {
        guard let invocation else { return }
        self.sink.end(invocation)
    }
}

nonisolated private struct LiveWatchStorageSignpostIntervalSink: WatchStorageSignpostIntervalSink {
    private let signposter = OSSignposter(
        logHandle: OSLog(subsystem: "app.solstone.swift", category: "watch-storage-signpost")
    )

    var isEnabled: Bool { self.signposter.isEnabled }

    func begin(_ boundary: WatchSignpostBoundary) -> WatchStorageSignpostInvocation {
        WatchStorageSignpostInvocation(
            boundary: boundary,
            state: self.signposter.beginInterval(boundary.name)
        )
    }

    func end(_ invocation: WatchStorageSignpostInvocation) {
        guard let state = invocation.state else { return }
        self.signposter.endInterval(invocation.boundary.name, state)
    }
}
