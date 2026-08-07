// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import WatchConnectivity
import XCTest

@MainActor
final class WatchRelayDiagnosticsCollectorTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-relay-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        self.tempDirectory = nil
        try super.tearDownWithError()
    }

    func testFifteenActiveManifestsAndMatchingAppleTransfersProduceExactTotalsAndCorrelations() throws {
        let now = Self.now
        let storage = try self.storage("fifteen")
        let store = WatchRelayDiagnosticsStore(storage: storage)
        let session = MockWatchConnectivitySession()
        session.activationState = .activated
        session.isReachable = true

        var expectedSourceBytes: Int64 = 0
        var ids: [UUID] = []
        for index in 0..<15 {
            let id = Self.uuid(index)
            ids.append(id)
            let entry = try self.writeManifest(id: id, state: .transferring, storage: storage)
            let bundleURL = storage.rootURL
                .appendingPathComponent(".relay-bundles", isDirectory: true)
                .appendingPathComponent("\(id.uuidString).watchrelay", isDirectory: false)
            let bytes = 128 + index
            expectedSourceBytes += Int64(bytes)
            try storage.fileWriter.writeData(Data(repeating: UInt8(index), count: bytes), to: bundleURL, options: .atomic)
            store.recordEnqueue(
                manifest: entry.manifest,
                directoryURL: entry.directoryURL,
                bundleURL: bundleURL,
                at: now.addingTimeInterval(TimeInterval(-(index + 1) * 60))
            )
            session.seedOutstandingTransfer(
                id: id,
                progress: MockWatchConnectivitySession.defaultProgress(
                    completedUnitCount: Int64(index),
                    totalUnitCount: 100,
                    fractionCompleted: Double(index) / 100
                )
            )
        }

        let collector = WatchRelayDiagnosticsCollector(
            storage: storage,
            diagnosticsStore: store,
            session: session,
            environmentProvider: MockWatchRelayDiagnosticsEnvironmentProvider()
        )
        let result = WatchRelayDiagnosticsEnvelope.decodeResult(from: collector.makeEnvelopeData(asOf: now))
        let payload = try XCTUnwrap(result.payload)
        let manifestSummary = try XCTUnwrap(payload.manifestSummary.value)
        let queue = try XCTUnwrap(payload.appleQueue.value)

        XCTAssertEqual(manifestSummary.activeBacklogCount, 15)
        XCTAssertEqual(manifestSummary.retainedSourceBytes.value, expectedSourceBytes)
        XCTAssertEqual(queue.outstandingFileTransferCount, 15)
        XCTAssertEqual(queue.reconciliation.matched, 15)
        XCTAssertEqual(queue.reconciliation.appActiveNotObserved, 0)
        XCTAssertEqual(Set(payload.observedFileTransfers.compactMap(\.segmentID)), Set(ids))
        XCTAssertTrue(payload.observedFileTransfers.allSatisfy { $0.appOwnedSourceBytes.value != nil })
        XCTAssertTrue(session.callLedger.isEmpty)
        XCTAssertTrue((try storage.scanManifests()).allSatisfy { $0.manifest.state == .transferring })
    }

    func testWatchCaptureModelSourceRetainsDiagnosticsCollectorStrongly() throws {
        let root = Self.worktreeRoot()
        let modelURL = root.appendingPathComponent("Watch/Sources/WatchCaptureModel.swift")
        let appURL = root.appendingPathComponent("Watch/Sources/SolstoneWatchApp.swift")
        let modelSource = try String(contentsOf: modelURL, encoding: .utf8)
        let appSource = try String(contentsOf: appURL, encoding: .utf8)

        XCTAssertTrue(modelSource.contains("@ObservationIgnored private let diagnosticsCollector: WatchRelayDiagnosticsCollector?"))
        XCTAssertTrue(modelSource.contains("self.diagnosticsCollector = diagnosticsCollector"))
        XCTAssertTrue(modelSource.contains("self.diagnosticsCollector = nil"))
        XCTAssertTrue(modelSource.contains("engine.onDiagnosticsEnvelopeRequested = { [diagnosticsCollector] asOf in"))
        XCTAssertFalse(modelSource.contains("[weak diagnosticsCollector]"))
        XCTAssertTrue(appSource.contains("diagnosticsCollector: diagnosticsCollector"))
    }

    func testWatchCaptureLifecycleSourceHasNoModelOrEngineBypass() throws {
        let root = Self.worktreeRoot()
        let modelURL = root.appendingPathComponent("Watch/Sources/WatchCaptureModel.swift")
        let engineURL = root.appendingPathComponent("Sources/WatchCapture/WatchCaptureEngine.swift")
        let modelSource = try String(contentsOf: modelURL, encoding: .utf8)
        let engineSource = try String(contentsOf: engineURL, encoding: .utf8)

        XCTAssertFalse(modelSource.contains("Task {"))
        XCTAssertFalse(modelSource.contains("WatchCaptureLifecycleSerializer"))
        XCTAssertFalse(modelSource.contains("reconcileOnLaunchInner"))
        XCTAssertFalse(modelSource.contains("startInner"))
        XCTAssertFalse(modelSource.contains("stopInner"))
        XCTAssertTrue(modelSource.contains("engine.reconcileOnLaunch()"))
        XCTAssertTrue(modelSource.contains("self.engine?.start()"))
        XCTAssertTrue(modelSource.contains("self.engine?.stop()"))

        XCTAssertTrue(engineSource.contains("func reconcileOnLaunch() {\n        self.lifecycleSerializer.submit(.reconcile)"))
        XCTAssertTrue(engineSource.contains("func start() {\n        self.lifecycleSerializer.submit(.start)"))
        XCTAssertTrue(engineSource.contains("func stop() {\n        self.lifecycleSerializer.submit(.stop)"))
        XCTAssertTrue(engineSource.contains("private func reconcileOnLaunchInner"))
        XCTAssertTrue(engineSource.contains("private func startInner"))
        XCTAssertTrue(engineSource.contains("private func stopInner"))
    }

    func testOriginalPayloadFactsCoverAllStatesAndAggregateReadableBytes() throws {
        let now = Self.now
        let writer = ForcedExistingWatchFileWriter()
        let storage = try self.storage("original-payload", fileWriter: writer)
        let store = WatchRelayDiagnosticsStore(storage: storage)
        let session = MockWatchConnectivitySession()
        let missing = try self.writeManifest(id: Self.uuid(100), state: .transferring, storage: storage)
        let zero = try self.writeManifest(id: Self.uuid(101), state: .transferring, storage: storage)
        let readable = try self.writeManifest(id: Self.uuid(102), state: .transferring, storage: storage)
        let unreadable = try self.writeManifest(id: Self.uuid(103), state: .transferring, storage: storage)

        try storage.fileWriter.writeData(Data(), to: storage.audioURL(directory: zero.directoryURL), options: .atomic)
        try storage.fileWriter.writeData(Data(), to: storage.locationURL(directory: zero.directoryURL), options: .atomic)
        try storage.fileWriter.writeData(
            Data(repeating: 1, count: 11),
            to: storage.audioURL(directory: readable.directoryURL),
            options: .atomic
        )
        try storage.fileWriter.writeData(
            Data(repeating: 2, count: 13),
            to: storage.locationURL(directory: readable.directoryURL),
            options: .atomic
        )
        writer.forceExists(at: storage.audioURL(directory: unreadable.directoryURL))
        writer.forceExists(at: storage.locationURL(directory: unreadable.directoryURL))

        for (index, entry) in [missing, zero, readable, unreadable].enumerated() {
            try self.recordEnqueue(
                store: store,
                entry: entry,
                storage: storage,
                byte: UInt8(index + 1),
                at: now.addingTimeInterval(TimeInterval(-index))
            )
        }

        let collector = WatchRelayDiagnosticsCollector(
            storage: storage,
            diagnosticsStore: store,
            session: session,
            environmentProvider: MockWatchRelayDiagnosticsEnvironmentProvider()
        )
        let payload = try XCTUnwrap(WatchRelayDiagnosticsEnvelope.decodeResult(from: collector.makeEnvelopeData(asOf: now)).payload)
        let observations = Dictionary(uniqueKeysWithValues: payload.observedFileTransfers.compactMap { observation in
            observation.segmentID.map { ($0, observation) }
        })
        XCTAssertEqual(observations[missing.manifest.id]?.originalAudioFile.value?.state, .missing)
        XCTAssertEqual(observations[missing.manifest.id]?.originalLocationFile.value?.state, .missing)
        XCTAssertEqual(observations[zero.manifest.id]?.originalAudioFile.value?.state, .zeroLength)
        XCTAssertEqual(observations[zero.manifest.id]?.originalLocationFile.value?.state, .zeroLength)
        XCTAssertEqual(observations[readable.manifest.id]?.originalAudioFile.value, WatchRelayOriginalFileFact(state: .readableNonempty, byteCount: 11))
        XCTAssertEqual(observations[readable.manifest.id]?.originalLocationFile.value, WatchRelayOriginalFileFact(state: .readableNonempty, byteCount: 13))
        XCTAssertEqual(observations[unreadable.manifest.id]?.originalAudioFile.value?.state, .unreadable)
        XCTAssertEqual(observations[unreadable.manifest.id]?.originalLocationFile.value?.state, .unreadable)

        let summary = try XCTUnwrap(payload.manifestSummary.value)
        XCTAssertEqual(summary.originalAudioFileCounts.value, WatchRelayOriginalFileStateCounts(
            missing: 1,
            readableNonempty: 1,
            zeroLength: 1,
            unreadable: 1
        ))
        XCTAssertEqual(summary.originalLocationFileCounts.value, WatchRelayOriginalFileStateCounts(
            missing: 1,
            readableNonempty: 1,
            zeroLength: 1,
            unreadable: 1
        ))
        XCTAssertEqual(summary.originalPayloadReadableBytes.value, 24)
    }

    func testLegacySourcePresentRemainsRelayBundleExistenceWithExplicitBundleFacts() throws {
        let now = Self.now
        let storage = try self.storage("legacy-source-present")
        let store = WatchRelayDiagnosticsStore(storage: storage)
        let session = MockWatchConnectivitySession()
        let entry = try self.writeManifest(id: Self.uuid(110), state: .transferring, storage: storage)
        try self.recordEnqueue(store: store, entry: entry, storage: storage, byte: 7, at: now)

        let collector = WatchRelayDiagnosticsCollector(
            storage: storage,
            diagnosticsStore: store,
            session: session,
            environmentProvider: MockWatchRelayDiagnosticsEnvironmentProvider()
        )
        let payload = try XCTUnwrap(WatchRelayDiagnosticsEnvelope.decodeResult(from: collector.makeEnvelopeData(asOf: now)).payload)
        let observation = try XCTUnwrap(payload.observedFileTransfers.first { $0.segmentID == entry.manifest.id })

        XCTAssertEqual(observation.sourcePresent.value, true)
        XCTAssertEqual(observation.relayBundlePresent.value, observation.sourcePresent.value)
        XCTAssertEqual(observation.relayBundleBytes.value, observation.appOwnedSourceBytes.value)
        XCTAssertEqual(observation.appOwnedSourceBytes.value, 256)
        XCTAssertEqual(observation.originalAudioFile.value?.state, .missing)
        XCTAssertEqual(observation.originalLocationFile.value?.state, .missing)
    }

    func testDecodedMissingRelayBundleClassifiesAsStaleSourceEmpty() throws {
        let now = Self.now
        let storage = try self.storage("missing-relay-bundle-classification")
        let store = WatchRelayDiagnosticsStore(storage: storage)
        let session = MockWatchConnectivitySession()
        let entry = try self.writeManifest(id: Self.uuid(115), state: .transferring, storage: storage)
        try storage.fileWriter.writeData(Data(), to: storage.audioURL(directory: entry.directoryURL), options: .atomic)
        try storage.fileWriter.writeData(Data(), to: storage.locationURL(directory: entry.directoryURL), options: .atomic)

        let collector = WatchRelayDiagnosticsCollector(
            storage: storage,
            diagnosticsStore: store,
            session: session,
            environmentProvider: MockWatchRelayDiagnosticsEnvironmentProvider()
        )
        let payload = try XCTUnwrap(WatchRelayDiagnosticsEnvelope.decodeResult(from: collector.makeEnvelopeData(asOf: now)).payload)
        let observation = try XCTUnwrap(payload.observedFileTransfers.first { $0.segmentID == entry.manifest.id })
        XCTAssertEqual(observation.relayBundlePresent.value, false)
        XCTAssertEqual(observation.relayBundleBytes.unavailableReason, WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)

        let emptyLedger = WatchSegmentLedgerReadSnapshot(
            asOf: now,
            entriesByID: [:],
            counts: WatchSegmentLedgerSnapshotCounts(
                retainedEntryCount: 0,
                receivedOnlyCount: 0,
                handedCount: 0,
                droppedCount: 0,
                handedAndDroppedCount: 0
            )
        )
        let input = Self.pipelineInput(
            payload: payload,
            lastReceivedAt: nil,
            phoneLedgerSnapshot: .available(emptyLedger)
        )
        let report = WatchPipelineReducer.classifyRelayIdentities(input)
        let classification = try XCTUnwrap(report.classifications.first { $0.segmentID == entry.manifest.id })
        XCTAssertEqual(classification.phoneOutcome, .ledgerAbsent)
        XCTAssertEqual(classification.sourceAssessment, .staleSourceEmpty)
        XCTAssertTrue(WatchPipelineReducer.reduce(input).diagnosticsExportText.contains("source stale-source-empty"))
    }

    func testMixedVersionEnvelopeDecodeDefaultsNewFieldsAndKeepsVersionOne() throws {
        let now = Self.now
        let observation = Self.observation(id: Self.uuid(120), age: 10)
        let payload = Self.payload(
            generatedAt: now,
            manifestSummary: WatchRelayManifestSummary(
                counts: .zero,
                activeBacklogCount: 1,
                retainedSourceBytes: .available(256),
                oldestActiveEnqueuedAt: .available(now.addingTimeInterval(-10)),
                oldestActiveEnqueueAgeSeconds: .available(10)
            ),
            observations: [observation]
        )
        let newData = try WatchRelayDiagnosticsEnvelope.makeEncoder().encode(WatchRelayDiagnosticsEnvelope(
            generatedAt: now,
            diagnostics: .available(payload)
        ))
        let newObject = try XCTUnwrap(JSONSerialization.jsonObject(with: newData) as? [String: Any])
        XCTAssertEqual(newObject["version"] as? Int, WatchRelayDiagnosticsEnvelope.currentVersion)
        XCTAssertLessThanOrEqual(newData.count, WatchRelayDiagnosticsEnvelope.maxEncodedByteCount)
        XCTAssertNotNil(WatchRelayDiagnosticsEnvelope.decodeResult(from: newData).payload)

        let oldData = try Self.removingNewDiagnosticKeys(from: newData)
        let oldDecoded = try XCTUnwrap(WatchRelayDiagnosticsEnvelope.decodeResult(from: oldData).payload)
        let oldSummary = try XCTUnwrap(oldDecoded.manifestSummary.value)
        let oldObservation = try XCTUnwrap(oldDecoded.observedFileTransfers.first)
        XCTAssertEqual(oldSummary.originalAudioFileCounts.unavailableReason, WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild)
        XCTAssertEqual(oldSummary.originalLocationFileCounts.unavailableReason, WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild)
        XCTAssertEqual(oldSummary.originalPayloadReadableBytes.unavailableReason, WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild)
        XCTAssertEqual(oldSummary.retainedRelayBundleBytes.unavailableReason, WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild)
        XCTAssertEqual(oldObservation.originalAudioFile.unavailableReason, WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild)
        XCTAssertEqual(oldObservation.relayBundlePresent.unavailableReason, WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild)
        XCTAssertEqual(oldObservation.sourcePresent.value, observation.sourcePresent.value)
    }

    func testSnapshotWitnessMarksChangedFactsUnresolvedWithoutWritesOrSessionCalls() throws {
        let now = Self.now
        let writer = MutatingWatchFileWriter()
        let storage = try self.storage("snapshot-witness", fileWriter: writer)
        let store = WatchRelayDiagnosticsStore(storage: storage)
        let session = MockWatchConnectivitySession()
        let entry = try self.writeManifest(id: Self.uuid(130), state: .transferring, storage: storage)
        let audioURL = storage.audioURL(directory: entry.directoryURL)
        try storage.fileWriter.writeData(Data(repeating: 9, count: 10), to: audioURL, options: .atomic)
        try self.recordEnqueue(store: store, entry: entry, storage: storage, byte: 9, at: now)
        writer.mutateBeforeSecondFileExists(at: audioURL) {
            try? FileManager.default.removeItem(at: audioURL)
        }
        writer.resetWriteCount()

        let collector = WatchRelayDiagnosticsCollector(
            storage: storage,
            diagnosticsStore: store,
            session: session,
            environmentProvider: MockWatchRelayDiagnosticsEnvironmentProvider()
        )
        let payload = try XCTUnwrap(WatchRelayDiagnosticsEnvelope.decodeResult(from: collector.makeEnvelopeData(asOf: now)).payload)
        let observation = try XCTUnwrap(payload.observedFileTransfers.first { $0.segmentID == entry.manifest.id })

        XCTAssertEqual(observation.collectionResolution.value, .snapshotChangedDuringCollection)
        XCTAssertEqual(observation.originalAudioFile.unavailableReason, WatchRelayObservationCollectionResolution.snapshotChangedDuringCollection.rawValue)
        XCTAssertEqual(observation.originalLocationFile.unavailableReason, WatchRelayObservationCollectionResolution.snapshotChangedDuringCollection.rawValue)
        XCTAssertEqual(observation.relayBundlePresent.unavailableReason, WatchRelayObservationCollectionResolution.snapshotChangedDuringCollection.rawValue)
        XCTAssertEqual(observation.relayBundleBytes.unavailableReason, WatchRelayObservationCollectionResolution.snapshotChangedDuringCollection.rawValue)
        XCTAssertTrue(session.callLedger.isEmpty)
        XCTAssertEqual(writer.writeCount, 0)
    }

    func testReconciliationDistinguishesMatchedMissingDuplicateOrphanedAndUnparseable() {
        let activeA = Self.uuid(1)
        let activeB = Self.uuid(2)
        let activeC = Self.uuid(3)
        let orphan = Self.uuid(4)
        let transfers = [
            Self.transfer(id: activeA),
            Self.transfer(id: activeB),
            Self.transfer(id: activeB),
            Self.transfer(id: orphan),
            Self.transfer(id: nil, idState: .missing),
            Self.transfer(id: nil, idState: .unparseable),
        ]

        let counts = WatchRelayDiagnosticsCollector.reconciliationCounts(
            activeManifestIDs: [activeA, activeB, activeC],
            fileTransfers: transfers
        )

        XCTAssertEqual(counts.matched, 1)
        XCTAssertEqual(counts.duplicate, 1)
        XCTAssertEqual(counts.appActiveNotObserved, 1)
        XCTAssertEqual(counts.orphaned, 1)
        XCTAssertEqual(counts.unparseable, 2)
    }

    func testTransferCompletingDuringSnapshotReportsPointInTimeDisagreement() throws {
        let now = Self.now
        let payload = Self.payload(
            generatedAt: now,
            manifestSummary: WatchRelayManifestSummary(
                counts: .zero,
                activeBacklogCount: 1,
                retainedSourceBytes: .available(128),
                oldestActiveEnqueuedAt: .available(now.addingTimeInterval(-900)),
                oldestActiveEnqueueAgeSeconds: .available(900)
            ),
            queue: WatchRelayAppleQueueSnapshot(
                asOf: now,
                outstandingFileTransferCount: 0,
                outstandingUserInfoTransferCountWatchToPhone: 0,
                reconciliation: WatchRelayReconciliationCounts(
                    matched: 0,
                    appActiveNotObserved: 1,
                    duplicate: 0,
                    orphaned: 0,
                    unparseable: 0
                ),
                exactObservationCountBeforeCompaction: 1
            )
        )
        let input = Self.pipelineInput(now: now, payload: payload, isReachable: true)
        XCTAssertTrue(WatchPipelineReducer.reduce(input).diagnosticsExportText.contains("point-in-time app/Apple queue disagreement"))
    }

    func testLargeTransferSetStaysUnder32KiBAndReportsExactOmittedCount() throws {
        let now = Self.now
        let storage = try self.storage("large")
        let store = WatchRelayDiagnosticsStore(storage: storage)
        let session = MockWatchConnectivitySession()
        var allObservations: [WatchRelayTransferObservation] = []

        for index in 0..<800 {
            let id = Self.uuid(index + 1000)
            session.seedOutstandingTransfer(id: id)
            allObservations.append(Self.orphanObservation(id: id))
        }
        let collector = WatchRelayDiagnosticsCollector(
            storage: storage,
            diagnosticsStore: store,
            session: session,
            environmentProvider: MockWatchRelayDiagnosticsEnvironmentProvider()
        )
        let data = try XCTUnwrap(collector.makeEnvelopeData(asOf: now))
        // Budget baseline: a real orphan observation is 966 B and a maximal compact history entry is 554 B.
        // With the ten-entry window, the 26-observation floor remains below the 32 KiB envelope limit.
        XCTAssertLessThanOrEqual(data.count, WatchRelayDiagnosticsEnvelope.maxEncodedByteCount)
        let payload = try XCTUnwrap(WatchRelayDiagnosticsEnvelope.decodeResult(from: data).payload)
        let queue = try XCTUnwrap(payload.appleQueue.value)
        XCTAssertEqual(queue.outstandingFileTransferCount, 800)
        XCTAssertEqual(payload.observedFileTransfers.count + payload.omittedObservationCount, queue.exactObservationCountBeforeCompaction)
        XCTAssertGreaterThan(payload.omittedObservationCount, 0)
        XCTAssertEqual(payload.observedFileTransfers, Array(allObservations.prefix(payload.observedFileTransfers.count)))

        let boundaryCount = payload.observedFileTransfers.count
        let plusOnePayload = Self.payload(
            payload,
            observations: Array(allObservations.prefix(boundaryCount + 1)),
            omittedObservationCount: allObservations.count - boundaryCount - 1
        )
        let plusOneData = try WatchRelayDiagnosticsEnvelope.makeEncoder().encode(WatchRelayDiagnosticsEnvelope(
            generatedAt: now,
            diagnostics: .available(plusOnePayload)
        ))
        XCTAssertGreaterThan(plusOneData.count, WatchRelayDiagnosticsEnvelope.maxEncodedByteCount)
    }

    func testHistoryBudgetBackwardDecodeAndCompactionFidelity() throws {
        let now = Self.now
        let entries = (0..<10).map { Self.historyEntry($0, at: now) }
        let observations = (0..<26).map { Self.orphanObservation(id: Self.uuid(9_000 + $0)) }
        let storage = try self.storage("history-compaction")
        let history = WatchCaptureSessionHistoryStore(storage: storage)
        for entry in entries {
            try history.upsert(entry, asOf: now)
            _ = try history.incrementLifetimeCounter()
        }
        let session = MockWatchConnectivitySession()
        for index in 0..<800 {
            session.seedOutstandingTransfer(id: Self.uuid(10_000 + index))
        }
        let collector = WatchRelayDiagnosticsCollector(
            storage: storage,
            diagnosticsStore: WatchRelayDiagnosticsStore(storage: storage),
            session: session,
            environmentProvider: MockWatchRelayDiagnosticsEnvironmentProvider()
        )
        let compacted = try XCTUnwrap(WatchRelayDiagnosticsEnvelope.decodeResult(
            from: collector.makeEnvelopeData(asOf: now)
        ).payload)
        XCTAssertGreaterThan(compacted.omittedObservationCount, 0)
        XCTAssertEqual(Set(compacted.sessionHistoryWindow.value?.map(\.sessionID) ?? []), Set(entries.map(\.sessionID)))
        XCTAssertEqual(compacted.sessionHistoryDepth, 10)
        XCTAssertEqual(compacted.lifetimeSessionsStarted.value, 10)
        XCTAssertEqual(compacted.sessionHistoryCounterEpoch.value?.isEmpty, false)

        let payload = Self.withHistory(Self.payload(generatedAt: now, observations: observations), entries: entries, depth: 10)
        let data = try WatchRelayDiagnosticsEnvelope.makeEncoder().encode(WatchRelayDiagnosticsEnvelope(
            generatedAt: now, diagnostics: .available(payload)
        ))
        // Budget baseline: a real orphan observation is 966 B and a maximal compact history entry is 554 B.
        XCTAssertLessThanOrEqual(data.count, WatchRelayDiagnosticsEnvelope.maxEncodedByteCount)
        let maxEntryBytes = try WatchRelayDiagnosticsEnvelope.makeEncoder().encode(Self.historyEntry(99, at: now)).count
        XCTAssertLessThanOrEqual(10 * maxEntryBytes, WatchRelayDiagnosticsEnvelope.maxEncodedByteCount - 20 * 1024)
        let decoded = try XCTUnwrap(WatchRelayDiagnosticsEnvelope.decodeResult(from: data).payload)
        XCTAssertEqual(decoded.sessionHistoryWindow.value, entries)
        XCTAssertEqual(decoded.sessionHistoryDepth, 10)
        XCTAssertEqual(decoded.lifetimeSessionsStarted.value, 10)

        let oldData = try WatchRelayDiagnosticsEnvelope.makeEncoder().encode(WatchRelayDiagnosticsEnvelope(
            generatedAt: now, diagnostics: .available(Self.payload(generatedAt: now))
        ))
        let oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: oldData) as? [String: Any])
        var diagnostics = try XCTUnwrap(oldJSON["diagnostics"] as? [String: Any])
        var oldPayload = try XCTUnwrap(diagnostics["value"] as? [String: Any])
        oldPayload.removeValue(forKey: "sessionHistoryWindow")
        oldPayload.removeValue(forKey: "lifetimeSessionsStarted")
        oldPayload.removeValue(forKey: "sessionHistoryCounterEpoch")
        oldPayload.removeValue(forKey: "sessionHistoryDepth")
        diagnostics["value"] = oldPayload
        var oldEnvelope = oldJSON
        oldEnvelope["diagnostics"] = diagnostics
        let backward = try JSONSerialization.data(withJSONObject: oldEnvelope, options: [.sortedKeys])
        let backwardPayload = try XCTUnwrap(WatchRelayDiagnosticsEnvelope.decodeResult(from: backward).payload)
        XCTAssertEqual(WatchRelayDiagnosticsEnvelope.currentVersion, 1)
        XCTAssertEqual(backwardPayload.watchAppBuild, .available("55"))
        XCTAssertEqual(backwardPayload.sessionHistoryWindow.unavailableReason, WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild)
    }

    func testObservationCompactionKeepsTheFullHistoryWindowAvailable() throws {
        let now = Self.now
        let entries = (0..<10).map {
            Self.historyEntry($0, at: now.addingTimeInterval(TimeInterval($0 - 10)))
        }
        let storage = try self.storage("history-survives-observation-compaction")
        let history = WatchCaptureSessionHistoryStore(storage: storage)
        for entry in entries {
            try history.upsert(entry, asOf: now)
            _ = try history.incrementLifetimeCounter()
        }
        let session = MockWatchConnectivitySession()
        for index in 0..<800 {
            session.seedOutstandingTransfer(id: Self.uuid(20_000 + index))
        }
        let collector = WatchRelayDiagnosticsCollector(
            storage: storage,
            diagnosticsStore: WatchRelayDiagnosticsStore(storage: storage),
            session: session,
            environmentProvider: MockWatchRelayDiagnosticsEnvironmentProvider()
        )

        let data = try XCTUnwrap(collector.makeEnvelopeData(asOf: now))
        let payload = try XCTUnwrap(WatchRelayDiagnosticsEnvelope.decodeResult(from: data).payload)
        XCTAssertLessThanOrEqual(data.count, WatchRelayDiagnosticsEnvelope.maxEncodedByteCount)
        XCTAssertGreaterThan(payload.omittedObservationCount, 0)
        XCTAssertEqual(
            payload.sessionHistoryWindow.value?.map(\.sessionID),
            entries.sorted { $0.startedAt > $1.startedAt }.map(\.sessionID)
        )
        XCTAssertEqual(payload.sessionHistoryWindow.value?.count, 10)
    }

    func testHistoryWindowContainsExactlyTheNewestTenSessionIdentities() throws {
        let now = Self.now
        let entries = (0..<11).map {
            Self.historyEntry($0, at: now.addingTimeInterval(TimeInterval($0 - 11) * 60))
        }
        let storage = try self.storage("history-window-identity-order")
        let history = WatchCaptureSessionHistoryStore(storage: storage)
        for entry in entries {
            try history.upsert(entry, asOf: now)
            _ = try history.incrementLifetimeCounter()
        }
        let collector = WatchRelayDiagnosticsCollector(
            storage: storage,
            diagnosticsStore: WatchRelayDiagnosticsStore(storage: storage),
            session: MockWatchConnectivitySession(),
            environmentProvider: MockWatchRelayDiagnosticsEnvironmentProvider()
        )

        let payload = try XCTUnwrap(WatchRelayDiagnosticsEnvelope.decodeResult(
            from: collector.makeEnvelopeData(asOf: now)
        ).payload)
        XCTAssertEqual(
            payload.sessionHistoryWindow.value?.map(\.sessionID),
            entries.sorted { $0.startedAt > $1.startedAt }.prefix(10).map(\.sessionID)
        )
        XCTAssertEqual(payload.sessionHistoryDepth, 11)
    }

    func testFloorHistoryWithoutObservationsStaysPublishableUnderTheEnvelopeCap() throws {
        let now = Self.now
        let storage = try self.storage("history-floor-under-cap")
        let history = WatchCaptureSessionHistoryStore(storage: storage)
        for index in 0..<10 {
            try history.upsert(Self.historyEntry(index, at: now.addingTimeInterval(TimeInterval(index - 10))), asOf: now)
            _ = try history.incrementLifetimeCounter()
        }
        let collector = WatchRelayDiagnosticsCollector(
            storage: storage,
            diagnosticsStore: WatchRelayDiagnosticsStore(storage: storage),
            session: MockWatchConnectivitySession(),
            environmentProvider: MockWatchRelayDiagnosticsEnvironmentProvider()
        )

        let data = try XCTUnwrap(collector.makeEnvelopeData(asOf: now))
        XCTAssertLessThanOrEqual(data.count, WatchRelayDiagnosticsEnvelope.maxEncodedByteCount)
        let payload = try XCTUnwrap(WatchRelayDiagnosticsEnvelope.decodeResult(from: data).payload)
        XCTAssertEqual(payload.observedFileTransfers, [])
        XCTAssertEqual(payload.sessionHistoryWindow.value?.count, 10)
    }

    func testCompactionRetentionOrderOldestActiveThenRecentFailureThenUUIDOrder() throws {
        let now = Self.now
        let storage = try self.storage("compaction-priority")
        let store = WatchRelayDiagnosticsStore(storage: storage)
        let session = MockWatchConnectivitySession()
        let oldest = Self.uuid(10)
        let newer = Self.uuid(11)
        let recentFailure = Self.uuid(12)

        let activeIDs = [oldest, newer, recentFailure]
        for (index, id) in activeIDs.enumerated() {
            let entry = try self.writeManifest(id: id, state: .transferring, storage: storage)
            let bundleURL = storage.rootURL
                .appendingPathComponent(".relay-bundles", isDirectory: true)
                .appendingPathComponent("\(id.uuidString).watchrelay", isDirectory: false)
            try storage.fileWriter.writeData(Data(repeating: UInt8(index), count: 256), to: bundleURL, options: .atomic)
            store.recordEnqueue(
                manifest: entry.manifest,
                directoryURL: entry.directoryURL,
                bundleURL: bundleURL,
                at: now.addingTimeInterval(TimeInterval(-(3 - index) * 600))
            )
            if id == recentFailure {
                store.recordTransferCompletion(
                    manifest: entry.manifest,
                    directoryURL: entry.directoryURL,
                    succeeded: false,
                    failure: WatchConnectivityTransferFailureSnapshot(
                        domain: "TestFailureDomain",
                        code: 77,
                        boundedRedactedDescription: "failed"
                    ),
                    at: now.addingTimeInterval(-5)
                )
            }
            session.seedOutstandingTransfer(id: id)
        }

        for index in 0..<800 {
            session.seedOutstandingTransfer(id: Self.uuid(index + 1000))
        }

        let collector = WatchRelayDiagnosticsCollector(
            storage: storage,
            diagnosticsStore: store,
            session: session,
            environmentProvider: MockWatchRelayDiagnosticsEnvironmentProvider()
        )
        let data = try XCTUnwrap(collector.makeEnvelopeData(asOf: now))
        XCTAssertLessThanOrEqual(data.count, WatchRelayDiagnosticsEnvelope.maxEncodedByteCount)
        let decoded = try XCTUnwrap(WatchRelayDiagnosticsEnvelope.decodeResult(from: data).payload)
        let queue = try XCTUnwrap(decoded.appleQueue.value)
        XCTAssertGreaterThan(decoded.omittedObservationCount, 0)
        XCTAssertEqual(decoded.observedFileTransfers.count + decoded.omittedObservationCount, queue.exactObservationCountBeforeCompaction)

        let retainedIDs = decoded.observedFileTransfers.compactMap(\.segmentID)
        XCTAssertEqual(Array(retainedIDs.prefix(3)), [oldest, newer, recentFailure])
        let remainingIDs = retainedIDs.dropFirst(3).map(\.uuidString)
        XCTAssertEqual(remainingIDs, remainingIDs.sorted())
    }

    func testQueueReconciliationWritesOnlyRootSummary() throws {
        let now = Self.now
        let writer = CountingWatchFileWriter()
        let storage = try self.storage("reconciliation-summary-only", fileWriter: writer)
        let store = WatchRelayDiagnosticsStore(storage: storage)
        let session = MockWatchConnectivitySession()
        session.activationState = .activated
        var entries: [WatchCaptureStorage.ManifestEntry] = []

        for index in 0..<200 {
            let entry = try self.writeManifest(id: Self.uuid(index + 2000), state: .transferring, storage: storage)
            entries.append(entry)
            session.seedOutstandingTransfer(id: entry.manifest.id)
        }

        let sender = WatchRelaySender(
            storage: storage,
            session: session,
            diagnosticsStore: store,
            clock: { now }
        )
        writer.resetCounts()
        sender.drain()

        XCTAssertEqual(writer.writeCount(for: store.summaryURL()), 1)
        for entry in entries {
            XCTAssertEqual(writer.writeCount(for: store.sidecarURL(directoryURL: entry.directoryURL)), 0)
        }
        let summary = try XCTUnwrap(store.readSummary().value)
        XCTAssertEqual(summary.lastQueueReconciliationObservation?.observedFileTransferCount, 200)
        XCTAssertEqual(summary.lastQueueReconciliationObservation?.activeManifestCount, 200)
    }

    func testObservationRelationsAndExactCountMatchReconciliationShape() throws {
        let now = Self.now
        let storage = try self.storage("observation-shape")
        let store = WatchRelayDiagnosticsStore(storage: storage)
        let session = MockWatchConnectivitySession()
        let activeA = Self.uuid(1)
        let activeB = Self.uuid(2)
        let activeC = Self.uuid(3)
        let orphan = Self.uuid(4)

        _ = try self.writeManifest(id: activeA, state: .transferring, storage: storage)
        _ = try self.writeManifest(id: activeB, state: .transferring, storage: storage)
        _ = try self.writeManifest(id: activeC, state: .transferring, storage: storage)
        session.seedOutstandingTransfer(id: activeA)
        session.seedOutstandingTransfer(id: activeB)
        session.seedOutstandingTransfer(id: activeB)
        session.seedOutstandingTransfer(id: orphan)
        session.seedOutstandingTransfer(id: nil, idState: .missing)
        session.seedOutstandingTransfer(id: nil, idState: .unparseable)

        let collector = WatchRelayDiagnosticsCollector(
            storage: storage,
            diagnosticsStore: store,
            session: session,
            environmentProvider: MockWatchRelayDiagnosticsEnvironmentProvider()
        )
        let payload = try XCTUnwrap(WatchRelayDiagnosticsEnvelope.decodeResult(from: collector.makeEnvelopeData(asOf: now)).payload)
        let queue = try XCTUnwrap(payload.appleQueue.value)
        let relationCounts = Dictionary(grouping: payload.observedFileTransfers, by: \.relation).mapValues(\.count)

        XCTAssertEqual(queue.exactObservationCountBeforeCompaction, 7)
        XCTAssertEqual(queue.reconciliation.matched, 1)
        XCTAssertEqual(queue.reconciliation.duplicate, 1)
        XCTAssertEqual(queue.reconciliation.appActiveNotObserved, 1)
        XCTAssertEqual(queue.reconciliation.orphaned, 1)
        XCTAssertEqual(queue.reconciliation.unparseable, 2)
        XCTAssertEqual(relationCounts[.matched], 1)
        XCTAssertEqual(relationCounts[.duplicate], 2)
        XCTAssertEqual(relationCounts[.appActiveNotObserved], 1)
        XCTAssertEqual(relationCounts[.orphaned], 1)
        XCTAssertEqual(relationCounts[.unparseable], 2)

        let expectedIdentity: [(UUID?, WatchRelayObservationRelation)] = [
            (activeA, .matched),
            (activeB, .duplicate),
            (activeB, .duplicate),
            (activeC, .appActiveNotObserved),
            (orphan, .orphaned),
            (nil, .unparseable),
            (nil, .unparseable),
        ]
        XCTAssertEqual(payload.observedFileTransfers.count, expectedIdentity.count)
        for (observation, expected) in zip(payload.observedFileTransfers, expectedIdentity) {
            XCTAssertEqual(observation.segmentID, expected.0)
            XCTAssertEqual(observation.relation, expected.1)
        }
    }

    func testSourceByteAggregateOverflowOnlyMakesRetainedBytesUnavailable() throws {
        let now = Self.now
        let oldest = now.addingTimeInterval(-600)
        let newer = now.addingTimeInterval(-60)
        let storage = try self.storage("source-byte-overflow")
        let store = WatchRelayDiagnosticsStore(storage: storage)
        let session = MockWatchConnectivitySession()
        let encoder = Self.diagnosticsEncoder()
        let sidecarFacts: [(UUID, Date, Int64)] = [
            (Self.uuid(10_000), oldest, Int64.max - 10),
            (Self.uuid(10_001), newer, 42),
        ]

        for (id, enqueuedAt, sourceBytes) in sidecarFacts {
            let entry = try self.writeManifest(id: id, state: .transferring, storage: storage)
            var sidecar = WatchRelaySegmentDiagnosticsSidecar(
                segmentID: id,
                originalEnqueuedAt: enqueuedAt,
                latestEnqueuedAt: enqueuedAt,
                attemptCount: 1,
                sourceBytes: sourceBytes,
                sourcePresent: true
            )
            sidecar.lastFacts.lastEnqueue = WatchRelayFactCounter(at: enqueuedAt, count: 1, segmentID: id)
            try storage.fileWriter.writeData(
                try encoder.encode(sidecar),
                to: store.sidecarURL(directoryURL: entry.directoryURL),
                options: .atomic
            )
            session.seedOutstandingTransfer(id: id)
        }

        let collector = WatchRelayDiagnosticsCollector(
            storage: storage,
            diagnosticsStore: store,
            session: session,
            environmentProvider: MockWatchRelayDiagnosticsEnvironmentProvider()
        )
        let payload = try XCTUnwrap(WatchRelayDiagnosticsEnvelope.decodeResult(from: collector.makeEnvelopeData(asOf: now)).payload)
        let summary = try XCTUnwrap(payload.manifestSummary.value)

        XCTAssertEqual(summary.retainedSourceBytes.unavailableReason, WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
        let oldestEnqueuedAt = try XCTUnwrap(summary.oldestActiveEnqueuedAt.value)
        let oldestEnqueueAge = try XCTUnwrap(summary.oldestActiveEnqueueAgeSeconds.value)
        XCTAssertEqual(try XCTUnwrap(oldestEnqueuedAt), oldest)
        XCTAssertEqual(try XCTUnwrap(oldestEnqueueAge), now.timeIntervalSince(oldest))
    }

    func testOldestActiveFailureStillSortsByActiveEnqueueOrder() throws {
        let now = Self.now
        let storage = try self.storage("active-failure-order")
        let store = WatchRelayDiagnosticsStore(storage: storage)
        let session = MockWatchConnectivitySession()
        let failedOldest = Self.uuid(20)
        let newer = Self.uuid(21)
        let newest = Self.uuid(22)

        for (index, id) in [failedOldest, newer, newest].enumerated() {
            let entry = try self.writeManifest(id: id, state: .transferring, storage: storage)
            try self.recordEnqueue(
                store: store,
                entry: entry,
                storage: storage,
                byte: UInt8(index),
                at: now.addingTimeInterval(TimeInterval(-(3 - index) * 600))
            )
            if id == failedOldest {
                store.recordTransferCompletion(
                    manifest: entry.manifest,
                    directoryURL: entry.directoryURL,
                    succeeded: false,
                    failure: WatchConnectivityTransferFailureSnapshot(domain: "TestFailureDomain", code: 77, boundedRedactedDescription: "failed"),
                    at: now.addingTimeInterval(-5)
                )
            }
            session.seedOutstandingTransfer(id: id)
        }
        for index in 0..<800 {
            session.seedOutstandingTransfer(id: Self.uuid(index + 3000))
        }

        let collector = WatchRelayDiagnosticsCollector(
            storage: storage,
            diagnosticsStore: store,
            session: session,
            environmentProvider: MockWatchRelayDiagnosticsEnvironmentProvider()
        )
        let payload = try XCTUnwrap(WatchRelayDiagnosticsEnvelope.decodeResult(from: collector.makeEnvelopeData(asOf: now)).payload)
        XCTAssertEqual(Array(payload.observedFileTransfers.compactMap(\.segmentID).prefix(3)), [failedOldest, newer, newest])
    }

    func testNonActiveSummaryFailureSortsAfterActiveBeforePlainOrphans() throws {
        let now = Self.now
        let storage = try self.storage("orphan-failure-order")
        let store = WatchRelayDiagnosticsStore(storage: storage)
        let session = MockWatchConnectivitySession()
        let activeOld = Self.uuid(30)
        let activeNew = Self.uuid(31)
        let plainLow = Self.uuid(1000)
        let failedOrphan = Self.uuid(5000)
        let plainHigh = Self.uuid(9000)

        for (index, id) in [activeOld, activeNew].enumerated() {
            let entry = try self.writeManifest(id: id, state: .transferring, storage: storage)
            try self.recordEnqueue(
                store: store,
                entry: entry,
                storage: storage,
                byte: UInt8(index),
                at: now.addingTimeInterval(TimeInterval(-(2 - index) * 600))
            )
            session.seedOutstandingTransfer(id: id)
        }
        let failedEntry = try self.writeManifest(id: failedOrphan, state: .delivered, storage: storage)
        store.recordTransferCompletion(
            manifest: failedEntry.manifest,
            directoryURL: failedEntry.directoryURL,
            succeeded: false,
            failure: WatchConnectivityTransferFailureSnapshot(domain: "TestFailureDomain", code: 78, boundedRedactedDescription: "failed"),
            at: now.addingTimeInterval(-5)
        )
        session.seedOutstandingTransfer(id: plainLow)
        session.seedOutstandingTransfer(id: failedOrphan)
        session.seedOutstandingTransfer(id: plainHigh)

        let collector = WatchRelayDiagnosticsCollector(
            storage: storage,
            diagnosticsStore: store,
            session: session,
            environmentProvider: MockWatchRelayDiagnosticsEnvironmentProvider()
        )
        let payload = try XCTUnwrap(WatchRelayDiagnosticsEnvelope.decodeResult(from: collector.makeEnvelopeData(asOf: now)).payload)
        let observations = payload.observedFileTransfers
        XCTAssertEqual(Array(observations.compactMap(\.segmentID).prefix(3)), [activeOld, activeNew, failedOrphan])
        XCTAssertEqual(observations.first(where: { $0.segmentID == failedOrphan })?.relation, .orphaned)
    }

    func testStaleStructuredFailureDoesNotPrioritizeAfterLaterSuccess() throws {
        let now = Self.now
        let storage = try self.storage("stale-failure-order")
        let store = WatchRelayDiagnosticsStore(storage: storage)
        let session = MockWatchConnectivitySession()
        let active = Self.uuid(40)
        let plainLow = Self.uuid(1000)
        let staleFailure = Self.uuid(9000)
        let laterSuccess = Self.uuid(9001)

        let activeEntry = try self.writeManifest(id: active, state: .transferring, storage: storage)
        try self.recordEnqueue(store: store, entry: activeEntry, storage: storage, byte: 1, at: now.addingTimeInterval(-600))
        let staleEntry = try self.writeManifest(id: staleFailure, state: .delivered, storage: storage)
        store.recordTransferCompletion(
            manifest: staleEntry.manifest,
            directoryURL: staleEntry.directoryURL,
            succeeded: false,
            failure: WatchConnectivityTransferFailureSnapshot(domain: "TestFailureDomain", code: 79, boundedRedactedDescription: "failed"),
            at: now.addingTimeInterval(-5)
        )
        let successEntry = try self.writeManifest(id: laterSuccess, state: .delivered, storage: storage)
        store.recordTransferCompletion(
            manifest: successEntry.manifest,
            directoryURL: successEntry.directoryURL,
            succeeded: true,
            failure: nil,
            at: now.addingTimeInterval(-1)
        )
        session.seedOutstandingTransfer(id: active)
        session.seedOutstandingTransfer(id: staleFailure)
        session.seedOutstandingTransfer(id: plainLow)

        let collector = WatchRelayDiagnosticsCollector(
            storage: storage,
            diagnosticsStore: store,
            session: session,
            environmentProvider: MockWatchRelayDiagnosticsEnvironmentProvider()
        )
        let payload = try XCTUnwrap(WatchRelayDiagnosticsEnvelope.decodeResult(from: collector.makeEnvelopeData(asOf: now)).payload)
        XCTAssertEqual(Array(payload.observedFileTransfers.compactMap(\.segmentID).prefix(2)), [active, plainLow])
    }

    func testBatterySnapshotReadsLevelAndStateInsideSingleMonitoringWindow() {
        let device = MockWatchBatteryDevice()
        let battery = LiveWatchRelayDiagnosticsEnvironmentProvider.batterySnapshot(device: device)

        XCTAssertEqual(battery.level.value ?? -1, 0.42, accuracy: 0.001)
        XCTAssertEqual(battery.state.value, "charging")
        XCTAssertFalse(device.isBatteryMonitoringEnabled)
        XCTAssertEqual(device.monitoringAssignments, [true, false])
    }

    func testDiagnosticWriteFailureDoesNotBlockEnqueueRelayEffectAndMarksHistoryUnavailable() throws {
        let now = Self.now
        let writer = WriteFailingWatchFileWriter()
        writer.failOnlyDiagnosticFiles = true
        let storage = try self.storage("write-fail-enqueue", fileWriter: writer)
        let store = WatchRelayDiagnosticsStore(storage: storage)
        let session = MockWatchConnectivitySession()
        session.activationState = .activated
        let entry = try self.writeManifest(id: Self.uuid(50), state: .queued, storage: storage)
        let sender = WatchRelaySender(
            storage: storage,
            session: session,
            diagnosticsStore: store,
            clock: { now }
        )

        // This drain path proves relay effects still complete; store-level tests isolate marker tripping per record method.
        writer.failWrites = true
        sender.drain()

        XCTAssertEqual(session.transferredFiles.count, 1)
        XCTAssertEqual(try storage.readManifest(from: entry.manifestURL).state, .transferring)
        XCTAssertEqual(store.readSummary().unavailableReason, WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)

        let collector = WatchRelayDiagnosticsCollector(
            storage: storage,
            diagnosticsStore: store,
            session: session,
            environmentProvider: MockWatchRelayDiagnosticsEnvironmentProvider()
        )
        let payload = try XCTUnwrap(WatchRelayDiagnosticsEnvelope.decodeResult(from: collector.makeEnvelopeData(asOf: now)).payload)
        XCTAssertEqual(payload.lastFacts.unavailableReason, WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
        XCTAssertEqual(payload.observedFileTransfers.first?.appOwnedSourceBytes.unavailableReason, WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
    }

    func testDiagnosticWriteFailureDoesNotBlockCompletionAndACKRelayEffects() throws {
        let now = Self.now
        let writer = WriteFailingWatchFileWriter()
        writer.failOnlyDiagnosticFiles = true
        let storage = try self.storage("write-fail-completion-ack", fileWriter: writer)
        let store = WatchRelayDiagnosticsStore(storage: storage)
        let session = MockWatchConnectivitySession()
        session.activationState = .activated
        let failed = try self.writeManifest(id: Self.uuid(60), state: .transferring, storage: storage)
        let acked = try self.writeManifest(id: Self.uuid(61), state: .delivered, storage: storage)
        let sender = WatchRelaySender(
            storage: storage,
            session: session,
            diagnosticsStore: store,
            clock: { now }
        )

        // This callback path proves relay effects still complete; store-level tests isolate marker tripping per record method.
        writer.failWrites = true
        session.finishTransfer(
            id: failed.manifest.id,
            failure: WatchConnectivityTransferFailureSnapshot(domain: "TestFailureDomain", code: 80, boundedRedactedDescription: "failed")
        )
        XCTAssertEqual(try storage.readManifest(from: failed.manifestURL).state, .queued)

        session.deliverUserInfo(WatchRelayACK.userInfo(id: acked.manifest.id))
        XCTAssertFalse(storage.fileWriter.fileExists(at: acked.directoryURL))
        XCTAssertEqual(store.readSummary().unavailableReason, WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)

        _ = sender
    }

    private func storage(_ name: String, fileWriter: (any WatchFileWriting)? = nil) throws -> WatchCaptureStorage {
        if let fileWriter {
            return try WatchCaptureStorage(
                rootURL: self.tempDirectory.appendingPathComponent(name, isDirectory: true),
                fileWriter: fileWriter
            )
        }
        return try WatchCaptureStorage(rootURL: self.tempDirectory.appendingPathComponent(name, isDirectory: true))
    }

    private func writeManifest(
        id: UUID,
        state: WatchSegmentState,
        storage: WatchCaptureStorage
    ) throws -> WatchCaptureStorage.ManifestEntry {
        let manifest = WatchSegmentManifest(
            id: id,
            day: "20260715",
            segment: id.uuidString,
            startedAt: Self.now,
            duration: 300,
            sensors: [.audio],
            partial: false,
            lost: false,
            gap: false,
            fixCount: 0,
            state: state
        )
        let directoryURL = storage.segmentDirectoryURL(day: manifest.day, segment: manifest.segment)
        try storage.fileWriter.createDirectory(at: directoryURL)
        try storage.writeManifest(manifest, in: directoryURL)
        return WatchCaptureStorage.ManifestEntry(
            directoryURL: directoryURL,
            manifestURL: storage.manifestURL(directory: directoryURL),
            manifest: manifest
        )
    }

    private func recordEnqueue(
        store: WatchRelayDiagnosticsStore,
        entry: WatchCaptureStorage.ManifestEntry,
        storage: WatchCaptureStorage,
        byte: UInt8,
        at date: Date
    ) throws {
        let bundleURL = storage.rootURL
            .appendingPathComponent(".relay-bundles", isDirectory: true)
            .appendingPathComponent("\(entry.manifest.id.uuidString).watchrelay", isDirectory: false)
        try storage.fileWriter.writeData(Data(repeating: byte, count: 256), to: bundleURL, options: .atomic)
        store.recordEnqueue(
            manifest: entry.manifest,
            directoryURL: entry.directoryURL,
            bundleURL: bundleURL,
            at: date
        )
    }

    private static func diagnosticsEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func removingNewDiagnosticKeys(from data: Data) throws -> Data {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var diagnostics = try XCTUnwrap(root["diagnostics"] as? [String: Any])
        var payload = try XCTUnwrap(diagnostics["value"] as? [String: Any])

        if var manifestSummary = payload["manifestSummary"] as? [String: Any],
           var manifestValue = manifestSummary["value"] as? [String: Any] {
            for key in [
                "originalAudioFileCounts",
                "originalLocationFileCounts",
                "originalPayloadReadableBytes",
                "retainedRelayBundleBytes",
            ] {
                manifestValue.removeValue(forKey: key)
            }
            manifestSummary["value"] = manifestValue
            payload["manifestSummary"] = manifestSummary
        }

        if var observations = payload["observedFileTransfers"] as? [[String: Any]] {
            for index in observations.indices {
                for key in [
                    "originalAudioFile",
                    "originalLocationFile",
                    "relayBundlePresent",
                    "relayBundleBytes",
                    "collectionResolution",
                ] {
                    observations[index].removeValue(forKey: key)
                }
            }
            payload["observedFileTransfers"] = observations
        }

        diagnostics["value"] = payload
        root["diagnostics"] = diagnostics
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}

@MainActor
final class WatchRelayDiagnosticsReadOnlyTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-relay-diagnostics-read-only-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        self.tempDirectory = nil
        try super.tearDownWithError()
    }

    func testSnapshotConstructionDoesNotTransferCancelRetryACKDeleteOrMutateManifests() throws {
        let now = WatchRelayDiagnosticsCollectorTests.now
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000090001")!
        let storage = try WatchCaptureStorage(rootURL: self.tempDirectory.appendingPathComponent("capture", isDirectory: true))
        let store = WatchRelayDiagnosticsStore(storage: storage)
        let session = MockWatchConnectivitySession()
        session.activationState = .activated
        session.isReachable = true

        let manifest = WatchSegmentManifest(
            id: id,
            day: "20260715",
            segment: id.uuidString,
            startedAt: now,
            duration: 300,
            sensors: [.audio],
            partial: false,
            lost: false,
            gap: false,
            fixCount: 0,
            state: .transferring
        )
        let directoryURL = storage.segmentDirectoryURL(day: manifest.day, segment: manifest.segment)
        try storage.fileWriter.createDirectory(at: directoryURL)
        try storage.writeManifest(manifest, in: directoryURL)
        let bundleURL = storage.rootURL
            .appendingPathComponent(".relay-bundles", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).watchrelay", isDirectory: false)
        try storage.fileWriter.writeData(Data(repeating: 7, count: 256), to: bundleURL, options: .atomic)
        store.recordEnqueue(manifest: manifest, directoryURL: directoryURL, bundleURL: bundleURL, at: now.addingTimeInterval(-600))
        session.seedOutstandingTransfer(id: id)

        let collector = WatchRelayDiagnosticsCollector(
            storage: storage,
            diagnosticsStore: store,
            session: session,
            environmentProvider: MockWatchRelayDiagnosticsEnvironmentProvider()
        )
        XCTAssertNotNil(collector.makeEnvelopeData(asOf: now))

        XCTAssertTrue(session.callLedger.isEmpty)
        let entries = try storage.scanManifests()
        XCTAssertEqual(entries.map(\.manifest.id), [id])
        XCTAssertEqual(entries.first?.manifest.state, .transferring)
        XCTAssertTrue(storage.fileWriter.fileExists(at: bundleURL))
    }
}

@MainActor
final class WatchRelayDiagnosticsStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-relay-diagnostics-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        self.tempDirectory = nil
        try super.tearDownWithError()
    }

    func testSidecarAndSummaryFactsSurviveReconstruction() throws {
        let now = WatchRelayDiagnosticsCollectorTests.now
        let storage = try WatchCaptureStorage(rootURL: self.tempDirectory.appendingPathComponent("store", isDirectory: true))
        let store = WatchRelayDiagnosticsStore(storage: storage)
        let entry = try self.writeManifest(storage: storage)
        let bundleURL = storage.rootURL
            .appendingPathComponent(".relay-bundles", isDirectory: true)
            .appendingPathComponent("\(entry.manifest.id.uuidString).watchrelay", isDirectory: false)
        try storage.fileWriter.writeData(Data(repeating: 7, count: 44), to: bundleURL, options: .atomic)

        store.recordEnqueue(manifest: entry.manifest, directoryURL: entry.directoryURL, bundleURL: bundleURL, at: now)
        store.recordTransferCompletion(
            manifest: entry.manifest,
            directoryURL: entry.directoryURL,
            succeeded: false,
            failure: WatchConnectivityTransferFailureSnapshot(domain: "Test", code: 42, boundedRedactedDescription: "failed"),
            at: now.addingTimeInterval(1)
        )

        let reconstructed = WatchRelayDiagnosticsStore(storage: storage)
        let sidecar = try XCTUnwrap(reconstructed.readSidecar(manifest: entry.manifest, directoryURL: entry.directoryURL).value)
        let summary = try XCTUnwrap(reconstructed.readSummary().value)
        XCTAssertEqual(sidecar.attemptCount, 1)
        XCTAssertEqual(sidecar.sourceBytes, 44)
        XCTAssertEqual(summary.lastTransferCompletion?.failureCount, 1)
        XCTAssertEqual(summary.lastStructuredFailure?.domain, "Test")
    }

    func testCorruptAndFutureDiagnosticPersistenceFailOpenAndSurfaceHistoryGap() throws {
        let storage = try WatchCaptureStorage(rootURL: self.tempDirectory.appendingPathComponent("corrupt", isDirectory: true))
        let store = WatchRelayDiagnosticsStore(storage: storage)
        let entry = try self.writeManifest(storage: storage)
        try storage.fileWriter.writeData(Data("not json".utf8), to: store.sidecarURL(directoryURL: entry.directoryURL), options: .atomic)
        try storage.fileWriter.writeData(Data("{\"version\":999}".utf8), to: store.summaryURL(), options: .atomic)

        XCTAssertEqual(store.readSidecar(manifest: entry.manifest, directoryURL: entry.directoryURL).unavailableReason, WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
        XCTAssertEqual(store.readSummary().unavailableReason, WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
        XCTAssertEqual(try storage.scanManifests().first?.manifest.id, entry.manifest.id)
    }

    func testNumericInvariantFailuresFailOpenPerHistoryFile() throws {
        let now = WatchRelayDiagnosticsCollectorTests.now
        let storage = try WatchCaptureStorage(rootURL: self.tempDirectory.appendingPathComponent("numeric-invariants", isDirectory: true))
        let store = WatchRelayDiagnosticsStore(storage: storage)
        let entry = try self.writeManifest(storage: storage)
        let encoder = Self.diagnosticsEncoder()

        let sidecarCases: [(String, (inout WatchRelaySegmentDiagnosticsSidecar) -> Void)] = [
            ("attempt", { $0.attemptCount = -1 }),
            ("source bytes", { $0.sourceBytes = -1 }),
            ("enqueue", { $0.lastFacts.lastEnqueue = WatchRelayFactCounter(at: now, count: Int.max, segmentID: entry.manifest.id) }),
            ("completion success", {
                $0.lastFacts.lastTransferCompletion = WatchRelayTransferCompletionFact(
                    at: now,
                    segmentID: entry.manifest.id,
                    succeeded: true,
                    successCount: -1,
                    failureCount: 0
                )
            }),
            ("completion failure", {
                $0.lastFacts.lastTransferCompletion = WatchRelayTransferCompletionFact(
                    at: now,
                    segmentID: entry.manifest.id,
                    succeeded: false,
                    successCount: 0,
                    failureCount: Int.max
                )
            }),
            ("ack", { $0.lastFacts.lastDurableACK = WatchRelayFactCounter(at: now, count: -1, segmentID: entry.manifest.id) }),
            ("reconciliation", {
                $0.lastFacts.lastQueueReconciliationObservation = WatchRelayQueueReconciliationFact(
                    at: now,
                    counts: WatchRelayReconciliationCounts(
                        matched: -1,
                        appActiveNotObserved: 0,
                        duplicate: 0,
                        orphaned: 0,
                        unparseable: 0
                    ),
                    observedFileTransferCount: 0,
                    activeManifestCount: 0
                )
            }),
        ]
        for (name, mutate) in sidecarCases {
            var sidecar = WatchRelaySegmentDiagnosticsSidecar(segmentID: entry.manifest.id)
            mutate(&sidecar)
            try storage.fileWriter.writeData(
                try encoder.encode(sidecar),
                to: store.sidecarURL(directoryURL: entry.directoryURL),
                options: .atomic
            )
            XCTAssertEqual(
                store.readSidecar(manifest: entry.manifest, directoryURL: entry.directoryURL).unavailableReason,
                WatchRelayDiagnosticsEnvelopeReason.historyUnavailable,
                name
            )
        }

        let summaryCases: [(String, (inout WatchRelayDiagnosticsSummaryFile) -> Void)] = [
            ("enqueue", { $0.lastEnqueue = WatchRelayFactCounter(at: now, count: -1, segmentID: entry.manifest.id) }),
            ("completion success", {
                $0.lastTransferCompletion = WatchRelayTransferCompletionFact(
                    at: now,
                    segmentID: entry.manifest.id,
                    succeeded: true,
                    successCount: Int.max,
                    failureCount: 0
                )
            }),
            ("completion failure", {
                $0.lastTransferCompletion = WatchRelayTransferCompletionFact(
                    at: now,
                    segmentID: entry.manifest.id,
                    succeeded: false,
                    successCount: 0,
                    failureCount: -1
                )
            }),
            ("ack", { $0.lastDurableACK = WatchRelayFactCounter(at: now, count: Int.max, segmentID: entry.manifest.id) }),
            ("reconciliation", {
                $0.lastQueueReconciliationObservation = WatchRelayQueueReconciliationFact(
                    at: now,
                    counts: WatchRelayReconciliationCounts(
                        matched: 0,
                        appActiveNotObserved: 0,
                        duplicate: 0,
                        orphaned: 0,
                        unparseable: Int.max
                    ),
                    observedFileTransferCount: 0,
                    activeManifestCount: 0
                )
            }),
            ("background completion", {
                $0.lastBackgroundWakeCompletion = WatchRelayBackgroundWakeFact(
                    at: now,
                    reason: "ready",
                    heldTaskCount: -1,
                    completedTaskCount: 0,
                    deadlineCount: 0
                )
            }),
            ("background deadline", {
                $0.lastBackgroundWakeDeadline = WatchRelayBackgroundWakeFact(
                    at: now,
                    reason: "deadline",
                    heldTaskCount: 0,
                    completedTaskCount: 0,
                    deadlineCount: Int.max
                )
            }),
        ]
        for (name, mutate) in summaryCases {
            var summary = WatchRelayDiagnosticsSummaryFile.empty
            mutate(&summary)
            try storage.fileWriter.writeData(
                try encoder.encode(summary),
                to: store.summaryURL(),
                options: .atomic
            )
            XCTAssertEqual(
                store.readSummary().unavailableReason,
                WatchRelayDiagnosticsEnvelopeReason.historyUnavailable,
                name
            )
        }
    }

    func testCounterOverflowMarksProcessHistoryUnavailable() throws {
        let now = WatchRelayDiagnosticsCollectorTests.now
        let storage = try WatchCaptureStorage(rootURL: self.tempDirectory.appendingPathComponent("counter-overflow", isDirectory: true))
        let store = WatchRelayDiagnosticsStore(storage: storage)
        let entry = try self.writeManifest(storage: storage)
        let bundleURL = storage.rootURL
            .appendingPathComponent(".relay-bundles", isDirectory: true)
            .appendingPathComponent("\(entry.manifest.id.uuidString).watchrelay", isDirectory: false)
        try storage.fileWriter.writeData(Data(repeating: 7, count: 44), to: bundleURL, options: .atomic)

        let sidecar = WatchRelaySegmentDiagnosticsSidecar(
            segmentID: entry.manifest.id,
            attemptCount: Int.max - 1
        )
        try storage.fileWriter.writeData(
            try Self.diagnosticsEncoder().encode(sidecar),
            to: store.sidecarURL(directoryURL: entry.directoryURL),
            options: .atomic
        )

        store.recordEnqueue(manifest: entry.manifest, directoryURL: entry.directoryURL, bundleURL: bundleURL, at: now)

        XCTAssertEqual(
            store.readSidecar(manifest: entry.manifest, directoryURL: entry.directoryURL).unavailableReason,
            WatchRelayDiagnosticsEnvelopeReason.historyUnavailable
        )
        XCTAssertEqual(store.readSummary().unavailableReason, WatchRelayDiagnosticsEnvelopeReason.historyUnavailable)
    }

    func testWriteFailureMarkerTripsForEachDiagnosticRecordMethod() throws {
        let now = WatchRelayDiagnosticsCollectorTests.now
        let cases: [(String, (WatchRelayDiagnosticsStore, WatchCaptureStorage.ManifestEntry, URL) -> Void)] = [
            ("enqueue", { store, entry, bundleURL in
                store.recordEnqueue(
                    manifest: entry.manifest,
                    directoryURL: entry.directoryURL,
                    bundleURL: bundleURL,
                    at: now.addingTimeInterval(10)
                )
            }),
            ("successful completion", { store, entry, _ in
                store.recordTransferCompletion(
                    manifest: entry.manifest,
                    directoryURL: entry.directoryURL,
                    succeeded: true,
                    failure: nil,
                    at: now.addingTimeInterval(10)
                )
            }),
            ("failed completion", { store, entry, _ in
                store.recordTransferCompletion(
                    manifest: entry.manifest,
                    directoryURL: entry.directoryURL,
                    succeeded: false,
                    failure: WatchConnectivityTransferFailureSnapshot(domain: "TestFailureDomain", code: 81, boundedRedactedDescription: "failed"),
                    at: now.addingTimeInterval(10)
                )
            }),
            ("durable ack", { store, entry, _ in
                store.recordDurableACK(
                    manifest: entry.manifest,
                    directoryURL: entry.directoryURL,
                    at: now.addingTimeInterval(10)
                )
            }),
            ("queue reconciliation", { store, _, _ in
                store.recordQueueReconciliation(
                    counts: .zero,
                    observedFileTransferCount: 0,
                    activeManifestCount: 0,
                    at: now.addingTimeInterval(10)
                )
            }),
        ]

        for (name, action) in cases {
            let writer = WriteFailingWatchFileWriter()
            let storage = try WatchCaptureStorage(
                rootURL: self.tempDirectory.appendingPathComponent("write-marker-\(name)", isDirectory: true),
                fileWriter: writer
            )
            let store = WatchRelayDiagnosticsStore(storage: storage)
            let entry = try self.writeManifest(storage: storage)
            let bundleURL = storage.rootURL
                .appendingPathComponent(".relay-bundles", isDirectory: true)
                .appendingPathComponent("\(entry.manifest.id.uuidString).watchrelay", isDirectory: false)
            try storage.fileWriter.writeData(Data(repeating: 7, count: 44), to: bundleURL, options: .atomic)
            store.recordEnqueue(manifest: entry.manifest, directoryURL: entry.directoryURL, bundleURL: bundleURL, at: now)
            XCTAssertNotNil(store.readSidecar(manifest: entry.manifest, directoryURL: entry.directoryURL).value, name)
            XCTAssertNotNil(store.readSummary().value, name)

            writer.failWrites = true
            action(store, entry, bundleURL)

            XCTAssertEqual(
                store.readSidecar(manifest: entry.manifest, directoryURL: entry.directoryURL).unavailableReason,
                WatchRelayDiagnosticsEnvelopeReason.historyUnavailable,
                name
            )
            XCTAssertEqual(
                store.readSummary().unavailableReason,
                WatchRelayDiagnosticsEnvelopeReason.historyUnavailable,
                name
            )
        }
    }

    func testStructuredFailureRedactionSurvivesPersistReadAndExport() throws {
        let now = WatchRelayDiagnosticsCollectorTests.now
        let rawPath = "/private/var/mobile/Containers/Data/Application/ABCDEF12-3456-7890-ABCD-EF1234567890/tmp/audio.watchrelay"
        let rawToken = "super-secret-token"
        let storage = try WatchCaptureStorage(rootURL: self.tempDirectory.appendingPathComponent("redaction", isDirectory: true))
        let store = WatchRelayDiagnosticsStore(storage: storage)
        let entry = try self.writeManifest(storage: storage)
        let bundleURL = storage.rootURL
            .appendingPathComponent(".relay-bundles", isDirectory: true)
            .appendingPathComponent("\(entry.manifest.id.uuidString).watchrelay", isDirectory: false)
        try storage.fileWriter.writeData(Data(repeating: 7, count: 44), to: bundleURL, options: .atomic)
        store.recordEnqueue(manifest: entry.manifest, directoryURL: entry.directoryURL, bundleURL: bundleURL, at: now)

        let error = NSError(
            domain: "NSURLErrorDomain",
            code: -1001,
            userInfo: [
                NSLocalizedDescriptionKey: "Authorization: Bearer \(rawToken) failed \(rawPath) token=\(rawToken)",
                "payload": String(repeating: "secret-payload", count: 80),
                "debugPath": rawPath,
                "debugToken": rawToken,
            ]
        )
        store.recordTransferCompletion(
            manifest: entry.manifest,
            directoryURL: entry.directoryURL,
            succeeded: false,
            failure: WatchConnectivityTransferFailureSnapshot(error: error),
            at: now.addingTimeInterval(1)
        )

        let sidecarJSON = String(
            decoding: try storage.fileWriter.readData(from: store.sidecarURL(directoryURL: entry.directoryURL)),
            as: UTF8.self
        )
        let summaryJSON = String(
            decoding: try storage.fileWriter.readData(from: store.summaryURL()),
            as: UTF8.self
        )
        for persisted in [sidecarJSON, summaryJSON] {
            XCTAssertFalse(persisted.contains(rawPath))
            XCTAssertFalse(persisted.contains(rawToken))
            XCTAssertFalse(persisted.contains("secret-payload"))
            XCTAssertFalse(persisted.contains("debugPath"))
            XCTAssertFalse(persisted.contains("debugToken"))
            XCTAssertFalse(persisted.contains("payload"))
            XCTAssertTrue(persisted.contains("NSURLErrorDomain"))
            XCTAssertTrue(persisted.contains("-1001"))
        }

        let reconstructed = WatchRelayDiagnosticsStore(storage: storage)
        let sidecar = try XCTUnwrap(reconstructed.readSidecar(manifest: entry.manifest, directoryURL: entry.directoryURL).value)
        let summary = try XCTUnwrap(reconstructed.readSummary().value)
        for failure in [
            sidecar.lastFacts.lastStructuredFailure,
            summary.lastStructuredFailure,
        ] {
            let structured = try XCTUnwrap(failure)
            XCTAssertEqual(structured.time, now.addingTimeInterval(1))
            XCTAssertEqual(structured.domain, "NSURLErrorDomain")
            XCTAssertEqual(structured.code, -1001)
            XCTAssertLessThanOrEqual(structured.boundedRedactedDescription.count, WatchTransferFailureFormatter.maxDescriptionLength)
            XCTAssertFalse(structured.boundedRedactedDescription.contains(rawPath))
            XCTAssertFalse(structured.boundedRedactedDescription.contains(rawToken))
            XCTAssertFalse(structured.boundedRedactedDescription.contains("secret-payload"))
            XCTAssertTrue(structured.boundedRedactedDescription.contains("[path]"))
            XCTAssertTrue(structured.boundedRedactedDescription.contains("[redacted]"))
        }

        let collector = WatchRelayDiagnosticsCollector(
            storage: storage,
            diagnosticsStore: reconstructed,
            session: MockWatchConnectivitySession(),
            environmentProvider: MockWatchRelayDiagnosticsEnvironmentProvider()
        )
        let data = try XCTUnwrap(collector.makeEnvelopeData(asOf: now.addingTimeInterval(2)))
        let payload = try XCTUnwrap(WatchRelayDiagnosticsEnvelope.decodeResult(from: data).payload)
        let export = WatchPipelineReducer.reduce(WatchRelayDiagnosticsCollectorTests.pipelineInput(
            now: now.addingTimeInterval(2),
            payload: payload
        )).diagnosticsExportText
        XCTAssertTrue(export.contains("NSURLErrorDomain"))
        XCTAssertTrue(export.contains("-1001"))
        XCTAssertFalse(export.contains(rawPath))
        XCTAssertFalse(export.contains(rawToken))
        XCTAssertFalse(export.contains("secret-payload"))
        XCTAssertFalse(export.contains("debugPath"))
        XCTAssertFalse(export.contains("debugToken"))
        XCTAssertFalse(export.contains("payload"))
    }

    private func writeManifest(storage: WatchCaptureStorage) throws -> WatchCaptureStorage.ManifestEntry {
        let manifest = WatchSegmentManifest(
            id: UUID(),
            day: "20260715",
            segment: "120000_300",
            startedAt: WatchRelayDiagnosticsCollectorTests.now,
            duration: 300,
            sensors: [.audio],
            partial: false,
            lost: false,
            gap: false,
            fixCount: 0,
            state: .transferring
        )
        let directoryURL = storage.segmentDirectoryURL(day: manifest.day, segment: manifest.segment)
        try storage.fileWriter.createDirectory(at: directoryURL)
        try storage.writeManifest(manifest, in: directoryURL)
        return WatchCaptureStorage.ManifestEntry(
            directoryURL: directoryURL,
            manifestURL: storage.manifestURL(directory: directoryURL),
            manifest: manifest
        )
    }

    private static func diagnosticsEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

nonisolated final class WatchTransferFailureFormatterTests: XCTestCase {
    func testStructuredFailureKeepsTimeDomainCodeAndRedactsPathBearerAuthorization() {
        let text = "Authorization: Bearer abc123 failed /private/var/mobile/Containers/Data/Application/ABC/file.watchrelay"
        let snapshot = WatchConnectivityTransferFailureSnapshot(domain: "NSURLErrorDomain", code: -1009, boundedRedactedDescription: text)
        let structured = WatchTransferStructuredFailure(time: WatchRelayDiagnosticsCollectorTests.now, snapshot: snapshot)

        XCTAssertEqual(structured.domain, "NSURLErrorDomain")
        XCTAssertEqual(structured.code, -1009)
        XCTAssertFalse(structured.boundedRedactedDescription.contains("abc123"))
        XCTAssertFalse(structured.boundedRedactedDescription.contains("/private/var"))
        XCTAssertLessThanOrEqual(structured.boundedRedactedDescription.count, 200)
    }

    func testOversizedNSErrorUserInfoIsNeverPersistedOrExported() {
        let error = NSError(
            domain: "TestDomain",
            code: 17,
            userInfo: [
                "payload": String(repeating: "secret", count: 200),
                NSLocalizedDescriptionKey: "failed with token=abc /tmp/raw/file"
            ]
        )
        let snapshot = WatchConnectivityTransferFailureSnapshot(error: error)
        XCTAssertEqual(snapshot.domain, "TestDomain")
        XCTAssertEqual(snapshot.code, 17)
        XCTAssertFalse(snapshot.boundedRedactedDescription.contains("secretsecret"))
        XCTAssertFalse(snapshot.boundedRedactedDescription.contains("abc"))
        XCTAssertFalse(snapshot.boundedRedactedDescription.contains("/tmp"))
    }
}

nonisolated final class WatchRelayProgressRenderingTests: XCTestCase {
    func testNilZeroAndIndeterminateProgressRenderDistinctly() {
        let zero = WatchRelayDiagnosticsCollectorTests.observation(
            id: UUID(),
            age: 0,
            progress: .available(MockWatchConnectivitySession.defaultProgress(
                isIndeterminate: false,
                completedUnitCount: 0,
                totalUnitCount: 100,
                fractionCompleted: 0
            ))
        )
        let indeterminate = WatchRelayDiagnosticsCollectorTests.observation(
            id: UUID(),
            age: 0,
            progress: .available(MockWatchConnectivitySession.defaultProgress(isIndeterminate: true))
        )
        let noValue = WatchRelayDiagnosticsCollectorTests.observation(
            id: UUID(),
            age: 0,
            progress: .unavailable(reason: "not provided")
        )
        let payload = WatchRelayDiagnosticsCollectorTests.payload(
            generatedAt: Self.now,
            observations: [zero, indeterminate, noValue]
        )
        let export = WatchPipelineReducer.reduce(WatchRelayDiagnosticsCollectorTests.pipelineInput(payload: payload)).diagnosticsExportText
        XCTAssertTrue(export.contains("fraction 0.000"))
        XCTAssertTrue(export.contains(SourceVocabulary.watchDiagnosticsIndeterminate))
        XCTAssertTrue(export.contains("progress not provided"))
    }

    func testThroughputAndETARenderNotProvidedWhenAppleDoesNotSupplyThem() {
        let payload = WatchRelayDiagnosticsCollectorTests.payload(
            generatedAt: Self.now,
            observations: [WatchRelayDiagnosticsCollectorTests.observation(
                id: UUID(),
                age: 0,
                progress: .available(MockWatchConnectivitySession.defaultProgress())
            )]
        )
        let export = WatchPipelineReducer.reduce(WatchRelayDiagnosticsCollectorTests.pipelineInput(payload: payload)).diagnosticsExportText
        XCTAssertTrue(export.contains("throughput \(SourceVocabulary.watchDiagnosticsNotProvided)"))
        XCTAssertTrue(export.contains("eta \(SourceVocabulary.watchDiagnosticsNotProvided)"))
        XCTAssertFalse(export.contains("synthetic"))
    }
}

nonisolated final class WatchRelayDiagnosticsEnvelopeTests: XCTestCase {
    func testValidEnvelopeDecodesAlongsideLegacyCore() throws {
        let payload = WatchRelayDiagnosticsCollectorTests.payload(generatedAt: Self.now)
        let data = try WatchRelayDiagnosticsEnvelope.makeEncoder().encode(WatchRelayDiagnosticsEnvelope(
            generatedAt: Self.now,
            diagnostics: .available(payload)
        ))
        let context = WatchStatusContext(
            phase: .observing,
            sessionID: "session",
            startedAt: Self.now,
            asOf: Self.now,
            seq: 7,
            queuedCount: 1,
            transferringCount: 2,
            diagnosticsEnvelope: data
        )
        let decoded = try XCTUnwrap(WatchStatusContext(applicationContext: context.applicationContext()))
        let result = WatchRelayDiagnosticsEnvelope.decodeResult(from: decoded.diagnosticsEnvelope)
        XCTAssertEqual(decoded.seq, 7)
        XCTAssertNotNil(result.payload)
    }

    func testOldPayloadWithoutEnvelopePreservesCoreAndReportsAbsent() throws {
        let context = WatchStatusContext(
            phase: .idle,
            sessionID: nil,
            startedAt: nil,
            asOf: Self.now,
            seq: 1,
            queuedCount: 0,
            transferringCount: 0
        )
        let decoded = try XCTUnwrap(WatchStatusContext(applicationContext: context.applicationContext()))
        let result = WatchRelayDiagnosticsEnvelope.decodeResult(from: decoded.diagnosticsEnvelope)
        XCTAssertEqual(decoded.phase, .idle)
        XCTAssertEqual(result.unavailableReason, WatchRelayDiagnosticsEnvelopeReason.absent)
    }

    func testUnknownVersionPreservesCoreAndReportsUnsupported() throws {
        let data = Data(#"{"version":999,"generatedAt":"2026-07-15T00:00:00Z","diagnostics":{"state":"unavailable","reason":"future"}}"#.utf8)
        let result = WatchRelayDiagnosticsEnvelope.decodeResult(from: data)
        XCTAssertEqual(result.unavailableReason, WatchRelayDiagnosticsEnvelopeReason.unsupportedVersion)
        XCTAssertEqual(result.unsupportedVersion, 999)
    }

    func testMalformedOptionalsAndInvalidEnvelopePreserveCoreAndReportMalformed() {
        let result = WatchRelayDiagnosticsEnvelope.decodeResult(from: Data("not json".utf8))
        XCTAssertEqual(result.unavailableReason, WatchRelayDiagnosticsEnvelopeReason.malformed)
    }

    func testPresentWrongTypeEnvelopePreservesCoreAndReportsUnreadable() throws {
        let json = Data("""
        {
          "phase": "observing",
          "sessionID": "session",
          "startedAt": "2026-07-15T00:00:00Z",
          "asOf": "2026-07-15T00:00:00Z",
          "seq": 9,
          "queuedCount": 2,
          "transferringCount": 1,
          "diagnosticsEnvelope": 42
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WatchStatusContext.self, from: json)
        let result = WatchRelayDiagnosticsEnvelope.decodeResult(from: decoded.diagnosticsEnvelope)

        XCTAssertEqual(decoded.phase, .observing)
        XCTAssertEqual(decoded.seq, 9)
        XCTAssertEqual(decoded.queuedCount, 2)
        XCTAssertEqual(decoded.transferringCount, 1)
        XCTAssertEqual(result.unavailableReason, WatchRelayDiagnosticsEnvelopeReason.unreadable)
        XCTAssertNotEqual(result.unavailableReason, WatchRelayDiagnosticsEnvelopeReason.absent)
        XCTAssertNotEqual(result.unavailableReason, WatchRelayDiagnosticsEnvelopeReason.malformed)
    }
}

nonisolated final class WatchRelayDiagnosticsPublicationTests: XCTestCase {
    func testExtendedPublicationFailureFallsBackToLegacyCoreWithUnavailableMarker() throws {
        let marker = try XCTUnwrap(WatchRelayDiagnosticsCollector.unavailableEnvelopeData(
            generatedAt: Self.now,
            reason: WatchRelayDiagnosticsEnvelopeReason.publicationFailed
        ))
        let context = WatchStatusContext(
            phase: .observing,
            sessionID: "session",
            startedAt: Self.now,
            asOf: Self.now,
            seq: 3,
            queuedCount: 4,
            transferringCount: 5,
            diagnosticsEnvelope: marker
        )

        let decoded = try XCTUnwrap(WatchStatusContext(applicationContext: context.applicationContext()))
        let result = WatchRelayDiagnosticsEnvelope.decodeResult(from: decoded.diagnosticsEnvelope)
        XCTAssertEqual(decoded.queuedCount, 4)
        XCTAssertEqual(decoded.transferringCount, 5)
        XCTAssertEqual(result.unavailableReason, WatchRelayDiagnosticsEnvelopeReason.publicationFailed)
    }
}

nonisolated final class WatchRelayCompatibilityTests: XCTestCase {
    func testNewIPhoneOldWatchStatusCoreStillDrivesExistingReceiptAndACKFlow() throws {
        let context = WatchStatusContext(
            phase: .observing,
            sessionID: "old",
            startedAt: Self.now,
            asOf: Self.now,
            seq: 1,
            queuedCount: 2,
            transferringCount: 1
        )
        let decoded = try XCTUnwrap(WatchStatusContext(applicationContext: context.applicationContext()))
        XCTAssertNil(decoded.diagnosticsEnvelope)
        XCTAssertEqual(decoded.queuedCount, 2)
        XCTAssertEqual(WatchRelayDiagnosticsEnvelope.decodeResult(from: decoded.diagnosticsEnvelope).unavailableReason, WatchRelayDiagnosticsEnvelopeReason.absent)
    }

    func testOldIPhoneNewWatchStatusCoreIgnoresEnvelopeAndPreservesRelaySemantics() throws {
        let envelope = WatchRelayDiagnosticsCollector.unavailableEnvelopeData(
            generatedAt: Self.now,
            reason: WatchRelayDiagnosticsEnvelopeReason.publicationFailed
        )
        let context = WatchStatusContext(
            phase: .observing,
            sessionID: "new",
            startedAt: Self.now,
            asOf: Self.now,
            seq: 2,
            queuedCount: 3,
            transferringCount: 4,
            diagnosticsEnvelope: envelope
        )
        let decoded = try XCTUnwrap(WatchStatusContext(applicationContext: context.applicationContext()))
        XCTAssertEqual(decoded.phase, .observing)
        XCTAssertEqual(decoded.seq, 2)
        XCTAssertEqual(decoded.queuedCount, 3)
        XCTAssertEqual(decoded.transferringCount, 4)
    }
}

nonisolated final class WatchPipelineReducerDiagnosticsExportTests: XCTestCase {
    func testDirectionLabeledUserInfoTotalsRenderFromWatchAndIPhoneInputs() {
        let payload = WatchRelayDiagnosticsCollectorTests.payload(
            generatedAt: Self.now,
            queue: WatchRelayAppleQueueSnapshot(
                asOf: Self.now,
                outstandingFileTransferCount: 0,
                outstandingUserInfoTransferCountWatchToPhone: 3,
                reconciliation: .zero,
                exactObservationCountBeforeCompaction: 0
            )
        )
        let export = WatchPipelineReducer.reduce(Self.input(payload: payload, iphoneACKCount: 2)).diagnosticsExportText
        XCTAssertTrue(export.contains("\(SourceVocabulary.watchDiagnosticsWatchUserInfoQueueLabel): 3"))
        XCTAssertTrue(export.contains("\(SourceVocabulary.watchDiagnosticsIPhoneACKQueueLabel): 2"))
    }

    func testOldTransferringManifestWithMatchingAppleTransferReportsAppleOwnedAgingWithoutPhoneReceipt() {
        let id = UUID()
        let payload = WatchRelayDiagnosticsCollectorTests.payload(
            generatedAt: Self.now,
            manifestSummary: Self.oldBacklogSummary(),
            queue: Self.queue(matched: 1),
            observations: [WatchRelayDiagnosticsCollectorTests.observation(id: id, age: 900)]
        )
        let summary = WatchPipelineReducer.reduce(Self.input(payload: payload, lastReceivedAt: nil))
        XCTAssertTrue(summary.diagnosticsExportText.contains("Apple owns matching outstanding transfers with determinate progress"))
        XCTAssertEqual(summary.stuck, WatchPipelineStuck.none)
    }

    func testOldTransferringManifestWithoutMatchingAppleTransferReportsPointInTimeDisagreement() {
        let payload = WatchRelayDiagnosticsCollectorTests.payload(
            generatedAt: Self.now,
            manifestSummary: Self.oldBacklogSummary(),
            queue: Self.queue(appActiveNotObserved: 1),
            observations: [WatchRelayDiagnosticsCollectorTests.observation(id: UUID(), age: 900, relation: .appActiveNotObserved, progress: .unavailable(reason: "not observed"))]
        )
        let export = WatchPipelineReducer.reduce(Self.input(payload: payload, lastReceivedAt: nil)).diagnosticsExportText
        XCTAssertTrue(export.contains("point-in-time app/Apple queue disagreement"))
    }

    func testReachabilityDoesNotChangeReportOnlyRelayAssessment() {
        let payload = WatchRelayDiagnosticsCollectorTests.payload(
            generatedAt: Self.now,
            manifestSummary: Self.oldBacklogSummary(),
            queue: Self.queue(appActiveNotObserved: 1)
        )
        let reachable = WatchPipelineReducer.reduce(Self.input(payload: payload, isReachable: true)).diagnosticsExportText
        let unreachable = WatchPipelineReducer.reduce(Self.input(payload: payload, isReachable: false)).diagnosticsExportText
        XCTAssertEqual(reachable.contains("point-in-time app/Apple queue disagreement"), unreachable.contains("point-in-time app/Apple queue disagreement"))
    }

    func testStaleSnapshotSuppressesCurrentProgressAndLabelsStale() {
        let progress = WatchConnectivityProgressSnapshot(
            isIndeterminate: false,
            isFinished: false,
            isCancelled: false,
            completedUnitCount: 42,
            totalUnitCount: 100,
            fractionCompleted: 0.42,
            throughputBytesPerSecond: 1234,
            estimatedTimeRemainingSeconds: 56,
            kind: "file",
            fileTotalCount: nil,
            fileCompletedCount: nil
        )
        let payload = WatchRelayDiagnosticsCollectorTests.payload(
            generatedAt: Self.now,
            observations: [
                WatchRelayDiagnosticsCollectorTests.observation(
                    id: UUID(),
                    age: 900,
                    progress: .available(progress)
                )
            ]
        )
        let export = WatchPipelineReducer.reduce(Self.input(
            watchStatus: Self.context(asOf: Self.now.addingTimeInterval(-120)),
            payload: payload
        )).diagnosticsExportText
        XCTAssertTrue(export.contains("diagnostic evidence stale"))
        XCTAssertTrue(export.contains("progress not shown - snapshot is stale"))
        XCTAssertFalse(export.contains("fraction 0.420"))
        XCTAssertFalse(export.contains("units 42/100"))
        XCTAssertFalse(export.contains("throughput 1234"))
        XCTAssertFalse(export.contains("eta 56s"))
    }

    func testBuildMatchRendersYesNoAndUnavailable() {
        let matching = WatchPipelineReducer.reduce(Self.input(
            payload: WatchRelayDiagnosticsCollectorTests.payload(generatedAt: Self.now, watchBuild: .available("55")),
            iphoneBuild: .available("55")
        )).diagnosticsExportText
        let different = WatchPipelineReducer.reduce(Self.input(
            payload: WatchRelayDiagnosticsCollectorTests.payload(generatedAt: Self.now, watchBuild: .available("56")),
            iphoneBuild: .available("55")
        )).diagnosticsExportText
        let unavailable = WatchPipelineReducer.reduce(Self.input(
            payload: WatchRelayDiagnosticsCollectorTests.payload(generatedAt: Self.now, watchBuild: .unavailable(reason: "missing")),
            iphoneBuild: .available("55")
        )).diagnosticsExportText
        XCTAssertTrue(matching.contains("watch build match: yes"))
        XCTAssertTrue(different.contains("watch build match: no"))
        XCTAssertTrue(unavailable.contains("watch build match: unavailable"))
    }

    func testPowerContextLabelsReportTimeAndSnapshotTime() {
        let export = WatchPipelineReducer.reduce(Self.input(payload: WatchRelayDiagnosticsCollectorTests.payload(generatedAt: Self.now))).diagnosticsExportText
        XCTAssertTrue(export.contains("iphone battery level at report time"))
        XCTAssertTrue(export.contains("watch battery level at snapshot time"))
    }

    func testExportContainsExactlyFiveStageSectionsInOrder() {
        let export = WatchPipelineReducer.reduce(Self.input(payload: WatchRelayDiagnosticsCollectorTests.payload(generatedAt: Self.now))).diagnosticsExportText
        let sections = [
            SourceVocabulary.watchDiagnosticsStageReportEnvironment,
            SourceVocabulary.watchDiagnosticsStageWatchSnapshot,
            SourceVocabulary.watchDiagnosticsStageRetentionAppleQueue,
            SourceVocabulary.watchDiagnosticsStageIPhoneStaging,
            SourceVocabulary.watchDiagnosticsStageJournalHandoff,
        ]
        for section in sections {
            XCTAssertTrue(export.contains(section))
        }
        XCTAssertEqual(sections.reduce(0) { count, section in count + (export.contains(section) ? 1 : 0) }, 5)
        XCTAssertFalse(export.contains("\nrelay assessment\n"))
    }

    func testExportIncludesTimestampAgeProgressUnavailableAndDirectionLabels() {
        let export = WatchPipelineReducer.reduce(Self.input(payload: WatchRelayDiagnosticsCollectorTests.payload(
            generatedAt: Self.now,
            observations: [WatchRelayDiagnosticsCollectorTests.observation(id: UUID(), age: 0, progress: .available(MockWatchConnectivitySession.defaultProgress(isIndeterminate: true)))]
        ))).diagnosticsExportText
        XCTAssertTrue(export.contains("as of"))
        XCTAssertTrue(export.contains(SourceVocabulary.watchDiagnosticsIndeterminate))
        XCTAssertTrue(export.contains(SourceVocabulary.watchDiagnosticsWatchUserInfoQueueLabel))
        XCTAssertTrue(export.contains(SourceVocabulary.watchDiagnosticsIPhoneACKQueueLabel))
    }

    func testExportDoesNotContainRawPathsPayloadAudioLocationDeviceIDEndpointCredentialOrToken() {
        let failure = WatchTransferStructuredFailure(
            time: Self.now,
            domain: "Test",
            code: 9,
            boundedRedactedDescription: "failed /tmp/raw/audio.m4a token=abc https://example.test/path"
        )
        let payload = WatchRelayDiagnosticsCollectorTests.payload(
            generatedAt: Self.now,
            lastFacts: WatchRelayLastFactsSummary(
                lastEnqueue: nil,
                lastTransferCompletion: nil,
                lastStructuredFailure: failure,
                lastDurableACK: nil,
                lastQueueReconciliationObservation: nil,
                lastBackgroundWakeCompletion: nil,
                lastBackgroundWakeDeadline: nil
            )
        )
        let export = WatchPipelineReducer.reduce(Self.input(
            payload: payload,
            lastUploadError: "credential=abc /Users/me/file"
        )).diagnosticsExportText
        XCTAssertFalse(export.contains("/tmp"))
        XCTAssertFalse(export.contains("/Users"))
        XCTAssertFalse(export.contains("abc"))
        XCTAssertFalse(export.contains("example.test"))
    }
}

@MainActor
private final class CountingWatchFileWriter: WatchFileWriting {
    private let base = FoundationWatchFileWriter()
    private(set) var writeCounts: [String: Int] = [:]

    func resetCounts() {
        self.writeCounts = [:]
    }

    func writeCount(for url: URL) -> Int {
        self.writeCounts[url.standardizedFileURL.path] ?? 0
    }

    func createDirectory(at url: URL) throws {
        try self.base.createDirectory(at: url)
    }

    func createFileIfNeeded(at url: URL) throws {
        try self.base.createFileIfNeeded(at: url)
    }

    func fileExists(at url: URL) -> Bool {
        self.base.fileExists(at: url)
    }

    func fileSize(at url: URL) throws -> Int64 {
        try self.base.fileSize(at: url)
    }

    func readData(from url: URL) throws -> Data {
        try self.base.readData(from: url)
    }

    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        self.writeCounts[url.standardizedFileURL.path, default: 0] += 1
        try self.base.writeData(data, to: url, options: options)
    }

    func appendLine(_ line: Data, to url: URL) throws {
        try self.base.appendLine(line, to: url)
    }

    func atomicReplaceFile(at url: URL, with data: Data) throws {
        try self.base.atomicReplaceFile(at: url, with: data)
    }

    func removeItem(at url: URL) throws {
        try self.base.removeItem(at: url)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try self.base.moveItem(at: sourceURL, to: destinationURL)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try self.base.contentsOfDirectory(at: url)
    }
}

@MainActor
private final class WriteFailingWatchFileWriter: WatchFileWriting {
    private let base = FoundationWatchFileWriter()
    var failWrites = false
    var failOnlyDiagnosticFiles = false

    func createDirectory(at url: URL) throws {
        try self.base.createDirectory(at: url)
    }

    func createFileIfNeeded(at url: URL) throws {
        try self.base.createFileIfNeeded(at: url)
    }

    func fileExists(at url: URL) -> Bool {
        self.base.fileExists(at: url)
    }

    func fileSize(at url: URL) throws -> Int64 {
        try self.base.fileSize(at: url)
    }

    func readData(from url: URL) throws -> Data {
        try self.base.readData(from: url)
    }

    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        if self.failWrites,
           (!self.failOnlyDiagnosticFiles || Self.isDiagnosticURL(url)) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        }
        try self.base.writeData(data, to: url, options: options)
    }

    func appendLine(_ line: Data, to url: URL) throws {
        try self.base.appendLine(line, to: url)
    }

    func atomicReplaceFile(at url: URL, with data: Data) throws {
        try self.base.atomicReplaceFile(at: url, with: data)
    }

    func removeItem(at url: URL) throws {
        try self.base.removeItem(at: url)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try self.base.moveItem(at: sourceURL, to: destinationURL)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try self.base.contentsOfDirectory(at: url)
    }

    private static func isDiagnosticURL(_ url: URL) -> Bool {
        url.lastPathComponent == WatchRelayDiagnosticsStore.sidecarFilename
            || url.lastPathComponent == WatchRelayDiagnosticsStore.summaryFilename
    }
}

@MainActor
private final class ForcedExistingWatchFileWriter: WatchFileWriting {
    private let base = FoundationWatchFileWriter()
    private var forcedExistingPaths: Set<String> = []

    func forceExists(at url: URL) {
        self.forcedExistingPaths.insert(url.standardizedFileURL.path)
    }

    func createDirectory(at url: URL) throws {
        try self.base.createDirectory(at: url)
    }

    func createFileIfNeeded(at url: URL) throws {
        try self.base.createFileIfNeeded(at: url)
    }

    func fileExists(at url: URL) -> Bool {
        self.forcedExistingPaths.contains(url.standardizedFileURL.path) || self.base.fileExists(at: url)
    }

    func fileSize(at url: URL) throws -> Int64 {
        try self.base.fileSize(at: url)
    }

    func readData(from url: URL) throws -> Data {
        try self.base.readData(from: url)
    }

    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        try self.base.writeData(data, to: url, options: options)
    }

    func appendLine(_ line: Data, to url: URL) throws {
        try self.base.appendLine(line, to: url)
    }

    func atomicReplaceFile(at url: URL, with data: Data) throws {
        try self.base.atomicReplaceFile(at: url, with: data)
    }

    func removeItem(at url: URL) throws {
        try self.base.removeItem(at: url)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try self.base.moveItem(at: sourceURL, to: destinationURL)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try self.base.contentsOfDirectory(at: url)
    }
}

@MainActor
private final class MutatingWatchFileWriter: WatchFileWriting {
    private let base = FoundationWatchFileWriter()
    private var fileExistsCounts: [String: Int] = [:]
    private var mutationPath: String?
    private var mutation: (() -> Void)?
    private(set) var writeCount = 0

    func mutateBeforeSecondFileExists(at url: URL, _ mutation: @escaping () -> Void) {
        self.mutationPath = url.standardizedFileURL.path
        self.mutation = mutation
    }

    func resetWriteCount() {
        self.writeCount = 0
    }

    func createDirectory(at url: URL) throws {
        try self.base.createDirectory(at: url)
    }

    func createFileIfNeeded(at url: URL) throws {
        try self.base.createFileIfNeeded(at: url)
    }

    func fileExists(at url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let count = (self.fileExistsCounts[path] ?? 0) + 1
        self.fileExistsCounts[path] = count
        if path == self.mutationPath, count == 2 {
            let mutation = self.mutation
            self.mutation = nil
            mutation?()
        }
        return self.base.fileExists(at: url)
    }

    func fileSize(at url: URL) throws -> Int64 {
        try self.base.fileSize(at: url)
    }

    func readData(from url: URL) throws -> Data {
        try self.base.readData(from: url)
    }

    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        self.writeCount += 1
        try self.base.writeData(data, to: url, options: options)
    }

    func appendLine(_ line: Data, to url: URL) throws {
        try self.base.appendLine(line, to: url)
    }

    func atomicReplaceFile(at url: URL, with data: Data) throws {
        try self.base.atomicReplaceFile(at: url, with: data)
    }

    func removeItem(at url: URL) throws {
        try self.base.removeItem(at: url)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try self.base.moveItem(at: sourceURL, to: destinationURL)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try self.base.contentsOfDirectory(at: url)
    }
}

@MainActor
private final class MockWatchBatteryDevice: WatchBatteryDevice {
    var isBatteryMonitoringEnabled: Bool {
        didSet {
            self.monitoringAssignments.append(self.isBatteryMonitoringEnabled)
        }
    }
    var monitoringAssignments: [Bool] = []

    init(isBatteryMonitoringEnabled: Bool = false) {
        self.isBatteryMonitoringEnabled = isBatteryMonitoringEnabled
    }

    var batteryLevelReading: Float {
        self.isBatteryMonitoringEnabled ? 0.42 : -1
    }

    var batteryStateReading: WatchBatteryStateReading {
        self.isBatteryMonitoringEnabled ? .charging : .unknown
    }
}

private extension WatchRelayDiagnosticsCollectorTests {
    nonisolated static let now = Date(timeIntervalSince1970: 1_784_073_600)

    static func historyEntry(_ index: Int, at date: Date) -> WatchCaptureSessionHistoryEntry {
        WatchCaptureSessionHistoryEntry(sessionID: "history-\(index)", startedAt: date.addingTimeInterval(-60), terminalAt: date,
            terminalReason: .processExitedWhileActive, terminalDisposition: .inferredStoppedItself,
            startRefusalReason: .microphonePermissionNotDetermined, settingsRoute: .notificationSettings,
            noticeOwed: true, noticeDecision: "cannot-schedule", noticeDelivered: false,
            notificationAuthorizationStatus: .denied, notificationAlertSetting: .notSupported, wristAlertAssurance: .alertsOff,
            audioArmed: true, audioSessionIsActive: true, locationArmed: true, segmentsProduced: 99,
            batteryLevelAtEnd: 0.987654321, batteryStateAtEnd: "charging", lowPowerModeEnabledAtEnd: true,
            thermalStateAtEnd: "critical", lastVerifiedAudioAt: date, lastAudioCurrentTime: 123456.789012345,
            zeroAudioCurrentTimeObservationCount: 999, locationAdvisory: .providerFailed, persistenceAdvisory: .sessionRecordWriteFailed)
    }

    static func withHistory(_ payload: WatchRelayDiagnosticsPayload, entries: [WatchCaptureSessionHistoryEntry], depth: Int) -> WatchRelayDiagnosticsPayload {
        WatchRelayDiagnosticsPayload(watchAppMarketingVersion: payload.watchAppMarketingVersion, watchAppBuild: payload.watchAppBuild,
            watchOSVersion: payload.watchOSVersion, activationState: payload.activationState,
            isCompanionAppInstalled: payload.isCompanionAppInstalled, isReachable: payload.isReachable,
            iOSDeviceNeedsUnlockAfterRebootForReachability: payload.iOSDeviceNeedsUnlockAfterRebootForReachability,
            hasContentPending: payload.hasContentPending, watchBatteryLevel: payload.watchBatteryLevel,
            watchBatteryState: payload.watchBatteryState, watchLowPowerModeEnabled: payload.watchLowPowerModeEnabled,
            watchThermalState: payload.watchThermalState, manifestSummary: payload.manifestSummary,
            appleQueue: payload.appleQueue, lastFacts: payload.lastFacts, observedFileTransfers: payload.observedFileTransfers,
            omittedObservationCount: payload.omittedObservationCount, sessionHistoryWindow: .available(entries),
            lifetimeSessionsStarted: .available(10), sessionHistoryCounterEpoch: .available("epoch"), sessionHistoryDepth: depth)
    }

    nonisolated static func uuid(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
    }

    nonisolated static func worktreeRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    nonisolated static func transfer(
        id: UUID?,
        idState: WatchRelayTransferIDState? = nil
    ) -> WatchConnectivityFileTransferSnapshot {
        WatchConnectivityFileTransferSnapshot(
            asOf: Self.now,
            segmentID: id,
            idState: idState ?? (id == nil ? .missing : .parseable),
            isTransferring: true,
            progress: MockWatchConnectivitySession.defaultProgress()
        )
    }

    nonisolated static func observation(
        id: UUID?,
        age: TimeInterval?,
        relation: WatchRelayObservationRelation = .matched,
        progress: DiagnosticAvailability<WatchConnectivityProgressSnapshot> = .available(MockWatchConnectivitySession.defaultProgress()),
        originalAudioFile: DiagnosticAvailability<WatchRelayOriginalFileFact> = .available(
            WatchRelayOriginalFileFact(state: .missing, byteCount: 0)
        ),
        originalLocationFile: DiagnosticAvailability<WatchRelayOriginalFileFact> = .available(
            WatchRelayOriginalFileFact(state: .missing, byteCount: 0)
        ),
        relayBundlePresent: DiagnosticAvailability<Bool> = .available(true),
        relayBundleBytes: DiagnosticAvailability<Int64> = .available(128),
        collectionResolution: DiagnosticAvailability<WatchRelayObservationCollectionResolution> = .available(.stable)
    ) -> WatchRelayTransferObservation {
        WatchRelayTransferObservation(
            asOf: Self.now,
            segmentID: id,
            idState: id == nil ? .missing : .parseable,
            relation: relation,
            appManifestState: relation == .orphaned ? nil : WatchSegmentState.transferring.rawValue,
            appOwnedEnqueueAgeSeconds: .available(age),
            appOwnedSourceBytes: .available(128),
            sourcePresent: .available(true),
            isTransferring: .available(true),
            progress: progress,
            originalAudioFile: originalAudioFile,
            originalLocationFile: originalLocationFile,
            relayBundlePresent: relayBundlePresent,
            relayBundleBytes: relayBundleBytes,
            collectionResolution: collectionResolution
        )
    }

    nonisolated static func orphanObservation(id: UUID) -> WatchRelayTransferObservation {
        WatchRelayTransferObservation(
            asOf: Date(timeIntervalSince1970: 0),
            segmentID: id,
            idState: .parseable,
            relation: .orphaned,
            appManifestState: nil,
            appOwnedEnqueueAgeSeconds: .unavailable(reason: "no app-active manifest"),
            appOwnedSourceBytes: .unavailable(reason: "no app-active manifest"),
            sourcePresent: .unavailable(reason: "no app-active manifest"),
            isTransferring: .available(true),
            progress: .available(MockWatchConnectivitySession.defaultProgress()),
            originalAudioFile: .unavailable(reason: "no app-active manifest"),
            originalLocationFile: .unavailable(reason: "no app-active manifest"),
            relayBundlePresent: .unavailable(reason: "no app-active manifest"),
            relayBundleBytes: .unavailable(reason: "no app-active manifest"),
            collectionResolution: .available(.stable)
        )
    }

    nonisolated static func payload(
        generatedAt: Date,
        watchBuild: DiagnosticAvailability<String> = .available("55"),
        manifestSummary: WatchRelayManifestSummary = WatchRelayManifestSummary(
            counts: .zero,
            activeBacklogCount: 0,
            retainedSourceBytes: .available(0),
            oldestActiveEnqueuedAt: .available(nil),
            oldestActiveEnqueueAgeSeconds: .available(nil)
        ),
        queue: WatchRelayAppleQueueSnapshot = WatchRelayAppleQueueSnapshot(
            asOf: WatchRelayDiagnosticsCollectorTests.now,
            outstandingFileTransferCount: 0,
            outstandingUserInfoTransferCountWatchToPhone: 0,
            reconciliation: .zero,
            exactObservationCountBeforeCompaction: 0
        ),
        lastFacts: WatchRelayLastFactsSummary = WatchRelayLastFactsSummary(
            lastEnqueue: nil,
            lastTransferCompletion: nil,
            lastStructuredFailure: nil,
            lastDurableACK: nil,
            lastQueueReconciliationObservation: nil,
            lastBackgroundWakeCompletion: nil,
            lastBackgroundWakeDeadline: nil
        ),
        observations: [WatchRelayTransferObservation] = []
    ) -> WatchRelayDiagnosticsPayload {
        WatchRelayDiagnosticsPayload(
            watchAppMarketingVersion: .available("0.1.0"),
            watchAppBuild: watchBuild,
            watchOSVersion: .available("26.0"),
            activationState: "activated",
            isCompanionAppInstalled: .available(true),
            isReachable: true,
            iOSDeviceNeedsUnlockAfterRebootForReachability: .available(false),
            hasContentPending: false,
            watchBatteryLevel: .available(0.75),
            watchBatteryState: .available("unplugged"),
            watchLowPowerModeEnabled: .available(false),
            watchThermalState: .available("nominal"),
            manifestSummary: .available(manifestSummary),
            appleQueue: .available(queue),
            lastFacts: .available(lastFacts),
            observedFileTransfers: observations,
            omittedObservationCount: 0
        )
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

    nonisolated static func pipelineInput(
        now: Date = WatchRelayDiagnosticsCollectorTests.now,
        watchStatus: WatchStatusContext? = nil,
        payload: WatchRelayDiagnosticsPayload,
        isReachable: Bool = true,
        lastReceivedAt: Date? = WatchRelayDiagnosticsCollectorTests.now,
        iphoneBuild: DiagnosticAvailability<String> = .available("55"),
        iphoneACKCount: Int = 0,
        lastUploadError: String? = nil,
        phoneLedgerSnapshot: DiagnosticAvailability<WatchSegmentLedgerReadSnapshot> = .unavailable(reason: "not provided")
    ) -> WatchPipelineInput {
        WatchPipelineInput(
            now: now,
            watchStatus: watchStatus ?? Self.context(asOf: now),
            lifetimeReceived: 0,
            lifetimeHanded: 0,
            nonTerminalCount: 0,
            lastHandedAt: nil,
            oldestNonTerminalReceivedAt: nil,
            lastLedgerError: nil,
            pendingCount: 0,
            failedCount: 0,
            inFlightCount: 0,
            lastUploadAt: nil,
            lastUploadError: lastUploadError,
            lastReceivedAt: lastReceivedAt,
            lastStagingError: nil,
            isPaired: true,
            isWatchAppInstalled: true,
            activationState: .activated,
            isReachable: isReachable,
            isJournalReachable: true,
            watchDiagnostics: .available(payload, rawEnvelopeByteCount: nil),
            iphoneAppMarketingVersion: .available("0.1.0"),
            iphoneAppBuild: iphoneBuild,
            iOSVersion: .available("26.0"),
            iphoneBatteryLevel: .available(0.5),
            iphoneBatteryState: .available("unplugged"),
            iphoneLowPowerModeEnabled: .available(false),
            iphoneThermalState: .available("nominal"),
            phoneLedgerSnapshot: phoneLedgerSnapshot,
            iphoneACKQueueSnapshot: Self.ackSnapshot(total: iphoneACKCount),
            phoneSessionHistory: .unavailable(reason: SourceVocabulary.watchDiagnosticsNotProvided)
        )
    }

    nonisolated static func ackSnapshot(total: Int) -> WatchRelayACKQueueSnapshot {
        WatchRelayACKQueueSnapshot(userInfoTransfers: (0..<max(0, total)).map { _ in
            WatchConnectivityUserInfoTransferSnapshot(
                asOf: Self.now,
                recognizedType: nil,
                segmentID: nil,
                idState: .missing,
                isTransferring: true
            )
        })
    }

    nonisolated static func context(asOf: Date) -> WatchStatusContext {
        WatchStatusContext(
            phase: .observing,
            sessionID: "session",
            startedAt: asOf.addingTimeInterval(-60),
            asOf: asOf,
            seq: 1,
            queuedCount: 0,
            transferringCount: 0
        )
    }
}

private extension WatchPipelineReducerDiagnosticsExportTests {
    static let now = WatchRelayDiagnosticsCollectorTests.now

    static func input(
        watchStatus: WatchStatusContext? = nil,
        payload: WatchRelayDiagnosticsPayload,
        isReachable: Bool = true,
        lastReceivedAt: Date? = WatchRelayDiagnosticsCollectorTests.now,
        iphoneBuild: DiagnosticAvailability<String> = .available("55"),
        iphoneACKCount: Int = 0,
        lastUploadError: String? = nil
    ) -> WatchPipelineInput {
        WatchRelayDiagnosticsCollectorTests.pipelineInput(
            watchStatus: watchStatus,
            payload: payload,
            isReachable: isReachable,
            lastReceivedAt: lastReceivedAt,
            iphoneBuild: iphoneBuild,
            iphoneACKCount: iphoneACKCount,
            lastUploadError: lastUploadError
        )
    }

    static func context(asOf: Date) -> WatchStatusContext {
        WatchRelayDiagnosticsCollectorTests.context(asOf: asOf)
    }

    static func oldBacklogSummary() -> WatchRelayManifestSummary {
        WatchRelayManifestSummary(
            counts: .zero,
            activeBacklogCount: 1,
            retainedSourceBytes: .available(128),
            oldestActiveEnqueuedAt: .available(Self.now.addingTimeInterval(-900)),
            oldestActiveEnqueueAgeSeconds: .available(900)
        )
    }

    static func queue(
        matched: Int = 0,
        appActiveNotObserved: Int = 0
    ) -> WatchRelayAppleQueueSnapshot {
        WatchRelayAppleQueueSnapshot(
            asOf: Self.now,
            outstandingFileTransferCount: matched,
            outstandingUserInfoTransferCountWatchToPhone: 0,
            reconciliation: WatchRelayReconciliationCounts(
                matched: matched,
                appActiveNotObserved: appActiveNotObserved,
                duplicate: 0,
                orphaned: 0,
                unparseable: 0
            ),
            exactObservationCountBeforeCompaction: matched + appActiveNotObserved
        )
    }
}

private extension WatchRelayDiagnosticsEnvelopeTests {
    static let now = WatchRelayDiagnosticsCollectorTests.now
}

private extension WatchRelayProgressRenderingTests {
    static let now = WatchRelayDiagnosticsCollectorTests.now
}

private extension WatchRelayDiagnosticsPublicationTests {
    static let now = WatchRelayDiagnosticsCollectorTests.now
}

private extension WatchRelayCompatibilityTests {
    static let now = WatchRelayDiagnosticsCollectorTests.now
}
