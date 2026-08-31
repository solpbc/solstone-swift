// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

@MainActor
final class WatchCaptureStorageActorTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchCaptureStorageActorTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.root)
        self.root = nil
    }

    func testMissingRootIsUnavailableRatherThanEmpty() async {
        let catalog = await WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: self.root),
            fileWriter: FoundationWatchFileWriter()
        ).scanCatalog()
        XCTAssertEqual(catalog.rootState, .unavailable(.missing))
        XCTAssertFalse(catalog.canInferUUIDAbsence)
    }

    func testHealthySiblingsSurviveMalformedManifest() async throws {
        let actor = self.actor()
        try await actor.prepareRoot()
        let good = self.manifest(id: UUID(), segment: "120000_300", state: .queued)
        try await actor.writeManifest(good)
        let bad = self.root.appendingPathComponent("20250101/120500_300", isDirectory: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: bad.appendingPathComponent("manifest.json"))

        let catalog = await actor.scanCatalog()
        XCTAssertEqual(catalog.rootState, .partial)
        XCTAssertEqual(catalog.entries.map(\.manifest.id), [good.id])
        XCTAssertEqual(catalog.issues.map(\.kind), [.manifestDecodeFailure])
        XCTAssertFalse(catalog.canInferUUIDAbsence)
    }

    func testEmptyExistingRootIsAuthoritative() async throws {
        let actor = self.actor()
        try await actor.prepareRoot()
        let catalog = await actor.scanCatalog()
        XCTAssertEqual(catalog.rootState, .emptyComplete)
        XCTAssertTrue(catalog.canInferUUIDAbsence)
    }

    func testCatalogIgnoresActorSessionFilesAtRoot() async throws {
        let actor = self.actor()
        let paths = WatchCaptureStoragePaths(rootURL: self.root)
        try await actor.prepareRoot()
        let manifest = self.manifest(id: UUID(), segment: "120000_300", state: .queued)
        try await actor.writeManifest(manifest)

        let writer = FoundationWatchFileWriter()
        try await writer.writeData(Data("session".utf8), to: paths.sessionRecordURL(), options: .atomic)
        try await writer.writeData(Data("history".utf8), to: paths.sessionHistoryURL(), options: .atomic)
        try await writer.writeData(Data("counter".utf8), to: paths.sessionHistoryCounterURL(), options: .atomic)

        let catalog = await actor.scanCatalog()
        XCTAssertEqual(catalog.rootState, .complete)
        XCTAssertEqual(catalog.entries.map(\.manifest.id), [manifest.id])
        XCTAssertTrue(catalog.issues.isEmpty)
        XCTAssertTrue(catalog.canInferUUIDAbsence)
    }

    func testWriteRejectsChangedManifestWitnessWithoutMutation() async throws {
        let actor = self.actor()
        let manifest = self.manifest(id: UUID(), segment: "120000_300", state: .queued)
        try await actor.writeManifest(manifest)
        let catalog = await actor.scanCatalog()
        let entry = try XCTUnwrap(catalog.entries.first)
        var replacement = manifest
        replacement.state = .transferring
        try await actor.writeManifest(replacement)
        let before = try Data(contentsOf: self.root.appendingPathComponent("20250101/120000_300/manifest.json"))

        var stale = manifest
        stale.state = .delivered
        do {
            try await actor.writeManifest(stale, entry: entry)
            XCTFail("expected content witness conflict")
        } catch let conflict as WatchCaptureStorageConflict {
            XCTAssertEqual(conflict, .contentWitnessChanged(id: entry.id))
        }
        XCTAssertEqual(try Data(contentsOf: self.root.appendingPathComponent("20250101/120000_300/manifest.json")), before)
    }

    func testTransactionGateDefersSecondWriterEntryUntilFirstReleases() async throws {
        let writer = BlockingStorageWriter()
        let storage = WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: self.root),
            fileWriter: writer
        )

        async let first: Void = storage.prepareRoot()
        await writer.waitUntilEntered()
        async let second: Void = storage.prepareRoot()
        await Task.yield()
        let entered = await writer.entryCount()
        XCTAssertEqual(entered, 1)

        await writer.release()
        try await first
        try await second
        let maximum = await writer.maximumConcurrentEntries()
        XCTAssertEqual(maximum, 1)
    }

    func testActorSignpostsMeasureSynchronousWorkAfterTransactionGateAdmission() async throws {
        let writer = BlockingStorageWriter()
        let sink = WatchStorageSignpostTestSink()
        let storage = WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: self.root),
            fileWriter: writer,
            storageSignposter: WatchStorageSignposter(sink: sink),
            synchronousWorkHook: { boundary in
                guard boundary == .capturePreparation else { return }
                Thread.sleep(forTimeInterval: 0.03)
            }
        )

        async let first: Void = storage.prepareRoot()
        await writer.waitUntilEntered()

        let secondSubmittedAt = Date()
        async let second: Void = storage.prepareRoot()
        try await Task.sleep(for: .milliseconds(30))
        let heldSnapshot = sink.snapshot()
        XCTAssertEqual(heldSnapshot.openBoundaries, [.storageActorTransactionElapsed])
        XCTAssertFalse(heldSnapshot.openBoundaries.contains(.capturePreparation))

        let releasedAt = Date()
        await writer.release()

        try await first
        try await second
        let secondCompletedAt = Date()

        let snapshot = sink.snapshot()
        XCTAssertEqual(
            snapshot.events.map(\.kind),
            [.begin, .begin, .end, .end, .begin, .begin, .end, .end]
        )
        XCTAssertEqual(
            snapshot.events.map(\.boundary),
            [
                .storageActorTransactionElapsed,
                .capturePreparation,
                .capturePreparation,
                .storageActorTransactionElapsed,
                .storageActorTransactionElapsed,
                .capturePreparation,
                .capturePreparation,
                .storageActorTransactionElapsed,
            ]
        )
        XCTAssertEqual(snapshot.openIntervalCount, 0)
        let captureBegins = snapshot.events.filter { $0.kind == .begin && $0.boundary == .capturePreparation }
        let secondBegin = try XCTUnwrap(captureBegins.dropFirst().first)
        XCTAssertGreaterThanOrEqual(secondBegin.at.timeIntervalSince1970, releasedAt.timeIntervalSince1970)
        XCTAssertGreaterThanOrEqual(secondCompletedAt.timeIntervalSince(secondSubmittedAt), 0.03)
        let captureEvents = snapshot.events.filter { $0.boundary == .capturePreparation }
        XCTAssertEqual(captureEvents.count, 4)
        for index in stride(from: 0, to: captureEvents.count, by: 2) {
            XCTAssertEqual(captureEvents[index].kind, .begin)
            XCTAssertEqual(captureEvents[index + 1].kind, .end)
            XCTAssertGreaterThanOrEqual(
                captureEvents[index + 1].at.timeIntervalSince(captureEvents[index].at),
                0.025
            )
        }
    }

    func testDisabledActorSignpostingDoesNotCreateIntervals() async throws {
        let sink = WatchStorageSignpostTestSink(isEnabled: false)
        let hook = WatchStorageSynchronousWorkCounter()
        let storage = WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: self.root),
            fileWriter: FoundationWatchFileWriter(),
            storageSignposter: WatchStorageSignposter(sink: sink),
            synchronousWorkHook: { _ in hook.increment() }
        )

        try await storage.writeComplicationSnapshot(
            Data("{}".utf8),
            to: self.root.appendingPathComponent("complication/snapshot.json", isDirectory: false)
        )

        let snapshot = sink.snapshot()
        XCTAssertEqual(snapshot.beginCallCount, 0)
        XCTAssertTrue(snapshot.events.isEmpty)
        XCTAssertEqual(snapshot.openIntervalCount, 0)
        XCTAssertEqual(hook.value(), 0)
    }

    func testActorSignpostsBalanceUnavailablePartialAndConflictExits() async throws {
        let sink = WatchStorageSignpostTestSink()
        let storage = WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: self.root),
            fileWriter: FoundationWatchFileWriter(),
            storageSignposter: WatchStorageSignposter(sink: sink)
        )

        let unavailableCatalog = await storage.scanCatalog()
        XCTAssertEqual(unavailableCatalog.rootState, .unavailable(.missing))
        try await storage.prepareRoot()
        let malformedDirectory = self.root.appendingPathComponent("20250101/120500_300", isDirectory: true)
        try FileManager.default.createDirectory(at: malformedDirectory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: malformedDirectory.appendingPathComponent("manifest.json"))
        let partialCatalog = await storage.scanCatalog()
        XCTAssertEqual(partialCatalog.rootState, .partial)

        let manifest = self.manifest(id: UUID(), segment: "120000_300", state: .queued)
        try await storage.writeManifest(manifest)
        let catalog = await storage.scanCatalog()
        let entry = try XCTUnwrap(catalog.entries.first { $0.manifest.id == manifest.id })
        var replacement = manifest
        replacement.state = .transferring
        try await storage.writeManifest(replacement)
        do {
            try await storage.writeManifest(manifest, entry: entry)
            XCTFail("expected content witness conflict")
        } catch let conflict as WatchCaptureStorageConflict {
            XCTAssertEqual(conflict, .contentWitnessChanged(id: entry.id))
        }

        let snapshot = sink.snapshot()
        XCTAssertEqual(snapshot.openIntervalCount, 0)
        XCTAssertTrue(snapshot.hasBalancedIntervals)
        XCTAssertGreaterThanOrEqual(snapshot.events.filter { $0.boundary == .manifestScan }.count, 4)
        XCTAssertGreaterThanOrEqual(snapshot.events.filter { $0.boundary == .storageActorManifestWrite }.count, 6)
    }

    func testTransactionGateSerializesMixedCaptureRelayDiagnosticsHistoryLocationAndComplicationIO() async throws {
        let detector = WatchStorageOverlapDetector()
        let writer = OverlapDetectingWatchFileWriter(detector: detector)
        let paths = WatchCaptureStoragePaths(rootURL: self.root)
        let storage = WatchCaptureStorageActor(paths: paths, fileWriter: writer)
        let date = Date(timeIntervalSince1970: 1_735_689_600)

        try await storage.prepareRoot()
        let queued = self.manifest(id: UUID(), segment: "120000_300", state: .queued)
        let transferring = self.manifest(id: UUID(), segment: "120500_300", state: .transferring)
        let locationManifest = self.manifest(id: UUID(), segment: "121000_300", state: .captured)
        try await storage.writeManifest(queued)
        try await storage.writeManifest(transferring)
        try await storage.writeManifest(locationManifest)
        let initialCatalog = await storage.scanCatalog()
        let queuedEntry = try XCTUnwrap(initialCatalog.entries.first { $0.manifest.id == queued.id })
        let transferringEntry = try XCTUnwrap(initialCatalog.entries.first { $0.manifest.id == transferring.id })
        let locationURL = paths.locationURL(directory: paths.segmentDirectoryURL(
            day: locationManifest.day,
            segment: locationManifest.segment
        ))
        try await storage.openLocationLogHeader(at: locationURL)

        await detector.reset()
        let captured = self.manifest(id: UUID(), segment: "121500_300", state: .captured)
        let history = self.historyEntry(id: "mixed-history", at: date)
        let fix = WatchLocationFix(
            t: date,
            lat: 39.7392,
            lon: -104.9903,
            hAcc: 25,
            alt: 1609,
            vAcc: 12,
            speed: 0,
            course: 180,
            stationary: false
        )
        let attempt = WatchRelayAttemptRecord(
            segmentID: transferring.id,
            generation: 1,
            attemptID: UUID(),
            attemptStartedAt: date
        )
        let bundleURL = self.root
            .appendingPathComponent(".relay-bundles", isDirectory: true)
            .appendingPathComponent("mixed.watchrelay", isDirectory: false)
        let complicationURL = self.root
            .deletingLastPathComponent()
            .appendingPathComponent("WatchCaptureStorageActorTests-complication-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("snapshot.json", isDirectory: false)

        async let manifestWrite: Void = storage.writeManifest(captured)
        async let relayPromotion: WatchRelayStorageTransition = storage.promoteQueuedForRelay(queuedEntry)
        async let relayTransfer: WatchRelayTransferPreparation = storage.prepareRelayTransfer(
            transferringEntry,
            bundleURL: bundleURL,
            attempt: attempt
        )
        async let diagnosticsWrite: Bool = storage.recordRelayQueueReconciliation(
            counts: .zero,
            observedFileTransferCount: 0,
            activeManifestCount: 3,
            at: date
        )
        async let historyWrite: Void = storage.upsertSessionHistory(history, asOf: date)
        async let locationAppend: Void = storage.appendLocationFix(fix, at: locationURL)
        async let complicationWrite: Void = storage.writeComplicationSnapshot(
            Data(#"{"queued_count":1}"#.utf8),
            to: complicationURL
        )

        try await manifestWrite
        let promoted = try await relayPromotion
        let preparation = try await relayTransfer
        let recordedDiagnostics = await diagnosticsWrite
        try await historyWrite
        try await locationAppend
        try await complicationWrite

        let overlap = await detector.snapshot()
        XCTAssertEqual(overlap.maximumConcurrentEntries, 1)
        XCTAssertTrue(overlap.hasOnlySerializedEntries)
        XCTAssertFalse(overlap.events.isEmpty)
        XCTAssertTrue(recordedDiagnostics)
        XCTAssertEqual(promoted.entry.manifest.state, .transferring)
        XCTAssertEqual(preparation.attempt, attempt)

        let catalog = await storage.scanCatalog()
        XCTAssertEqual(catalog.entries.first { $0.manifest.id == captured.id }?.manifest.state, .captured)
        XCTAssertEqual(catalog.entries.first { $0.manifest.id == queued.id }?.manifest.state, .transferring)
        XCTAssertEqual(catalog.entries.first { $0.manifest.id == transferring.id }?.manifest.state, .transferring)

        guard case let .available(summary) = await storage.readDiagnosticsSummary() else {
            return XCTFail("diagnostics summary should remain decodable")
        }
        XCTAssertNotNil(summary.lastQueueReconciliationObservation)
        guard case let .available(historyEntries) = await storage.readSessionHistory(asOf: date) else {
            return XCTFail("session history should remain decodable")
        }
        XCTAssertEqual(historyEntries.map(\.sessionID), [history.sessionID])
        let location = try await storage.finalizeLocationLog(at: locationURL, armed: true)
        XCTAssertEqual(location, WatchCaptureLocationLogFinalizedStats(fixCount: 1, gap: false))

        let decoder = WatchRelayDiagnosticsEnvelope.makeDecoder()
        let attemptData = try Data(contentsOf: paths.segmentDirectoryURL(
            day: transferring.day,
            segment: transferring.segment
        ).appendingPathComponent(WatchRelayAttemptRecord.filename, isDirectory: false))
        XCTAssertEqual(try decoder.decode(WatchRelayAttemptRecord.self, from: attemptData), attempt)
        let bundleData = try Data(contentsOf: bundleURL)
        let bundle = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: bundleData, options: [], format: nil) as? [String: Data]
        )
        XCTAssertEqual(
            try decoder.decode(WatchSegmentManifest.self, from: try XCTUnwrap(bundle[WatchSegmentBundleCodec.manifestFilename])).id,
            transferring.id
        )
        _ = try JSONSerialization.jsonObject(with: try Data(contentsOf: complicationURL))
    }

    func testMainActorProgressSentinelAdvancesWhileStorageWriterSuspends() async throws {
        let writer = SuspendingMainActorProgressWriter()
        let storage = WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: self.root),
            fileWriter: writer
        )
        let sentinel = MainActorProgressSentinel()
        let ticker = self.startMainActorProgressTicker(sentinel)
        let snapshotURL = self.root.appendingPathComponent("complication/snapshot.json", isDirectory: false)
        let write = Task {
            try await storage.writeComplicationSnapshot(Data("{}".utf8), to: snapshotURL)
        }

        await writer.waitUntilSuspended()
        let progressBeforeHold = sentinel.count
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertGreaterThan(sentinel.count, progressBeforeHold)

        await writer.release()
        try await write.value
        ticker.cancel()
        await ticker.value
    }

    func testMainActorProgressSentinelNegativeControlDetectsBlockingWriter() async throws {
        let writer = MainActorBlockingProgressWriter()
        let storage = WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: self.root),
            fileWriter: writer
        )
        let sentinel = MainActorProgressSentinel()
        let ticker = self.startMainActorProgressTicker(sentinel)
        try await Task.sleep(for: .milliseconds(5))
        XCTAssertGreaterThan(sentinel.count, 0)

        let snapshotURL = self.root.appendingPathComponent("complication/snapshot.json", isDirectory: false)
        let write = Task {
            try await storage.writeComplicationSnapshot(Data("{}".utf8), to: snapshotURL)
        }
        try await write.value
        ticker.cancel()
        await ticker.value

        let blockingWindow = await writer.blockingWindow()
        let window = try XCTUnwrap(blockingWindow)
        XCTAssertGreaterThan(window.endedAt.timeIntervalSince(window.startedAt), 0.02)
        XCTAssertFalse(sentinel.ticks.contains { $0 > window.startedAt && $0 < window.endedAt })
    }

    func testLocationLogRoundTripFinalizesDurableFixes() async throws {
        let actor = self.actor()
        let manifest = self.manifest(id: UUID(), segment: "120000_300", state: .captured)
        try await actor.writeManifest(manifest)
        let directory = self.root.appendingPathComponent("20250101/120000_300", isDirectory: true)
        let locationURL = directory.appendingPathComponent("location.jsonl")
        let fix = WatchLocationFix(
            t: Date(timeIntervalSince1970: 1_735_689_610),
            lat: 39.7392,
            lon: -104.9903,
            hAcc: 25,
            alt: 1609,
            vAcc: 12,
            speed: 0,
            course: 180,
            stationary: false
        )

        try await actor.openLocationLogHeader(at: locationURL)
        try await actor.appendLocationFix(fix, at: locationURL)
        let stats = try await actor.finalizeLocationLog(at: locationURL, armed: true)

        XCTAssertEqual(stats, WatchCaptureLocationLogFinalizedStats(fixCount: 1, gap: false))
        let lines = String(decoding: try Data(contentsOf: locationURL), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        let durableFix = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertEqual(header["fix_count"] as? Int, 1)
        XCTAssertEqual(header["gap"] as? Bool, false)
        XCTAssertEqual(durableFix["lat"] as? Double, fix.lat)
    }

    func testRelayPromotionRejectsStaleQueuedSnapshotsWithoutMutation() async throws {
        for (index, state) in [
            WatchSegmentState.transferring,
            .delivered,
            .acked,
        ].enumerated() {
            let actor = self.actor()
            let manifest = self.manifest(
                id: UUID(),
                segment: "120\(index)00_300",
                state: .queued
            )
            try await actor.writeManifest(manifest)
            let catalog = await actor.scanCatalog()
            let stale = try XCTUnwrap(catalog.entries.first { $0.manifest.id == manifest.id })
            var current = manifest
            current.state = state
            try await actor.writeManifest(current)
            let manifestURL = self.root
                .appendingPathComponent("20250101/\(manifest.segment)/manifest.json")
            let before = try Data(contentsOf: manifestURL)

            do {
                _ = try await actor.promoteQueuedForRelay(stale)
                XCTFail("expected stale queued snapshot conflict")
            } catch let conflict as WatchCaptureStorageConflict {
                XCTAssertEqual(
                    conflict,
                    .staleRelayState(id: manifest.id, expected: .queued, actual: state)
                )
            }
            XCTAssertEqual(try Data(contentsOf: manifestURL), before)
        }
    }

    func testRelayPromotionRejectsChangedMediaWitnessWithoutMutation() async throws {
        let actor = self.actor()
        let manifest = self.manifest(id: UUID(), segment: "121000_300", state: .queued)
        try await actor.writeManifest(manifest)
        let directory = self.root.appendingPathComponent("20250101/121000_300", isDirectory: true)
        let audioURL = directory.appendingPathComponent("audio.m4a")
        try Data("audio".utf8).write(to: audioURL, options: .atomic)
        let catalog = await actor.scanCatalog()
        let stale = try XCTUnwrap(catalog.entries.first)
        try Data("other".utf8).write(to: audioURL, options: .atomic)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let beforeManifest = try Data(contentsOf: manifestURL)
        let beforeAudio = try Data(contentsOf: audioURL)

        do {
            _ = try await actor.promoteQueuedForRelay(stale)
            XCTFail("expected content witness conflict")
        } catch let conflict as WatchCaptureStorageConflict {
            XCTAssertEqual(conflict, .contentWitnessChanged(id: stale.id))
        }
        XCTAssertEqual(try Data(contentsOf: manifestURL), beforeManifest)
        XCTAssertEqual(try Data(contentsOf: audioURL), beforeAudio)
    }

    func testRelayDeletionRejectsReplacementTreeWithoutMutation() async throws {
        let actor = self.actor()
        let manifest = self.manifest(id: UUID(), segment: "122000_300", state: .safeToDelete)
        try await actor.writeManifest(manifest)
        let catalog = await actor.scanCatalog()
        let stale = try XCTUnwrap(catalog.entries.first)
        let replacement = self.manifest(id: UUID(), segment: "122000_300", state: .safeToDelete)
        try await actor.writeManifest(replacement)
        let manifestURL = self.root.appendingPathComponent("20250101/122000_300/manifest.json")
        let before = try Data(contentsOf: manifestURL)

        do {
            try await actor.deleteAcknowledgedRelaySegment(
                stale,
                bundleURL: self.root.appendingPathComponent("replacement.watchrelay")
            )
            XCTFail("expected stale acknowledgement replacement conflict")
        } catch let conflict as WatchCaptureStorageConflict {
            XCTAssertEqual(
                conflict,
                .staleAcknowledgementReplacement(
                    id: manifest.id,
                    expected: stale.id,
                    found: stale.id
                )
            )
        }
        XCTAssertEqual(try Data(contentsOf: manifestURL), before)
    }

    func testRelayDeletionRejectsMissingTree() async throws {
        let actor = self.actor()
        let manifest = self.manifest(id: UUID(), segment: "123000_300", state: .safeToDelete)
        try await actor.writeManifest(manifest)
        let catalog = await actor.scanCatalog()
        let stale = try XCTUnwrap(catalog.entries.first)
        try await actor.removeItem(at: stale.directoryURL)

        do {
            try await actor.deleteAcknowledgedRelaySegment(
                stale,
                bundleURL: self.root.appendingPathComponent("missing.watchrelay")
            )
            XCTFail("expected stale acknowledgement replacement conflict")
        } catch let conflict as WatchCaptureStorageConflict {
            XCTAssertEqual(
                conflict,
                .staleAcknowledgementReplacement(
                    id: manifest.id,
                    expected: stale.id,
                    found: nil
                )
            )
        }
    }

    private func manifest(id: UUID, segment: String, state: WatchSegmentState) -> WatchSegmentManifest {
        WatchSegmentManifest(
            id: id,
            day: "20250101",
            segment: segment,
            startedAt: Date(timeIntervalSince1970: 1_735_689_600),
            duration: 300,
            sensors: [.audio],
            partial: false,
            lost: false,
            gap: false,
            fixCount: 0,
            state: state,
            failureReason: nil
        )
    }

    private func historyEntry(id: String, at date: Date) -> WatchCaptureSessionHistoryEntry {
        WatchCaptureSessionHistoryEntry(
            sessionID: id,
            startedAt: date,
            terminalAt: date,
            terminalReason: .ownerStopped,
            terminalDisposition: .ownerStopped,
            startRefusalReason: nil,
            settingsRoute: nil,
            noticeOwed: false,
            noticeDecision: nil,
            noticeDelivered: nil,
            notificationAuthorizationStatus: nil,
            notificationAlertSetting: nil,
            wristAlertAssurance: nil,
            audioArmed: false,
            audioSessionIsActive: false,
            locationArmed: false,
            segmentsProduced: 0,
            batteryLevelAtEnd: nil,
            batteryStateAtEnd: nil,
            lowPowerModeEnabledAtEnd: nil,
            thermalStateAtEnd: nil,
            lastVerifiedAudioAt: nil,
            lastAudioCurrentTime: nil,
            zeroAudioCurrentTimeObservationCount: nil,
            locationAdvisory: nil,
            persistenceAdvisory: nil
        )
    }

    private func startMainActorProgressTicker(_ sentinel: MainActorProgressSentinel) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                sentinel.advance()
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    private func actor() -> WatchCaptureStorageActor {
        WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: self.root),
            fileWriter: FoundationWatchFileWriter()
        )
    }
}

