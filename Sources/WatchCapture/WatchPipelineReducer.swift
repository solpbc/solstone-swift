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
    /// The watch source's transfer error while it is still recent, and when it happened.
    let lastUploadError: String?
    let lastUploadErrorAt: Date?
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
    /// When the watch's stopped-itself state started counting, for the day it is shown.
    let watchStoppedItselfSince: Date?

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
        lastUploadErrorAt: Date? = nil,
        lastReceivedAt: Date?,
        lastStagingError: String?,
        isPaired: Bool,
        isWatchAppInstalled: Bool,
        activationState: WCSessionActivationState,
        isReachable: Bool,
        isJournalReachable: Bool,
        watchDiagnostics: WatchRelayDiagnosticsEnvelopeResult = .absent,
        iphoneAppMarketingVersion: DiagnosticAvailability<String> = .unavailable(reason: AppStrings.ios_watch_notprovided()),
        iphoneAppBuild: DiagnosticAvailability<String> = .unavailable(reason: AppStrings.ios_watch_notprovided()),
        iOSVersion: DiagnosticAvailability<String> = .unavailable(reason: AppStrings.ios_watch_notprovided()),
        iphoneBatteryLevel: DiagnosticAvailability<Double> = .unavailable(reason: AppStrings.ios_watch_notprovided()),
        iphoneBatteryState: DiagnosticAvailability<String> = .unavailable(reason: AppStrings.ios_watch_notprovided()),
        iphoneLowPowerModeEnabled: DiagnosticAvailability<Bool> = .unavailable(reason: AppStrings.ios_watch_notprovided()),
        iphoneThermalState: DiagnosticAvailability<String> = .unavailable(reason: AppStrings.ios_watch_notprovided()),
        phoneLedgerSnapshot: DiagnosticAvailability<WatchSegmentLedgerReadSnapshot> = .unavailable(reason: AppStrings.ios_watch_notprovided()),
        iphoneACKQueueSnapshot: WatchRelayACKQueueSnapshot = WatchRelayACKQueueSnapshot(),
        phoneSessionHistory: DiagnosticAvailability<WatchPhoneSessionHistoryInput>,
        watchStoppedItselfSince: Date? = nil
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
        self.lastUploadErrorAt = lastUploadErrorAt
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
        self.watchStoppedItselfSince = watchStoppedItselfSince
    }
}

