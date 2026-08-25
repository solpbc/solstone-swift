// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import WatchConnectivity

nonisolated struct WatchPhoneSessionHistoryInput: Codable, Equatable, Sendable {
    let entries: [WatchCaptureSessionHistoryEntry]
    let retainedCount: Int
    let retentionDays: Int
    let droppedAsOlderThanRetentionWindow: Int
    let sessionsNotReceived: DiagnosticAvailability<Int>
}

nonisolated struct WatchPipelineInput: Sendable {
    let now: Date
    let watchStatus: WatchStatusContext?
    let lifetimeReceived: Int
    let lifetimeHanded: Int
    let nonTerminalCount: Int
    let lastHandedAt: Date?
    let oldestNonTerminalReceivedAt: Date?
    let lastLedgerError: String?
    let pendingCount: Int
    let failedCount: Int
    let inFlightCount: Int
    let lastUploadAt: Date?
    let lastUploadError: String?
    let lastReceivedAt: Date?
    let lastStagingError: String?
    let isPaired: Bool
    let isWatchAppInstalled: Bool
    let activationState: WCSessionActivationState
    let isReachable: Bool
    let isJournalReachable: Bool
    let watchDiagnostics: WatchRelayDiagnosticsEnvelopeResult
    let iphoneAppMarketingVersion: DiagnosticAvailability<String>
    let iphoneAppBuild: DiagnosticAvailability<String>
    let iOSVersion: DiagnosticAvailability<String>
    let iphoneBatteryLevel: DiagnosticAvailability<Double>
    let iphoneBatteryState: DiagnosticAvailability<String>
    let iphoneLowPowerModeEnabled: DiagnosticAvailability<Bool>
    let iphoneThermalState: DiagnosticAvailability<String>
    let phoneLedgerSnapshot: DiagnosticAvailability<WatchSegmentLedgerReadSnapshot>
    let iphoneACKQueueSnapshot: WatchRelayACKQueueSnapshot
    let phoneSessionHistory: DiagnosticAvailability<WatchPhoneSessionHistoryInput>

    init(
        now: Date,
        watchStatus: WatchStatusContext?,
        lifetimeReceived: Int,
        lifetimeHanded: Int,
        nonTerminalCount: Int,
        lastHandedAt: Date?,
        oldestNonTerminalReceivedAt: Date?,
        lastLedgerError: String?,
        pendingCount: Int,
        failedCount: Int,
        inFlightCount: Int,
        lastUploadAt: Date?,
        lastUploadError: String?,
        lastReceivedAt: Date?,
        lastStagingError: String?,
        isPaired: Bool,
        isWatchAppInstalled: Bool,
        activationState: WCSessionActivationState,
        isReachable: Bool,
        isJournalReachable: Bool,
        watchDiagnostics: WatchRelayDiagnosticsEnvelopeResult = .absent,
        iphoneAppMarketingVersion: DiagnosticAvailability<String> = .unavailable(reason: "not provided"),
        iphoneAppBuild: DiagnosticAvailability<String> = .unavailable(reason: "not provided"),
        iOSVersion: DiagnosticAvailability<String> = .unavailable(reason: "not provided"),
        iphoneBatteryLevel: DiagnosticAvailability<Double> = .unavailable(reason: "not provided"),
        iphoneBatteryState: DiagnosticAvailability<String> = .unavailable(reason: "not provided"),
        iphoneLowPowerModeEnabled: DiagnosticAvailability<Bool> = .unavailable(reason: "not provided"),
        iphoneThermalState: DiagnosticAvailability<String> = .unavailable(reason: "not provided"),
        phoneLedgerSnapshot: DiagnosticAvailability<WatchSegmentLedgerReadSnapshot> = .unavailable(reason: "not provided"),
        iphoneACKQueueSnapshot: WatchRelayACKQueueSnapshot = WatchRelayACKQueueSnapshot(),
        phoneSessionHistory: DiagnosticAvailability<WatchPhoneSessionHistoryInput>
    ) {
        self.now = now
        self.watchStatus = watchStatus
        self.lifetimeReceived = lifetimeReceived
        self.lifetimeHanded = lifetimeHanded
        self.nonTerminalCount = nonTerminalCount
        self.lastHandedAt = lastHandedAt
        self.oldestNonTerminalReceivedAt = oldestNonTerminalReceivedAt
        self.lastLedgerError = lastLedgerError
        self.pendingCount = pendingCount
        self.failedCount = failedCount
        self.inFlightCount = inFlightCount
        self.lastUploadAt = lastUploadAt
        self.lastUploadError = lastUploadError
        self.lastReceivedAt = lastReceivedAt
        self.lastStagingError = lastStagingError
        self.isPaired = isPaired
        self.isWatchAppInstalled = isWatchAppInstalled
        self.activationState = activationState
        self.isReachable = isReachable
        self.isJournalReachable = isJournalReachable
        self.watchDiagnostics = watchDiagnostics
        self.iphoneAppMarketingVersion = iphoneAppMarketingVersion
        self.iphoneAppBuild = iphoneAppBuild
        self.iOSVersion = iOSVersion
        self.iphoneBatteryLevel = iphoneBatteryLevel
        self.iphoneBatteryState = iphoneBatteryState
        self.iphoneLowPowerModeEnabled = iphoneLowPowerModeEnabled
        self.iphoneThermalState = iphoneThermalState
        self.phoneLedgerSnapshot = phoneLedgerSnapshot
        self.iphoneACKQueueSnapshot = iphoneACKQueueSnapshot
        self.phoneSessionHistory = phoneSessionHistory
    }
}

nonisolated enum WatchPipelineStuck: Equatable, Sendable {
    case none
    case relay
    case handoff
    case orphan

    var reason: String? {
        switch self {
        case .none:
            nil
        case .relay:
            SourceVocabulary.watchPipelineRelayStuckReason
        case .handoff:
            SourceVocabulary.watchPipelineHandoffStuckReason
        case .orphan:
            SourceVocabulary.watchPipelineOrphanStuckReason
        }
    }
}

nonisolated struct WatchPipelineSummary: Equatable, Sendable {
    let pipelineRows: [WatchSourceDetailRow]
    let syncSummary: WatchSourceSyncSummary
    let diagnosticsRows: [WatchSourceDetailRow]
    let diagnosticsExportText: String
    let stuck: WatchPipelineStuck
}

nonisolated struct WatchWaitingBreakdown: Equatable, Sendable {
    let watch: WatchSideWaiting
    let phone: PhoneSideWaiting
    let leading: WatchWaitingLead?
}

nonisolated enum WatchSideWaiting: Equatable, Sendable {
    case unknown
    case reported(count: Int, freshness: WatchClaimFreshness)
}

nonisolated struct PhoneSideWaiting: Equatable, Sendable {
    let count: Int
}

nonisolated enum WatchClaimFreshness: Equatable, Sendable {
    case fresh(asOf: Date)
    case stale(asOf: Date, age: TimeInterval)
}

nonisolated enum WatchWaitingLead: Equatable, Sendable {
    case watch(count: Int, freshness: WatchClaimFreshness)
    case phone(count: Int)

    var count: Int {
        switch self {
        case .watch(let count, _), .phone(let count):
            count
        }
    }
}

nonisolated enum WatchRelayPhoneOutcome: Equatable, Sendable {
    case alreadyHanded(ackQueued: Bool)
    case receivedStaged
    case terminalDropped
    case ledgerAbsent
    case ledgerUnavailable
}

nonisolated enum WatchRelaySourceAssessment: String, Equatable, Sendable {
    case pending
    case copyBacked = "copy-backed"
    case staleSourceEmpty = "stale-source-empty"
    case unresolved
}

nonisolated struct WatchRelayIdentityClassification: Equatable, Sendable {
    let segmentID: UUID
    let observation: WatchRelayTransferObservation
    let phoneOutcome: WatchRelayPhoneOutcome
    let sourceAssessment: WatchRelaySourceAssessment?
    let ledgerEntry: WatchSegmentLedgerEntrySnapshot?
}

nonisolated struct WatchRelayClassificationReport: Equatable, Sendable {
    let activeBacklogCount: DiagnosticAvailability<Int>
    let visibleActiveDistinctCount: Int
    let omittedActiveCount: DiagnosticAvailability<Int>
    let evidenceUnavailableCount: Int
    let omittedObservationCount: Int
    let classifications: [WatchRelayIdentityClassification]
}