private struct WatchStorageSignpostTestSink: WatchStorageSignpostIntervalSink {
    enum Kind: Equatable {
        case begin
        case end
    }

    struct Event: Equatable {
        let kind: Kind
        let boundary: WatchSignpostBoundary
        let ordinal: Int
        let at: Date
    }

    struct Snapshot {
        let beginCallCount: Int
        let events: [Event]
        let openIntervalCount: Int
        let openBoundaries: [WatchSignpostBoundary]

        var hasBalancedIntervals: Bool {
            var boundaries: [WatchSignpostBoundary] = []
            for event in self.events {
                switch event.kind {
                case .begin:
                    boundaries.append(event.boundary)
                case .end:
                    guard boundaries.popLast() == event.boundary else { return false }
                }
            }
            return boundaries.isEmpty
        }
    }

    private struct State {
        var beginCallCount = 0
        var events: [Event] = []
        var openBoundaries: [WatchSignpostBoundary] = []
    }

    let isEnabled: Bool
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }

    func begin(_ boundary: WatchSignpostBoundary) -> WatchStorageSignpostInvocation {
        self.state.withLock { state in
            state.beginCallCount += 1
            state.openBoundaries.append(boundary)
            state.events.append(Event(
                kind: .begin,
                boundary: boundary,
                ordinal: state.beginCallCount,
                at: Date()
            ))
        }
        return WatchStorageSignpostInvocation(boundary: boundary, state: nil)
    }

    func end(_ invocation: WatchStorageSignpostInvocation) {
        self.state.withLock { state in
            precondition(state.openBoundaries.last == invocation.boundary)
            state.openBoundaries.removeLast()
            state.events.append(Event(
                kind: .end,
                boundary: invocation.boundary,
                ordinal: state.beginCallCount,
                at: Date()
            ))
        }
    }

    func snapshot() -> Snapshot {
        self.state.withLock { state in
            Snapshot(
                beginCallCount: state.beginCallCount,
                events: state.events,
                openIntervalCount: state.openBoundaries.count,
                openBoundaries: state.openBoundaries
            )
        }
    }
}

