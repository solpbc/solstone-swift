// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class WatchRelayRecoveryLeaseStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchRelayRecoveryLeaseStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    func testNewTaggedLeaseUsesSoleSubsecondAttemptSample() throws {
        let storage = try WatchCaptureStorage(rootURL: self.tempDirectory.appendingPathComponent("tagged-new"))
        let entry = try self.writeSegment(storage: storage, index: 0)
        let route = WatchRelayRecoveryRouteRecord(
            eraID: UUID(),
            successfulTransferGeneration: 4,
            durableACKGeneration: 3
        )
        let startedAt = Date(timeIntervalSince1970: 2_000_000_000.125)
        let attempt = WatchRelayAttemptRecord(
            segmentID: entry.manifest.id,
            generation: 0,
            attemptID: UUID(),
            attemptStartedAt: startedAt
        )
        let store = WatchRelayRecoveryLeaseStore(storage: storage)

        XCTAssertTrue(store.recordNewTaggedLease(
            manifest: entry.manifest,
            directoryURL: entry.directoryURL,
            attempt: attempt,
            route: route
        ))

        let lease = try self.readLease(store: store, directoryURL: entry.directoryURL, storage: storage)
        XCTAssertEqual(lease.attemptStartedAt, startedAt)
        XCTAssertEqual(lease.leaseStartedAt, startedAt)
        XCTAssertEqual(lease.successfulTransferBaseline, 4)
        XCTAssertEqual(lease.durableACKBaseline, 3)

        let metadata = WatchSegmentBundleCodec.metadata(for: entry.manifest, attempt: attempt.tag)
        let completion = LiveWatchConnectivitySession.fileTransferCompletion(
            metadata: metadata,
            fileURL: URL(fileURLWithPath: "/mock/tagged.watchrelay"),
            error: nil
        )
        XCTAssertEqual(completion.attemptStartedAt, startedAt)
    }

    func testTaggedReconcileRebasesOnceAndKeepsExactCapturedObservation() throws {
        let storage = try WatchCaptureStorage(rootURL: self.tempDirectory.appendingPathComponent("tagged-reconcile"))
        let entry = try self.writeSegment(storage: storage, index: 0, state: .transferring)
        let route = WatchRelayRecoveryRouteRecord(eraID: UUID())
        let attempt = WatchRelayAttemptRecord(
            segmentID: entry.manifest.id,
            generation: 0,
            attemptID: UUID(),
            attemptStartedAt: Date(timeIntervalSince1970: 2_000_000_000.25)
        )
        try self.writeAttempt(attempt, entry: entry, storage: storage)
        let captured = self.observation(segmentID: entry.manifest.id, attempt: attempt, token: 41)
        let hypotheticalNext = self.observation(segmentID: entry.manifest.id, attempt: attempt, token: 99)
        let leaseStartedAt = Date(timeIntervalSince1970: 2_000_000_100.5)
        let store = WatchRelayRecoveryLeaseStore(storage: storage)

        let candidate = try XCTUnwrap(store.reconcile(
            manifest: entry.manifest,
            directoryURL: entry.directoryURL,
            observations: [captured],
            route: route,
            diagnosticsStore: nil,
            now: leaseStartedAt
        ))
        XCTAssertEqual(candidate.observation.runtimeToken.value, 41)
        XCTAssertEqual(hypotheticalNext.runtimeToken.value, 99)
        XCTAssertEqual(candidate.lease.attemptStartedAt, attempt.attemptStartedAt)
        XCTAssertEqual(candidate.lease.leaseStartedAt, leaseStartedAt)

        let preserved = try XCTUnwrap(store.reconcile(
            manifest: entry.manifest,
            directoryURL: entry.directoryURL,
            observations: [captured],
            route: route,
            diagnosticsStore: nil,
            now: leaseStartedAt.addingTimeInterval(60)
        ))
        XCTAssertEqual(preserved.lease, candidate.lease)
        XCTAssertEqual(preserved.observation.runtimeToken.value, 41)
    }

    func testTaggedReconcileRejectsInvalidAttemptRecordsAndMetadataMismatch() throws {
        let storage = try WatchCaptureStorage(rootURL: self.tempDirectory.appendingPathComponent("invalid-attempt"))
        let entry = try self.writeSegment(storage: storage, index: 0, state: .transferring)
        let route = WatchRelayRecoveryRouteRecord(eraID: UUID())
        let valid = WatchRelayAttemptRecord(
            segmentID: entry.manifest.id,
            generation: 0,
            attemptID: UUID(),
            attemptStartedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let observation = self.observation(segmentID: entry.manifest.id, attempt: valid, token: 1)
        let attemptURL = entry.directoryURL.appendingPathComponent(WatchRelayAttemptRecord.filename)
        let store = WatchRelayRecoveryLeaseStore(storage: storage)
        let invalidRecords: [Data?] = [
            nil,
            Data("truncated".utf8),
            try WatchRelayAttemptRecord.makeEncoder().encode(WatchRelayAttemptRecord(
                version: 2,
                segmentID: entry.manifest.id,
                generation: 0,
                attemptID: valid.attemptID,
                attemptStartedAt: valid.attemptStartedAt
            )),
            try WatchRelayAttemptRecord.makeEncoder().encode(WatchRelayAttemptRecord(
                segmentID: UUID(),
                generation: 0,
                attemptID: valid.attemptID,
                attemptStartedAt: valid.attemptStartedAt
            )),
            try WatchRelayAttemptRecord.makeEncoder().encode(WatchRelayAttemptRecord(
                segmentID: entry.manifest.id,
                generation: -1,
                attemptID: valid.attemptID,
                attemptStartedAt: valid.attemptStartedAt
            )),
            Data(#"{"attemptID":"00000000-0000-0000-0000-000000000002","attemptStartedAt":1e999,"generation":0,"segmentID":"00000000-0000-0000-0000-000000000001","version":1}"#.utf8),
        ]

        for data in invalidRecords {
            try? storage.fileWriter.removeItem(at: attemptURL)
            try? storage.fileWriter.removeItem(at: store.leaseURL(directoryURL: entry.directoryURL))
            if let data {
                try storage.fileWriter.writeData(data, to: attemptURL, options: .atomic)
            }
            XCTAssertNil(store.reconcile(
                manifest: entry.manifest,
                directoryURL: entry.directoryURL,
                observations: [observation],
                route: route,
                diagnosticsStore: nil,
                now: Date(timeIntervalSince1970: 2_000_000_100)
            ))
            XCTAssertFalse(storage.fileWriter.fileExists(at: store.leaseURL(directoryURL: entry.directoryURL)))
        }

        try self.writeAttempt(valid, entry: entry, storage: storage)
        let mismatched = WatchRelayAttemptRecord(
            segmentID: entry.manifest.id,
            generation: 0,
            attemptID: UUID(),
            attemptStartedAt: valid.attemptStartedAt
        )
        XCTAssertNil(store.reconcile(
            manifest: entry.manifest,
            directoryURL: entry.directoryURL,
            observations: [self.observation(segmentID: entry.manifest.id, attempt: mismatched, token: 2)],
            route: route,
            diagnosticsStore: nil,
            now: Date(timeIntervalSince1970: 2_000_000_100)
        ))
        XCTAssertFalse(storage.fileWriter.fileExists(at: store.leaseURL(directoryURL: entry.directoryURL)))
    }

    func testLegacyContinuityUsesTimestampAndAttemptCountAndRejectsAmbiguousGroups() throws {
        let storage = try WatchCaptureStorage(rootURL: self.tempDirectory.appendingPathComponent("legacy"))
        let entry = try self.writeSegment(storage: storage, index: 0, state: .transferring)
        let diagnostics = WatchRelayDiagnosticsStore(storage: storage)
        let route = WatchRelayRecoveryRouteRecord(eraID: UUID())
        let store = WatchRelayRecoveryLeaseStore(storage: storage)
        let legacy = self.legacyObservation(segmentID: entry.manifest.id, token: 10)
        let sameWholeSecond = Date(timeIntervalSince1970: 2_000_000_000)
        diagnostics.recordEnqueue(
            manifest: entry.manifest,
            directoryURL: entry.directoryURL,
            bundleURL: storage.audioURL(directory: entry.directoryURL),
            at: sameWholeSecond
        )

        let first = try XCTUnwrap(store.reconcile(
            manifest: entry.manifest,
            directoryURL: entry.directoryURL,
            observations: [legacy],
            route: route,
            diagnosticsStore: diagnostics,
            now: Date(timeIntervalSince1970: 2_000_000_100)
        ))
        XCTAssertEqual(first.lease.legacyLatestEnqueuedAt, sameWholeSecond)
        XCTAssertEqual(first.lease.legacyAttemptCount, 1)

        diagnostics.recordEnqueue(
            manifest: entry.manifest,
            directoryURL: entry.directoryURL,
            bundleURL: storage.audioURL(directory: entry.directoryURL),
            at: sameWholeSecond
        )
        let advancedRoute = WatchRelayRecoveryRouteRecord(
            eraID: route.eraID,
            successfulTransferGeneration: 2,
            durableACKGeneration: 3
        )
        let secondStart = sameWholeSecond.addingTimeInterval(-100)
        let second = try XCTUnwrap(store.reconcile(
            manifest: entry.manifest,
            directoryURL: entry.directoryURL,
            observations: [legacy],
            route: advancedRoute,
            diagnosticsStore: diagnostics,
            now: secondStart
        ))
        XCTAssertEqual(second.lease.legacyLatestEnqueuedAt, sameWholeSecond)
        XCTAssertEqual(second.lease.legacyAttemptCount, 2)
        XCTAssertEqual(second.lease.leaseStartedAt, sameWholeSecond)
        XCTAssertEqual(second.lease.successfulTransferBaseline, 2)
        XCTAssertEqual(second.lease.durableACKBaseline, 3)

        let invalidLegacy = WatchRelayRecoveryLeaseRecord.legacy(
            segmentID: entry.manifest.id,
            latestEnqueuedAt: sameWholeSecond,
            attemptCount: 2,
            leaseStartedAt: sameWholeSecond.addingTimeInterval(-1),
            route: advancedRoute
        )
        try storage.fileWriter.writeData(
            try WatchRelayRecoveryLeaseRecord.makeEncoder().encode(invalidLegacy),
            to: store.leaseURL(directoryURL: entry.directoryURL),
            options: .atomic
        )
        let repaired = try XCTUnwrap(store.reconcile(
            manifest: entry.manifest,
            directoryURL: entry.directoryURL,
            observations: [legacy],
            route: advancedRoute,
            diagnosticsStore: diagnostics,
            now: sameWholeSecond.addingTimeInterval(-100)
        ))
        XCTAssertEqual(repaired.lease.leaseStartedAt, sameWholeSecond)
        let committed = try storage.fileWriter.readData(from: store.leaseURL(directoryURL: entry.directoryURL))

        let tagged = self.observation(
            segmentID: entry.manifest.id,
            attempt: WatchRelayAttemptRecord(
                segmentID: entry.manifest.id,
                generation: 0,
                attemptID: UUID(),
                attemptStartedAt: sameWholeSecond
            ),
            token: 11
        )
        XCTAssertNil(store.reconcile(
            manifest: entry.manifest,
            directoryURL: entry.directoryURL,
            observations: [legacy, legacy],
            route: advancedRoute,
            diagnosticsStore: diagnostics,
            now: secondStart.addingTimeInterval(1)
        ))
        XCTAssertNil(store.reconcile(
            manifest: entry.manifest,
            directoryURL: entry.directoryURL,
            observations: [tagged, legacy],
            route: advancedRoute,
            diagnosticsStore: diagnostics,
            now: secondStart.addingTimeInterval(2)
        ))
        XCTAssertNil(store.reconcile(
            manifest: entry.manifest,
            directoryURL: entry.directoryURL,
            observations: [legacy, tagged],
            route: advancedRoute,
            diagnosticsStore: diagnostics,
            now: secondStart.addingTimeInterval(3)
        ))
        XCTAssertEqual(try storage.fileWriter.readData(from: store.leaseURL(directoryURL: entry.directoryURL)), committed)

        let malformed = WatchConnectivityFileTransferObservation(
            runtimeToken: WatchConnectivityFileTransferRuntimeToken(value: 12),
            snapshot: legacy.snapshot,
            generation: nil,
            generationState: .unparseable,
            attemptID: nil,
            attemptIDState: .missing,
            attemptStartedAt: nil,
            attemptStartedAtState: .missing,
            cancel: {}
        )
        XCTAssertNil(store.reconcile(
            manifest: entry.manifest,
            directoryURL: entry.directoryURL,
            observations: [malformed],
            route: advancedRoute,
            diagnosticsStore: diagnostics,
            now: secondStart.addingTimeInterval(4)
        ))
    }

    func testSemanticLeaseFailuresRebaseOnlyAfterValidCurrentIdentity() throws {
        let storage = try WatchCaptureStorage(rootURL: self.tempDirectory.appendingPathComponent("semantic"))
        let entry = try self.writeSegment(storage: storage, index: 0, state: .transferring)
        let route = WatchRelayRecoveryRouteRecord(
            eraID: UUID(),
            successfulTransferGeneration: 2,
            durableACKGeneration: 2
        )
        let attempt = WatchRelayAttemptRecord(
            segmentID: entry.manifest.id,
            generation: 0,
            attemptID: UUID(),
            attemptStartedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        try self.writeAttempt(attempt, entry: entry, storage: storage)
        let observation = self.observation(segmentID: entry.manifest.id, attempt: attempt, token: 1)
        let store = WatchRelayRecoveryLeaseStore(storage: storage)
        let start = Date(timeIntervalSince1970: 2_000_000_100)
        let invalid: [WatchRelayRecoveryLeaseRecord] = [
            WatchRelayRecoveryLeaseRecord(
                version: 2,
                segmentID: entry.manifest.id,
                kind: .tagged,
                generation: 0,
                attemptID: attempt.attemptID,
                attemptStartedAt: attempt.attemptStartedAt,
                leaseStartedAt: start,
                routeEraID: route.eraID,
                successfulTransferBaseline: 0,
                durableACKBaseline: 0
            ),
            WatchRelayRecoveryLeaseRecord(
                segmentID: UUID(),
                kind: .tagged,
                generation: 0,
                attemptID: attempt.attemptID,
                attemptStartedAt: attempt.attemptStartedAt,
                leaseStartedAt: start,
                routeEraID: route.eraID,
                successfulTransferBaseline: 0,
                durableACKBaseline: 0
            ),
            WatchRelayRecoveryLeaseRecord(
                segmentID: entry.manifest.id,
                kind: .tagged,
                leaseStartedAt: start,
                routeEraID: route.eraID,
                successfulTransferBaseline: 0,
                durableACKBaseline: 0
            ),
            WatchRelayRecoveryLeaseRecord(
                segmentID: entry.manifest.id,
                kind: .tagged,
                generation: 0,
                attemptID: attempt.attemptID,
                attemptStartedAt: attempt.attemptStartedAt,
                leaseStartedAt: start,
                routeEraID: route.eraID,
                successfulTransferBaseline: -1,
                durableACKBaseline: 0
            ),
            WatchRelayRecoveryLeaseRecord(
                segmentID: entry.manifest.id,
                kind: .tagged,
                generation: 0,
                attemptID: attempt.attemptID,
                attemptStartedAt: attempt.attemptStartedAt,
                leaseStartedAt: start,
                routeEraID: route.eraID,
                successfulTransferBaseline: 3,
                durableACKBaseline: 2
            ),
            WatchRelayRecoveryLeaseRecord(
                segmentID: entry.manifest.id,
                kind: .tagged,
                generation: 0,
                attemptID: attempt.attemptID,
                attemptStartedAt: attempt.attemptStartedAt,
                leaseStartedAt: attempt.attemptStartedAt.addingTimeInterval(-1),
                routeEraID: route.eraID,
                successfulTransferBaseline: 2,
                durableACKBaseline: 2
            ),
        ]

        for invalidLease in invalid {
            let data = try WatchRelayRecoveryLeaseRecord.makeEncoder().encode(invalidLease)
            try storage.fileWriter.writeData(data, to: store.leaseURL(directoryURL: entry.directoryURL), options: .atomic)
            let candidate = try XCTUnwrap(store.reconcile(
                manifest: entry.manifest,
                directoryURL: entry.directoryURL,
                observations: [observation],
                route: route,
                diagnosticsStore: nil,
                now: start
            ))
            XCTAssertEqual(candidate.lease.version, WatchRelayRecoveryLeaseRecord.currentVersion)
            XCTAssertEqual(candidate.lease.segmentID, entry.manifest.id)
            XCTAssertEqual(candidate.lease.successfulTransferBaseline, 2)
            XCTAssertEqual(candidate.lease.durableACKBaseline, 2)
        }

        let rollbackInvalid = WatchRelayRecoveryLeaseRecord(
            segmentID: entry.manifest.id,
            kind: .tagged,
            generation: 0,
            attemptID: attempt.attemptID,
            attemptStartedAt: attempt.attemptStartedAt,
            leaseStartedAt: attempt.attemptStartedAt.addingTimeInterval(-1),
            routeEraID: route.eraID,
            successfulTransferBaseline: 0,
            durableACKBaseline: 0
        )
        try storage.fileWriter.writeData(
            try WatchRelayRecoveryLeaseRecord.makeEncoder().encode(rollbackInvalid),
            to: store.leaseURL(directoryURL: entry.directoryURL),
            options: .atomic
        )
        let rollbackRepaired = try XCTUnwrap(store.reconcile(
            manifest: entry.manifest,
            directoryURL: entry.directoryURL,
            observations: [observation],
            route: route,
            diagnosticsStore: nil,
            now: attempt.attemptStartedAt.addingTimeInterval(-100)
        ))
        XCTAssertEqual(rollbackRepaired.lease.leaseStartedAt, attempt.attemptStartedAt)
        XCTAssertEqual(rollbackRepaired.lease.successfulTransferBaseline, 2)
        XCTAssertEqual(rollbackRepaired.lease.durableACKBaseline, 2)

        let retired = WatchRelayRecoveryLeaseRecord(
            segmentID: entry.manifest.id,
            kind: .tagged,
            generation: 0,
            attemptID: attempt.attemptID,
            attemptStartedAt: attempt.attemptStartedAt,
            leaseStartedAt: start.addingTimeInterval(-100),
            routeEraID: UUID(),
            successfulTransferBaseline: 10,
            durableACKBaseline: 10
        )
        try storage.fileWriter.writeData(
            try WatchRelayRecoveryLeaseRecord.makeEncoder().encode(retired),
            to: store.leaseURL(directoryURL: entry.directoryURL),
            options: .atomic
        )
        let rebased = try XCTUnwrap(store.reconcile(
            manifest: entry.manifest,
            directoryURL: entry.directoryURL,
            observations: [observation],
            route: route,
            diagnosticsStore: nil,
            now: start
        ))
        XCTAssertEqual(rebased.lease.routeEraID, route.eraID)
        XCTAssertEqual(rebased.lease.leaseStartedAt, start)

        try? storage.fileWriter.removeItem(at: store.leaseURL(directoryURL: entry.directoryURL))
        let rolledBackNow = attempt.attemptStartedAt.addingTimeInterval(-100)
        let rollbackSafe = try XCTUnwrap(store.reconcile(
            manifest: entry.manifest,
            directoryURL: entry.directoryURL,
            observations: [observation],
            route: route,
            diagnosticsStore: nil,
            now: rolledBackNow
        ))
        XCTAssertEqual(rollbackSafe.lease.leaseStartedAt, attempt.attemptStartedAt)
    }

    func testFailedLeaseReplacementPreservesCommittedBytesAndHealthySibling() throws {
        let writer = FailingWatchFileWriter(failAppend: false)
        let storage = try WatchCaptureStorage(
            rootURL: self.tempDirectory.appendingPathComponent("write-failure"),
            fileWriter: writer
        )
        let first = try self.writeSegment(storage: storage, index: 0, state: .transferring)
        let second = try self.writeSegment(storage: storage, index: 1, state: .transferring)
        let route = WatchRelayRecoveryRouteRecord(eraID: UUID())
        let firstAttempt = WatchRelayAttemptRecord(
            segmentID: first.manifest.id,
            generation: 0,
            attemptID: UUID(),
            attemptStartedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let secondAttempt = WatchRelayAttemptRecord(
            segmentID: second.manifest.id,
            generation: 0,
            attemptID: UUID(),
            attemptStartedAt: Date(timeIntervalSince1970: 2_000_000_001)
        )
        try self.writeAttempt(firstAttempt, entry: first, storage: storage)
        try self.writeAttempt(secondAttempt, entry: second, storage: storage)
        let store = WatchRelayRecoveryLeaseStore(storage: storage)
        let firstURL = store.leaseURL(directoryURL: first.directoryURL)
        let stale = Data("not-json".utf8)
        try writer.writeData(stale, to: firstURL, options: .atomic)
        writer.failNextWriteData(at: firstURL)

        XCTAssertNil(store.reconcile(
            manifest: first.manifest,
            directoryURL: first.directoryURL,
            observations: [self.observation(segmentID: first.manifest.id, attempt: firstAttempt, token: 1)],
            route: route,
            diagnosticsStore: nil,
            now: Date(timeIntervalSince1970: 2_000_000_100)
        ))
        XCTAssertEqual(try writer.readData(from: firstURL), stale)

        XCTAssertNotNil(store.reconcile(
            manifest: second.manifest,
            directoryURL: second.directoryURL,
            observations: [self.observation(segmentID: second.manifest.id, attempt: secondAttempt, token: 2)],
            route: route,
            diagnosticsStore: nil,
            now: Date(timeIntervalSince1970: 2_000_000_101)
        ))

        let relaunched = WatchRelayRecoveryLeaseStore(storage: storage)
        let recovered = try XCTUnwrap(relaunched.reconcile(
            manifest: first.manifest,
            directoryURL: first.directoryURL,
            observations: [self.observation(segmentID: first.manifest.id, attempt: firstAttempt, token: 3)],
            route: route,
            diagnosticsStore: nil,
            now: Date(timeIntervalSince1970: 2_000_000_200)
        ))
        XCTAssertEqual(recovered.lease.leaseStartedAt, Date(timeIntervalSince1970: 2_000_000_200))
    }
}

@MainActor
private extension WatchRelayRecoveryLeaseStoreTests {
    func writeSegment(
        storage: WatchCaptureStorage,
        index: Int,
        state: WatchSegmentState = .queued
    ) throws -> WatchCaptureStorage.ManifestEntry {
        let startedAt = Date(timeIntervalSince1970: 1_713_624_000 + Double(index * 60))
        let day = storage.dayString(for: startedAt)
        let segment = storage.segmentString(for: startedAt, durationSeconds: 60)
        let directory = try storage.ensureSegmentDirectory(day: day, segment: segment)
        let manifest = WatchSegmentManifest(
            id: UUID(),
            day: day,
            segment: segment,
            startedAt: startedAt,
            duration: 60,
            sensors: [.audio],
            partial: false,
            lost: false,
            gap: false,
            fixCount: 0,
            state: state,
            failureReason: nil
        )
        try storage.fileWriter.writeData(
            Data("audio-\(index)".utf8),
            to: storage.audioURL(directory: directory),
            options: .atomic
        )
        try storage.writeManifest(manifest, in: directory)
        return WatchCaptureStorage.ManifestEntry(
            directoryURL: directory,
            manifestURL: storage.manifestURL(directory: directory),
            manifest: manifest
        )
    }

    func writeAttempt(
        _ attempt: WatchRelayAttemptRecord,
        entry: WatchCaptureStorage.ManifestEntry,
        storage: WatchCaptureStorage
    ) throws {
        try storage.fileWriter.writeData(
            try WatchRelayAttemptRecord.makeEncoder().encode(attempt),
            to: entry.directoryURL.appendingPathComponent(WatchRelayAttemptRecord.filename),
            options: .atomic
        )
    }

    func readLease(
        store: WatchRelayRecoveryLeaseStore,
        directoryURL: URL,
        storage: WatchCaptureStorage
    ) throws -> WatchRelayRecoveryLeaseRecord {
        try WatchRelayRecoveryLeaseRecord.makeDecoder().decode(
            WatchRelayRecoveryLeaseRecord.self,
            from: storage.fileWriter.readData(from: store.leaseURL(directoryURL: directoryURL))
        )
    }

    func observation(
        segmentID: UUID,
        attempt: WatchRelayAttemptRecord,
        token: Int
    ) -> WatchConnectivityFileTransferObservation {
        WatchConnectivityFileTransferObservation(
            runtimeToken: WatchConnectivityFileTransferRuntimeToken(value: token),
            snapshot: WatchConnectivityFileTransferSnapshot(
                asOf: Date(timeIntervalSince1970: 0),
                segmentID: segmentID,
                idState: .parseable,
                isTransferring: true,
                progress: MockWatchConnectivitySession.defaultProgress()
            ),
            generation: attempt.generation,
            generationState: .parseable,
            attemptID: attempt.attemptID,
            attemptIDState: .parseable,
            attemptStartedAt: attempt.attemptStartedAt,
            attemptStartedAtState: .parseable,
            cancel: {}
        )
    }

    func legacyObservation(segmentID: UUID, token: Int) -> WatchConnectivityFileTransferObservation {
        WatchConnectivityFileTransferObservation(
            runtimeToken: WatchConnectivityFileTransferRuntimeToken(value: token),
            snapshot: WatchConnectivityFileTransferSnapshot(
                asOf: Date(timeIntervalSince1970: 0),
                segmentID: segmentID,
                idState: .parseable,
                isTransferring: true,
                progress: MockWatchConnectivitySession.defaultProgress()
            ),
            generation: nil,
            generationState: .missing,
            attemptID: nil,
            attemptIDState: .missing,
            attemptStartedAt: nil,
            attemptStartedAtState: .missing,
            cancel: {}
        )
    }
}