private nonisolated struct WatchDiagnosticsExportRow: Equatable, Sendable {
    let label: String
    let value: String
}

nonisolated enum WatchPipelineReducer {
    // 2× the 45s recording-status TTL → 90s trust boundary
    static let watchClaimFreshnessWindow: TimeInterval = WatchRecordingStatus.defaultTTL * 2
    static let relayStuckThreshold: TimeInterval = 600
    static let handoffStuckThreshold: TimeInterval = 600
    static let orphanStuckThreshold: TimeInterval = 1800

    static func reduce(_ input: WatchPipelineInput) -> WatchPipelineSummary {
        let syncSummary = self.syncSummary(input)
        let pipelineRows = self.pipelineRows(
            context: input.watchStatus,
            summary: syncSummary,
            now: input.now
        )
        let diagnosticsRows = self.diagnosticsRows(input)
        let stuck = self.stuck(input)
        let diagnosticsExportText = self.diagnosticsExportText(
            input: input,
            primaryRows: pipelineRows,
            diagnosticsRows: diagnosticsRows,
            stuck: stuck
        )
        return WatchPipelineSummary(
            pipelineRows: pipelineRows,
            syncSummary: syncSummary,
            diagnosticsRows: diagnosticsRows,
            diagnosticsExportText: diagnosticsExportText,
            stuck: stuck
        )
    }

    nonisolated static func phoneWaitingCount(_ input: WatchPipelineInput) -> Int {
        max(0, input.nonTerminalCount)
    }

    nonisolated static func waitingBreakdown(_ input: WatchPipelineInput) -> WatchWaitingBreakdown {
        let phone = PhoneSideWaiting(count: self.phoneWaitingCount(input))
        let watch: WatchSideWaiting
        if let context = input.watchStatus {
            let watchCount = max(0, context.queuedCount) + max(0, context.transferringCount)
            let age = max(0, input.now.timeIntervalSince(context.asOf))
            let freshness: WatchClaimFreshness = age > self.watchClaimFreshnessWindow
                ? .stale(asOf: context.asOf, age: age)
                : .fresh(asOf: context.asOf)
            watch = .reported(count: watchCount, freshness: freshness)
        } else {
            watch = .unknown
        }

        let leading: WatchWaitingLead?
        switch watch {
        case .reported(let count, .fresh(let asOf)) where count > phone.count:
            leading = .watch(count: count, freshness: .fresh(asOf: asOf))
        case _ where phone.count > 0:
            leading = .phone(count: phone.count)
        case .reported(let count, .fresh(let asOf)) where count > 0:
            leading = .watch(count: count, freshness: .fresh(asOf: asOf))
        case .unknown, .reported:
            leading = nil
        }

        return WatchWaitingBreakdown(watch: watch, phone: phone, leading: leading)
    }

    nonisolated static func stuckState(_ input: WatchPipelineInput) -> WatchPipelineStuck {
        self.stuck(input)
    }

    nonisolated static func classifyRelayIdentities(_ input: WatchPipelineInput) -> WatchRelayClassificationReport {
        guard let payload = input.watchDiagnostics.payload else {
            return WatchRelayClassificationReport(
                activeBacklogCount: .unavailable(
                    reason: input.watchDiagnostics.unavailableReason ?? WatchRelayDiagnosticsEnvelopeReason.absent
                ),
                visibleActiveDistinctCount: 0,
                omittedActiveCount: .unavailable(
                    reason: input.watchDiagnostics.unavailableReason ?? WatchRelayDiagnosticsEnvelopeReason.absent
                ),
                evidenceUnavailableCount: 0,
                omittedObservationCount: 0,
                classifications: []
            )
        }

        let activeBacklogCount: DiagnosticAvailability<Int>
        switch payload.manifestSummary {
        case let .available(summary):
            activeBacklogCount = .available(summary.activeBacklogCount)
        case let .unavailable(reason):
            activeBacklogCount = .unavailable(reason: reason)
        }

        let observations = self.visibleActiveObservations(payload.observedFileTransfers)
        let classifications = observations.map { visible in
            self.classification(
                segmentID: visible.segmentID,
                observation: visible.observation,
                ledgerSnapshot: input.phoneLedgerSnapshot,
                ackSnapshot: input.iphoneACKQueueSnapshot
            )
        }
        let visibleActiveDistinctCount = classifications.count

        let omittedActiveCount: DiagnosticAvailability<Int>
        switch activeBacklogCount {
        case let .available(activeBacklog):
            if activeBacklog >= visibleActiveDistinctCount {
                omittedActiveCount = .available(activeBacklog - visibleActiveDistinctCount)
            } else {
                omittedActiveCount = .unavailable(reason: "active backlog less than visible active identities")
            }
        case let .unavailable(reason):
            omittedActiveCount = .unavailable(reason: reason)
        }

        let evidenceUnavailableCount = classifications.filter { classification in
            switch classification.phoneOutcome {
            case .ledgerUnavailable:
                return true
            case .alreadyHanded, .receivedStaged, .terminalDropped:
                return false
            case .ledgerAbsent:
                return classification.sourceAssessment == .unresolved
            }
        }.count

        return WatchRelayClassificationReport(
            activeBacklogCount: activeBacklogCount,
            visibleActiveDistinctCount: visibleActiveDistinctCount,
            omittedActiveCount: omittedActiveCount,
            evidenceUnavailableCount: evidenceUnavailableCount,
            omittedObservationCount: payload.omittedObservationCount,
            classifications: classifications
        )
    }
}

private extension WatchPipelineReducer {
    nonisolated static func visibleActiveObservations(
        _ observations: [WatchRelayTransferObservation]
    ) -> [(segmentID: UUID, observation: WatchRelayTransferObservation)] {
        var seen = Set<UUID>()
        var visible: [(segmentID: UUID, observation: WatchRelayTransferObservation)] = []
        for observation in observations where self.isAppActiveRelation(observation.relation) {
            guard let segmentID = observation.segmentID, seen.insert(segmentID).inserted else {
                continue
            }
            visible.append((segmentID: segmentID, observation: observation))
        }
        return visible
    }

    nonisolated static func isAppActiveRelation(_ relation: WatchRelayObservationRelation) -> Bool {
        switch relation {
        case .matched, .duplicate, .appActiveNotObserved:
            true
        case .orphaned, .unparseable:
            false
        }
    }

    nonisolated static func classification(
        segmentID: UUID,
        observation: WatchRelayTransferObservation,
        ledgerSnapshot: DiagnosticAvailability<WatchSegmentLedgerReadSnapshot>,
        ackSnapshot: WatchRelayACKQueueSnapshot
    ) -> WatchRelayIdentityClassification {
        switch ledgerSnapshot {
        case .unavailable:
            return WatchRelayIdentityClassification(
                segmentID: segmentID,
                observation: observation,
                phoneOutcome: .ledgerUnavailable,
                sourceAssessment: nil,
                ledgerEntry: nil
            )
        case let .available(snapshot):
            guard let entry = snapshot.entriesByID[segmentID] else {
                return WatchRelayIdentityClassification(
                    segmentID: segmentID,
                    observation: observation,
                    phoneOutcome: .ledgerAbsent,
                    sourceAssessment: self.sourceAssessment(observation),
                    ledgerEntry: nil
                )
            }

            let outcome: WatchRelayPhoneOutcome
            switch entry.state {
            case .handed, .handedAndDropped:
                outcome = .alreadyHanded(ackQueued: (ackSnapshot.identityCounts[segmentID] ?? 0) > 0)
            case .received:
                outcome = .receivedStaged
            case .dropped:
                outcome = .terminalDropped
            }

            return WatchRelayIdentityClassification(
                segmentID: segmentID,
                observation: observation,
                phoneOutcome: outcome,
                sourceAssessment: nil,
                ledgerEntry: entry
            )
        }
    }

    nonisolated static func sourceAssessment(
        _ observation: WatchRelayTransferObservation
    ) -> WatchRelaySourceAssessment {
        guard case let .available(collectionResolution) = observation.collectionResolution,
              collectionResolution == .stable,
              case let .available(audioFact) = observation.originalAudioFile,
              case let .available(locationFact) = observation.originalLocationFile,
              case let .available(relayBundlePresent) = observation.relayBundlePresent
        else {
            return .unresolved
        }

        let appleMatch = observation.relation == .matched || observation.relation == .duplicate

        if audioFact.state == .readableNonempty || locationFact.state == .readableNonempty {
            return .pending
        }

        if relayBundlePresent {
            guard case let .available(relayBundleBytes) = observation.relayBundleBytes else {
                return appleMatch ? .copyBacked : .unresolved
            }
            return relayBundleBytes > 0 || appleMatch ? .copyBacked : .staleSourceEmpty
        }

        return appleMatch ? .copyBacked : .staleSourceEmpty
    }