nonisolated enum WatchPipelineStuck: Equatable, Sendable {
    case none
    case watchAppUpdate
    case relay
    case handoff
    case orphan

    var reason: String? {
        switch self {
        case .none:
            nil
        case .watchAppUpdate:
            SourceVocabulary.watchAppUpdateReason
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

nonisolated struct WatchDiagnosticsExportRow: Equatable, Sendable {
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
            // Only what is still on the watch waits there. A segment this device already has is
            // waiting on nothing but its confirmation back to the watch, which owners never see.
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

        return WatchWaitingBreakdown(
            watch: watch,
            phone: phone,
            leading: leading
        )
    }

    nonisolated static func stuckState(_ input: WatchPipelineInput) -> WatchPipelineStuck {
        self.stuck(input)
    }

    nonisolated static func isRelayStuck(_ input: WatchPipelineInput) -> Bool {
        guard let watchStatus = input.watchStatus,
              let claimAge = self.age(of: watchStatus.asOf, now: input.now),
              claimAge <= self.watchClaimFreshnessWindow,
              input.isPaired,
              input.isWatchAppInstalled,
              input.activationState == .activated
        else {
            return false
        }
        guard max(0, watchStatus.queuedCount) > 0,
              let receivedAge = self.age(of: input.lastReceivedAt, now: input.now)
        else {
            return false
        }
        return receivedAge >= self.relayStuckThreshold
    }

    /// The watch runs an older build than this device and this device no longer sees it as
    /// installed: watchOS is holding the newer watch app until the old one stops and closes.
    nonisolated static func isWatchAppUpdateWaiting(_ input: WatchPipelineInput) -> Bool {
        guard input.isPaired,
              !input.isWatchAppInstalled,
              input.activationState == .activated,
              let iphoneBuild = input.iphoneAppBuild.value.flatMap({ Int($0) }),
              let watchBuild = input.watchDiagnostics.payload?.watchAppBuild.value.flatMap({ Int($0) })
        else {
            return false
        }
        return watchBuild < iphoneBuild
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
                omittedActiveCount = .unavailable(reason: AppStrings.ios_watch_omittedactivecount())
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

extension WatchPipelineReducer {
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
        rows.append(WatchSourceDetailRow(label: SourceVocabulary.watchLastUploadErrorLabel, value: self.uploadErrorText(
            self.detailText(input.lastUploadError),
            at: input.lastUploadError == nil ? nil : input.lastUploadErrorAt,
            now: input.now
        )))
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
            AppStrings.ios_watch_diagnosticsexporttext(),
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
            lines.append(AppStrings.ios_frame_watchpipelinereducer_n622("\(row.label)", "\(row.value)"))
        }
    }

    nonisolated static func reportEnvironmentRows(
        input: WatchPipelineInput,
        stuck: WatchPipelineStuck
    ) -> [WatchDiagnosticsExportRow] {
        var rows = [
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_rows(), value: self.dateWithAgeText(input.now, now: input.now)),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_reportenvironmentrows4(), value: self.availabilityText(input.iphoneAppMarketingVersion)),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_reportenvironmentrows3(), value: self.availabilityText(input.iphoneAppBuild)),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_reportenvironmentrows2(), value: self.availabilityText(input.iOSVersion)),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_reportenvironmentrows5(), value: self.percentAvailabilityText(input.iphoneBatteryLevel)),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_reportenvironmentrows6(), value: self.availabilityText(input.iphoneBatteryState)),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_reportenvironmentrows7(), value: self.boolAvailabilityText(input.iphoneLowPowerModeEnabled)),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_reportenvironmentrows8(), value: self.availabilityText(input.iphoneThermalState)),
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchPairedWithPhoneLabel, value: self.booleanText(input.isPaired)),
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchInstalledLabel, value: self.booleanText(input.isWatchAppInstalled)),
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchActivationLabel, value: self.activationText(input.activationState)),
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchReachableLabel, value: self.booleanText(input.isReachable)),
        ]
        if let reason = stuck.reason {
            rows.append(WatchDiagnosticsExportRow(
                label: AppStrings.ios_watch_reportenvironmentrows(),
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
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_watchsnapshotrows2(), value: self.diagnosticEvidenceText(input)),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_watchsnapshotrows6(), value: payload.map { self.availabilityText($0.watchAppMarketingVersion) } ?? SourceVocabulary.watchDiagnosticsUnavailable),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_watchsnapshotrows5(), value: payload.map { self.availabilityText($0.watchAppBuild) } ?? SourceVocabulary.watchDiagnosticsUnavailable),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_watchsnapshotrows9(), value: self.buildMatchText(input)),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_watchsnapshotrows12(), value: payload.map { self.availabilityText($0.watchOSVersion) } ?? SourceVocabulary.watchDiagnosticsUnavailable),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_watchsnapshotrows7(), value: payload.map { self.percentAvailabilityText($0.watchBatteryLevel) } ?? SourceVocabulary.watchDiagnosticsUnavailable),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_watchsnapshotrows8(), value: payload.map { self.availabilityText($0.watchBatteryState) } ?? SourceVocabulary.watchDiagnosticsUnavailable),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_watchsnapshotrows10(), value: payload.map { self.boolAvailabilityText($0.watchLowPowerModeEnabled) } ?? SourceVocabulary.watchDiagnosticsUnavailable),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_watchsnapshotrows11(), value: payload.map { self.availabilityText($0.watchThermalState) } ?? SourceVocabulary.watchDiagnosticsUnavailable),
        ]
        if let payload {
            rows.append(contentsOf: [
                WatchDiagnosticsExportRow(label: SourceVocabulary.watchActivationLabel, value: payload.activationState),
                WatchDiagnosticsExportRow(label: AppStrings.ios_watch_watchsnapshotrows(), value: self.boolAvailabilityText(payload.isCompanionAppInstalled)),
                WatchDiagnosticsExportRow(label: SourceVocabulary.watchReachableLabel, value: self.booleanText(payload.isReachable)),
                WatchDiagnosticsExportRow(label: AppStrings.ios_watch_watchsnapshotrows3(), value: self.boolAvailabilityText(payload.iOSDeviceNeedsUnlockAfterRebootForReachability)),
                WatchDiagnosticsExportRow(label: AppStrings.ios_watch_watchsnapshotrows4(), value: self.booleanText(payload.hasContentPending)),
            ])
        }
        return rows
    }

    nonisolated static func sessionHistoryRows(input: WatchPipelineInput) -> [WatchDiagnosticsExportRow] {
        let labels = [
            AppStrings.ios_watch_labels3(),
            AppStrings.ios_watch_labels(),
            AppStrings.ios_watch_labels2(),
            AppStrings.ios_watch_sessionhistoryrows11(),
        ]
        let values: [String]
        let entries: [WatchCaptureSessionHistoryEntry]
        switch input.phoneSessionHistory {
        case let .available(history):
            values = [
                "\(history.retainedCount)",
                AppStrings.ios_watch_values("\(history.retentionDays)"),
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
        let terminalLabel: String
        switch entry.terminalDisposition {
        case .inferredStoppedItself:
            terminalLabel = AppStrings.ios_presentation_watchpipelinereducer_n11()
        case .ownerStopped, .detectedStoppedItself, .none:
            terminalLabel = AppStrings.ios_presentation_watchpipelinereducer_n12()
        }

        var rows: [WatchDiagnosticsExportRow] = [
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_watchdiagnosticsexportrow(), value: AppStrings.ios_watch_sessionhistoryrows16_native("\(index)", "\(total)")),
            WatchDiagnosticsExportRow(label: AppStrings.ios_tunnel_phase4(), value: self.dateWithAgeText(entry.startedAt, now: now)),
            WatchDiagnosticsExportRow(label: terminalLabel, value: self.optionalDateWithAgeText(entry.terminalAt, now: now)),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_sessionhistoryrows4(), value: self.optionalDateWithAgeText(entry.lastObservedAt, now: now)),
        ]

        if entry.terminalDisposition == .inferredStoppedItself,
           let lastObservedAt = entry.lastObservedAt,
           let terminalAt = entry.terminalAt {
            let gap = terminalAt.timeIntervalSince(lastObservedAt)
            rows.append(WatchDiagnosticsExportRow(label: AppStrings.ios_watch_sessionhistoryrows3(), value: self.secondsText(gap)))
        }

        rows.append(contentsOf: [
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_sessionhistoryrows5(), value: self.optionalDateWithAgeText(entry.lastVerifiedAudioAt, now: now)),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_sessionhistoryrows8(), value: "\(entry.terminalReason?.rawValue ?? SourceVocabulary.watchDiagnosticsNotProvided) / \(entry.terminalDisposition?.rawValue ?? SourceVocabulary.watchDiagnosticsNotProvided)"),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_sessionhistoryrows12(), value: entry.startRefusalReason?.rawValue ?? AppStrings.ios_presentation_watchpipelinereducer_n16()),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_sessionhistoryrows2(), value: "\(self.optionalPercentText(entry.batteryLevelAtEnd)) / \(entry.batteryStateAtEnd ?? SourceVocabulary.watchDiagnosticsNotProvided)"),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_sessionhistoryrows7(), value: self.optionalBooleanText(entry.lowPowerModeEnabledAtEnd)),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_sessionhistoryrows13(), value: entry.thermalStateAtEnd ?? SourceVocabulary.watchDiagnosticsNotProvided),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_sessionhistoryrows(), value: entry.lastAudioCurrentTime.map { self.secondsText($0) } ?? SourceVocabulary.watchDiagnosticsNotProvided),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_sessionhistoryrows14(), value: entry.zeroAudioCurrentTimeObservationCount.map(String.init) ?? SourceVocabulary.watchDiagnosticsNotProvided),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_sessionhistoryrows10(), value: "\(entry.segmentsProduced)"),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_sessionhistoryrows9(), value: entry.persistenceAdvisory?.rawValue ?? AppStrings.ios_presentation_watchpipelinereducer_n19()),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_sessionhistoryrows6(), value: entry.locationAdvisory?.rawValue ?? AppStrings.ios_presentation_watchpipelinereducer_n20())
        ])
        return rows
    }

    nonisolated static func watchRetentionRows(input: WatchPipelineInput) -> [WatchDiagnosticsExportRow] {
        let classificationReport = self.classifyRelayIdentities(input)
        guard let payload = input.watchDiagnostics.payload else {
            return [
                WatchDiagnosticsExportRow(label: SourceVocabulary.watchDiagnosticsRelayAssessmentLabel, value: self.relayAssessmentText(input)),
                WatchDiagnosticsExportRow(label: AppStrings.ios_watch_watchretentionrows4(), value: input.watchDiagnostics.unavailableReason ?? SourceVocabulary.watchDiagnosticsUnavailable),
            ] + self.classificationDenominatorRows(classificationReport)
        }

        var rows = [
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchDiagnosticsRelayAssessmentLabel, value: self.relayAssessmentText(input))
        ]

        switch payload.manifestSummary {
        case let .available(summary):
            rows.append(contentsOf: [
                WatchDiagnosticsExportRow(label: AppStrings.ios_watch_watchretentionrows6(), value: self.manifestCountsText(summary.counts)),
                // How long the watch's accumulated hear-back clock has run for the
                // current confirming (delivered, unacked) backlog. The auto-retry
                // that requeues a stuck delivered segment only evaluates this clock
                // when a relay drain pass runs (app launch, a new segment, a
                // connectivity activation/reachability change, or a durable ACK) —
                // there is no periodic timer, so this can sit well past its own
                // threshold between those events. 0s here (with delivered > 0 above)
                // means the clock isn't currently accumulating at all.
                WatchDiagnosticsExportRow(
                    label: AppStrings.ios_watch_watchretentionrows3(),
                    value: self.secondsText(input.watchStatus?.confirmingHearBackSeconds ?? 0)
                ),
                WatchDiagnosticsExportRow(label: AppStrings.ios_watch_watchretentionrows10(), value: self.originalFileCountsText(summary.originalAudioFileCounts)),
                WatchDiagnosticsExportRow(label: AppStrings.ios_watch_watchretentionrows13(), value: self.int64AvailabilityText(summary.retainedSourceBytes)),
                WatchDiagnosticsExportRow(label: AppStrings.ios_watch_watchretentionrows8(), value: self.dateAvailabilityText(summary.oldestActiveEnqueuedAt, now: input.now)),
                WatchDiagnosticsExportRow(label: AppStrings.ios_watch_watchretentionrows9(), value: self.intervalAvailabilityText(summary.oldestActiveEnqueueAgeSeconds)),
            ])
        case let .unavailable(reason):
            rows.append(WatchDiagnosticsExportRow(label: AppStrings.ios_watch_watchretentionrows7(), value: reason))
        }

        switch payload.lastFacts {
        case let .available(lastFacts):
            rows.append(contentsOf: self.lastFactRows(lastFacts, now: input.now))
        case let .unavailable(reason):
            rows.append(WatchDiagnosticsExportRow(label: AppStrings.ios_watch_lastfacts(), value: reason))
        }

        switch payload.appleQueue {
        case let .available(queue):
            rows.append(contentsOf: [
                WatchDiagnosticsExportRow(label: AppStrings.ios_watch_watchretentionrows(), value: "\(queue.outstandingFileTransferCount)"),
                WatchDiagnosticsExportRow(label: AppStrings.ios_watch_watchretentionrows12(), value: self.reconciliationText(queue.reconciliation)),
                WatchDiagnosticsExportRow(label: SourceVocabulary.watchDiagnosticsWatchUserInfoQueueLabel, value: "\(queue.outstandingUserInfoTransferCountWatchToPhone)"),
                WatchDiagnosticsExportRow(label: AppStrings.ios_watch_watchretentionrows5(), value: "\(queue.exactObservationCountBeforeCompaction)"),
            ])
        case let .unavailable(reason):
            rows.append(WatchDiagnosticsExportRow(label: AppStrings.ios_watch_watchretentionrows2(), value: reason))
        }

        rows.append(contentsOf: self.classificationDenominatorRows(classificationReport))
        for (index, classification) in classificationReport.classifications.enumerated() {
            rows.append(WatchDiagnosticsExportRow(
                label: AppStrings.ios_frame_watchpipelinereducer_n814("\(SourceVocabulary.watchDiagnosticsVisibleActiveClassificationLabel)", "\(index + 1)"),
                value: self.classificationText(classification)
            ))
        }

        let staleSnapshotAge = self.staleWatchSnapshotAge(input)
        for (index, observation) in payload.observedFileTransfers.enumerated() {
            rows.append(WatchDiagnosticsExportRow(
                label: AppStrings.ios_watch_watchretentionrows11("\(index + 1)"),
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
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_iphonereceiptrows(), value: self.optionalAgeText(input.oldestNonTerminalReceivedAt, now: input.now)),
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
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_journalhandoffrows3(), value: "\(max(0, input.pendingCount))"),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_journalhandoffrows(), value: "\(max(0, input.failedCount))"),
            WatchDiagnosticsExportRow(label: AppStrings.ios_watch_journalhandoffrows2(), value: "\(max(0, input.inFlightCount))"),
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchHandedToJournalLabel, value: "\(max(0, input.lifetimeHanded))"),
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchLastSyncDetailLabel, value: self.lastSyncText(input.lastUploadAt, now: input.now)),
            WatchDiagnosticsExportRow(label: SourceVocabulary.watchLastUploadErrorLabel, value: self.uploadErrorText(
                WatchTransferFailureFormatter.exportSafeText(input.lastUploadError),
                at: input.lastUploadError == nil ? nil : input.lastUploadErrorAt,
                now: input.now
            )),
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
            AppStrings.ios_watch_parts3("\(classification.segmentID.uuidString)"),
            AppStrings.ios_watch_parts2("\(self.phoneOutcomeText(classification.phoneOutcome))"),
        ]
        parts.append(AppStrings.ios_watch_classificationtext("\(self.relationText(classification.observation.relation))"))
        if let sourceAssessment = classification.sourceAssessment {
            parts.append(AppStrings.ios_watch_classificationtext8("\(sourceAssessment.rawValue)"))
        }
        parts.append(AppStrings.ios_watch_classificationtext4("\(self.originalFileText(classification.observation.originalAudioFile))"))
        parts.append(AppStrings.ios_watch_classificationtext5("\(self.originalFileText(classification.observation.originalLocationFile))"))
        parts.append(AppStrings.ios_watch_classificationtext7("\(self.boolAvailabilityText(classification.observation.relayBundlePresent))"))
        parts.append(AppStrings.ios_watch_classificationtext6("\(self.int64AvailabilityText(classification.observation.relayBundleBytes))"))
        parts.append(AppStrings.ios_watch_classificationtext2("\(self.collectionResolutionText(classification.observation.collectionResolution))"))
        parts.append(AppStrings.ios_watch_classificationtext3("\(self.ledgerText(classification))"))
        if let ledgerEntry = classification.ledgerEntry {
            parts.append(contentsOf: self.ledgerTimestampParts(ledgerEntry))
        }
        return AppStrings.joinedSemicolon(parts)
    }

    nonisolated static func phoneOutcomeText(_ outcome: WatchRelayPhoneOutcome) -> String {
        switch outcome {
        case let .alreadyHanded(ackQueued):
            return AppStrings.ios_watch_phoneoutcometext("\(self.booleanText(ackQueued))")
        case .receivedStaged:
            return AppStrings.ios_watch_phoneoutcometext3()
        case .terminalDropped:
            return AppStrings.ios_watch_phoneoutcometext4()
        case .ledgerAbsent:
            return AppStrings.ios_watch_notpresentinretainedphoneledger()
        case .ledgerUnavailable:
            return AppStrings.ios_watch_phoneoutcometext2()
        }
    }

    nonisolated static func originalFileText(
        _ availability: DiagnosticAvailability<WatchRelayOriginalFileFact>
    ) -> String {
        switch availability {
        case let .available(fact):
            let byteText = fact.byteCount.map { "\($0)" } ?? SourceVocabulary.watchDiagnosticsNotProvided
            return AppStrings.ios_watch_originalfiletext("\(fact.state.rawValue)", "\(byteText)")
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
            return AppStrings.ios_watch_notpresentinretainedphoneledger()
        case .ledgerUnavailable:
            return SourceVocabulary.watchDiagnosticsUnavailable
        case .alreadyHanded, .receivedStaged, .terminalDropped:
            return SourceVocabulary.watchDiagnosticsNotProvided
        }
    }

    nonisolated static func ledgerTimestampParts(_ entry: WatchSegmentLedgerEntrySnapshot) -> [String] {
        var parts: [String] = []
        if let receivedAt = entry.receivedAt {
            parts.append(AppStrings.ios_watch_ledgertimestampparts6("\(self.iso8601Text(receivedAt))"))
        }
        if let receivedAgeSeconds = entry.receivedAgeSeconds {
            parts.append(AppStrings.ios_watch_ledgertimestampparts5("\(self.secondsText(receivedAgeSeconds))"))
        }
        if let handedAt = entry.handedAt {
            parts.append(AppStrings.ios_watch_ledgertimestampparts4("\(self.iso8601Text(handedAt))"))
        }
        if let handedAgeSeconds = entry.handedAgeSeconds {
            parts.append(AppStrings.ios_watch_ledgertimestampparts3("\(self.secondsText(handedAgeSeconds))"))
        }
        if let droppedAt = entry.droppedAt {
            parts.append(AppStrings.ios_watch_ledgertimestampparts2("\(self.iso8601Text(droppedAt))"))
        }
        if let droppedAgeSeconds = entry.droppedAgeSeconds {
            parts.append(AppStrings.ios_watch_ledgertimestampparts("\(self.secondsText(droppedAgeSeconds))"))
        }
        return parts
    }

    nonisolated static func relayAssessmentText(_ input: WatchPipelineInput) -> String {
        guard let payload = input.watchDiagnostics.payload else {
            let reason = input.watchDiagnostics.unavailableReason ?? SourceVocabulary.watchDiagnosticsUnavailable
            if reason == WatchRelayDiagnosticsEnvelopeReason.malformed {
                return AppStrings.ios_watch_relayassessmenttext5()
            }
            if reason == WatchRelayDiagnosticsEnvelopeReason.unsupportedVersion {
                return AppStrings.ios_watch_relayassessmenttext8()
            }
            if reason == WatchRelayDiagnosticsEnvelopeReason.publicationFailed
                || reason == WatchRelayDiagnosticsEnvelopeReason.encodeFailed {
                return AppStrings.ios_watch_relayassessmenttext9()
            }
            return AppStrings.ios_watch_relayassessmenttext7("\(reason)")
        }

        if self.staleWatchSnapshotAge(input) != nil {
            return AppStrings.ios_watch_relayassessmenttext6()
        }

        guard case let .available(manifestSummary) = payload.manifestSummary else {
            let reason = payload.manifestSummary.unavailableReason ?? SourceVocabulary.watchDiagnosticsUnavailable
            return AppStrings.ios_watch_relayassessmenttext4("\(reason)")
        }
        guard manifestSummary.activeBacklogCount > 0 else {
            return AppStrings.ios_watch_relayassessmenttext12()
        }

        if case let .available(queue) = payload.appleQueue {
            if queue.reconciliation.duplicate > 0 {
                return AppStrings.ios_watch_relayassessmenttext10()
            }
            if queue.reconciliation.orphaned > 0 {
                return AppStrings.ios_watch_relayassessmenttext13()
            }
            if queue.reconciliation.unparseable > 0 {
                return AppStrings.ios_watch_relayassessmenttext16()
            }
        }

        if case let .available(lastFacts) = payload.lastFacts,
           let failure = lastFacts.lastStructuredFailure,
           self.age(of: failure.time, now: input.now).map({ $0 <= self.relayStuckThreshold }) == true {
            return AppStrings.ios_watch_relayassessmenttext15("\(failure.domain)", "\(failure.code)", "\(WatchTransferFailureFormatter.redactedDescription(failure.boundedRedactedDescription))")
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
                return AppStrings.ios_watch_relayassessmenttext()
            }
            if matching.contains(where: { observation in
                guard case let .available(progress) = observation.progress else { return false }
                return progress.isIndeterminate
            }) {
                return AppStrings.ios_watch_relayassessmenttext2()
            }
            return AppStrings.ios_watch_relayassessmenttext3()
        }

        if isOld {
            return AppStrings.ios_watch_relayassessmenttext14()
        }
        return AppStrings.ios_watch_relayassessmenttext11()
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
            return AppStrings.ios_watch_diagnosticevidencetext2("\(self.relativeText(secondsAgo: claimAge))")
        }
        return AppStrings.ios_watch_diagnosticevidencetext("\(self.relativeText(secondsAgo: claimAge))")
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
            rows.append(WatchDiagnosticsExportRow(label: AppStrings.ios_watch_lastfactrows(), value: self.factCounterText(fact, now: now)))
        }
        if let fact = facts.lastTransferCompletion {
            rows.append(WatchDiagnosticsExportRow(label: AppStrings.ios_watch_lastfactrows2(), value: self.transferCompletionText(fact, now: now)))
        }
        if let failure = facts.lastStructuredFailure {
            rows.append(WatchDiagnosticsExportRow(label: AppStrings.ios_watch_lastfactrows3(), value: self.structuredFailureText(failure, now: now)))
        }
        if let fact = facts.lastDurableACK {
            rows.append(WatchDiagnosticsExportRow(label: AppStrings.ios_watch_lastfactrows6(), value: self.factCounterText(fact, now: now)))
        }
        if let fact = facts.lastQueueReconciliationObservation {
            rows.append(WatchDiagnosticsExportRow(label: AppStrings.ios_watch_lastfactrows7(), value: self.queueReconciliationText(fact, now: now)))
        }
        if let fact = facts.lastBackgroundWakeCompletion {
            rows.append(WatchDiagnosticsExportRow(label: AppStrings.ios_watch_lastfactrows4(), value: self.backgroundWakeText(fact, now: now)))
        }
        if let fact = facts.lastBackgroundWakeDeadline {
            rows.append(WatchDiagnosticsExportRow(label: AppStrings.ios_watch_lastfactrows5(), value: self.backgroundWakeText(fact, now: now)))
        }
        if rows.isEmpty {
            rows.append(WatchDiagnosticsExportRow(label: AppStrings.ios_watch_lastfacts(), value: AppStrings.ios_watch_lastfactrows8()))
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
        return AppStrings.joinedSemicolon([
            AppStrings.ios_watch_parts3("\(segment)"),
            AppStrings.ios_watch_observationtext8("\(self.relationText(observation.relation))"),
            AppStrings.ios_watch_observationtext5("\(observation.idState.rawValue)"),
            AppStrings.ios_watch_observationtext6(AppStrings.ios_frame_watchpipelinereducer_n1213("\(observation.appManifestState ?? SourceVocabulary.watchDiagnosticsUnavailable)")),
            AppStrings.ios_watch_observationtext7("\(self.intervalAvailabilityText(observation.appOwnedEnqueueAgeSeconds))"),
            AppStrings.ios_watch_observationtext2("\(self.attemptIDText(observation))"),
            AppStrings.ios_watch_observationtext3("\(self.attemptStartedText(observation))"),
            AppStrings.ios_watch_observationtext4("\(self.attemptAgeText(observation))"),
            AppStrings.ios_watch_observationtext10("\(self.int64AvailabilityText(observation.appOwnedSourceBytes))"),
            AppStrings.ios_watch_observationtext11("\(self.boolAvailabilityText(observation.sourcePresent))"),
            AppStrings.ios_watch_observationtext12("\(transferring)"),
            progress,
            AppStrings.ios_watch_observationtext("\(self.iso8601Text(observation.asOf))"),
        ])
    }

    nonisolated static func attemptIDText(_ observation: WatchRelayTransferObservation) -> String {
        switch observation.attemptIDState {
        case .parseable:
            return observation.attemptID?.uuidString ?? SourceVocabulary.watchDiagnosticsUnavailable
        case .missing:
            return AppStrings.ios_watch_legacynotprovided()
        case .unparseable:
            return AppStrings.ios_presentation_watchpipelinereducer_n93()
        }
    }

    nonisolated static func attemptStartedText(_ observation: WatchRelayTransferObservation) -> String {
        switch observation.attemptStartedAtState {
        case .parseable:
            return observation.attemptStartedAt.map(self.iso8601Text) ?? SourceVocabulary.watchDiagnosticsUnavailable
        case .missing:
            return AppStrings.ios_watch_legacynotprovided()
        case .unparseable:
            return AppStrings.ios_presentation_watchpipelinereducer_n94()
        }
    }

    nonisolated static func attemptAgeText(_ observation: WatchRelayTransferObservation) -> String {
        guard observation.attemptStartedAtState == .parseable,
              let startedAt = observation.attemptStartedAt
        else {
            return observation.attemptStartedAtState == .unparseable
                ? AppStrings.ios_presentation_watchpipelinereducer_n95()
                : AppStrings.ios_watch_legacynotprovided()
        }
        return self.secondsText(max(0, observation.asOf.timeIntervalSince(startedAt)))
    }

    nonisolated static func staleProgressText(age: TimeInterval) -> String {
        AppStrings.ios_watch_staleprogresstext("\(self.relativeText(secondsAgo: age))")
    }

    nonisolated static func progressText(_ availability: DiagnosticAvailability<WatchConnectivityProgressSnapshot>) -> String {
        switch availability {
        case let .unavailable(reason):
            return AppStrings.ios_watch_progresstext2("\(WatchTransferFailureFormatter.redactedDescription(reason))")
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
            return AppStrings.ios_watch_progresstext("\(fraction)", "\(progress.completedUnitCount)", "\(progress.totalUnitCount)", "\(self.booleanText(progress.isFinished))", "\(self.booleanText(progress.isCancelled))", "\(throughput)", "\(eta)", "\(kind)")
        }
    }

    nonisolated static func manifestCountsText(_ counts: WatchRelayManifestCounts) -> String {
        AppStrings.ios_watch_manifestcountstext_native("\(counts.captured)", "\(counts.persisted)", "\(counts.finalized)", "\(counts.queued)", "\(counts.transferring)", "\(counts.delivered)", "\(counts.acked)", "\(counts.safeToDelete)")
    }

    nonisolated static func reconciliationText(_ counts: WatchRelayReconciliationCounts) -> String {
        AppStrings.ios_watch_reconciliationtext("\(counts.matched)", "\(counts.appActiveNotObserved)", "\(counts.duplicate)", "\(counts.orphaned)", "\(counts.unparseable)")
    }

    nonisolated static func factCounterText(_ fact: WatchRelayFactCounter, now: Date) -> String {
        var parts = ["\(self.dateWithAgeText(fact.at, now: now))", AppStrings.ios_watch_parts_native("\(fact.count)")]
        if let segmentID = fact.segmentID {
            parts.append(AppStrings.ios_watch_parts3("\(segmentID.uuidString)"))
        }
        return AppStrings.joinedSemicolon(parts)
    }

    nonisolated static func transferCompletionText(_ fact: WatchRelayTransferCompletionFact, now: Date) -> String {
        AppStrings.ios_watch_transfercompletiontext("\(self.dateWithAgeText(fact.at, now: now))", "\(fact.segmentID.uuidString)", "\(self.booleanText(fact.succeeded))", "\(fact.successCount)", "\(fact.failureCount)")
    }

    nonisolated static func structuredFailureText(_ failure: WatchTransferStructuredFailure, now: Date) -> String {
        AppStrings.ios_watch_structuredfailuretext("\(self.dateWithAgeText(failure.time, now: now))", "\(failure.domain)", "\(failure.code)", "\(WatchTransferFailureFormatter.redactedDescription(failure.boundedRedactedDescription))")
    }

    nonisolated static func queueReconciliationText(_ fact: WatchRelayQueueReconciliationFact, now: Date) -> String {
        AppStrings.ios_watch_queuereconciliationtext("\(self.dateWithAgeText(fact.at, now: now))", "\(self.reconciliationText(fact.counts))", "\(fact.observedFileTransferCount)", "\(fact.activeManifestCount)")
    }

    nonisolated static func backgroundWakeText(_ fact: WatchRelayBackgroundWakeFact, now: Date) -> String {
        AppStrings.ios_watch_backgroundwaketext("\(self.dateWithAgeText(fact.at, now: now))", "\(fact.reason)", "\(fact.heldTaskCount)", "\(fact.completedTaskCount)", "\(fact.deadlineCount)")
    }

    nonisolated static func availabilityText(_ availability: DiagnosticAvailability<String>) -> String {
        switch availability {
        case let .available(value):
            return WatchTransferFailureFormatter.redactedDescription(value)
        case let .unavailable(reason):
            return AppStrings.ios_frame_watchpipelinereducer_n1320("\(SourceVocabulary.watchDiagnosticsUnavailable)", "\(WatchTransferFailureFormatter.redactedDescription(reason))")
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
            return AppStrings.ios_frame_watchpipelinereducer_n1320("\(SourceVocabulary.watchDiagnosticsUnavailable)", "\(WatchTransferFailureFormatter.redactedDescription(reason))")
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
        AppStrings.ios_frame_watchpipelinereducer_n1320("\(SourceVocabulary.watchDiagnosticsUnavailable)", "\(WatchTransferFailureFormatter.redactedDescription(reason))")
    }

    nonisolated static func percentAvailabilityText(_ availability: DiagnosticAvailability<Double>) -> String {
        switch availability {
        case let .available(value):
            return String(format: "%.0f%%", value * 100)
        case let .unavailable(reason):
            return AppStrings.ios_frame_watchpipelinereducer_n1320("\(SourceVocabulary.watchDiagnosticsUnavailable)", "\(WatchTransferFailureFormatter.redactedDescription(reason))")
        }
    }

    nonisolated static func intervalAvailabilityText(_ availability: DiagnosticAvailability<TimeInterval?>) -> String {
        switch availability {
        case let .available(value):
            guard let value else { return SourceVocabulary.watchDiagnosticsNotProvided }
            return self.secondsText(value)
        case let .unavailable(reason):
            return AppStrings.ios_frame_watchpipelinereducer_n1320("\(SourceVocabulary.watchDiagnosticsUnavailable)", "\(WatchTransferFailureFormatter.redactedDescription(reason))")
        }
    }

    nonisolated static func dateAvailabilityText(_ availability: DiagnosticAvailability<Date?>, now: Date) -> String {
        switch availability {
        case let .available(value):
            guard let value else { return SourceVocabulary.watchDiagnosticsNotProvided }
            return self.dateWithAgeText(value, now: now)
        case let .unavailable(reason):
            return AppStrings.ios_frame_watchpipelinereducer_n1320("\(SourceVocabulary.watchDiagnosticsUnavailable)", "\(WatchTransferFailureFormatter.redactedDescription(reason))")
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
        return AppStrings.ios_frame_watchpipelinereducer_n1320("\(self.iso8601Text(date))", "\(self.relativeText(secondsAgo: age))")
    }

    nonisolated static func iso8601Text(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    nonisolated static func secondsText(_ seconds: TimeInterval) -> String {
        AppStrings.ios_presentation_watchpipelinereducer_n153("\(max(0, Int(exactly: seconds.rounded()) ?? 0))")
    }

    nonisolated static func stuck(_ input: WatchPipelineInput) -> WatchPipelineStuck {
        if self.isOrphanStuck(input) {
            return .orphan
        }
        if self.isHandoffStuck(input) {
            return .handoff
        }
        if self.isWatchAppUpdateWaiting(input) {
            return .watchAppUpdate
        }
        if self.isRelayStuck(input) {
            return .relay
        }
        return .none
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

    /// An upload error carries its age in this page's own relative wording.
    nonisolated static func uploadErrorText(_ text: String, at: Date?, now: Date) -> String {
        guard let age = self.age(of: at, now: now) else { return text }
        return AppStrings.ios_frame_watchpipelinereducer_n1320("\(text)", "\(self.relativeText(secondsAgo: age))")
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

    /// Owner-facing word for a published capture phase. The rawValue is wire state
    /// carried between the watch and the phone, so it is mapped here rather than renamed.
    nonisolated static func phaseText(_ phase: WatchStatusContext.Phase) -> String {
        switch phase {
        case .observing:
            SourceVocabulary.watchHeadlineListening
        case .idle:
            SourceVocabulary.watchHeadlineOff
        case .stopping:
            SourceVocabulary.watchHeadlineStopping
        }
    }

    /// Owner-facing wording for how an app-side record relates to Apple's transfer queue.
    /// The rawValue rides the diagnostics envelope, so it is mapped rather than renamed.
    nonisolated static func relationText(_ relation: WatchRelayObservationRelation) -> String {
        switch relation {
        case .matched:
            AppStrings.ios_presentation_watchpipelinereducer_n157()
        case .appActiveNotObserved:
            AppStrings.ios_presentation_watchpipelinereducer_n158()
        case .duplicate:
            AppStrings.ios_presentation_watchpipelinereducer_n159()
        case .orphaned:
            AppStrings.ios_presentation_watchpipelinereducer_n160()
        case .unparseable:
            AppStrings.ios_presentation_watchpipelinereducer_n161()
        }
    }

    nonisolated static func watchStatusText(_ status: WatchStatusContext?, now: Date) -> String {
        guard let status else {
            return SourceVocabulary.watchDetailNone
        }
        var parts = [
            self.phaseText(status.phase),
            self.relativeText(secondsAgo: self.age(of: status.asOf, now: now) ?? 0),
        ]
        if status.audioTerminalDisposition == .ownerStopped {
            parts.append(AppStrings.ios_frame_watchpipelinereducer_n622("\(SourceVocabulary.watchStatusAudioOutcomeLabel)", "\(SourceVocabulary.watchStatusAudioOutcomeOwnerStopped)"))
        } else if let copy = WatchNoticeCopy(
            terminalReason: status.audioTerminalReason,
            terminalDisposition: status.audioTerminalDisposition
        ) {
            parts.append(AppStrings.ios_frame_watchpipelinereducer_n622("\(SourceVocabulary.watchStatusAudioOutcomeLabel)", "\(copy.title)"))
        }
        return AppStrings.joinedMiddleDot(parts)
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
