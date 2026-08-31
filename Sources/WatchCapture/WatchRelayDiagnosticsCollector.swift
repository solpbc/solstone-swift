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
    private let paths: WatchCaptureStoragePaths
    private let storageActor: WatchCaptureStorageActor
    private let session: any WatchConnectivitySession
    private let environmentProvider: any WatchRelayDiagnosticsEnvironmentProviding
    private let signposter: any WatchSignposting
    private let diagnosticsEncoder: WatchRelayDiagnosticsEncoder

    init(
        paths: WatchCaptureStoragePaths,
        storageActor: WatchCaptureStorageActor,
        session: any WatchConnectivitySession,
        environmentProvider: any WatchRelayDiagnosticsEnvironmentProviding = LiveWatchRelayDiagnosticsEnvironmentProvider(),
        signposter: any WatchSignposting = WatchSignpost.live,
        diagnosticsSignposter: WatchStorageSignposter = WatchStorageSignposter()
    ) {
        self.paths = paths
        self.storageActor = storageActor
        self.session = session
        self.environmentProvider = environmentProvider
        self.signposter = signposter
        self.diagnosticsEncoder = WatchRelayDiagnosticsEncoder(signposter: diagnosticsSignposter)
    }

    func makeEnvelopeData(asOf: Date) async -> Data? {
        let environment = self.environmentProvider.snapshot()
        let payloadInterval = self.signposter.begin(.diagnosticsPayloadAssembly)
        let fullPayload = await self.makePayload(asOf: asOf, environment: environment)
        self.signposter.end(payloadInterval, fields: WatchSignpostFields(result: .completed))
        return await self.diagnosticsEncoder.encodeCompactedEnvelope(
            generatedAt: asOf,
            payload: fullPayload
        )
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
            guard !Task.isCancelled else { return .zero }
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
            guard !Task.isCancelled else { return .zero }
            let count = transfersByID[id] ?? 0
            if count == 0 {
                appActiveNotObserved += 1
            } else if count == 1 {
                matched += 1
            } else {
                duplicate += 1
            }
        }

        var orphaned = 0
        for pair in transfersByID {
            guard !Task.isCancelled else { return .zero }
            if !activeManifestIDs.contains(pair.key) {
                orphaned += pair.value
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

/// Owns diagnostics encoding so JSON construction and bounded compaction never
/// occupy MainActor. Its signposts are emitted directly from actor-local work,
/// so their intervals never require an instrumentation hop through MainActor.
private actor WatchRelayDiagnosticsEncoder {
    private let signposter: WatchStorageSignposter

    init(signposter: WatchStorageSignposter) {
        self.signposter = signposter
    }

    func encodeCompactedEnvelope(
        generatedAt: Date,
        payload: WatchRelayDiagnosticsPayload
    ) -> Data? {
        let interval = self.signposter.begin(.diagnosticsFirstEncode)
        let data = self.encodeCompactedEnvelopeInner(
            generatedAt: generatedAt,
            payload: payload
        )
        self.signposter.end(
            interval,
            fields: WatchSignpostFields(
                result: data == nil ? .failed : .completed,
                encodedByteCount: data?.count
            )
        )
        return data
    }

    private func encodeCompactedEnvelopeInner(
        generatedAt: Date,
        payload: WatchRelayDiagnosticsPayload
    ) -> Data? {
        let observations = payload.observedFileTransfers
        let observationCount = observations.count
        do {
            let fullData = try WatchRelayDiagnosticsCollector.encodedEnvelopeData(
                generatedAt: generatedAt,
                payload: payload,
                observations: observations,
                retainedObservationCount: observationCount
            )
            guard fullData.count > WatchRelayDiagnosticsEnvelope.maxEncodedByteCount else {
                return fullData
            }

            let emptyData = try self.encodeCompactionEnvelope(
                generatedAt: generatedAt,
                payload: payload,
                observations: observations,
                retainedObservationCount: 0
            )
            guard emptyData.count <= WatchRelayDiagnosticsEnvelope.maxEncodedByteCount else {
                return WatchRelayDiagnosticsCollector.unavailableEnvelopeData(
                    generatedAt: generatedAt,
                    reason: WatchRelayDiagnosticsEnvelopeReason.publicationFailed
                )
            }

            var low = 0
            var lowData = emptyData
            var high = observationCount
            while high - low > 1 {
                let mid = low + (high - low) / 2
                let data = try self.encodeCompactionEnvelope(
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
            return WatchRelayDiagnosticsCollector.unavailableEnvelopeData(
                generatedAt: generatedAt,
                reason: WatchRelayDiagnosticsEnvelopeReason.encodeFailed
            )
        }
    }

    private func encodeCompactionEnvelope(
        generatedAt: Date,
        payload: WatchRelayDiagnosticsPayload,
        observations: [WatchRelayTransferObservation],
        retainedObservationCount: Int
    ) throws -> Data {
        let interval = self.signposter.begin(
            .diagnosticsCompactionEncode,
            fields: WatchSignpostFields(retainedObservationCount: retainedObservationCount)
        )
        do {
            let data = try WatchRelayDiagnosticsCollector.encodedEnvelopeData(
                generatedAt: generatedAt,
                payload: payload,
                observations: observations,
                retainedObservationCount: retainedObservationCount
            )
            self.signposter.end(
                interval,
                fields: WatchSignpostFields(
                    result: .completed,
                    retainedObservationCount: retainedObservationCount,
                    encodedByteCount: data.count
                )
            )
            return data
        } catch {
            self.signposter.end(
                interval,
                fields: WatchSignpostFields(
                    result: .failed,
                    retainedObservationCount: retainedObservationCount
                )
            )
            throw error
        }
    }
}

private extension WatchRelayDiagnosticsCollector {
    struct ActiveManifestFact {
        let entry: WatchCaptureCatalogEntry
        let sidecar: DiagnosticAvailability<WatchRelaySegmentDiagnosticsSidecar>
        let sourcePresent: DiagnosticAvailability<Bool>
        let relayBundlePresent: DiagnosticAvailability<Bool>
        let relayBundleBytes: DiagnosticAvailability<Int64>
        let originalAudioFile: DiagnosticAvailability<WatchRelayOriginalFileFact>
        let originalLocationFile: DiagnosticAvailability<WatchRelayOriginalFileFact>
        let witness: ActiveManifestWitness
    }

    struct ActiveManifestWitness: Equatable {
        let segmentID: UUID
        let manifestState: WatchSegmentState
        let sidecarAvailabilityKey: String
        let sidecarOriginalEnqueuedAt: Date?
        let sidecarBundleBytes: Int64?
        let legacySourcePresent: DiagnosticAvailability<Bool>
        let legacyAppOwnedSourceBytes: DiagnosticAvailability<Int64>
        let relayBundlePresent: DiagnosticAvailability<Bool>
        let relayBundleBytes: DiagnosticAvailability<Int64>
        let originalAudioFile: DiagnosticAvailability<WatchRelayOriginalFileFact>
        let originalLocationFile: DiagnosticAvailability<WatchRelayOriginalFileFact>
    }

    struct OriginalPayloadAggregate {
        let audioCounts: WatchRelayOriginalFileStateCounts
        let locationCounts: WatchRelayOriginalFileStateCounts
        let readableBytes: DiagnosticAvailability<Int64>
    }

    func makePayload(
        asOf: Date,
        environment: WatchRelayDiagnosticsEnvironmentSnapshot
    ) async -> WatchRelayDiagnosticsPayload {
        let catalog = await self.storageActor.scanCatalog(transactionClass: .maintenance)
        let entries = catalog.entries
        let activeEntries = entries.filter { entry in
            entry.manifest.state == .queued || entry.manifest.state == .transferring
        }
        let manifestFactsInterval = self.signposter.begin(.diagnosticsManifestFacts)
        var activeFacts: [ActiveManifestFact] = []
        var entryFactsCompleted = catalog.canInferUUIDAbsence
        if entryFactsCompleted {
            for entry in activeEntries {
                guard !Task.isCancelled,
                      let fact = await self.activeManifestFact(entry: entry)
                else {
                    entryFactsCompleted = false
                    break
                }
                activeFacts.append(fact)
            }
        }
        if Task.isCancelled {
            entryFactsCompleted = false
        }
        self.signposter.end(
            manifestFactsInterval,
            fields: WatchSignpostFields(result: entryFactsCompleted ? .completed : .partial)
        )
        var canAssembleMembershipFacts = entryFactsCompleted && !Task.isCancelled
        let fileTransferObservations = canAssembleMembershipFacts
            ? self.session.outstandingFileTransfers
            : []
        var fileTransferSnapshots: [WatchConnectivityFileTransferSnapshot] = []
        fileTransferSnapshots.reserveCapacity(fileTransferObservations.count)
        for observation in fileTransferObservations {
            guard !Task.isCancelled else {
                canAssembleMembershipFacts = false
                entryFactsCompleted = false
                fileTransferSnapshots.removeAll(keepingCapacity: false)
                break
            }
            fileTransferSnapshots.append(observation.snapshot)
        }
        let userInfoSnapshots = canAssembleMembershipFacts
            ? self.session.outstandingUserInfoTransferSnapshots
            : []
        let activeIDs = canAssembleMembershipFacts
            ? Set(activeEntries.map(\.manifest.id))
            : []
        let reconciliation = Self.reconciliationCounts(
            activeManifestIDs: activeIDs,
            fileTransfers: fileTransferSnapshots
        )
        if Task.isCancelled {
            canAssembleMembershipFacts = false
            entryFactsCompleted = false
        }
        let perItemFactsInterval = self.signposter.begin(.diagnosticsPerItemFacts)
        let observations = canAssembleMembershipFacts
            ? self.observations(
                activeFacts: activeFacts,
                fileTransfers: fileTransferObservations,
                asOf: asOf
            )
            : []
        if Task.isCancelled {
            canAssembleMembershipFacts = false
            entryFactsCompleted = false
        }
        self.signposter.end(
            perItemFactsInterval,
            fields: WatchSignpostFields(result: canAssembleMembershipFacts ? .completed : .partial)
        )
        let lastFacts: DiagnosticAvailability<WatchRelayLastFactsSummary> = !Task.isCancelled
            ? await self.storageActor.readDiagnosticsSummary()
            : .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
        let failureSegmentID = Self.failureSegmentID(from: lastFacts)
        let historyInterval = self.signposter.begin(.diagnosticsHistorySummaryRead)
        let historyResult = !Task.isCancelled
            ? await self.storageActor.readSessionHistory(asOf: asOf)
            : .unreadable
        let historyWindow: DiagnosticAvailability<[WatchCaptureSessionHistoryEntry]>
        let historyDepth: Int
        switch historyResult {
        case let .available(entries):
            historyDepth = entries.count
            historyWindow = .available(Array(entries.filter(\.isComplete).prefix(10)))
        case .unreadable:
            historyDepth = 0
            historyWindow = .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.sessionHistoryUnreadable)
        }
        let counter = !Task.isCancelled ? await self.storageActor.readSessionHistoryCounter() : nil
        self.signposter.end(historyInterval, fields: WatchSignpostFields(result: .completed))

        let witnessInterval = self.signposter.begin(.diagnosticsChangedWitnessRevalidation)
        let membershipIsAuthoritative = await self.isMembershipAuthoritative(
            snapshotGeneration: catalog.relevantMutationGeneration,
            canInferUUIDAbsence: catalog.canInferUUIDAbsence,
            entryFactsCompleted: entryFactsCompleted
        ) && !Task.isCancelled
        let resolvedObservations = membershipIsAuthoritative ? observations : []
        self.signposter.end(
            witnessInterval,
            fields: WatchSignpostFields(result: membershipIsAuthoritative ? .completed : .partial)
        )

        let membershipUnavailableReason = WatchRelayObservationCollectionResolution
            .snapshotChangedDuringCollection.rawValue
        let manifestSummary = membershipIsAuthoritative
            ? self.manifestSummary(catalog: catalog, activeFacts: activeFacts, asOf: asOf)
            : .unavailable(reason: membershipUnavailableReason)

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
            appleQueue: membershipIsAuthoritative
                ? .available(WatchRelayAppleQueueSnapshot(
                    asOf: asOf,
                    outstandingFileTransferCount: fileTransferSnapshots.count,
                    outstandingUserInfoTransferCountWatchToPhone: userInfoSnapshots.count,
                    reconciliation: reconciliation,
                    exactObservationCountBeforeCompaction: resolvedObservations.count
                ))
                : .unavailable(reason: membershipUnavailableReason),
            lastFacts: lastFacts,
            observedFileTransfers: self.orderedForCompaction(
                resolvedObservations,
                activeFacts: activeFacts,
                failureSegmentID: failureSegmentID
            ),
            omittedObservationCount: 0,
            sessionHistoryWindow: historyWindow,
            lifetimeSessionsStarted: counter.map { .available($0.lifetimeSessionsStarted) }
                ?? .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild),
            sessionHistoryCounterEpoch: counter.map { .available($0.epoch) }
                ?? .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild),
            sessionHistoryDepth: historyDepth
        )
    }

    func activeManifestFact(entry: WatchCaptureCatalogEntry) async -> ActiveManifestFact? {
        guard let storageFacts = try? await self.storageActor.readDiagnosticsEntryStorageFacts(
            entry: entry,
            bundleURL: self.bundleURL(for: entry.manifest.id)
        ) else {
            return nil
        }
        let sidecar = storageFacts.sidecar
        let sourcePresent = storageFacts.relayBundlePresent
        let originalAudioFile = storageFacts.originalAudioFile
        let originalLocationFile = storageFacts.originalLocationFile
        let legacyAppOwnedSourceBytes = Self.legacySourceBytes(from: sidecar)
        let witnessValues = Self.sidecarWitnessValues(sidecar)
        let witness = ActiveManifestWitness(
            segmentID: entry.manifest.id,
            manifestState: entry.manifest.state,
            sidecarAvailabilityKey: witnessValues.availabilityKey,
            sidecarOriginalEnqueuedAt: witnessValues.originalEnqueuedAt,
            sidecarBundleBytes: witnessValues.bundleBytes,
            legacySourcePresent: sourcePresent,
            legacyAppOwnedSourceBytes: legacyAppOwnedSourceBytes,
            relayBundlePresent: storageFacts.relayBundlePresent,
            relayBundleBytes: storageFacts.relayBundleBytes,
            originalAudioFile: originalAudioFile,
            originalLocationFile: originalLocationFile
        )
        return ActiveManifestFact(
            entry: entry,
            sidecar: sidecar,
            sourcePresent: sourcePresent,
            relayBundlePresent: storageFacts.relayBundlePresent,
            relayBundleBytes: storageFacts.relayBundleBytes,
            originalAudioFile: originalAudioFile,
            originalLocationFile: originalLocationFile,
            witness: witness
        )
    }

    func manifestSummary(
        catalog: WatchCaptureCatalog,
        activeFacts: [ActiveManifestFact],
        asOf: Date
    ) -> DiagnosticAvailability<WatchRelayManifestSummary> {
        let counts = Self.manifestCounts(catalog.entries)
        let catalogIssues = Self.catalogIssueSummary(catalog.issues)
        let originalAggregate = self.originalPayloadAggregate(activeFacts: activeFacts)
        guard !activeFacts.isEmpty else {
            return .available(WatchRelayManifestSummary(
                counts: counts,
                catalogRootState: catalog.rootState,
                catalogIssues: catalogIssues,
                activeBacklogCount: 0,
                retainedSourceBytes: .available(0),
                oldestActiveEnqueuedAt: .available(nil),
                oldestActiveEnqueueAgeSeconds: .available(nil),
                originalAudioFileCounts: .available(.zero),
                originalLocationFileCounts: .available(.zero),
                originalPayloadReadableBytes: .available(0),
                retainedRelayBundleBytes: .available(0)
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
                    catalogRootState: catalog.rootState,
                    catalogIssues: catalogIssues,
                    activeBacklogCount: activeFacts.count,
                    retainedSourceBytes: .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable),
                    oldestActiveEnqueuedAt: .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable),
                    oldestActiveEnqueueAgeSeconds: .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable),
                    originalAudioFileCounts: .available(originalAggregate.audioCounts),
                    originalLocationFileCounts: .available(originalAggregate.locationCounts),
                    originalPayloadReadableBytes: originalAggregate.readableBytes,
                    retainedRelayBundleBytes: .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
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
            catalogRootState: catalog.rootState,
            catalogIssues: catalogIssues,
            activeBacklogCount: activeFacts.count,
            retainedSourceBytes: sourceBytesOverflowed
                ? .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
                : .available(sourceBytes),
            oldestActiveEnqueuedAt: .available(oldest),
            oldestActiveEnqueueAgeSeconds: .available(oldest.map { max(0, asOf.timeIntervalSince($0)) }),
            originalAudioFileCounts: .available(originalAggregate.audioCounts),
            originalLocationFileCounts: .available(originalAggregate.locationCounts),
            originalPayloadReadableBytes: originalAggregate.readableBytes,
            retainedRelayBundleBytes: sourceBytesOverflowed
                ? .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
                : .available(sourceBytes)
        ))
    }

    func observations(
        activeFacts: [ActiveManifestFact],
        fileTransfers: [WatchConnectivityFileTransferObservation],
        asOf: Date
    ) -> [WatchRelayTransferObservation] {
        let activeByID = Dictionary(uniqueKeysWithValues: activeFacts.map { ($0.entry.manifest.id, $0) })
        var observations: [WatchRelayTransferObservation] = []
        var transfersByID: [UUID: [(index: Int, transfer: WatchConnectivityFileTransferObservation)]] = [:]
        var firstSeenOrder: [UUID] = []
        var unparseables: [(index: Int, transfer: WatchConnectivityFileTransferObservation)] = []

        for (index, transfer) in fileTransfers.enumerated() {
            guard !Task.isCancelled else { return [] }
            guard transfer.snapshot.idState == .parseable,
                  let segmentID = transfer.snapshot.segmentID
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
            guard !Task.isCancelled else { return [] }
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
                    asOf: transfer.snapshot.asOf,
                    segmentID: id,
                    idState: .parseable,
                    relation: relation,
                    fact: fact,
                    transfer: transfer
                ))
            }
        }

        for id in firstSeenOrder where activeByID[id] == nil && !consumedIDs.contains(id) {
            guard !Task.isCancelled else { return [] }
            for (_, transfer) in transfersByID[id] ?? [] {
                guard !Task.isCancelled else { return [] }
                observations.append(self.observation(
                    asOf: transfer.snapshot.asOf,
                    segmentID: id,
                    idState: .parseable,
                    relation: .orphaned,
                    fact: nil,
                    transfer: transfer
                ))
            }
        }

        for (_, transfer) in unparseables {
            guard !Task.isCancelled else { return [] }
            observations.append(self.observation(
                asOf: transfer.snapshot.asOf,
                segmentID: nil,
                idState: transfer.snapshot.idState,
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
        transfer: WatchConnectivityFileTransferObservation?
    ) -> WatchRelayTransferObservation {
        let appOwnedEnqueueAgeSeconds: DiagnosticAvailability<TimeInterval?>
        let appOwnedSourceBytes: DiagnosticAvailability<Int64>
        let sourcePresent: DiagnosticAvailability<Bool>
        let originalAudioFile: DiagnosticAvailability<WatchRelayOriginalFileFact>
        let originalLocationFile: DiagnosticAvailability<WatchRelayOriginalFileFact>
        let relayBundlePresent: DiagnosticAvailability<Bool>
        let relayBundleBytes: DiagnosticAvailability<Int64>
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
            originalAudioFile = fact.originalAudioFile
            originalLocationFile = fact.originalLocationFile
            relayBundlePresent = fact.relayBundlePresent
            relayBundleBytes = fact.relayBundleBytes
        } else {
            appManifestState = nil
            appOwnedEnqueueAgeSeconds = .unavailable(reason: "no app-active manifest")
            appOwnedSourceBytes = .unavailable(reason: "no app-active manifest")
            sourcePresent = .unavailable(reason: "no app-active manifest")
            originalAudioFile = .unavailable(reason: "no app-active manifest")
            originalLocationFile = .unavailable(reason: "no app-active manifest")
            relayBundlePresent = .unavailable(reason: "no app-active manifest")
            relayBundleBytes = .unavailable(reason: "no app-active manifest")
        }

        let isTransferring: DiagnosticAvailability<Bool>
        let progress: DiagnosticAvailability<WatchConnectivityProgressSnapshot>
        if let transfer {
            isTransferring = .available(transfer.snapshot.isTransferring)
            progress = .available(transfer.snapshot.progress)
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
            progress: progress,
            attemptID: transfer?.attemptID,
            attemptIDState: transfer?.attemptIDState ?? .missing,
            attemptStartedAt: transfer?.attemptStartedAt,
            attemptStartedAtState: transfer?.attemptStartedAtState ?? .missing,
            originalAudioFile: originalAudioFile,
            originalLocationFile: originalLocationFile,
            relayBundlePresent: relayBundlePresent,
            relayBundleBytes: relayBundleBytes,
            collectionResolution: .available(.stable)
        )
    }

    func originalPayloadAggregate(activeFacts: [ActiveManifestFact]) -> OriginalPayloadAggregate {
        var audioCounts = WatchRelayOriginalFileStateCounts.zero
        var locationCounts = WatchRelayOriginalFileStateCounts.zero
        var readableBytes: Int64 = 0
        var readableBytesOverflowed = false

        for fact in activeFacts {
            self.accumulateOriginalFileFact(
                fact.originalAudioFile,
                counts: &audioCounts,
                readableBytes: &readableBytes,
                readableBytesOverflowed: &readableBytesOverflowed
            )
            self.accumulateOriginalFileFact(
                fact.originalLocationFile,
                counts: &locationCounts,
                readableBytes: &readableBytes,
                readableBytesOverflowed: &readableBytesOverflowed
            )
        }

        return OriginalPayloadAggregate(
            audioCounts: audioCounts,
            locationCounts: locationCounts,
            readableBytes: readableBytesOverflowed
                ? .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
                : .available(readableBytes)
        )
    }

    func accumulateOriginalFileFact(
        _ availability: DiagnosticAvailability<WatchRelayOriginalFileFact>,
        counts: inout WatchRelayOriginalFileStateCounts,
        readableBytes: inout Int64,
        readableBytesOverflowed: inout Bool
    ) {
        guard case let .available(fact) = availability else { return }
        counts = Self.incremented(counts, state: fact.state)
        guard fact.state == .readableNonempty,
              let byteCount = fact.byteCount,
              !readableBytesOverflowed
        else {
            return
        }
        let (nextBytes, overflow) = readableBytes.addingReportingOverflow(byteCount)
        if overflow {
            readableBytesOverflowed = true
        } else {
            readableBytes = nextBytes
        }
    }

    static func incremented(
        _ counts: WatchRelayOriginalFileStateCounts,
        state: WatchRelayOriginalFileState
    ) -> WatchRelayOriginalFileStateCounts {
        switch state {
        case .missing:
            WatchRelayOriginalFileStateCounts(
                missing: counts.missing + 1,
                readableNonempty: counts.readableNonempty,
                zeroLength: counts.zeroLength,
                unreadable: counts.unreadable
            )
        case .readableNonempty:
            WatchRelayOriginalFileStateCounts(
                missing: counts.missing,
                readableNonempty: counts.readableNonempty + 1,
                zeroLength: counts.zeroLength,
                unreadable: counts.unreadable
            )
        case .zeroLength:
            WatchRelayOriginalFileStateCounts(
                missing: counts.missing,
                readableNonempty: counts.readableNonempty,
                zeroLength: counts.zeroLength + 1,
                unreadable: counts.unreadable
            )
        case .unreadable:
            WatchRelayOriginalFileStateCounts(
                missing: counts.missing,
                readableNonempty: counts.readableNonempty,
                zeroLength: counts.zeroLength,
                unreadable: counts.unreadable + 1
            )
        }
    }

    func isMembershipAuthoritative(
        snapshotGeneration: UInt64,
        canInferUUIDAbsence: Bool,
        entryFactsCompleted: Bool
    ) async -> Bool {
        guard entryFactsCompleted, canInferUUIDAbsence else {
            return false
        }
        return (try? await self.storageActor.validateRelevantMutationGeneration(snapshotGeneration)) == true
    }

    func bundleURL(for id: UUID) -> URL {
        self.paths.rootURL
            .appendingPathComponent(".relay-bundles", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).watchrelay", isDirectory: false)
    }

    func orderedForCompaction(
        _ observations: [WatchRelayTransferObservation],
        activeFacts: [ActiveManifestFact],
        failureSegmentID: UUID?
    ) -> [WatchRelayTransferObservation] {
        guard !observations.isEmpty else { return [] }
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

    static func legacySourceBytes(
        from sidecar: DiagnosticAvailability<WatchRelaySegmentDiagnosticsSidecar>
    ) -> DiagnosticAvailability<Int64> {
        switch sidecar {
        case let .available(sidecar):
            if let sourceBytes = sidecar.sourceBytes {
                return .available(sourceBytes)
            }
            return .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
        case let .unavailable(reason):
            return .unavailable(reason: reason)
        }
    }

    static func sidecarWitnessValues(
        _ sidecar: DiagnosticAvailability<WatchRelaySegmentDiagnosticsSidecar>
    ) -> (availabilityKey: String, originalEnqueuedAt: Date?, bundleBytes: Int64?) {
        switch sidecar {
        case let .available(sidecar):
            return ("available", sidecar.originalEnqueuedAt, sidecar.sourceBytes)
        case let .unavailable(reason):
            return ("unavailable:\(reason)", nil, nil)
        }
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

    static func manifestCounts(_ entries: [WatchCaptureCatalogEntry]) -> WatchRelayManifestCounts {
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

    static func catalogIssueSummary(
        _ issues: [WatchCaptureCatalogIssue]
    ) -> [WatchRelayCatalogIssueSummary] {
        Dictionary(grouping: issues, by: \.kind)
            .map { kind, issues in
                WatchRelayCatalogIssueSummary(kind: kind, count: issues.count)
            }
            .sorted { $0.kind.rawValue < $1.kind.rawValue }
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
            omittedObservationCount: omittedObservationCount,
            sessionHistoryWindow: payload.sessionHistoryWindow,
            lifetimeSessionsStarted: payload.lifetimeSessionsStarted,
            sessionHistoryCounterEpoch: payload.sessionHistoryCounterEpoch,
            sessionHistoryDepth: payload.sessionHistoryDepth
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