private struct WatchStorageSynchronousWorkCounter: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    func increment() {
        self.count.withLock { $0 += 1 }
    }

    func value() -> Int {
        self.count.withLock { $0 }
    }
}

private actor BlockingStorageWriter: WatchFileWriting {
    private let base = FoundationWatchFileWriter()
    private var entered = 0
    private var maximum = 0
    private var active = 0
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldBlock = true

    func createDirectory(at url: URL) async throws {
        self.active += 1
        self.maximum = max(self.maximum, self.active)
        self.entered += 1
        let waiters = self.enteredWaiters
        self.enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if self.shouldBlock {
            await withCheckedContinuation { self.releaseWaiters.append($0) }
            self.shouldBlock = false
        }
        defer { self.active -= 1 }
        try await self.base.createDirectory(at: url)
    }

    func fileExists(at url: URL) async -> Bool { await self.base.fileExists(at: url) }
    func itemKind(at url: URL) async throws -> WatchCaptureStorageItemKind { try await self.base.itemKind(at: url) }
    func createFileIfNeeded(at url: URL) async throws { try await self.base.createFileIfNeeded(at: url) }
    func fileSize(at url: URL) async throws -> Int64 { try await self.base.fileSize(at: url) }
    func fileFingerprint(at url: URL) async throws -> WatchCaptureStorageFileFingerprint? {
        try await self.base.fileFingerprint(at: url)
    }
    func readData(from url: URL) async throws -> Data { try await self.base.readData(from: url) }
    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) async throws { try await self.base.writeData(data, to: url, options: options) }
    func appendLine(_ line: Data, to url: URL) async throws { try await self.base.appendLine(line, to: url) }
    func atomicReplaceFile(at url: URL, with data: Data) async throws { try await self.base.atomicReplaceFile(at: url, with: data) }
    func removeItem(at url: URL) async throws { try await self.base.removeItem(at: url) }
    func moveItem(at sourceURL: URL, to destinationURL: URL) async throws { try await self.base.moveItem(at: sourceURL, to: destinationURL) }
    func contentsOfDirectory(at url: URL) async throws -> [URL] { try await self.base.contentsOfDirectory(at: url) }

    func waitUntilEntered() async {
        guard self.entered == 0 else { return }
        await withCheckedContinuation { self.enteredWaiters.append($0) }
    }

    func release() {
        let waiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func entryCount() -> Int { self.entered }
    func maximumConcurrentEntries() -> Int { self.maximum }
}

