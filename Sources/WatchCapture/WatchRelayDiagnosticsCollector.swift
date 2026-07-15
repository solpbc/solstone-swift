// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import WatchConnectivity
#if os(watchOS)
import WatchKit
#endif

nonisolated struct WatchRelayDiagnosticsEnvironmentSnapshot: Codable, Equatable, Sendable {
    let watchAppMarketingVersion: DiagnosticAvailability<String>
    let watchAppBuild: DiagnosticAvailability<String>
    let watchOSVersion: DiagnosticAvailability<String>
    let watchBatteryLevel: DiagnosticAvailability<Double>
    let watchBatteryState: DiagnosticAvailability<String>
    let watchLowPowerModeEnabled: DiagnosticAvailability<Bool>
    let watchThermalState: DiagnosticAvailability<String>
}

nonisolated enum WatchBatteryStateReading: String, Equatable, Sendable {
    case unknown
    case unplugged
    case charging
    case full
}

@MainActor
protocol WatchBatteryDevice: AnyObject {
    var isBatteryMonitoringEnabled: Bool { get set }
    var batteryLevelReading: Float { get }
    var batteryStateReading: WatchBatteryStateReading { get }
}

@MainActor
protocol WatchRelayDiagnosticsEnvironmentProviding: AnyObject {
    func snapshot() -> WatchRelayDiagnosticsEnvironmentSnapshot
}

@MainActor
final class LiveWatchRelayDiagnosticsEnvironmentProvider: WatchRelayDiagnosticsEnvironmentProviding {
    func snapshot() -> WatchRelayDiagnosticsEnvironmentSnapshot {
        let battery = Self.watchBatterySnapshot()
        return WatchRelayDiagnosticsEnvironmentSnapshot(
            watchAppMarketingVersion: Self.bundleString("CFBundleShortVersionString"),
            watchAppBuild: Self.bundleString("CFBundleVersion"),
            watchOSVersion: Self.watchOSVersion(),
            watchBatteryLevel: battery.level,
            watchBatteryState: battery.state,
            watchLowPowerModeEnabled: .available(ProcessInfo.processInfo.isLowPowerModeEnabled),
            watchThermalState: .available(Self.thermalStateString(ProcessInfo.processInfo.thermalState))
        )
    }

    static func batterySnapshot(
        device: any WatchBatteryDevice
    ) -> (level: DiagnosticAvailability<Double>, state: DiagnosticAvailability<String>) {
        let previous = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        defer { device.isBatteryMonitoringEnabled = previous }

        let levelReading = device.batteryLevelReading
        let level: DiagnosticAvailability<Double>
        if levelReading >= 0 {
            level = .available(Double(levelReading))
        } else {
            level = .unavailable(reason: "not provided")
        }
        return (level, .available(device.batteryStateReading.rawValue))
    }
}

@MainActor
final class WatchRelayDiagnosticsCollector {
    private let storage: WatchCaptureStorage
    private let diagnosticsStore: WatchRelayDiagnosticsStore
    private let session: any WatchConnectivitySession
    private let environmentProvider: any WatchRelayDiagnosticsEnvironmentProviding

    init(
        storage: WatchCaptureStorage,
        diagnosticsStore: WatchRelayDiagnosticsStore,
        session: any WatchConnectivitySession,
        environmentProvider: any WatchRelayDiagnosticsEnvironmentProviding = LiveWatchRelayDiagnosticsEnvironmentProvider()
    ) {
        self.storage = storage
        self.diagnosticsStore = diagnosticsStore
        self.session = session
        self.environmentProvider = environmentProvider
    }

    func makeEnvelopeData(asOf: Date) -> Data? {
        let environment = self.environmentProvider.snapshot()
        let fullPayload = self.makePayload(asOf: asOf, environment: environment)
        return Self.encodeCompactedEnvelope(generatedAt: asOf, payload: fullPayload)
    }

