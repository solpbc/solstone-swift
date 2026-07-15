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
        let payload = try XCTUnwrap(WatchRelayDiagnosticsEnvelope.decodeResult(from: data).payload)
        let queue = try XCTUnwrap(payload.appleQueue.value)
        XCTAssertEqual(queue.outstandingFileTransferCount, 800)
        XCTAssertEqual(payload.observedFileTransfers.count + payload.omittedObservationCount, queue.exactObservationCountBeforeCompaction)
        XCTAssertGreaterThan(payload.omittedObservationCount, 0)
    }

    func testCompactionRetentionOrderOldestActiveThenRecentFailureThenUUIDOrder() throws {
        let now = Self.now
        let older = Self.uuid(10)
        let newer = Self.uuid(11)
        let payload = Self.payload(
            generatedAt: now,
            observations: [
                Self.observation(id: newer, age: 60),
                Self.observation(id: older, age: 600),
                Self.observation(id: Self.uuid(12), age: nil, relation: .orphaned),
            ]
        )
        let data = try XCTUnwrap(WatchRelayDiagnosticsCollector.encodeCompactedEnvelope(generatedAt: now, payload: payload))
        let decoded = try XCTUnwrap(WatchRelayDiagnosticsEnvelope.decodeResult(from: data).payload)
        XCTAssertEqual(decoded.observedFileTransfers.map(\.segmentID), [newer, older, Self.uuid(12)])
    }

    private func storage(_ name: String) throws -> WatchCaptureStorage {
        try WatchCaptureStorage(rootURL: self.tempDirectory.appendingPathComponent(name, isDirectory: true))
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
        let payload = WatchRelayDiagnosticsCollectorTests.payload(generatedAt: Self.now)
        let export = WatchPipelineReducer.reduce(Self.input(
            watchStatus: Self.context(asOf: Self.now.addingTimeInterval(-120)),
            payload: payload
        )).diagnosticsExportText
        XCTAssertTrue(export.contains("diagnostic evidence stale"))
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
private final class MockWatchRelayDiagnosticsEnvironmentProvider: WatchRelayDiagnosticsEnvironmentProviding {
    func snapshot() -> WatchRelayDiagnosticsEnvironmentSnapshot {
        WatchRelayDiagnosticsEnvironmentSnapshot(
            watchAppMarketingVersion: .available("0.1.0"),
            watchAppBuild: .available("55"),
            watchOSVersion: .available("26.0"),
            watchBatteryLevel: .available(0.75),
            watchBatteryState: .available("unplugged"),
            watchLowPowerModeEnabled: .available(false),
            watchThermalState: .available("nominal")
        )
    }
}

private extension WatchRelayDiagnosticsCollectorTests {
    nonisolated static let now = Date(timeIntervalSince1970: 1_784_073_600)

    nonisolated static func uuid(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
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
        progress: DiagnosticAvailability<WatchConnectivityProgressSnapshot> = .available(MockWatchConnectivitySession.defaultProgress())
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
            progress: progress
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

    nonisolated static func pipelineInput(
        now: Date = WatchRelayDiagnosticsCollectorTests.now,
        watchStatus: WatchStatusContext? = nil,
        payload: WatchRelayDiagnosticsPayload,
        isReachable: Bool = true,
        lastReceivedAt: Date? = WatchRelayDiagnosticsCollectorTests.now,
        iphoneBuild: DiagnosticAvailability<String> = .available("55"),
        iphoneACKCount: Int = 0,
        lastUploadError: String? = nil
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
            iphoneOutstandingUserInfoTransferCountACKControl: iphoneACKCount
        )
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