private actor WatchStorageOverlapDetector {
    enum Event: Equatable, Sendable {
        case entered(String)
        case exited(String)
    }

    struct Snapshot: Sendable {
        let maximumConcurrentEntries: Int
        let events: [Event]

        var hasOnlySerializedEntries: Bool {
            var active = 0
            for event in self.events {
                switch event {
                case .entered:
                    guard active == 0 else { return false }
                    active = 1
                case .exited:
                    guard active == 1 else { return false }
                    active = 0
                }
            }
            return active == 0
        }
    }

    private var active = 0
    private var maximum = 0
    private var events: [Event] = []

    func enter(_ operation: String) {
        self.active += 1
        self.maximum = max(self.maximum, self.active)
        self.events.append(.entered(operation))
    }

    func exit(_ operation: String) {
        self.events.append(.exited(operation))
        self.active -= 1
    }

    func reset() {
        self.active = 0
        self.maximum = 0
        self.events.removeAll()
    }

    func snapshot() -> Snapshot {
        Snapshot(maximumConcurrentEntries: self.maximum, events: self.events)
    }
}

private struct OverlapDetectingWatchFileWriter: WatchFileWriting {
    private let base = FoundationWatchFileWriter()
    private let detector: WatchStorageOverlapDetector

    init(detector: WatchStorageOverlapDetector) {
        self.detector = detector
    }