    nonisolated static func age(of date: Date?, now: Date) -> TimeInterval? {
        date.map { max(0, now.timeIntervalSince($0)) }
    }

    nonisolated static func syncSummary(_ input: WatchPipelineInput) -> WatchSourceSyncSummary {
        WatchSourceSyncSummary(
            received: max(0, input.lifetimeReceived),
            waiting: self.phoneWaitingCount(input),
            handedToJournal: max(0, input.lifetimeHanded),
            lastSyncAt: input.lastHandedAt
        )
    }

    nonisolated static func pipelineRows(
        context: WatchStatusContext?,
        summary: WatchSourceSyncSummary,
        now: Date
    ) -> [WatchSourceDetailRow] {
        [
            self.pipelineRow(
                label: SourceVocabulary.watchPipelineSaved,
                context: context,
                count: context?.queuedCount ?? 0,
                now: now
            ),
            self.pipelineRow(
                label: SourceVocabulary.watchPipelineSending,
                context: context,
                count: context?.transferringCount ?? 0,
                now: now
            ),
            WatchSourceDetailRow(label: SourceVocabulary.watchReceivedLabel, value: "\(summary.received)"),
            WatchSourceDetailRow(label: SourceVocabulary.watchNotYetInJournalLabel, value: "\(summary.waiting)"),
            WatchSourceDetailRow(label: SourceVocabulary.watchHandedToJournalLabel, value: "\(summary.handedToJournal)")
        ]
    }

    nonisolated static func diagnosticsRows(_ input: WatchPipelineInput) -> [WatchSourceDetailRow] {
        var rows = [
            WatchSourceDetailRow(label: SourceVocabulary.watchActivationLabel, value: self.activationText(input.activationState)),
            WatchSourceDetailRow(label: SourceVocabulary.watchPairedWithPhoneLabel, value: self.booleanText(input.isPaired)),
            WatchSourceDetailRow(label: SourceVocabulary.watchInstalledLabel, value: self.booleanText(input.isWatchAppInstalled)),
            WatchSourceDetailRow(label: SourceVocabulary.watchReachableLabel, value: self.booleanText(input.isReachable)),
            WatchSourceDetailRow(label: SourceVocabulary.watchStatusLabel, value: self.watchStatusText(input.watchStatus, now: input.now)),
            WatchSourceDetailRow(label: SourceVocabulary.watchLastReceivedLabel, value: self.lastReceivedText(input.lastReceivedAt, now: input.now)),
            WatchSourceDetailRow(label: SourceVocabulary.watchLastStagingDetailLabel, value: self.detailText(input.lastStagingError))
        ]
        if let lastLedgerError = input.lastLedgerError, !lastLedgerError.isEmpty {
            rows.append(WatchSourceDetailRow(label: SourceVocabulary.watchLastLedgerDetailLabel, value: lastLedgerError))
        }
        rows.append(WatchSourceDetailRow(label: SourceVocabulary.watchLastSyncDetailLabel, value: self.lastSyncText(input.lastUploadAt, now: input.now)))
        rows.append(WatchSourceDetailRow(label: SourceVocabulary.watchLastUploadErrorLabel, value: self.detailText(input.lastUploadError)))
        return rows
    }

    nonisolated static func diagnosticsExportText(
        input: WatchPipelineInput,
        primaryRows: [WatchSourceDetailRow],
        diagnosticsRows: [WatchSourceDetailRow],
        stuck: WatchPipelineStuck
    ) -> String {
        var lines = [SourceVocabulary.watchDiagnosticsExportTitle]
        self.appendExportSection(
            SourceVocabulary.watchDiagnosticsStageReportEnvironment,
            rows: self.reportEnvironmentRows(input: input, stuck: stuck),
            to: &lines
        )
        self.appendExportSection(
            SourceVocabulary.watchDiagnosticsStageWatchSnapshot,
            rows: self.watchSnapshotRows(input: input),
            to: &lines
        )
        self.appendExportSection(
            "watch session history",
            rows: self.sessionHistoryRows(input: input),
            to: &lines
        )
        self.appendExportSection(
            SourceVocabulary.watchDiagnosticsStageRetentionAppleQueue,
            rows: self.watchRetentionRows(input: input),
            to: &lines
        )
        self.appendExportSection(
            SourceVocabulary.watchDiagnosticsStageIPhoneStaging,
            rows: self.iphoneReceiptRows(input: input, diagnosticsRows: diagnosticsRows),
            to: &lines
        )
        self.appendExportSection(
            SourceVocabulary.watchDiagnosticsStageJournalHandoff,
            rows: self.journalHandoffRows(input: input),
            to: &lines
        )
        return lines.joined(separator: "\n")
    }

    nonisolated static func appendExportSection(
        _ title: String,
        rows: [WatchDiagnosticsExportRow],
        to lines: inout [String]
    ) {
        lines.append("")
        lines.append(title)
        for row in rows {
            lines.append("\(row.label): \(row.value)")
        }
    }