    nonisolated static func encodeCompactedEnvelope(
        generatedAt: Date,
        payload: WatchRelayDiagnosticsPayload
    ) -> Data? {
        self._encodeCompactedEnvelope(generatedAt: generatedAt, payload: payload)
    }

    nonisolated static func unavailableEnvelopeData(generatedAt: Date, reason: String) -> Data? {
        WatchRelayDiagnosticsEnvelope.unavailableData(generatedAt: generatedAt, reason: reason)
    }

    nonisolated static func reconciliationCounts(
        activeManifestIDs: Set<UUID>,
        fileTransfers: [WatchConnectivityFileTransferSnapshot]
    ) -> WatchRelayReconciliationCounts {
        var transfersByID: [UUID: Int] = [:]
        var unparseable = 0
        for transfer in fileTransfers {
            guard transfer.idState == .parseable, let segmentID = transfer.segmentID else {
                unparseable += 1
                continue
            }
            transfersByID[segmentID, default: 0] += 1
        }

        var matched = 0
        var appActiveNotObserved = 0
        var duplicate = 0
        for id in activeManifestIDs {
            let count = transfersByID[id] ?? 0
            if count == 0 {
                appActiveNotObserved += 1
            } else if count == 1 {
                matched += 1
            } else {
                duplicate += 1
            }
        }

        let orphaned = transfersByID.reduce(into: 0) { total, pair in
            if !activeManifestIDs.contains(pair.key) {
                total += pair.value
            }
        }

        return WatchRelayReconciliationCounts(
            matched: matched,
            appActiveNotObserved: appActiveNotObserved,
            duplicate: duplicate,
            orphaned: orphaned,
            unparseable: unparseable
        )
    }
}

private extension WatchRelayDiagnosticsCollector {
    struct ActiveManifestFact {
        let entry: WatchCaptureStorage.ManifestEntry
        let sidecar: DiagnosticAvailability<WatchRelaySegmentDiagnosticsSidecar>
        let sourcePresent: DiagnosticAvailability<Bool>
    }

    func makePayload(
        asOf: Date,
        environment: WatchRelayDiagnosticsEnvironmentSnapshot
    ) -> WatchRelayDiagnosticsPayload {
        let entriesResult = Result { try self.storage.scanManifests() }
        let entries = (try? entriesResult.get()) ?? []
        let activeEntries = entries.filter { entry in
            entry.manifest.state == .queued || entry.manifest.state == .transferring
        }
        let activeFacts = activeEntries.map { entry in
            ActiveManifestFact(
                entry: entry,
                sidecar: self.diagnosticsStore.readSidecar(manifest: entry.manifest, directoryURL: entry.directoryURL),
                sourcePresent: self.sourcePresent(for: entry.manifest.id)
            )
        }
        let fileTransferSnapshots = self.session.outstandingFileTransferSnapshots
        let userInfoSnapshots = self.session.outstandingUserInfoTransferSnapshots
        let activeIDs = Set(activeEntries.map(\.manifest.id))
        let reconciliation = Self.reconciliationCounts(
            activeManifestIDs: activeIDs,
            fileTransfers: fileTransferSnapshots
        )
        let observations = self.observations(
            activeFacts: activeFacts,
            fileTransfers: fileTransferSnapshots,
            asOf: asOf
        )
        let lastFacts = self.diagnosticsStore.readSummary()
        let failureSegmentID = Self.failureSegmentID(from: lastFacts)

        let manifestSummary: DiagnosticAvailability<WatchRelayManifestSummary>
        switch entriesResult {
        case .success:
            manifestSummary = self.manifestSummary(entries: entries, activeFacts: activeFacts, asOf: asOf)
        case .failure:
            manifestSummary = .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
        }

        return WatchRelayDiagnosticsPayload(
            watchAppMarketingVersion: environment.watchAppMarketingVersion,
            watchAppBuild: environment.watchAppBuild,
            watchOSVersion: environment.watchOSVersion,
            activationState: Self.activationStateString(self.session.activationState),
            isCompanionAppInstalled: self.session.isCompanionAppInstalledForDiagnostics,
            isReachable: self.session.isReachable,
            iOSDeviceNeedsUnlockAfterRebootForReachability: self.session.iOSDeviceNeedsUnlockAfterRebootForDiagnostics,
            hasContentPending: self.session.hasContentPending,
            watchBatteryLevel: environment.watchBatteryLevel,
            watchBatteryState: environment.watchBatteryState,
            watchLowPowerModeEnabled: environment.watchLowPowerModeEnabled,
            watchThermalState: environment.watchThermalState,
            manifestSummary: manifestSummary,
            appleQueue: .available(WatchRelayAppleQueueSnapshot(
                asOf: asOf,
                outstandingFileTransferCount: fileTransferSnapshots.count,
                outstandingUserInfoTransferCountWatchToPhone: userInfoSnapshots.count,
                reconciliation: reconciliation,
                exactObservationCountBeforeCompaction: observations.count
            )),
            lastFacts: lastFacts,
            observedFileTransfers: self.orderedForCompaction(
                observations,
                activeFacts: activeFacts,
                failureSegmentID: failureSegmentID
            ),
            omittedObservationCount: 0
        )
    }