    func createDirectory(at url: URL) async throws {
        try await self.perform("createDirectory") {
            try await self.base.createDirectory(at: url)
        }
    }

    func createFileIfNeeded(at url: URL) async throws {
        try await self.perform("createFileIfNeeded") {
            try await self.base.createFileIfNeeded(at: url)
        }
    }

    func fileExists(at url: URL) async -> Bool {
        await self.perform("fileExists") {
            await self.base.fileExists(at: url)
        }
    }

    func itemKind(at url: URL) async throws -> WatchCaptureStorageItemKind {
        try await self.perform("itemKind") {
            try await self.base.itemKind(at: url)
        }
    }

    func fileSize(at url: URL) async throws -> Int64 {
        try await self.perform("fileSize") {
            try await self.base.fileSize(at: url)
        }
    }

    func fileFingerprint(at url: URL) async throws -> WatchCaptureStorageFileFingerprint? {
        try await self.perform("fileFingerprint") {
            try await self.base.fileFingerprint(at: url)
        }
    }

    func readData(from url: URL) async throws -> Data {
        try await self.perform("readData") {
            try await self.base.readData(from: url)
        }
    }

    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) async throws {
        try await self.perform("writeData") {
            try await self.base.writeData(data, to: url, options: options)
        }
    }

    func appendLine(_ line: Data, to url: URL) async throws {
        try await self.perform("appendLine") {
            try await self.base.appendLine(line, to: url)
        }
    }

    func atomicReplaceFile(at url: URL, with data: Data) async throws {
        try await self.perform("atomicReplaceFile") {
            try await self.base.atomicReplaceFile(at: url, with: data)
        }
    }

    func removeItem(at url: URL) async throws {
        try await self.perform("removeItem") {
            try await self.base.removeItem(at: url)
        }
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) async throws {
        try await self.perform("moveItem") {
            try await self.base.moveItem(at: sourceURL, to: destinationURL)
        }
    }

    func contentsOfDirectory(at url: URL) async throws -> [URL] {
        try await self.perform("contentsOfDirectory") {
            try await self.base.contentsOfDirectory(at: url)
        }
    }

    private func perform<Value: Sendable>(
        _ operation: String,
        _ body: () async throws -> Value
    ) async rethrows -> Value {
        await self.detector.enter(operation)
        do {
            await Task.yield()
            let value = try await body()
            await self.detector.exit(operation)
            return value
        } catch {
            await self.detector.exit(operation)
            throw error
        }
    }
}