    nonisolated static func reportEnvironmentRows(
        input: WatchPipelineInput,
        stuck: WatchPipelineStuck
    ) -> [WatchDiagnosticsExportRow] {
        var rows = [
            WatchDiagnosticsExportRow(label: "report generated", value: self.dateWithAgeText(input.now, now: input.now)),
            WatchDiagnosticsExportRow(label: "iphone app version", value: self.availabilityText(input.iphoneAppMarketingVersion)),
            WatchDiagnosticsExportRow(label: "iphone app build", value: self.availabilityText(input.iphoneAppBuild)),
            WatchDiagnosticsExportRow(label: "iOS version", value: self.availabilityText(input.iOSVersion)),
            WatchDiagnosticsExportRow(label: "iphone battery level at report time", value: self.percentAvailabilityText(input.iphoneBatteryLevel)),
            WatchDiagnosticsExportRow(label: "iphone battery state at report time", value: self.availabilityText(input.iphoneBatteryState)),
            WatchDiagnosticsExportRow(label: "iphone low power at report time", value: self.boolAvailabilityText(input.iphoneLowPowerModeEnabled)),
            WatchDiagnosticsExportRow(label: "iphone thermal state at report time", value: self.availabilityText(input.iphoneThermalState)),
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchPairedWithPhoneLabel, value: self.booleanText(input.isPaired)),
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchInstalledLabel, value: self.booleanText(input.isWatchAppInstalled)),
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchActivationLabel, value: self.activationText(input.activationState)),
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchReachableLabel, value: self.booleanText(input.isReachable)),
        ]
        if let reason = stuck.reason {
            rows.append(WatchDiagnosticsExportRow(
                label: "current pipeline notice",
                value: WatchTransferFailureFormatter.redactedDescription(reason)
            ))
        }
        return rows
    }

    nonisolated static func watchSnapshotRows(input: WatchPipelineInput) -> [WatchDiagnosticsExportRow] {
        let status = input.watchStatus
        let payload = input.watchDiagnostics.payload
        var rows = [
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchStatusLabel, value: self.watchStatusText(status, now: input.now)),
            WatchDiagnosticsExportRow(label: "diagnostic evidence", value: self.diagnosticEvidenceText(input)),
            WatchDiagnosticsExportRow(label: "watch app version", value: payload.map { self.availabilityText($0.watchAppMarketingVersion) } ?? SourceVocabulary.watchDiagnosticsUnavailable),
            WatchDiagnosticsExportRow(label: "watch app build", value: payload.map { self.availabilityText($0.watchAppBuild) } ?? SourceVocabulary.watchDiagnosticsUnavailable),
            WatchDiagnosticsExportRow(label: "watch build match", value: self.buildMatchText(input)),
            WatchDiagnosticsExportRow(label: "watchOS version", value: payload.map { self.availabilityText($0.watchOSVersion) } ?? SourceVocabulary.watchDiagnosticsUnavailable),
            WatchDiagnosticsExportRow(label: "watch battery level at snapshot time", value: payload.map { self.percentAvailabilityText($0.watchBatteryLevel) } ?? SourceVocabulary.watchDiagnosticsUnavailable),
            WatchDiagnosticsExportRow(label: "watch battery state at snapshot time", value: payload.map { self.availabilityText($0.watchBatteryState) } ?? SourceVocabulary.watchDiagnosticsUnavailable),
            WatchDiagnosticsExportRow(label: "watch low power at snapshot time", value: payload.map { self.boolAvailabilityText($0.watchLowPowerModeEnabled) } ?? SourceVocabulary.watchDiagnosticsUnavailable),
            WatchDiagnosticsExportRow(label: "watch thermal state at snapshot time", value: payload.map { self.availabilityText($0.watchThermalState) } ?? SourceVocabulary.watchDiagnosticsUnavailable),
        ]
        if let payload {
            rows.append(contentsOf: [
                WatchDiagnosticsExportRow(label: SourceVocabulary.watchActivationLabel, value: payload.activationState),
                WatchDiagnosticsExportRow(label: "companion installed", value: self.boolAvailabilityText(payload.isCompanionAppInstalled)),
                WatchDiagnosticsExportRow(label: SourceVocabulary.watchReachableLabel, value: self.booleanText(payload.isReachable)),
                WatchDiagnosticsExportRow(label: "iphone unlock after reboot needed for reachability", value: self.boolAvailabilityText(payload.iOSDeviceNeedsUnlockAfterRebootForReachability)),
                WatchDiagnosticsExportRow(label: "receiver has content pending", value: self.booleanText(payload.hasContentPending)),
            ])
        }
        return rows
    }

    nonisolated static func sessionHistoryRows(input: WatchPipelineInput) -> [WatchDiagnosticsExportRow] {
        let labels = [
            "sessions retained on this iphone",
            "retention window",
            "sessions dropped as older than the retention window",
            "sessions this iphone has not received",
        ]
        let values: [String]
        let entries: [WatchCaptureSessionHistoryEntry]
        switch input.phoneSessionHistory {
        case let .available(history):
            values = [
                "\(history.retainedCount)",
                "\(history.retentionDays) days",
                "\(history.droppedAsOlderThanRetentionWindow)",
                self.intAvailabilityText(history.sessionsNotReceived),
            ]
            entries = history.entries
        case .unavailable:
            let reason = self.availabilityReason(input.phoneSessionHistory)
            values = Array(repeating: reason, count: labels.count)
            entries = []
        }
        var rows = zip(labels, values).map { WatchDiagnosticsExportRow(label: $0, value: $1) }
        for (offset, entry) in entries.enumerated() {
            rows.append(contentsOf: self.sessionHistoryRows(entry: entry, index: offset + 1, total: entries.count, now: input.now))
        }
        return rows
    }

    nonisolated static func sessionHistoryRows(
        entry: WatchCaptureSessionHistoryEntry,
        index: Int,
        total: Int,
        now: Date
    ) -> [WatchDiagnosticsExportRow] {
        [
            WatchDiagnosticsExportRow(label: "session", value: "\(index) of \(total)"),
            WatchDiagnosticsExportRow(label: "started", value: self.dateWithAgeText(entry.startedAt, now: now)),
            WatchDiagnosticsExportRow(label: "ended", value: self.optionalDateWithAgeText(entry.terminalAt, now: now)),
            WatchDiagnosticsExportRow(label: "outcome", value: "\(entry.terminalReason?.rawValue ?? SourceVocabulary.watchDiagnosticsNotProvided) / \(entry.terminalDisposition?.rawValue ?? SourceVocabulary.watchDiagnosticsNotProvided)"),
            WatchDiagnosticsExportRow(label: "start refusal", value: entry.startRefusalReason?.rawValue ?? "none"),
            WatchDiagnosticsExportRow(label: "wrist alert", value: "\(entry.noticeDecision ?? "none") / delivered \(self.optionalBooleanText(entry.noticeDelivered))"),
            WatchDiagnosticsExportRow(label: "wrist alert authorization", value: "\(entry.notificationAuthorizationStatus?.rawValue ?? SourceVocabulary.watchDiagnosticsNotProvided) / alerts \(entry.notificationAlertSetting?.rawValue ?? SourceVocabulary.watchDiagnosticsNotProvided)"),
            WatchDiagnosticsExportRow(label: "notice owed cleared", value: self.booleanText(!entry.noticeOwed)),
            WatchDiagnosticsExportRow(label: "battery at end", value: "\(self.optionalPercentText(entry.batteryLevelAtEnd)) / \(entry.batteryStateAtEnd ?? SourceVocabulary.watchDiagnosticsNotProvided)"),
            WatchDiagnosticsExportRow(label: "low power at end", value: self.optionalBooleanText(entry.lowPowerModeEnabledAtEnd)),
            WatchDiagnosticsExportRow(label: "thermal at end", value: entry.thermalStateAtEnd ?? SourceVocabulary.watchDiagnosticsNotProvided),
            WatchDiagnosticsExportRow(label: "audio clock at end", value: entry.lastAudioCurrentTime.map { self.secondsText($0) } ?? SourceVocabulary.watchDiagnosticsNotProvided),
            WatchDiagnosticsExportRow(label: "zero-clock observations at end", value: entry.zeroAudioCurrentTimeObservationCount.map(String.init) ?? SourceVocabulary.watchDiagnosticsNotProvided),
            WatchDiagnosticsExportRow(label: "segments produced", value: "\(entry.segmentsProduced)"),
            WatchDiagnosticsExportRow(label: "persistence advisory", value: entry.persistenceAdvisory?.rawValue ?? "none"),
            WatchDiagnosticsExportRow(label: "location advisory", value: entry.locationAdvisory?.rawValue ?? "none")
        ]
    }

    nonisolated static func watchRetentionRows(input: WatchPipelineInput) -> [WatchDiagnosticsExportRow] {
        let classificationReport = self.classifyRelayIdentities(input)
        guard let payload = input.watchDiagnostics.payload else {
            return [
                WatchDiagnosticsExportRow(label: SourceVocabulary.watchDiagnosticsRelayAssessmentLabel, value: self.relayAssessmentText(input)),
                WatchDiagnosticsExportRow(label: "diagnostic detail", value: input.watchDiagnostics.unavailableReason ?? SourceVocabulary.watchDiagnosticsUnavailable),
            ] + self.classificationDenominatorRows(classificationReport)
        }

        var rows = [
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchDiagnosticsRelayAssessmentLabel, value: self.relayAssessmentText(input))
        ]

        switch payload.manifestSummary {
        case let .available(summary):
            rows.append(contentsOf: [
                WatchDiagnosticsExportRow(label: "manifest counts", value: self.manifestCountsText(summary.counts)),
                WatchDiagnosticsExportRow(label: "original audio files", value: self.originalFileCountsText(summary.originalAudioFileCounts)),
                WatchDiagnosticsExportRow(label: "retained source bytes", value: self.int64AvailabilityText(summary.retainedSourceBytes)),
                WatchDiagnosticsExportRow(label: "oldest active enqueue", value: self.dateAvailabilityText(summary.oldestActiveEnqueuedAt, now: input.now)),
                WatchDiagnosticsExportRow(label: "oldest active enqueue age", value: self.intervalAvailabilityText(summary.oldestActiveEnqueueAgeSeconds)),
            ])
        case let .unavailable(reason):
            rows.append(WatchDiagnosticsExportRow(label: "manifest diagnostics", value: reason))
        }

        switch payload.lastFacts {
        case let .available(lastFacts):
            rows.append(contentsOf: self.lastFactRows(lastFacts, now: input.now))
        case let .unavailable(reason):
            rows.append(WatchDiagnosticsExportRow(label: "last facts", value: reason))
        }

        switch payload.appleQueue {
        case let .available(queue):
            rows.append(contentsOf: [
                WatchDiagnosticsExportRow(label: "Apple outstanding file transfers", value: "\(queue.outstandingFileTransferCount)"),
                WatchDiagnosticsExportRow(label: "reconciliation", value: self.reconciliationText(queue.reconciliation)),
                WatchDiagnosticsExportRow(label: SourceVocabulary.watchDiagnosticsWatchUserInfoQueueLabel, value: "\(queue.outstandingUserInfoTransferCountWatchToPhone)"),
                WatchDiagnosticsExportRow(label: "exact observations before compaction", value: "\(queue.exactObservationCountBeforeCompaction)"),
            ])
        case let .unavailable(reason):
            rows.append(WatchDiagnosticsExportRow(label: "Apple queue", value: reason))
        }

        rows.append(contentsOf: self.classificationDenominatorRows(classificationReport))
        for (index, classification) in classificationReport.classifications.enumerated() {
            rows.append(WatchDiagnosticsExportRow(
                label: "\(SourceVocabulary.watchDiagnosticsVisibleActiveClassificationLabel) \(index + 1)",
                value: self.classificationText(classification)
            ))
        }

        let staleSnapshotAge = self.staleWatchSnapshotAge(input)
        for (index, observation) in payload.observedFileTransfers.enumerated() {
            rows.append(WatchDiagnosticsExportRow(
                label: "transfer observation \(index + 1)",
                value: self.observationText(observation, staleSnapshotAge: staleSnapshotAge)
            ))
        }
        return rows
    }

    nonisolated static func iphoneReceiptRows(
        input: WatchPipelineInput,
        diagnosticsRows: [WatchSourceDetailRow]
    ) -> [WatchDiagnosticsExportRow] {
        var rows = [
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchReceivedLabel, value: "\(max(0, input.lifetimeReceived))"),
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchLastReceivedLabel, value: self.lastReceivedText(input.lastReceivedAt, now: input.now)),
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchLastStagingDetailLabel, value: WatchTransferFailureFormatter.exportSafeText(input.lastStagingError)),
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchNotYetInJournalLabel, value: "\(self.phoneWaitingCount(input))"),
            WatchDiagnosticsExportRow(label: "oldest staged age", value: self.optionalAgeText(input.oldestNonTerminalReceivedAt, now: input.now)),
        ]
        rows.append(contentsOf: self.phoneLedgerRows(input.phoneLedgerSnapshot))
        rows.append(contentsOf: self.ackQueueRows(input.iphoneACKQueueSnapshot))
        if diagnosticsRows.contains(where: { $0.label == SourceVocabulary.watchLastLedgerDetailLabel }),
           let lastLedgerError = input.lastLedgerError,
           !lastLedgerError.isEmpty {
            rows.append(WatchDiagnosticsExportRow(
                label: SourceVocabulary.watchLastLedgerDetailLabel,
                value: WatchTransferFailureFormatter.exportSafeText(lastLedgerError)
            ))
        }
        return rows
    }

    nonisolated static func journalHandoffRows(input: WatchPipelineInput) -> [WatchDiagnosticsExportRow] {
        [
            WatchDiagnosticsExportRow(label: "pending journal handoff", value: "\(max(0, input.pendingCount))"),
            WatchDiagnosticsExportRow(label: "failed journal handoff", value: "\(max(0, input.failedCount))"),
            WatchDiagnosticsExportRow(label: "in-flight journal handoff", value: "\(max(0, input.inFlightCount))"),
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchHandedToJournalLabel, value: "\(max(0, input.lifetimeHanded))"),
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchLastSyncDetailLabel, value: self.lastSyncText(input.lastUploadAt, now: input.now)),
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchLastUploadErrorLabel, value: WatchTransferFailureFormatter.exportSafeText(input.lastUploadError)),
        ]
    }

    nonisolated static func classificationDenominatorRows(
        _ report: WatchRelayClassificationReport
    ) -> [WatchDiagnosticsExportRow] {
        [
            WatchDiagnosticsExportRow(
                label: SourceVocabulary.watchDiagnosticsActiveBacklogLabel,
                value: self.intAvailabilityText(report.activeBacklogCount)
            ),
            WatchDiagnosticsExportRow(
                label: SourceVocabulary.watchDiagnosticsVisibleActiveLabel,
                value: "\(report.visibleActiveDistinctCount)"
            ),
            WatchDiagnosticsExportRow(
                label: SourceVocabulary.watchDiagnosticsOmittedActiveLabel,
                value: self.intAvailabilityText(report.omittedActiveCount)
            ),
            WatchDiagnosticsExportRow(
                label: SourceVocabulary.watchDiagnosticsEvidenceUnavailableLabel,
                value: "\(report.evidenceUnavailableCount)"
            ),
            WatchDiagnosticsExportRow(
                label: SourceVocabulary.watchDiagnosticsOmittedObservationsLabel,
                value: "\(report.omittedObservationCount)"
            ),
        ]
    }

    nonisolated static func phoneLedgerRows(
        _ ledgerSnapshot: DiagnosticAvailability<WatchSegmentLedgerReadSnapshot>
    ) -> [WatchDiagnosticsExportRow] {
        switch ledgerSnapshot {
        case let .available(snapshot):
            return [
                WatchDiagnosticsExportRow(
                    label: SourceVocabulary.watchDiagnosticsPhoneLedgerRetainedEntriesLabel,
                    value: "\(snapshot.counts.retainedEntryCount)"
                ),
                WatchDiagnosticsExportRow(
                    label: SourceVocabulary.watchDiagnosticsPhoneLedgerReceivedLabel,
                    value: "\(snapshot.counts.receivedOnlyCount)"
                ),
                WatchDiagnosticsExportRow(
                    label: SourceVocabulary.watchDiagnosticsPhoneLedgerHandedLabel,
                    value: "\(snapshot.counts.handedCount)"
                ),
                WatchDiagnosticsExportRow(
                    label: SourceVocabulary.watchDiagnosticsPhoneLedgerDroppedLabel,
                    value: "\(snapshot.counts.droppedCount)"
                ),
                WatchDiagnosticsExportRow(
                    label: SourceVocabulary.watchDiagnosticsPhoneLedgerHandedAndDroppedLabel,
                    value: "\(snapshot.counts.handedAndDroppedCount)"
                ),
            ]
        case let .unavailable(reason):
            return [
                WatchDiagnosticsExportRow(
                    label: SourceVocabulary.watchDiagnosticsPhoneLedgerLabel,
                    value: self.unavailableText(reason)
                )
            ]
        }
    }

    nonisolated static func ackQueueRows(_ ackSnapshot: WatchRelayACKQueueSnapshot) -> [WatchDiagnosticsExportRow] {
        [
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchDiagnosticsIPhoneACKQueueLabel, value: "\(ackSnapshot.total)"),
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchDiagnosticsIPhoneRecognizedACKLabel, value: "\(ackSnapshot.recognizedACK)"),
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchDiagnosticsIPhoneParseableACKLabel, value: "\(ackSnapshot.parseableACK)"),
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchDiagnosticsIPhoneDistinctACKIdentitiesLabel, value: "\(ackSnapshot.distinctIdentities)"),
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchDiagnosticsIPhoneDuplicateACKExtrasLabel, value: "\(ackSnapshot.duplicateExtras)"),
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchDiagnosticsIPhoneMalformedMissingACKLabel, value: "\(ackSnapshot.malformedOrMissing)"),
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchDiagnosticsIPhoneNonACKUserInfoLabel, value: "\(ackSnapshot.nonACK)"),
        ]
    }

    nonisolated static func classificationText(_ classification: WatchRelayIdentityClassification) -> String {
        var parts = [
            "segment \(classification.segmentID.uuidString)",
            "phone \(self.phoneOutcomeText(classification.phoneOutcome))",
        ]
        parts.append("apple relation \(classification.observation.relation.rawValue)")
        if let sourceAssessment = classification.sourceAssessment {
            parts.append("source \(sourceAssessment.rawValue)")
        }
        parts.append("original audio \(self.originalFileText(classification.observation.originalAudioFile))")
        parts.append("original location \(self.originalFileText(classification.observation.originalLocationFile))")
        parts.append("relay bundle present \(self.boolAvailabilityText(classification.observation.relayBundlePresent))")
        parts.append("relay bundle bytes \(self.int64AvailabilityText(classification.observation.relayBundleBytes))")
        parts.append("collection \(self.collectionResolutionText(classification.observation.collectionResolution))")
        parts.append("ledger \(self.ledgerText(classification))")
        if let ledgerEntry = classification.ledgerEntry {
            parts.append(contentsOf: self.ledgerTimestampParts(ledgerEntry))
        }
        return parts.joined(separator: "; ")
    }

    nonisolated static func phoneOutcomeText(_ outcome: WatchRelayPhoneOutcome) -> String {
        switch outcome {
        case let .alreadyHanded(ackQueued):
            return "already handed to journal / Watch retention-cleanup lag; ack queued \(self.booleanText(ackQueued))"
        case .receivedStaged:
            return "received/staged, journal handoff not proven"
        case .terminalDropped:
            return "terminal-dropped / Watch retention-cleanup lag"
        case .ledgerAbsent:
            return "not present in retained phone ledger"
        case .ledgerUnavailable:
            return "phone ledger unavailable"
        }
    }

    nonisolated static func originalFileText(
        _ availability: DiagnosticAvailability<WatchRelayOriginalFileFact>
    ) -> String {
        switch availability {
        case let .available(fact):
            let byteText = fact.byteCount.map { "\($0)" } ?? SourceVocabulary.watchDiagnosticsNotProvided
            return "\(fact.state.rawValue) bytes \(byteText)"
        case let .unavailable(reason):
            return self.unavailableText(reason)
        }
    }

    nonisolated static func originalFileCountsText(
        _ availability: DiagnosticAvailability<WatchRelayOriginalFileStateCounts>
    ) -> String {
        switch availability {
        case let .available(counts):
            return [
                "\(WatchRelayOriginalFileState.missing.rawValue) \(counts.missing)",
                "\(WatchRelayOriginalFileState.readableNonempty.rawValue) \(counts.readableNonempty)",
                "\(WatchRelayOriginalFileState.zeroLength.rawValue) \(counts.zeroLength)",
                "\(WatchRelayOriginalFileState.unreadable.rawValue) \(counts.unreadable)",
            ].joined(separator: ", ")
        case let .unavailable(reason):
            return self.unavailableText(reason)
        }
    }

    nonisolated static func collectionResolutionText(
        _ availability: DiagnosticAvailability<WatchRelayObservationCollectionResolution>
    ) -> String {
        switch availability {
        case let .available(resolution):
            return resolution.rawValue
        case let .unavailable(reason):
            return self.unavailableText(reason)
        }
    }

    nonisolated static func ledgerText(_ classification: WatchRelayIdentityClassification) -> String {
        if let ledgerEntry = classification.ledgerEntry {
            return ledgerEntry.state.rawValue
        }
        switch classification.phoneOutcome {
        case .ledgerAbsent:
            return "not present in retained phone ledger"
        case .ledgerUnavailable:
            return SourceVocabulary.watchDiagnosticsUnavailable
        case .alreadyHanded, .receivedStaged, .terminalDropped:
            return SourceVocabulary.watchDiagnosticsNotProvided
        }
    }

    nonisolated static func ledgerTimestampParts(_ entry: WatchSegmentLedgerEntrySnapshot) -> [String] {
        var parts: [String] = []
        if let receivedAt = entry.receivedAt {
            parts.append("received at \(self.iso8601Text(receivedAt))")
        }
        if let receivedAgeSeconds = entry.receivedAgeSeconds {
            parts.append("received age \(self.secondsText(receivedAgeSeconds))")
        }
        if let handedAt = entry.handedAt {
            parts.append("handed at \(self.iso8601Text(handedAt))")
        }
        if let handedAgeSeconds = entry.handedAgeSeconds {
            parts.append("handed age \(self.secondsText(handedAgeSeconds))")
        }
        if let droppedAt = entry.droppedAt {
            parts.append("dropped at \(self.iso8601Text(droppedAt))")
        }
        if let droppedAgeSeconds = entry.droppedAgeSeconds {
            parts.append("dropped age \(self.secondsText(droppedAgeSeconds))")
        }
        return parts
    }

    nonisolated static func relayAssessmentText(_ input: WatchPipelineInput) -> String {
        guard let payload = input.watchDiagnostics.payload else {
            let reason = input.watchDiagnostics.unavailableReason ?? SourceVocabulary.watchDiagnosticsUnavailable
            if reason == WatchRelayDiagnosticsEnvelopeReason.malformed {
                return "diagnostic evidence malformed"
            }
            if reason == WatchRelayDiagnosticsEnvelopeReason.unsupportedVersion {
                return "diagnostic evidence unsupported version"
            }
            if reason == WatchRelayDiagnosticsEnvelopeReason.publicationFailed
                || reason == WatchRelayDiagnosticsEnvelopeReason.encodeFailed {
                return "diagnostic publication failed"
            }
            return "diagnostic evidence unavailable: \(reason)"
        }

        if self.staleWatchSnapshotAge(input) != nil {
            return "diagnostic evidence stale"
        }

        guard case let .available(manifestSummary) = payload.manifestSummary else {
            return "diagnostic evidence unavailable"
        }
        guard manifestSummary.activeBacklogCount > 0 else {
            return "no active backlog"
        }

        if case let .available(queue) = payload.appleQueue {
            if queue.reconciliation.duplicate > 0 {
                return "duplicate Apple queue entries observed"
            }
            if queue.reconciliation.orphaned > 0 {
                return "orphaned Apple queue entries observed"
            }
            if queue.reconciliation.unparseable > 0 {
                return "unparseable Apple queue entries observed"
            }
        }

        if case let .available(lastFacts) = payload.lastFacts,
           let failure = lastFacts.lastStructuredFailure,
           self.age(of: failure.time, now: input.now).map({ $0 <= self.relayStuckThreshold }) == true {
            return "recent structured transfer failure: \(failure.domain) \(failure.code) \(WatchTransferFailureFormatter.redactedDescription(failure.boundedRedactedDescription))"
        }

        let oldestAge: TimeInterval?
        if case let .available(age) = manifestSummary.oldestActiveEnqueueAgeSeconds {
            oldestAge = age
        } else {
            oldestAge = nil
        }
        let isOld = (oldestAge ?? 0) >= self.relayStuckThreshold
        let matching = payload.observedFileTransfers.filter { observation in
            observation.relation == .matched || observation.relation == .duplicate
        }

        if !matching.isEmpty {
            if matching.contains(where: { observation in
                guard case let .available(progress) = observation.progress else { return false }
                return !progress.isIndeterminate
            }) {
                return "Apple owns matching outstanding transfers with determinate progress"
            }
            if matching.contains(where: { observation in
                guard case let .available(progress) = observation.progress else { return false }
                return progress.isIndeterminate
            }) {
                return "Apple owns matching outstanding transfers with indeterminate progress"
            }
            return "Apple owns matching outstanding transfers with no progress value provided"
        }

        if isOld {
            return "point-in-time app/Apple queue disagreement"
        }
        return "newly queued in the app but not yet observed in Apple's queue"
    }

    nonisolated static func diagnosticEvidenceText(_ input: WatchPipelineInput) -> String {
        guard input.watchDiagnostics.payload != nil else {
            return input.watchDiagnostics.unavailableReason ?? SourceVocabulary.watchDiagnosticsUnavailable
        }
        guard let status = input.watchStatus,
              let claimAge = self.age(of: status.asOf, now: input.now)
        else {
            return SourceVocabulary.watchDiagnosticsUnavailable
        }
        if claimAge > self.watchClaimFreshnessWindow {
            return "stale · \(self.relativeText(secondsAgo: claimAge))"
        }
        return "available · \(self.relativeText(secondsAgo: claimAge))"
    }

    nonisolated static func buildMatchText(_ input: WatchPipelineInput) -> String {
        guard let iphoneBuild = input.iphoneAppBuild.value,
              let watchBuild = input.watchDiagnostics.payload?.watchAppBuild.value
        else {
            return SourceVocabulary.watchDiagnosticsUnavailable
        }
        return iphoneBuild == watchBuild ? SourceVocabulary.watchBooleanYes : SourceVocabulary.watchBooleanNo
    }

    nonisolated static func lastFactRows(
        _ facts: WatchRelayLastFactsSummary,
        now: Date
    ) -> [WatchDiagnosticsExportRow] {
        var rows: [WatchDiagnosticsExportRow] = []
        if let fact = facts.lastEnqueue {
            rows.append(WatchDiagnosticsExportRow(label: "last Watch enqueue", value: self.factCounterText(fact, now: now)))
        }
        if let fact = facts.lastTransferCompletion {
            rows.append(WatchDiagnosticsExportRow(label: "last Watch transfer completion", value: self.transferCompletionText(fact, now: now)))
        }
        if let failure = facts.lastStructuredFailure {
            rows.append(WatchDiagnosticsExportRow(label: "last Watch transfer failure", value: self.structuredFailureText(failure, now: now)))
        }
        if let fact = facts.lastDurableACK {
            rows.append(WatchDiagnosticsExportRow(label: "last durable ACK", value: self.factCounterText(fact, now: now)))
        }
        if let fact = facts.lastQueueReconciliationObservation {
            rows.append(WatchDiagnosticsExportRow(label: "last queue reconciliation", value: self.queueReconciliationText(fact, now: now)))
        }
        if let fact = facts.lastBackgroundWakeCompletion {
            rows.append(WatchDiagnosticsExportRow(label: "last background wake completion", value: self.backgroundWakeText(fact, now: now)))
        }
        if let fact = facts.lastBackgroundWakeDeadline {
            rows.append(WatchDiagnosticsExportRow(label: "last background wake deadline", value: self.backgroundWakeText(fact, now: now)))
        }
        if rows.isEmpty {
            rows.append(WatchDiagnosticsExportRow(label: "last facts", value: "not observed yet"))
        }
        return rows
    }

    nonisolated static func staleWatchSnapshotAge(_ input: WatchPipelineInput) -> TimeInterval? {
        guard let status = input.watchStatus,
              let claimAge = self.age(of: status.asOf, now: input.now),
              claimAge > self.watchClaimFreshnessWindow
        else {
            return nil
        }
        return claimAge
    }

    nonisolated static func observationText(
        _ observation: WatchRelayTransferObservation,
        staleSnapshotAge: TimeInterval? = nil
    ) -> String {
        let segment = observation.segmentID?.uuidString ?? SourceVocabulary.watchDiagnosticsUnavailable
        let transferring = self.boolAvailabilityText(observation.isTransferring)
        let progress = staleSnapshotAge.map { self.staleProgressText(age: $0) }
            ?? self.progressText(observation.progress)
        return [
            "segment \(segment)",
            "relation \(observation.relation.rawValue)",
            "id \(observation.idState.rawValue)",
            "manifest \(observation.appManifestState ?? SourceVocabulary.watchDiagnosticsUnavailable)",
            "original enqueue age \(self.intervalAvailabilityText(observation.appOwnedEnqueueAgeSeconds))",
            "attempt id \(self.attemptIDText(observation))",
            "attempt started \(self.attemptStartedText(observation))",
            "current attempt age \(self.attemptAgeText(observation))",
            "source bytes \(self.int64AvailabilityText(observation.appOwnedSourceBytes))",
            "source present \(self.boolAvailabilityText(observation.sourcePresent))",
            "transferring \(transferring)",
            progress,
            "as of \(self.iso8601Text(observation.asOf))",
        ].joined(separator: "; ")
    }

    nonisolated static func attemptIDText(_ observation: WatchRelayTransferObservation) -> String {
        switch observation.attemptIDState {
        case .parseable:
            return observation.attemptID?.uuidString ?? SourceVocabulary.watchDiagnosticsUnavailable
        case .missing:
            return "legacy / not provided"
        case .unparseable:
            return "unparseable"
        }
    }

    nonisolated static func attemptStartedText(_ observation: WatchRelayTransferObservation) -> String {
        switch observation.attemptStartedAtState {
        case .parseable:
            return observation.attemptStartedAt.map(self.iso8601Text) ?? SourceVocabulary.watchDiagnosticsUnavailable
        case .missing:
            return "legacy / not provided"
        case .unparseable:
            return "unparseable"
        }
    }

    nonisolated static func attemptAgeText(_ observation: WatchRelayTransferObservation) -> String {
        guard observation.attemptStartedAtState == .parseable,
              let startedAt = observation.attemptStartedAt
        else {
            return observation.attemptStartedAtState == .unparseable
                ? "unparseable"
                : "legacy / not provided"
        }
        return self.secondsText(max(0, observation.asOf.timeIntervalSince(startedAt)))
    }

    nonisolated static func staleProgressText(age: TimeInterval) -> String {
        "progress not shown - snapshot is stale (as of \(self.relativeText(secondsAgo: age)))"
    }

    nonisolated static func progressText(_ availability: DiagnosticAvailability<WatchConnectivityProgressSnapshot>) -> String {
        switch availability {
        case let .unavailable(reason):
            return "progress \(WatchTransferFailureFormatter.redactedDescription(reason))"
        case let .available(progress):
            let fraction: String
            if progress.isIndeterminate {
                fraction = SourceVocabulary.watchDiagnosticsIndeterminate
            } else if let fractionCompleted = progress.fractionCompleted {
                fraction = String(format: "%.3f", fractionCompleted)
            } else {
                fraction = SourceVocabulary.watchDiagnosticsNotProvided
            }
            let throughput = progress.throughputBytesPerSecond.map { "\($0)" } ?? SourceVocabulary.watchDiagnosticsNotProvided
            let eta = progress.estimatedTimeRemainingSeconds.map { self.secondsText($0) } ?? SourceVocabulary.watchDiagnosticsNotProvided
            let kind = progress.kind ?? SourceVocabulary.watchDiagnosticsNotProvided
            return "progress fraction \(fraction), units \(progress.completedUnitCount)/\(progress.totalUnitCount), finished \(self.booleanText(progress.isFinished)), cancelled \(self.booleanText(progress.isCancelled)), throughput \(throughput), eta \(eta), kind \(kind)"
        }
    }

    nonisolated static func manifestCountsText(_ counts: WatchRelayManifestCounts) -> String {
        "initial \(counts.captured), persisted \(counts.persisted), finalized \(counts.finalized), queued \(counts.queued), transferring \(counts.transferring), delivered \(counts.delivered), acked \(counts.acked), safeToDelete \(counts.safeToDelete)"
    }

    nonisolated static func reconciliationText(_ counts: WatchRelayReconciliationCounts) -> String {
        "matched \(counts.matched), app-active-not-observed \(counts.appActiveNotObserved), duplicate \(counts.duplicate), orphaned \(counts.orphaned), unparseable \(counts.unparseable)"
    }

    nonisolated static func factCounterText(_ fact: WatchRelayFactCounter, now: Date) -> String {
        var parts = ["\(self.dateWithAgeText(fact.at, now: now))", "count \(fact.count)"]
        if let segmentID = fact.segmentID {
            parts.append("segment \(segmentID.uuidString)")
        }
        return parts.joined(separator: "; ")
    }

    nonisolated static func transferCompletionText(_ fact: WatchRelayTransferCompletionFact, now: Date) -> String {
        "\(self.dateWithAgeText(fact.at, now: now)); segment \(fact.segmentID.uuidString); succeeded \(self.booleanText(fact.succeeded)); success count \(fact.successCount); failure count \(fact.failureCount)"
    }

    nonisolated static func structuredFailureText(_ failure: WatchTransferStructuredFailure, now: Date) -> String {
        "\(self.dateWithAgeText(failure.time, now: now)); domain \(failure.domain); code \(failure.code); \(WatchTransferFailureFormatter.redactedDescription(failure.boundedRedactedDescription))"
    }

    nonisolated static func queueReconciliationText(_ fact: WatchRelayQueueReconciliationFact, now: Date) -> String {
        "\(self.dateWithAgeText(fact.at, now: now)); \(self.reconciliationText(fact.counts)); observed \(fact.observedFileTransferCount); active \(fact.activeManifestCount)"
    }

    nonisolated static func backgroundWakeText(_ fact: WatchRelayBackgroundWakeFact, now: Date) -> String {
        "\(self.dateWithAgeText(fact.at, now: now)); reason \(fact.reason); held \(fact.heldTaskCount); completed \(fact.completedTaskCount); deadlines \(fact.deadlineCount)"
    }

    nonisolated static func availabilityText(_ availability: DiagnosticAvailability<String>) -> String {
        switch availability {
        case let .available(value):
            return WatchTransferFailureFormatter.redactedDescription(value)
        case let .unavailable(reason):
            return "\(SourceVocabulary.watchDiagnosticsUnavailable) (\(WatchTransferFailureFormatter.redactedDescription(reason)))"
        }
    }

    nonisolated static func availabilityReason<Value>(_ availability: DiagnosticAvailability<Value>) -> String where Value: Codable & Equatable & Sendable {
        switch availability {
        case .available:
            SourceVocabulary.watchDiagnosticsNotProvided
        case let .unavailable(reason):
            self.unavailableText(reason)
        }
    }

    nonisolated static func optionalDateWithAgeText(_ date: Date?, now: Date) -> String {
        guard let date else { return SourceVocabulary.watchDiagnosticsNotProvided }
        return self.dateWithAgeText(date, now: now)
    }

    nonisolated static func optionalBooleanText(_ value: Bool?) -> String {
        guard let value else { return SourceVocabulary.watchDiagnosticsNotProvided }
        return self.booleanText(value)
    }

    nonisolated static func optionalPercentText(_ value: Double?) -> String {
        guard let value else { return SourceVocabulary.watchDiagnosticsNotProvided }
        return self.percentAvailabilityText(.available(value))
    }

    nonisolated static func boolAvailabilityText(_ availability: DiagnosticAvailability<Bool>) -> String {
        switch availability {
        case let .available(value):
            return self.booleanText(value)
        case let .unavailable(reason):
            return "\(SourceVocabulary.watchDiagnosticsUnavailable) (\(WatchTransferFailureFormatter.redactedDescription(reason)))"
        }
    }

    nonisolated static func intAvailabilityText(_ availability: DiagnosticAvailability<Int>) -> String {
        switch availability {
        case let .available(value):
            return "\(value)"
        case let .unavailable(reason):
            return self.unavailableText(reason)
        }
    }

    nonisolated static func int64AvailabilityText(_ availability: DiagnosticAvailability<Int64>) -> String {
        switch availability {
        case let .available(value):
            return "\(value)"
        case let .unavailable(reason):
            return self.unavailableText(reason)
        }
    }

    nonisolated static func unavailableText(_ reason: String) -> String {
        "\(SourceVocabulary.watchDiagnosticsUnavailable) (\(WatchTransferFailureFormatter.redactedDescription(reason)))"
    }

    nonisolated static func percentAvailabilityText(_ availability: DiagnosticAvailability<Double>) -> String {
        switch availability {
        case let .available(value):
            return String(format: "%.0f%%", value * 100)
        case let .unavailable(reason):
            return "\(SourceVocabulary.watchDiagnosticsUnavailable) (\(WatchTransferFailureFormatter.redactedDescription(reason)))"
        }
    }

    nonisolated static func intervalAvailabilityText(_ availability: DiagnosticAvailability<TimeInterval?>) -> String {
        switch availability {
        case let .available(value):
            guard let value else { return SourceVocabulary.watchDiagnosticsNotProvided }
            return self.secondsText(value)
        case let .unavailable(reason):
            return "\(SourceVocabulary.watchDiagnosticsUnavailable) (\(WatchTransferFailureFormatter.redactedDescription(reason)))"
        }
    }

    nonisolated static func dateAvailabilityText(_ availability: DiagnosticAvailability<Date?>, now: Date) -> String {
        switch availability {
        case let .available(value):
            guard let value else { return SourceVocabulary.watchDiagnosticsNotProvided }
            return self.dateWithAgeText(value, now: now)
        case let .unavailable(reason):
            return "\(SourceVocabulary.watchDiagnosticsUnavailable) (\(WatchTransferFailureFormatter.redactedDescription(reason)))"
        }
    }

    nonisolated static func optionalAgeText(_ date: Date?, now: Date) -> String {
        guard let date, let age = self.age(of: date, now: now) else {
            return SourceVocabulary.watchDiagnosticsNotProvided
        }
        return self.secondsText(age)
    }

    nonisolated static func dateWithAgeText(_ date: Date, now: Date) -> String {
        let age = self.age(of: date, now: now) ?? 0
        return "\(self.iso8601Text(date)) (\(self.relativeText(secondsAgo: age)))"
    }

    nonisolated static func iso8601Text(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    nonisolated static func secondsText(_ seconds: TimeInterval) -> String {
        "\(Int(max(0, seconds).rounded()))s"
    }

    nonisolated static func stuck(_ input: WatchPipelineInput) -> WatchPipelineStuck {
        if self.isOrphanStuck(input) {
            return .orphan
        }
        if self.isHandoffStuck(input) {
            return .handoff
        }
        if self.isRelayStuck(input) {
            return .relay
        }
        return .none
    }

    nonisolated static func isRelayStuck(_ input: WatchPipelineInput) -> Bool {
        guard let watchStatus = input.watchStatus,
              let claimAge = self.age(of: watchStatus.asOf, now: input.now),
              claimAge <= self.watchClaimFreshnessWindow,
              max(0, watchStatus.queuedCount) > 0,
              input.isPaired,
              input.isWatchAppInstalled,
              input.activationState == .activated,
              let receivedAge = self.age(of: input.lastReceivedAt, now: input.now)
        else {
            return false
        }
        return receivedAge >= self.relayStuckThreshold
    }

    nonisolated static func isHandoffStuck(_ input: WatchPipelineInput) -> Bool {
        guard let age = self.age(of: input.oldestNonTerminalReceivedAt, now: input.now),
              age >= self.handoffStuckThreshold,
              input.isJournalReachable
        else {
            return false
        }
        return self.uploadQueueCount(input) > 0
    }

    nonisolated static func isOrphanStuck(_ input: WatchPipelineInput) -> Bool {
        guard let age = self.age(of: input.oldestNonTerminalReceivedAt, now: input.now),
              age >= self.orphanStuckThreshold
        else {
            return false
        }
        return self.uploadQueueCount(input) == 0
    }

    nonisolated static func uploadQueueCount(_ input: WatchPipelineInput) -> Int {
        max(0, input.pendingCount) + max(0, input.failedCount) + max(0, input.inFlightCount)
    }

    nonisolated static func lastSyncText(_ date: Date?, now: Date) -> String {
        guard let secondsAgo = self.age(of: date, now: now) else {
            return SourceVocabulary.watchLastSyncNever
        }
        return self.relativeText(secondsAgo: secondsAgo)
    }

    nonisolated static func lastReceivedText(_ date: Date?, now: Date) -> String {
        guard let secondsAgo = self.age(of: date, now: now) else {
            return SourceVocabulary.watchLastReceivedNever
        }
        return self.relativeText(secondsAgo: secondsAgo)
    }

    nonisolated static func booleanText(_ value: Bool) -> String {
        value ? SourceVocabulary.watchBooleanYes : SourceVocabulary.watchBooleanNo
    }

    nonisolated static func activationText(_ state: WCSessionActivationState) -> String {
        switch state {
        case .activated:
            SourceVocabulary.watchActivationActivated
        case .inactive:
            SourceVocabulary.watchActivationInactive
        case .notActivated:
            SourceVocabulary.watchActivationNotActivated
        @unknown default:
            SourceVocabulary.watchActivationNotActivated
        }
    }

    nonisolated static func detailText(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return SourceVocabulary.watchDetailNone
        }
        return value
    }

    nonisolated static func pipelineRow(
        label: String,
        context: WatchStatusContext?,
        count: Int,
        now: Date
    ) -> WatchSourceDetailRow {
        guard let context else {
            return WatchSourceDetailRow(label: label, value: SourceVocabulary.watchPipelineUnknown)
        }
        let safeCount = max(0, count)
        let secondsAgo = self.age(of: context.asOf, now: now) ?? 0
        guard secondsAgo > self.watchClaimFreshnessWindow else {
            return WatchSourceDetailRow(label: label, value: "\(safeCount)")
        }
        return WatchSourceDetailRow(
            label: label,
            value: "\(safeCount)",
            detail: SourceVocabulary.watchPipelineStaleAsOf(self.relativeText(secondsAgo: secondsAgo))
        )
    }

    nonisolated static func watchStatusText(_ status: WatchStatusContext?, now: Date) -> String {
        guard let status else {
            return SourceVocabulary.watchDetailNone
        }
        var parts = [
            status.phase.rawValue,
            self.relativeText(secondsAgo: self.age(of: status.asOf, now: now) ?? 0),
        ]
        if status.audioTerminalDisposition == .ownerStopped {
            parts.append("\(SourceVocabulary.watchStatusAudioOutcomeLabel): \(SourceVocabulary.watchStatusAudioOutcomeOwnerStopped)")
        } else if let copy = WatchNoticeCopy(
            terminalReason: status.audioTerminalReason,
            terminalDisposition: status.audioTerminalDisposition
        ) {
            parts.append("\(SourceVocabulary.watchStatusAudioOutcomeLabel): \(copy.title)")
        }
        return parts.joined(separator: " · ")
    }
}

extension WatchPipelineReducer {
    nonisolated static func relativeText(secondsAgo: TimeInterval) -> String {
        if secondsAgo < 60 {
            return SourceVocabulary.watchRelativeJustNow
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(fromTimeInterval: -secondsAgo)
    }
}