    func manifestSummary(
        entries: [WatchCaptureStorage.ManifestEntry],
        activeFacts: [ActiveManifestFact],
        asOf: Date
    ) -> DiagnosticAvailability<WatchRelayManifestSummary> {
        let counts = Self.manifestCounts(entries)
        guard !activeFacts.isEmpty else {
            return .available(WatchRelayManifestSummary(
                counts: counts,
                activeBacklogCount: 0,
                retainedSourceBytes: .available(0),
                oldestActiveEnqueuedAt: .available(nil),
                oldestActiveEnqueueAgeSeconds: .available(nil)
            ))
        }

        var sourceBytes: Int64 = 0
        var sourceBytesOverflowed = false
        var enqueueDates: [Date] = []
        for fact in activeFacts {
            guard case let .available(sidecar) = fact.sidecar,
                  let bytes = sidecar.sourceBytes,
                  let originalEnqueuedAt = sidecar.originalEnqueuedAt
            else {
                return .available(WatchRelayManifestSummary(
                    counts: counts,
                    activeBacklogCount: activeFacts.count,
                    retainedSourceBytes: .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable),
                    oldestActiveEnqueuedAt: .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable),
                    oldestActiveEnqueueAgeSeconds: .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
                ))
            }
            if !sourceBytesOverflowed {
                let (nextSourceBytes, overflow) = sourceBytes.addingReportingOverflow(bytes)
                if overflow {
                    sourceBytesOverflowed = true
                } else {
                    sourceBytes = nextSourceBytes
                }
            }
            enqueueDates.append(originalEnqueuedAt)
        }

        let oldest = enqueueDates.min()
        return .available(WatchRelayManifestSummary(
            counts: counts,
            activeBacklogCount: activeFacts.count,
            retainedSourceBytes: sourceBytesOverflowed
                ? .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
                : .available(sourceBytes),
            oldestActiveEnqueuedAt: .available(oldest),
            oldestActiveEnqueueAgeSeconds: .available(oldest.map { max(0, asOf.timeIntervalSince($0)) })
        ))
    }

    func observations(
        activeFacts: [ActiveManifestFact],
        fileTransfers: [WatchConnectivityFileTransferSnapshot],
        asOf: Date
    ) -> [WatchRelayTransferObservation] {
        let activeByID = Dictionary(uniqueKeysWithValues: activeFacts.map { ($0.entry.manifest.id, $0) })
        var observations: [WatchRelayTransferObservation] = []
        var transfersByID: [UUID: [(index: Int, transfer: WatchConnectivityFileTransferSnapshot)]] = [:]
        var firstSeenOrder: [UUID] = []
        var unparseables: [(index: Int, transfer: WatchConnectivityFileTransferSnapshot)] = []

        for (index, transfer) in fileTransfers.enumerated() {
            guard transfer.idState == .parseable,
                  let segmentID = transfer.segmentID
            else {
                unparseables.append((index, transfer))
                continue
            }
            if transfersByID[segmentID] == nil {
                firstSeenOrder.append(segmentID)
            }
            transfersByID[segmentID, default: []].append((index, transfer))
        }

        var consumedIDs = Set<UUID>()

        for fact in activeFacts {
            let id = fact.entry.manifest.id
            let matching = transfersByID[id] ?? []
            if matching.isEmpty {
                observations.append(self.observation(
                    asOf: asOf,
                    segmentID: id,
                    idState: .parseable,
                    relation: .appActiveNotObserved,
                    fact: fact,
                    transfer: nil
                ))
                continue
            }

            let relation: WatchRelayObservationRelation = matching.count == 1 ? .matched : .duplicate
            consumedIDs.insert(id)
            for (_, transfer) in matching {
                observations.append(self.observation(
                    asOf: transfer.asOf,
                    segmentID: id,
                    idState: .parseable,
                    relation: relation,
                    fact: fact,
                    transfer: transfer
                ))
            }
        }

        for id in firstSeenOrder where activeByID[id] == nil && !consumedIDs.contains(id) {
            for (_, transfer) in transfersByID[id] ?? [] {
                observations.append(self.observation(
                    asOf: transfer.asOf,
                    segmentID: id,
                    idState: .parseable,
                    relation: .orphaned,
                    fact: nil,
                    transfer: transfer
                ))
            }
        }

        for (_, transfer) in unparseables {
            observations.append(self.observation(
                asOf: transfer.asOf,
                segmentID: nil,
                idState: transfer.idState,
                relation: .unparseable,
                fact: nil,
                transfer: transfer
            ))
        }

        return observations
    }

    func observation(
        asOf: Date,
        segmentID: UUID?,
        idState: WatchRelayTransferIDState,
        relation: WatchRelayObservationRelation,
        fact: ActiveManifestFact?,
        transfer: WatchConnectivityFileTransferSnapshot?
    ) -> WatchRelayTransferObservation {
        let appOwnedEnqueueAgeSeconds: DiagnosticAvailability<TimeInterval?>
        let appOwnedSourceBytes: DiagnosticAvailability<Int64>
        let sourcePresent: DiagnosticAvailability<Bool>
        let appManifestState: String?

        if let fact {
            appManifestState = fact.entry.manifest.state.rawValue
            switch fact.sidecar {
            case let .available(sidecar):
                appOwnedEnqueueAgeSeconds = .available(sidecar.originalEnqueuedAt.map { max(0, asOf.timeIntervalSince($0)) })
                if let sourceBytes = sidecar.sourceBytes {
                    appOwnedSourceBytes = .available(sourceBytes)
                } else {
                    appOwnedSourceBytes = .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
                }
            case let .unavailable(reason):
                appOwnedEnqueueAgeSeconds = .unavailable(reason: reason)
                appOwnedSourceBytes = .unavailable(reason: reason)
            }
            sourcePresent = fact.sourcePresent
        } else {
            appManifestState = nil
            appOwnedEnqueueAgeSeconds = .unavailable(reason: "no app-active manifest")
            appOwnedSourceBytes = .unavailable(reason: "no app-active manifest")
            sourcePresent = .unavailable(reason: "no app-active manifest")
        }

        let isTransferring: DiagnosticAvailability<Bool>
        let progress: DiagnosticAvailability<WatchConnectivityProgressSnapshot>
        if let transfer {
            isTransferring = .available(transfer.isTransferring)
            progress = .available(transfer.progress)
        } else {
            isTransferring = .unavailable(reason: "not observed in Apple queue snapshot")
            progress = .unavailable(reason: "not observed in Apple queue snapshot")
        }

        return WatchRelayTransferObservation(
            asOf: asOf,
            segmentID: segmentID,
            idState: idState,
            relation: relation,
            appManifestState: appManifestState,
            appOwnedEnqueueAgeSeconds: appOwnedEnqueueAgeSeconds,
            appOwnedSourceBytes: appOwnedSourceBytes,
            sourcePresent: sourcePresent,
            isTransferring: isTransferring,
            progress: progress
        )
    }

    func sourcePresent(for id: UUID) -> DiagnosticAvailability<Bool> {
        .available(self.storage.fileWriter.fileExists(at: self.bundleURL(for: id)))
    }

    func bundleURL(for id: UUID) -> URL {
        self.storage.rootURL
            .appendingPathComponent(".relay-bundles", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).watchrelay", isDirectory: false)
    }

    func orderedForCompaction(
        _ observations: [WatchRelayTransferObservation],
        activeFacts: [ActiveManifestFact],
        failureSegmentID: UUID?
    ) -> [WatchRelayTransferObservation] {
        let activeOrder = self.activeCompactionOrder(activeFacts)
        let indexed = observations.enumerated().map { index, observation in
            (index: index, observation: observation)
        }
        return indexed.sorted { lhs, rhs in
            let lhsKey = self.compactionKey(
                observation: lhs.observation,
                index: lhs.index,
                activeOrder: activeOrder,
                failureSegmentID: failureSegmentID
            )
            let rhsKey = self.compactionKey(
                observation: rhs.observation,
                index: rhs.index,
                activeOrder: activeOrder,
                failureSegmentID: failureSegmentID
            )
            return lhsKey < rhsKey
        }.map(\.observation)
    }

    func activeCompactionOrder(_ activeFacts: [ActiveManifestFact]) -> [UUID: String] {
        var pairs: [(UUID, String)] = []
        for fact in activeFacts {
            let dateKey: String
            if case let .available(sidecar) = fact.sidecar,
               let originalEnqueuedAt = sidecar.originalEnqueuedAt {
                dateKey = Self.iso8601String(originalEnqueuedAt)
            } else {
                dateKey = "9999-12-31T23:59:59Z"
            }
            pairs.append((fact.entry.manifest.id, "\(dateKey)|\(fact.entry.manifest.id.uuidString)"))
        }
        return Dictionary(uniqueKeysWithValues: pairs)
    }

    static func failureSegmentID(from lastFacts: DiagnosticAvailability<WatchRelayLastFactsSummary>) -> UUID? {
        guard case let .available(summary) = lastFacts,
              let completion = summary.lastTransferCompletion,
              completion.succeeded == false,
              let failure = summary.lastStructuredFailure,
              failure.time == completion.at
        else {
            return nil
        }
        return completion.segmentID
    }

    func compactionKey(
        observation: WatchRelayTransferObservation,
        index: Int,
        activeOrder: [UUID: String],
        failureSegmentID: UUID?
    ) -> String {
        if let segmentID = observation.segmentID,
           let order = activeOrder[segmentID] {
            return "0|\(order)|\(index)"
        }
        if let failureSegmentID,
           observation.segmentID == failureSegmentID {
            return "1|\(failureSegmentID.uuidString)|\(index)"
        }
        if let segmentID = observation.segmentID {
            return "2|\(segmentID.uuidString)|\(index)"
        }
        return "3|\(String(format: "%06d", index))"
    }

    static func manifestCounts(_ entries: [WatchCaptureStorage.ManifestEntry]) -> WatchRelayManifestCounts {
        var counts = WatchRelayManifestCounts.zero
        for entry in entries {
            switch entry.manifest.state {
            case .captured:
                counts = WatchRelayManifestCounts(
                    captured: counts.captured + 1,
                    persisted: counts.persisted,
                    finalized: counts.finalized,
                    queued: counts.queued,
                    transferring: counts.transferring,
                    delivered: counts.delivered,
                    acked: counts.acked,
                    safeToDelete: counts.safeToDelete
                )
            case .persisted:
                counts = WatchRelayManifestCounts(
                    captured: counts.captured,
                    persisted: counts.persisted + 1,
                    finalized: counts.finalized,
                    queued: counts.queued,
                    transferring: counts.transferring,
                    delivered: counts.delivered,
                    acked: counts.acked,
                    safeToDelete: counts.safeToDelete
                )
            case .finalized:
                counts = WatchRelayManifestCounts(
                    captured: counts.captured,
                    persisted: counts.persisted,
                    finalized: counts.finalized + 1,
                    queued: counts.queued,
                    transferring: counts.transferring,
                    delivered: counts.delivered,
                    acked: counts.acked,
                    safeToDelete: counts.safeToDelete
                )
            case .queued:
                counts = WatchRelayManifestCounts(
                    captured: counts.captured,
                    persisted: counts.persisted,
                    finalized: counts.finalized,
                    queued: counts.queued + 1,
                    transferring: counts.transferring,
                    delivered: counts.delivered,
                    acked: counts.acked,
                    safeToDelete: counts.safeToDelete
                )
            case .transferring:
                counts = WatchRelayManifestCounts(
                    captured: counts.captured,
                    persisted: counts.persisted,
                    finalized: counts.finalized,
                    queued: counts.queued,
                    transferring: counts.transferring + 1,
                    delivered: counts.delivered,
                    acked: counts.acked,
                    safeToDelete: counts.safeToDelete
                )
            case .delivered:
                counts = WatchRelayManifestCounts(
                    captured: counts.captured,
                    persisted: counts.persisted,
                    finalized: counts.finalized,
                    queued: counts.queued,
                    transferring: counts.transferring,
                    delivered: counts.delivered + 1,
                    acked: counts.acked,
                    safeToDelete: counts.safeToDelete
                )
            case .acked:
                counts = WatchRelayManifestCounts(
                    captured: counts.captured,
                    persisted: counts.persisted,
                    finalized: counts.finalized,
                    queued: counts.queued,
                    transferring: counts.transferring,
                    delivered: counts.delivered,
                    acked: counts.acked + 1,
                    safeToDelete: counts.safeToDelete
                )
            case .safeToDelete:
                counts = WatchRelayManifestCounts(
                    captured: counts.captured,
                    persisted: counts.persisted,
                    finalized: counts.finalized,
                    queued: counts.queued,
                    transferring: counts.transferring,
                    delivered: counts.delivered,
                    acked: counts.acked,
                    safeToDelete: counts.safeToDelete + 1
                )
            }
        }
        return counts
    }

    static func activationStateString(_ state: WCSessionActivationState) -> String {
        switch state {
        case .activated:
            return "activated"
        case .inactive:
            return "inactive"
        case .notActivated:
            return "not activated"
        @unknown default:
            return "unknown"
        }
    }

    nonisolated static func _encodeCompactedEnvelope(
        generatedAt: Date,
        payload: WatchRelayDiagnosticsPayload
    ) -> Data? {
        let observations = payload.observedFileTransfers
        let observationCount = observations.count
        do {
            let fullData = try self.encodedEnvelopeData(
                generatedAt: generatedAt,
                payload: payload,
                observations: observations,
                retainedObservationCount: observationCount
            )
            guard fullData.count > WatchRelayDiagnosticsEnvelope.maxEncodedByteCount else {
                return fullData
            }

            let emptyData = try self.encodedEnvelopeData(
                generatedAt: generatedAt,
                payload: payload,
                observations: observations,
                retainedObservationCount: 0
            )
            guard emptyData.count <= WatchRelayDiagnosticsEnvelope.maxEncodedByteCount else {
                return self.unavailableEnvelopeData(
                    generatedAt: generatedAt,
                    reason: WatchRelayDiagnosticsEnvelopeReason.publicationFailed
                )
            }

            var low = 0
            var lowData = emptyData
            var high = observationCount
            while high - low > 1 {
                let mid = low + (high - low) / 2
                let data = try self.encodedEnvelopeData(
                    generatedAt: generatedAt,
                    payload: payload,
                    observations: observations,
                    retainedObservationCount: mid
                )
                if data.count <= WatchRelayDiagnosticsEnvelope.maxEncodedByteCount {
                    low = mid
                    lowData = data
                } else {
                    high = mid
                }
            }
            return lowData
        } catch {
            return self.unavailableEnvelopeData(
                generatedAt: generatedAt,
                reason: WatchRelayDiagnosticsEnvelopeReason.encodeFailed
            )
        }
    }

    nonisolated static func encodedEnvelopeData(
        generatedAt: Date,
        payload: WatchRelayDiagnosticsPayload,
        observations: [WatchRelayTransferObservation],
        retainedObservationCount: Int
    ) throws -> Data {
        let retainedObservations = Array(observations.prefix(retainedObservationCount))
        let compacted = self.payload(
            payload,
            observations: retainedObservations,
            omittedObservationCount: observations.count - retainedObservationCount
        )
        return try WatchRelayDiagnosticsEnvelope.makeEncoder().encode(WatchRelayDiagnosticsEnvelope(
            generatedAt: generatedAt,
            diagnostics: .available(compacted)
        ))
    }

    nonisolated static func payload(
        _ payload: WatchRelayDiagnosticsPayload,
        observations: [WatchRelayTransferObservation],
        omittedObservationCount: Int
    ) -> WatchRelayDiagnosticsPayload {
        WatchRelayDiagnosticsPayload(
            watchAppMarketingVersion: payload.watchAppMarketingVersion,
            watchAppBuild: payload.watchAppBuild,
            watchOSVersion: payload.watchOSVersion,
            activationState: payload.activationState,
            isCompanionAppInstalled: payload.isCompanionAppInstalled,
            isReachable: payload.isReachable,
            iOSDeviceNeedsUnlockAfterRebootForReachability: payload.iOSDeviceNeedsUnlockAfterRebootForReachability,
            hasContentPending: payload.hasContentPending,
            watchBatteryLevel: payload.watchBatteryLevel,
            watchBatteryState: payload.watchBatteryState,
            watchLowPowerModeEnabled: payload.watchLowPowerModeEnabled,
            watchThermalState: payload.watchThermalState,
            manifestSummary: payload.manifestSummary,
            appleQueue: payload.appleQueue,
            lastFacts: payload.lastFacts,
            observedFileTransfers: observations,
            omittedObservationCount: omittedObservationCount
        )
    }

    static func iso8601String(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

private extension LiveWatchRelayDiagnosticsEnvironmentProvider {
    static func bundleString(_ key: String) -> DiagnosticAvailability<String> {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty
        else {
            return .unavailable(reason: "not provided")
        }
        return .available(value)
    }

    static func thermalStateString(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }

    static func watchOSVersion() -> DiagnosticAvailability<String> {
        #if os(watchOS)
        return .available(WKInterfaceDevice.current().systemVersion)
        #else
        return .unavailable(reason: "not available off watch")
        #endif
    }

    static func watchBatterySnapshot() -> (level: DiagnosticAvailability<Double>, state: DiagnosticAvailability<String>) {
        #if os(watchOS)
        return LiveWatchRelayDiagnosticsEnvironmentProvider.batterySnapshot(
            device: WatchKitBatteryDevice(device: WKInterfaceDevice.current())
        )
        #else
        return (
            .unavailable(reason: "not available off watch"),
            .unavailable(reason: "not available off watch")
        )
        #endif
    }
}

#if os(watchOS)
@MainActor
private final class WatchKitBatteryDevice: WatchBatteryDevice {
    private let device: WKInterfaceDevice

    init(device: WKInterfaceDevice) {
        self.device = device
    }

    var isBatteryMonitoringEnabled: Bool {
        get {
            self.device.isBatteryMonitoringEnabled
        }
        set {
            self.device.isBatteryMonitoringEnabled = newValue
        }
    }

    var batteryLevelReading: Float {
        self.device.batteryLevel
    }

    var batteryStateReading: WatchBatteryStateReading {
        switch self.device.batteryState {
        case .unknown:
            return .unknown
        case .unplugged:
            return .unplugged
        case .charging:
            return .charging
        case .full:
            return .full
        @unknown default:
            return .unknown
        }
    }
}
#endif