@MainActor
private final class MainActorProgressSentinel {
    private(set) var ticks: [Date] = []

    var count: Int { self.ticks.count }

    func advance() {
        self.ticks.append(Date())
    }
}

private actor SuspendingMainActorProgressWriter: WatchFileWriting {
    private let base = FoundationWatchFileWriter()
    private var didSuspend = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func createDirectory(at url: URL) async throws { try await self.base.createDirectory(at: url) }
    func createFileIfNeeded(at url: URL) async throws { try await self.base.createFileIfNeeded(at: url) }
    func fileExists(at url: URL) async -> Bool { await self.base.fileExists(at: url) }
    func itemKind(at url: URL) async throws -> WatchCaptureStorageItemKind { try await self.base.itemKind(at: url) }
    func fileSize(at url: URL) async throws -> Int64 { try await self.base.fileSize(at: url) }
    func fileFingerprint(at url: URL) async throws -> WatchCaptureStorageFileFingerprint? {
        try await self.base.fileFingerprint(at: url)
    }
    func readData(from url: URL) async throws -> Data { try await self.base.readData(from: url) }

    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) async throws {
        if !self.didSuspend {
            self.didSuspend = true
            let waiters = self.enteredWaiters
            self.enteredWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { self.releaseWaiters.append($0) }
        }
        try await self.base.writeData(data, to: url, options: options)
    }

    func appendLine(_ line: Data, to url: URL) async throws { try await self.base.appendLine(line, to: url) }
    func atomicReplaceFile(at url: URL, with data: Data) async throws {
        try await self.base.atomicReplaceFile(at: url, with: data)
    }
    func removeItem(at url: URL) async throws { try await self.base.removeItem(at: url) }
    func moveItem(at sourceURL: URL, to destinationURL: URL) async throws {
        try await self.base.moveItem(at: sourceURL, to: destinationURL)
    }
    func contentsOfDirectory(at url: URL) async throws -> [URL] {
        try await self.base.contentsOfDirectory(at: url)
    }

    func waitUntilSuspended() async {
        guard !self.didSuspend else { return }
        await withCheckedContinuation { self.enteredWaiters.append($0) }
    }

    func release() {
        let waiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor MainActorBlockingProgressWriter: WatchFileWriting {
    struct Window: Sendable {
        let startedAt: Date
        let endedAt: Date
    }

    private let base = FoundationWatchFileWriter()
    private var window: Window?

    func createDirectory(at url: URL) async throws { try await self.base.createDirectory(at: url) }
    func createFileIfNeeded(at url: URL) async throws { try await self.base.createFileIfNeeded(at: url) }
    func fileExists(at url: URL) async -> Bool { await self.base.fileExists(at: url) }
    func itemKind(at url: URL) async throws -> WatchCaptureStorageItemKind { try await self.base.itemKind(at: url) }
    func fileSize(at url: URL) async throws -> Int64 { try await self.base.fileSize(at: url) }
    func fileFingerprint(at url: URL) async throws -> WatchCaptureStorageFileFingerprint? {
        try await self.base.fileFingerprint(at: url)
    }
    func readData(from url: URL) async throws -> Data { try await self.base.readData(from: url) }

    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) async throws {
        self.window = await MainActor.run {
            let startedAt = Date()
            Thread.sleep(forTimeInterval: 0.05)
            return Window(startedAt: startedAt, endedAt: Date())
        }
        try await self.base.writeData(data, to: url, options: options)
    }

    func appendLine(_ line: Data, to url: URL) async throws { try await self.base.appendLine(line, to: url) }
    func atomicReplaceFile(at url: URL, with data: Data) async throws {
        try await self.base.atomicReplaceFile(at: url, with: data)
    }
    func removeItem(at url: URL) async throws { try await self.base.removeItem(at: url) }
    func moveItem(at sourceURL: URL, to destinationURL: URL) async throws {
        try await self.base.moveItem(at: sourceURL, to: destinationURL)
    }
    func contentsOfDirectory(at url: URL) async throws -> [URL] {
        try await self.base.contentsOfDirectory(at: url)
    }

    func blockingWindow() -> Window? { self.window }
}
