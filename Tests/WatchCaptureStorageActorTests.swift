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

    func testRelevantMutationGenerationBumpsOnWriteAndDeleteNotOnScanOrExists() async throws {
        let actor = self.actor()
        let initial = await actor.currentRelevantMutationGeneration()
        XCTAssertEqual(initial, 0)
        try await actor.prepareRoot()
        let afterRoot = await actor.currentRelevantMutationGeneration()
        XCTAssertEqual(afterRoot, 1)
        let manifest = self.manifest(id: UUID(), segment: "120000_300", state: .queued)
        try await actor.writeManifest(manifest, transactionClass: .captureSafety)
        let afterWrite = await actor.currentRelevantMutationGeneration()
        XCTAssertEqual(afterWrite, 2)
        _ = await actor.scanCatalog(transactionClass: .maintenance)
        let afterScan = await actor.currentRelevantMutationGeneration()
        XCTAssertEqual(afterScan, afterWrite)
        let catalog = await actor.scanCatalog(transactionClass: .maintenance)
        let entry = try XCTUnwrap(catalog.entries.first)
        _ = await actor.fileExists(at: entry.manifestURL, transactionClass: .maintenance)
        let afterExists = await actor.currentRelevantMutationGeneration()
        XCTAssertEqual(afterExists, afterWrite)
        try await actor.removeItem(at: entry.directoryURL, transactionClass: .maintenance)
        let afterDelete = await actor.currentRelevantMutationGeneration()
        XCTAssertEqual(afterDelete, afterWrite + 1)
    }

    func testScanCatalogCarriesGenerationSampledAtStart() async throws {
        let actor = self.actor()
        try await actor.prepareRoot()
        let generation = await actor.currentRelevantMutationGeneration()
        let catalog = await actor.scanCatalog(transactionClass: .maintenance)
        XCTAssertEqual(catalog.relevantMutationGeneration, generation)
        XCTAssertEqual(catalog.rootState, .emptyComplete)
    }

    func testGenerationValidationWaitsForInFlightMutation() async throws {
        let writer = BlockingStorageWriter()
        let actor = WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: self.root),
            fileWriter: writer
        )

        async let mutation: Void = actor.prepareRoot()
        await writer.waitUntilEntered()
        let validation = Task {
            try await actor.validateRelevantMutationGeneration(0)
        }

        await writer.release()
        try await mutation
        let remainedCurrent = try await validation.value
        XCTAssertFalse(remainedCurrent)
    }

    func testWriteComplicationSnapshotReturnsUnchangedForByteIdenticalPayload() async throws {
        let actor = self.actor()
        let url = self.root.appendingPathComponent("complication-snapshot.json")
        let data = Data(#"{"mark":"paused"}"#.utf8)
        let first = try await actor.writeComplicationSnapshot(data, to: url)
        XCTAssertEqual(first, .written)
        let afterWrite = await actor.currentRelevantMutationGeneration()
        let second = try await actor.writeComplicationSnapshot(data, to: url)
        XCTAssertEqual(second, .unchanged)
        let afterUnchanged = await actor.currentRelevantMutationGeneration()
        XCTAssertEqual(afterUnchanged, afterWrite)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testNeedsCatalogFallbackRescanWhenPartialOrGenerationDrifted() async throws {
        let actor = self.actor()
        try await actor.prepareRoot()
        let complete = await actor.scanCatalog(transactionClass: .maintenance)
        let completeUnchanged = await actor.needsCatalogFallbackRescan(snapshot: complete, successfulBumps: 0)
        XCTAssertFalse(completeUnchanged)
        let manifest = self.manifest(id: UUID(), segment: "120000_300", state: .queued)
        try await actor.writeManifest(manifest, transactionClass: .captureSafety)
        let drifted = await actor.needsCatalogFallbackRescan(snapshot: complete, successfulBumps: 0)
        XCTAssertTrue(drifted)
        let current = await actor.currentRelevantMutationGeneration()
        let accounted = await actor.needsCatalogFallbackRescan(
            snapshot: complete,
            successfulBumps: current - complete.relevantMutationGeneration
        )
        XCTAssertFalse(accounted)

        let bad = self.root.appendingPathComponent("20250101/120500_300", isDirectory: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: bad.appendingPathComponent("manifest.json"))
        let partial = await actor.scanCatalog(transactionClass: .maintenance)
        XCTAssertEqual(partial.rootState, .partial)
        let partialNeedsFallback = await actor.needsCatalogFallbackRescan(snapshot: partial, successfulBumps: 0)
        XCTAssertTrue(partialNeedsFallback)
    }

    func testMissingRootIsUnavailableRatherThanEmpty() async {
        let catalog = await WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: self.root),
            fileWriter: FoundationWatchFileWriter()
        ).scanCatalog(transactionClass: .maintenance)
        XCTAssertEqual(catalog.rootState, .unavailable(.missing))
        XCTAssertFalse(catalog.canInferUUIDAbsence)
    }

    func testHealthySiblingsSurviveMalformedManifest() async throws {
        let actor = self.actor()
        try await actor.prepareRoot()
        let good = self.manifest(id: UUID(), segment: "120000_300", state: .queued)
        try await actor.writeManifest(good, transactionClass: .captureSafety)
        let bad = self.root.appendingPathComponent("20250101/120500_300", isDirectory: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: bad.appendingPathComponent("manifest.json"))

        let catalog = await actor.scanCatalog(transactionClass: .maintenance)
        XCTAssertEqual(catalog.rootState, .partial)
        XCTAssertEqual(catalog.entries.map(\.manifest.id), [good.id])
        XCTAssertEqual(catalog.issues.map(\.kind), [.manifestDecodeFailure])
        XCTAssertFalse(catalog.canInferUUIDAbsence)
    }

    func testDirectoryShapedMediaIsIsolatedWithoutSuppressingHealthySibling() async throws {
        let actor = self.actor()
        let healthy = self.manifest(id: UUID(), segment: "120000_300", state: .queued)
        let malformed = self.manifest(id: UUID(), segment: "120500_300", state: .queued)
        try await actor.writeManifest(healthy, transactionClass: .captureSafety)
        try await actor.writeManifest(malformed, transactionClass: .captureSafety)
        let malformedAudioURL = self.root
            .appendingPathComponent("20250101/120500_300/audio.m4a", isDirectory: true)
        try FileManager.default.createDirectory(at: malformedAudioURL, withIntermediateDirectories: true)

        let catalog = await actor.scanCatalog(transactionClass: .maintenance)

        XCTAssertEqual(catalog.rootState, .partial)
        XCTAssertEqual(catalog.entries.map(\.manifest.id), [healthy.id])
        XCTAssertEqual(catalog.issues, [WatchCaptureCatalogIssue(
            id: "unexpectedShape:20250101/120500_300/audio.m4a",
            kind: .unexpectedShape,
            namespace: "20250101/120500_300/audio.m4a"
        )])
        XCTAssertFalse(catalog.canInferUUIDAbsence)
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformedAudioURL.path))
    }

    func testEmptyExistingRootIsAuthoritative() async throws {
        let actor = self.actor()
        try await actor.prepareRoot()
        let catalog = await actor.scanCatalog(transactionClass: .maintenance)
        XCTAssertEqual(catalog.rootState, .emptyComplete)
        XCTAssertTrue(catalog.canInferUUIDAbsence)
    }

    func testCatalogIgnoresActorSessionFilesAtRoot() async throws {
        let actor = self.actor()
        let paths = WatchCaptureStoragePaths(rootURL: self.root)
        try await actor.prepareRoot()
        let manifest = self.manifest(id: UUID(), segment: "120000_300", state: .queued)
        try await actor.writeManifest(manifest, transactionClass: .captureSafety)

        let writer = FoundationWatchFileWriter()
        try await writer.writeData(Data("session".utf8), to: paths.sessionRecordURL(), options: .atomic)
        try await writer.writeData(Data("history".utf8), to: paths.sessionHistoryURL(), options: .atomic)
        try await writer.writeData(Data("counter".utf8), to: paths.sessionHistoryCounterURL(), options: .atomic)

        let catalog = await actor.scanCatalog(transactionClass: .maintenance)
        XCTAssertEqual(catalog.rootState, .complete)
        XCTAssertEqual(catalog.entries.map(\.manifest.id), [manifest.id])
        XCTAssertTrue(catalog.issues.isEmpty)
        XCTAssertTrue(catalog.canInferUUIDAbsence)
    }

    func testWriteRejectsChangedManifestWitnessWithoutMutation() async throws {
        let actor = self.actor()
        let manifest = self.manifest(id: UUID(), segment: "120000_300", state: .queued)
        try await actor.writeManifest(manifest, transactionClass: .captureSafety)
        let catalog = await actor.scanCatalog(transactionClass: .maintenance)
        let entry = try XCTUnwrap(catalog.entries.first)
        var replacement = manifest
        replacement.state = .transferring
        try await actor.writeManifest(replacement, transactionClass: .captureSafety)
        let before = try Data(contentsOf: self.root.appendingPathComponent("20250101/120000_300/manifest.json"))

        var stale = manifest
        stale.state = .delivered
        do {
            try await actor.writeManifest(stale, entry: entry, transactionClass: .captureSafety)
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

    func testTransactionGatePrioritizesCaptureSafetyAndPreservesLaneFIFO() async throws {
        let writer = BlockingStorageWriter()
        let root = self.root!
        let storage = WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: root),
            fileWriter: writer
        )
        let sentinel = MainActorProgressSentinel()
        let ticker = self.startMainActorProgressTicker(sentinel)

        let first = Task { try await storage.prepareRoot() }
        await writer.waitUntilEntered()
        let maintenanceOne = Task {
            try await storage.writeComplicationSnapshot(
                Data("one".utf8),
                to: root.appendingPathComponent("maintenance-one.json")
            )
        }
        await Task.yield()
        let maintenanceTwo = Task {
            try await storage.writeComplicationSnapshot(
                Data("two".utf8),
                to: root.appendingPathComponent("maintenance-two.json")
            )
        }
        await Task.yield()
        let captureSafety = Task { try await storage.prepareRoot() }
        await Task.yield()

        let progressBeforeHold = sentinel.count
        for _ in 0..<100 { await Task.yield() }
        XCTAssertGreaterThan(sentinel.count, progressBeforeHold)
        let heldEntryCount = await writer.entryCount()
        XCTAssertEqual(heldEntryCount, 1)

        await writer.release()
        try await first.value
        try await captureSafety.value
        try await maintenanceOne.value
        try await maintenanceTwo.value
        ticker.cancel()
        await ticker.value

        let priorityOperations = await writer.operations()
        XCTAssertEqual(
            priorityOperations,
            [
                "createDirectory",
                "createDirectory",
                "writeData:maintenance-one.json",
                "writeData:maintenance-two.json",
            ]
        )
    }

    func testTransactionGateDoesNotReserveIdleBoundariesForCaptureSafety() async throws {
        let writer = BlockingStorageWriter()
        let root = self.root!
        let storage = WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: root),
            fileWriter: writer
        )

        let first = Task { try await storage.prepareRoot() }
        await writer.waitUntilEntered()
        let maintenanceOne = Task {
            try await storage.writeComplicationSnapshot(
                Data("one".utf8),
                to: root.appendingPathComponent("maintenance-one.json")
            )
        }
        await Task.yield()
        let maintenanceTwo = Task {
            try await storage.writeComplicationSnapshot(
                Data("two".utf8),
                to: root.appendingPathComponent("maintenance-two.json")
            )
        }
        await Task.yield()
        let maintenanceThree = Task {
            try await storage.writeComplicationSnapshot(
                Data("three".utf8),
                to: root.appendingPathComponent("maintenance-three.json")
            )
        }
        await Task.yield()

        await writer.release()
        try await first.value
        try await maintenanceOne.value
        try await maintenanceTwo.value
        try await maintenanceThree.value

        let maintenanceOperations = await writer.operations()
        XCTAssertEqual(
            maintenanceOperations,
            [
                "createDirectory",
                "writeData:maintenance-one.json",
                "writeData:maintenance-two.json",
                "writeData:maintenance-three.json",
            ]
        )
    }

    func testCanceledQueuedMaintenanceManifestWriteIsRemovedWithoutMutation() async throws {
        let writer = BlockingStorageWriter()
        let root = self.root!
        let storage = WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: root),
            fileWriter: writer
        )

        let admitted = Task { try await storage.prepareRoot() }
        await writer.waitUntilEntered()
        let manifest = self.manifest(id: UUID(), segment: "120000_300", state: .finalized)
        let canceled = Task {
            try await storage.writeManifest(manifest, transactionClass: .maintenance)
        }
        await Task.yield()
        canceled.cancel()
        do {
            try await canceled.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected: the queued waiter exits without acquiring or mutating storage.
        }

        let followerURL = root.appendingPathComponent("maintenance-after-cancel.json")
        let follower = Task {
            try await storage.writeComplicationSnapshot(Data("after".utf8), to: followerURL)
        }
        await writer.release()
        try await admitted.value
        try await follower.value

        let manifestURL = WatchCaptureStoragePaths(rootURL: root).manifestURL(
            directory: WatchCaptureStoragePaths(rootURL: root).segmentDirectoryURL(
                day: manifest.day,
                segment: manifest.segment
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path))
        let operations = await writer.operations()
        XCTAssertEqual(
            operations,
            ["createDirectory", "writeData:maintenance-after-cancel.json"]
        )
    }

    func testScanCatalogYieldsAtCheckpointAndReturnsPartialAfterInterruption() async throws {
        let setup = self.actor()
        let existing = self.manifest(id: UUID(), segment: "120000_300", state: .queued)
        try await setup.writeManifest(existing, transactionClass: .captureSafety)

        let writer = BlockingStorageWriter()
        await writer.holdNextOperation("itemKind")
        let storage = WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: self.root),
            fileWriter: writer
        )
        let scan = Task { await storage.scanCatalog(transactionClass: .maintenance) }
        await writer.waitUntilEntered()
        let captured = self.manifest(id: UUID(), segment: "120500_300", state: .captured)
        let capture = Task {
            try await storage.writeManifest(captured, transactionClass: .captureSafety)
        }
        await Task.yield()

        await writer.release()
        let catalog = await scan.value
        try await capture.value

        XCTAssertEqual(catalog.rootState, .partial)
        XCTAssertFalse(catalog.canInferUUIDAbsence)
        XCTAssertTrue(catalog.issues.contains {
            $0.kind == .incompleteSubtree && $0.namespace == "catalog"
        })
        let operations = await writer.operations()
        let firstScanOperation = try XCTUnwrap(operations.firstIndex(of: "itemKind"))
        let captureWrite = try XCTUnwrap(operations.firstIndex(of: "writeData:manifest.json"))
        let nextScanOperation = try XCTUnwrap(operations.lastIndex(of: "itemKind"))
        XCTAssertLessThan(firstScanOperation, captureWrite)
        XCTAssertLessThan(captureWrite, nextScanOperation)
    }

    func testTerminalTupleResolverMergesCompatibleWitnessesAndFailsClosedForConflicts() async throws {
        let date = Date(timeIntervalSince1970: 1_735_689_600)
        let compatible = self.storage(named: "compatible")
        let compatibleRecord = self.terminalRecord(
            id: "session",
            startedAt: date,
            reason: .ownerStopped,
            disposition: nil,
            terminalAt: nil,
            noticeOwed: false
        )
        try await compatible.writeSessionRecord(compatibleRecord, transactionClass: .captureSafety)
        try await compatible.upsertSessionHistory(
            self.terminalHistoryEntry(
                id: "session",
                startedAt: date,
                reason: nil,
                disposition: .ownerStopped,
                terminalAt: date,
                noticeOwed: false
            ),
            asOf: date,
            transactionClass: .captureSafety
        )

        let compatibleResolution = await compatible.resolveAndPersistTerminalTuple(
            recordProposal: nil,
            proposedTerminal: self.terminalTuple(id: "session", startedAt: date, noticeOwed: false),
            asOf: date.addingTimeInterval(1)
        )
        guard case let .resolvedAndPersisted(tuple) = compatibleResolution else {
            return XCTFail("expected compatible terminal tuple to resolve")
        }
        XCTAssertEqual(tuple.reason, .ownerStopped)
        XCTAssertEqual(tuple.disposition, .ownerStopped)
        XCTAssertEqual(tuple.terminalAt, date)
        let compatibleRecordValue = try await compatible.readSessionRecord(transactionClass: .captureSafety)
        let persistedRecord = try XCTUnwrap(compatibleRecordValue)
        XCTAssertEqual(persistedRecord.terminalReason, .ownerStopped)
        XCTAssertEqual(persistedRecord.terminalDisposition, .ownerStopped)
        XCTAssertEqual(persistedRecord.terminalAt, date)

        let startMismatch = self.storage(named: "start-mismatch")
        let original = self.terminalRecord(
            id: "same-id",
            startedAt: date,
            reason: .ownerStopped,
            disposition: .ownerStopped,
            terminalAt: date,
            noticeOwed: false
        )
        try await startMismatch.writeSessionRecord(original, transactionClass: .captureSafety)
        let mismatchResolution = await startMismatch.resolveAndPersistTerminalTuple(
            recordProposal: nil,
            proposedTerminal: self.terminalTuple(
                id: "same-id",
                startedAt: date.addingTimeInterval(1),
                reason: .ownerStopped,
                disposition: .ownerStopped,
                terminalAt: date,
                noticeOwed: false
            ),
            asOf: date
        )
        XCTAssertEqual(mismatchResolution, .failClosed)
        let mismatchedRecord = try await startMismatch.readSessionRecord(transactionClass: .captureSafety)
        XCTAssertEqual(mismatchedRecord, original)

        let conflict = self.storage(named: "conflict")
        let conflictingRecord = self.terminalRecord(
            id: "conflict",
            startedAt: date,
            reason: .ownerStopped,
            disposition: .ownerStopped,
            terminalAt: date,
            noticeOwed: false
        )
        let conflictingHistory = self.terminalHistoryEntry(
            id: "conflict",
            startedAt: date,
            reason: .audioEncodeError,
            disposition: .ownerStopped,
            terminalAt: date,
            noticeOwed: false
        )
        try await conflict.writeSessionRecord(conflictingRecord, transactionClass: .captureSafety)
        try await conflict.upsertSessionHistory(
            conflictingHistory,
            asOf: date,
            transactionClass: .captureSafety
        )
        let conflictResolution = await conflict.resolveAndPersistTerminalTuple(
            recordProposal: nil,
            proposedTerminal: self.terminalTuple(id: "conflict", startedAt: date, noticeOwed: false),
            asOf: date
        )
        XCTAssertEqual(conflictResolution, .failClosed)
        let conflictingRecordAfterResolution = try await conflict.readSessionRecord(transactionClass: .captureSafety)
        XCTAssertEqual(conflictingRecordAfterResolution, conflictingRecord)
        let conflictingHistoryAfterResolution = await conflict.sessionHistoryEntry(
            sessionID: "conflict",
            asOf: date,
            transactionClass: .captureSafety
        )
        XCTAssertEqual(conflictingHistoryAfterResolution, conflictingHistory)
    }

    func testTerminalTupleResolverFillsOnlyOwnerStoppedAndMintsTerminalDateOnce() async throws {
        let date = Date(timeIntervalSince1970: 1_735_689_600)
        let ownerStoppedCases: [(String, WatchCaptureTerminalReason?, WatchCaptureTerminalDisposition?)] = [
            ("reason", WatchCaptureTerminalReason.ownerStopped, nil),
            ("disposition", nil, WatchCaptureTerminalDisposition.ownerStopped),
        ]
        for (name, reason, disposition) in ownerStoppedCases {
            let storage = self.storage(named: name)
            try await storage.writeSessionRecord(
                self.terminalRecord(
                    id: name,
                    startedAt: date,
                    reason: reason,
                    disposition: disposition,
                    terminalAt: nil,
                    noticeOwed: false
                ),
                transactionClass: .captureSafety
            )
            let resolution = await storage.resolveAndPersistTerminalTuple(
                recordProposal: nil,
                proposedTerminal: self.terminalTuple(id: name, startedAt: date, noticeOwed: false),
                asOf: date
            )
            guard case let .resolvedAndPersisted(tuple) = resolution else {
                return XCTFail("expected \(name) owner-stopped tuple to resolve")
            }
            XCTAssertEqual(tuple.reason, .ownerStopped)
            XCTAssertEqual(tuple.disposition, .ownerStopped)
        }

        let noGuess = self.storage(named: "no-guess")
        try await noGuess.writeSessionRecord(
            self.terminalRecord(
                id: "no-guess",
                startedAt: date,
                reason: nil,
                disposition: nil,
                terminalAt: nil,
                noticeOwed: false,
                state: .active
            ),
            transactionClass: .captureSafety
        )
        let noGuessResolution = await noGuess.resolveAndPersistTerminalTuple(
            recordProposal: nil,
            proposedTerminal: self.terminalTuple(
                id: "no-guess",
                startedAt: date,
                reason: .audioEncodeError,
                noticeOwed: false
            ),
            asOf: date
        )
        XCTAssertEqual(noGuessResolution, .failClosed)

        let mintOnce = self.storage(named: "mint-once")
        try await mintOnce.writeSessionRecord(
            self.terminalRecord(
                id: "mint-once",
                startedAt: date,
                reason: nil,
                disposition: nil,
                terminalAt: nil,
                noticeOwed: true,
                state: .active
            ),
            transactionClass: .captureSafety
        )
        let proposal = self.terminalTuple(
            id: "mint-once",
            startedAt: date,
            reason: .processExitedWhileActive,
            disposition: .inferredStoppedItself,
            noticeOwed: true
        )
        let first = await mintOnce.resolveAndPersistTerminalTuple(
            recordProposal: nil,
            proposedTerminal: proposal,
            asOf: date
        )
        let second = await mintOnce.resolveAndPersistTerminalTuple(
            recordProposal: nil,
            proposedTerminal: proposal,
            asOf: date.addingTimeInterval(60)
        )
        guard case let .resolvedAndPersisted(firstTuple) = first,
              case let .resolvedAndPersisted(secondTuple) = second
        else {
            return XCTFail("expected repeated resolution to succeed")
        }
        XCTAssertEqual(firstTuple.terminalAt, date)
        XCTAssertEqual(secondTuple.terminalAt, firstTuple.terminalAt)
    }

    func testTerminalTupleResolverAppliesAgeBeforeCapacityAndRequiresHealthyCapacityPopulation() async throws {
        let asOf = Date(timeIntervalSince1970: 1_735_689_600)
        let expiredAt = asOf.addingTimeInterval(-8 * 24 * 60 * 60)
        let failedHistoryRoot = self.root.appendingPathComponent("failed-history", isDirectory: true)
        let failedHistoryWriter = BlockingStorageWriter()
        await failedHistoryWriter.holdNextOperation("never")
        let failedHistory = WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: failedHistoryRoot),
            fileWriter: failedHistoryWriter
        )
        try await failedHistory.prepareRoot()
        let expiredRecord = self.terminalRecord(
            id: "expired",
            startedAt: expiredAt.addingTimeInterval(-60),
            reason: nil,
            disposition: nil,
            terminalAt: nil,
            noticeOwed: false,
            state: .active
        )
        try await failedHistory.writeSessionRecord(expiredRecord, transactionClass: .captureSafety)
        let failedHistoryURL = WatchCaptureStoragePaths(rootURL: failedHistoryRoot).sessionHistoryURL()
        try await FoundationWatchFileWriter().writeData(Data("history".utf8), to: failedHistoryURL, options: .atomic)
        await failedHistoryWriter.failReads(at: failedHistoryURL)
        guard case .resolvedAndPersisted = await failedHistory.resolveAndPersistTerminalTuple(
            recordProposal: nil,
            proposedTerminal: self.terminalTuple(
                id: "expired",
                startedAt: expiredRecord.startedAt,
                reason: .ownerStopped,
                disposition: .ownerStopped,
                terminalAt: expiredAt,
                noticeOwed: false
            ),
            asOf: asOf
        ) else {
            return XCTFail("age expiry should resolve without a readable history population")
        }

        let failedCapacityRoot = self.root.appendingPathComponent("failed-capacity", isDirectory: true)
        let failedCapacityWriter = BlockingStorageWriter()
        await failedCapacityWriter.holdNextOperation("never")
        let failedCapacity = WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: failedCapacityRoot),
            fileWriter: failedCapacityWriter
        )
        try await failedCapacity.prepareRoot()
        let active = self.terminalRecord(
            id: "fresh",
            startedAt: asOf,
            reason: nil,
            disposition: nil,
            terminalAt: nil,
            noticeOwed: false,
            state: .active
        )
        try await failedCapacity.writeSessionRecord(active, transactionClass: .captureSafety)
        let failedCapacityURL = WatchCaptureStoragePaths(rootURL: failedCapacityRoot).sessionHistoryURL()
        try await FoundationWatchFileWriter().writeData(Data("history".utf8), to: failedCapacityURL, options: .atomic)
        await failedCapacityWriter.failReads(at: failedCapacityURL)
        let failedCapacityResolution = await failedCapacity.resolveAndPersistTerminalTuple(
            recordProposal: nil,
            proposedTerminal: self.terminalTuple(
                id: "fresh",
                startedAt: asOf,
                reason: .ownerStopped,
                disposition: .ownerStopped,
                terminalAt: asOf,
                noticeOwed: false
            ),
            asOf: asOf
        )
        XCTAssertEqual(failedCapacityResolution, .failClosed)
        let failedCapacityRecord = try await failedCapacity.readSessionRecord(transactionClass: .captureSafety)
        XCTAssertEqual(failedCapacityRecord, active)

        for (name, hasMalformedLine) in [("complete-capacity", false), ("malformed-capacity", true)] {
            let root = self.root.appendingPathComponent(name, isDirectory: true)
            let storage = WatchCaptureStorageActor(
                paths: WatchCaptureStoragePaths(rootURL: root),
                fileWriter: FoundationWatchFileWriter()
            )
            try await storage.prepareRoot()
            let targetStart = asOf.addingTimeInterval(-10_000)
            let target = self.terminalRecord(
                id: "target",
                startedAt: targetStart,
                reason: nil,
                disposition: nil,
                terminalAt: nil,
                noticeOwed: false,
                state: .active
            )
            try await storage.writeSessionRecord(target, transactionClass: .captureSafety)
            var history = (0..<40).map { index in
                self.terminalHistoryEntry(
                    id: "newer-\(index)",
                    startedAt: asOf.addingTimeInterval(-Double(index)),
                    reason: .ownerStopped,
                    disposition: .ownerStopped,
                    terminalAt: asOf,
                    noticeOwed: false
                )
            }
            history.append(self.terminalHistoryEntry(
                id: "target",
                startedAt: targetStart,
                reason: nil,
                disposition: nil,
                terminalAt: nil,
                noticeOwed: false
            ))
            let paths = WatchCaptureStoragePaths(rootURL: root)
            try await self.writeRawHistory(
                history,
                malformedLine: hasMalformedLine ? Data("malformed".utf8) : nil,
                to: paths.sessionHistoryURL()
            )
            guard case .resolvedAndPersisted = await storage.resolveAndPersistTerminalTuple(
                recordProposal: nil,
                proposedTerminal: self.terminalTuple(
                    id: "target",
                    startedAt: targetStart,
                    reason: .ownerStopped,
                    disposition: .ownerStopped,
                    terminalAt: asOf,
                    noticeOwed: false
                ),
                asOf: asOf
            ) else {
                return XCTFail("terminal tuple should resolve")
            }
            let raw = try Data(contentsOf: paths.sessionHistoryURL())
            let storedIDs = self.rawHistoryEntries(from: raw).map(\.sessionID)
            if hasMalformedLine {
                XCTAssertTrue(storedIDs.contains("target"))
                XCTAssertTrue(String(decoding: raw, as: UTF8.self).contains("malformed"))
            } else {
                XCTAssertFalse(storedIDs.contains("target"))
                XCTAssertEqual(storedIDs.count, 40)
            }
        }
    }

    func testMergeTerminalNoticeMetadataRequiresTheExpectedTuple() async throws {
        let date = Date(timeIntervalSince1970: 1_735_689_600)
        let storage = self.storage(named: "notice")
        let record = self.terminalRecord(
            id: "notice",
            startedAt: date,
            reason: .ownerStopped,
            disposition: .ownerStopped,
            terminalAt: date,
            noticeOwed: true
        )
        let entry = self.terminalHistoryEntry(
            id: "notice",
            startedAt: date,
            reason: .ownerStopped,
            disposition: .ownerStopped,
            terminalAt: date,
            noticeOwed: true
        )
        try await storage.writeSessionRecord(record, transactionClass: .captureSafety)
        try await storage.upsertSessionHistory(entry, asOf: date, transactionClass: .captureSafety)
        let expected = self.terminalTuple(
            id: "notice",
            startedAt: date,
            reason: .ownerStopped,
            disposition: .ownerStopped,
            terminalAt: date,
            noticeOwed: true
        )
        let didMergeNotice = await storage.mergeTerminalNoticeMetadata(
            expected: expected,
            update: WatchCaptureTerminalNoticeMetadata(
                noticeOwed: false,
                noticeDecision: "schedule",
                noticeDelivered: true
            )
        )
        XCTAssertTrue(didMergeNotice)
        let noticeRecord = try await storage.readSessionRecord(transactionClass: .maintenance)
        XCTAssertEqual(noticeRecord?.noticeOwed, false)
        let updatedEntry = await storage.sessionHistoryEntry(
            sessionID: "notice",
            asOf: date,
            transactionClass: .maintenance
        )
        XCTAssertEqual(updatedEntry?.noticeOwed, false)
        XCTAssertEqual(updatedEntry?.noticeDecision, "schedule")
        XCTAssertEqual(updatedEntry?.noticeDelivered, true)

        let successor = self.terminalRecord(
            id: "newer",
            startedAt: date.addingTimeInterval(1),
            reason: .ownerStopped,
            disposition: .ownerStopped,
            terminalAt: date.addingTimeInterval(1),
            noticeOwed: true
        )
        try await storage.writeSessionRecord(successor, transactionClass: .captureSafety)
        let didMergeSupersededNotice = await storage.mergeTerminalNoticeMetadata(
            expected: expected,
            update: WatchCaptureTerminalNoticeMetadata(noticeOwed: true, noticeDecision: "cannot-schedule")
        )
        XCTAssertFalse(didMergeSupersededNotice)
        let historyAfterSupersededNotice = await storage.sessionHistoryEntry(
            sessionID: "notice",
            asOf: date,
            transactionClass: .maintenance
        )
        XCTAssertEqual(historyAfterSupersededNotice, updatedEntry)
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

        let unavailableCatalog = await storage.scanCatalog(transactionClass: .maintenance)
        XCTAssertEqual(unavailableCatalog.rootState, .unavailable(.missing))
        try await storage.prepareRoot()
        let malformedDirectory = self.root.appendingPathComponent("20250101/120500_300", isDirectory: true)
        try FileManager.default.createDirectory(at: malformedDirectory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: malformedDirectory.appendingPathComponent("manifest.json"))
        let partialCatalog = await storage.scanCatalog(transactionClass: .maintenance)
        XCTAssertEqual(partialCatalog.rootState, .partial)

        let manifest = self.manifest(id: UUID(), segment: "120000_300", state: .queued)
        try await storage.writeManifest(manifest, transactionClass: .captureSafety)
        let catalog = await storage.scanCatalog(transactionClass: .maintenance)
        let entry = try XCTUnwrap(catalog.entries.first { $0.manifest.id == manifest.id })
        var replacement = manifest
        replacement.state = .transferring
        try await storage.writeManifest(replacement, transactionClass: .captureSafety)
        do {
            try await storage.writeManifest(manifest, entry: entry, transactionClass: .captureSafety)
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
        try await storage.writeManifest(queued, transactionClass: .captureSafety)
        try await storage.writeManifest(transferring, transactionClass: .captureSafety)
        try await storage.writeManifest(locationManifest, transactionClass: .captureSafety)
        let initialCatalog = await storage.scanCatalog(transactionClass: .maintenance)
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

        async let manifestWrite = storage.writeManifest(captured, transactionClass: .captureSafety)
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
        async let historyWrite: Void = storage.upsertSessionHistory(
            history,
            asOf: date,
            transactionClass: .maintenance
        )
        async let locationAppend: Void = storage.appendLocationFix(fix, at: locationURL)
        async let complicationWrite = storage.writeComplicationSnapshot(
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

        let catalog = await storage.scanCatalog(transactionClass: .maintenance)
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
        try await actor.writeManifest(manifest, transactionClass: .captureSafety)
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
            try await actor.writeManifest(manifest, transactionClass: .captureSafety)
            let catalog = await actor.scanCatalog(transactionClass: .maintenance)
            let stale = try XCTUnwrap(catalog.entries.first { $0.manifest.id == manifest.id })
            var current = manifest
            current.state = state
            try await actor.writeManifest(current, transactionClass: .captureSafety)
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
        try await actor.writeManifest(manifest, transactionClass: .captureSafety)
        let directory = self.root.appendingPathComponent("20250101/121000_300", isDirectory: true)
        let audioURL = directory.appendingPathComponent("audio.m4a")
        try Data("audio".utf8).write(to: audioURL, options: .atomic)
        let catalog = await actor.scanCatalog(transactionClass: .maintenance)
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
        try await actor.writeManifest(manifest, transactionClass: .captureSafety)
        let catalog = await actor.scanCatalog(transactionClass: .maintenance)
        let stale = try XCTUnwrap(catalog.entries.first)
        let replacement = self.manifest(id: UUID(), segment: "122000_300", state: .safeToDelete)
        try await actor.writeManifest(replacement, transactionClass: .captureSafety)
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
        try await actor.writeManifest(manifest, transactionClass: .captureSafety)
        let catalog = await actor.scanCatalog(transactionClass: .maintenance)
        let stale = try XCTUnwrap(catalog.entries.first)
        try await actor.removeItem(at: stale.directoryURL, transactionClass: .maintenance)

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

    func testRelayReceiptRoundTripPreservesFractionalModificationDates() async throws {
        let fingerprint = WatchCaptureStorageFileFingerprint(
            byteCount: 13,
            modificationDate: Date(timeIntervalSince1970: 1_735_689_600.125)
        )
        let witness = WatchCaptureContentWitness(
            manifestData: Data("manifest".utf8),
            manifestFingerprint: WatchCaptureStorageFileFingerprint(
                byteCount: Int64(Data("manifest".utf8).count),
                modificationDate: fingerprint.modificationDate
            ),
            audioState: .readableNonempty,
            audioFingerprint: fingerprint,
            locationState: .missing
        )
        let receipt = WatchRelayBundleReceipt(
            segmentID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            source: witness,
            bundle: fingerprint
        )
        let encoded = try WatchRelayBundleReceipt.makeEncoder().encode(receipt)
        let decoded = try WatchRelayBundleReceipt.makeDecoder().decode(WatchRelayBundleReceipt.self, from: encoded)
        XCTAssertEqual(decoded, receipt)
        XCTAssertEqual(decoded.bundle.modificationDate, fingerprint.modificationDate)
        XCTAssertEqual(decoded.source.manifestFingerprint?.modificationDate, fingerprint.modificationDate)
        XCTAssertEqual(decoded.source.audioFingerprint?.modificationDate, fingerprint.modificationDate)
    }

    func testPrepareReusesThenRebuildsWhenSourceAudioChanges() async throws {
        let actor = self.actor()
        let seeded = try await self.seedTransferringSegment(actor: actor)
        let first = try await actor.prepareRelayTransfer(
            seeded.entry,
            bundleURL: seeded.bundleURL,
            attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
        )
        XCTAssertEqual(first.disposition, .rebuilt)
        let paths = WatchCaptureStoragePaths(rootURL: self.root)
        let receiptURL = paths.relayReceiptURL(directory: seeded.directory)
        let receipt = try WatchRelayBundleReceipt.makeDecoder().decode(
            WatchRelayBundleReceipt.self,
            from: Data(contentsOf: receiptURL)
        )
        let catalog = await actor.scanCatalog(transactionClass: .maintenance)
        let entry = try XCTUnwrap(catalog.entries.first { $0.manifest.id == seeded.manifest.id })
        XCTAssertEqual(receipt.segmentID, seeded.manifest.id)
        XCTAssertEqual(receipt.source, entry.witness)
        let reuseID = UUID()
        let reused = try await actor.prepareRelayTransfer(
            entry,
            bundleURL: seeded.bundleURL,
            attempt: self.attempt(id: seeded.manifest.id, attemptID: reuseID)
        )
        XCTAssertEqual(reused.disposition, .reused)
        XCTAssertEqual(reused.attempt?.attemptID, reuseID)

        try Data("audio-changed".utf8).write(to: seeded.audioURL, options: .atomic)
        let changedCatalog = await actor.scanCatalog(transactionClass: .maintenance)
        let changed = try XCTUnwrap(changedCatalog.entries.first { $0.manifest.id == seeded.manifest.id })
        let rebuilt = try await actor.prepareRelayTransfer(
            changed,
            bundleURL: seeded.bundleURL,
            attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
        )
        XCTAssertEqual(rebuilt.disposition, .rebuilt)
        let decoded = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: seeded.bundleURL),
                options: [],
                format: nil
            ) as? [String: Data]
        )
        XCTAssertEqual(decoded[WatchSegmentBundleCodec.audioFilename], Data("audio-changed".utf8))

        try Data("location-changed".utf8).write(to: seeded.locationURL, options: .atomic)
        let locationCatalog = await actor.scanCatalog(transactionClass: .maintenance)
        let locationChanged = try XCTUnwrap(
            locationCatalog.entries.first { $0.manifest.id == seeded.manifest.id }
        )
        let locationRebuilt = try await actor.prepareRelayTransfer(
            locationChanged,
            bundleURL: seeded.bundleURL,
            attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
        )
        XCTAssertEqual(locationRebuilt.disposition, .rebuilt)
        let locationDecoded = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: seeded.bundleURL),
                options: [],
                format: nil
            ) as? [String: Data]
        )
        XCTAssertEqual(
            locationDecoded[WatchSegmentBundleCodec.locationFilename],
            Data("location-changed".utf8)
        )
    }

    func testMalformedAndMismatchedReceiptsMissThenRebuildOnce() async throws {
        let actor = self.actor()
        let seeded = try await self.seedTransferringSegment(actor: actor)
        _ = try await actor.prepareRelayTransfer(
            seeded.entry,
            bundleURL: seeded.bundleURL,
            attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
        )
        let receiptURL = WatchCaptureStoragePaths(rootURL: self.root).relayReceiptURL(directory: seeded.directory)
        try Data("{".utf8).write(to: receiptURL, options: .atomic)
        let catalog = await actor.scanCatalog(transactionClass: .maintenance)
        let entry = try XCTUnwrap(catalog.entries.first { $0.manifest.id == seeded.manifest.id })
        let rebuilt = try await actor.prepareRelayTransfer(
            entry,
            bundleURL: seeded.bundleURL,
            attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
        )
        XCTAssertEqual(rebuilt.disposition, .rebuilt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptURL.path))
    }

    func testSemanticReceiptMismatchesEachRebuildOnce() async throws {
        enum Mismatch: CaseIterable {
            case futureVersion
            case segmentID
            case source
            case bundle
        }

        let writer = RelayPreparationFaultWriter()
        let actor = WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: self.root),
            fileWriter: writer
        )
        let seeded = try await self.seedTransferringSegment(actor: actor)
        _ = try await actor.prepareRelayTransfer(
            seeded.entry,
            bundleURL: seeded.bundleURL,
            attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
        )
        let receiptURL = WatchCaptureStoragePaths(rootURL: self.root).relayReceiptURL(
            directory: seeded.directory
        )

        for mismatch in Mismatch.allCases {
            let valid = try WatchRelayBundleReceipt.makeDecoder().decode(
                WatchRelayBundleReceipt.self,
                from: Data(contentsOf: receiptURL)
            )
            let invalid: WatchRelayBundleReceipt
            switch mismatch {
            case .futureVersion:
                invalid = WatchRelayBundleReceipt(
                    version: WatchRelayBundleReceipt.currentVersion + 1,
                    segmentID: valid.segmentID,
                    source: valid.source,
                    bundle: valid.bundle
                )
            case .segmentID:
                invalid = WatchRelayBundleReceipt(
                    segmentID: UUID(),
                    source: valid.source,
                    bundle: valid.bundle
                )
            case .source:
                let manifestFingerprint = try XCTUnwrap(valid.source.manifestFingerprint)
                invalid = WatchRelayBundleReceipt(
                    segmentID: valid.segmentID,
                    source: WatchCaptureContentWitness(
                        manifestData: valid.source.manifestData,
                        manifestFingerprint: WatchCaptureStorageFileFingerprint(
                            byteCount: manifestFingerprint.byteCount,
                            modificationDate: try XCTUnwrap(
                                manifestFingerprint.modificationDate
                            ).addingTimeInterval(1)
                        ),
                        audioState: valid.source.audioState,
                        audioFingerprint: valid.source.audioFingerprint,
                        locationState: valid.source.locationState,
                        locationFingerprint: valid.source.locationFingerprint
                    ),
                    bundle: valid.bundle
                )
            case .bundle:
                invalid = WatchRelayBundleReceipt(
                    segmentID: valid.segmentID,
                    source: valid.source,
                    bundle: WatchCaptureStorageFileFingerprint(
                        byteCount: valid.bundle.byteCount + 1,
                        modificationDate: valid.bundle.modificationDate
                    )
                )
            }
            try WatchRelayBundleReceipt.makeEncoder().encode(invalid).write(
                to: receiptURL,
                options: .atomic
            )
            await writer.resetWriteCount(at: seeded.bundleURL)
            let catalog = await actor.scanCatalog(transactionClass: .maintenance)
            let entry = try XCTUnwrap(catalog.entries.first { $0.manifest.id == seeded.manifest.id })
            let rebuilt = try await actor.prepareRelayTransfer(
                entry,
                bundleURL: seeded.bundleURL,
                attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
            )
            XCTAssertEqual(rebuilt.disposition, .rebuilt, "mismatch: \(mismatch)")
            let bundleWriteCount = await writer.writeCount(at: seeded.bundleURL)
            XCTAssertEqual(bundleWriteCount, 1, "mismatch: \(mismatch)")
        }
    }

    func testCrashWindowsRebuildOrReuseWithFreshAttempt() async throws {
        let actor = self.actor()
        let seeded = try await self.seedTransferringSegment(actor: actor)
        let firstID = UUID()
        _ = try await actor.prepareRelayTransfer(
            seeded.entry,
            bundleURL: seeded.bundleURL,
            attempt: self.attempt(id: seeded.manifest.id, attemptID: firstID)
        )
        let paths = WatchCaptureStoragePaths(rootURL: self.root)
        let receiptURL = paths.relayReceiptURL(directory: seeded.directory)
        let attemptURL = seeded.directory.appendingPathComponent(WatchRelayAttemptRecord.filename)

        try FileManager.default.removeItem(at: receiptURL)
        let noReceiptCatalog = await actor.scanCatalog(transactionClass: .maintenance)
        let noReceiptEntry = try XCTUnwrap(noReceiptCatalog.entries.first)
        let noReceipt = try await actor.prepareRelayTransfer(
            noReceiptEntry,
            bundleURL: seeded.bundleURL,
            attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
        )
        XCTAssertEqual(noReceipt.disposition, .rebuilt)

        try Data("replaced-bundle".utf8).write(to: seeded.bundleURL, options: .atomic)
        let staleCatalog = await actor.scanCatalog(transactionClass: .maintenance)
        let staleEntry = try XCTUnwrap(staleCatalog.entries.first)
        let stale = try await actor.prepareRelayTransfer(
            staleEntry,
            bundleURL: seeded.bundleURL,
            attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
        )
        XCTAssertEqual(stale.disposition, .rebuilt)

        try FileManager.default.removeItem(at: seeded.bundleURL)
        let missingBundleCatalog = await actor.scanCatalog(transactionClass: .maintenance)
        let missingBundleEntry = try XCTUnwrap(missingBundleCatalog.entries.first)
        let missingBundle = try await actor.prepareRelayTransfer(
            missingBundleEntry,
            bundleURL: seeded.bundleURL,
            attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
        )
        XCTAssertEqual(missingBundle.disposition, .rebuilt)

        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptURL.path))
        try FileManager.default.removeItem(at: attemptURL)
        let noAttemptCatalog = await actor.scanCatalog(transactionClass: .maintenance)
        let noAttemptEntry = try XCTUnwrap(noAttemptCatalog.entries.first { $0.manifest.id == seeded.manifest.id })
        let freshAttemptID = UUID()
        let noAttempt = try await actor.prepareRelayTransfer(
            noAttemptEntry,
            bundleURL: seeded.bundleURL,
            attempt: self.attempt(id: seeded.manifest.id, attemptID: freshAttemptID)
        )
        XCTAssertEqual(noAttempt.disposition, .reused)
        XCTAssertEqual(noAttempt.attempt?.attemptID, freshAttemptID)
    }

    func testDirectoryShapedAudioFailsPreparationWithoutEnqueueing() async throws {
        let actor = self.actor()
        let seeded = try await self.seedTransferringSegment(actor: actor)
        try FileManager.default.removeItem(at: seeded.audioURL)
        try FileManager.default.createDirectory(at: seeded.audioURL, withIntermediateDirectories: true)
        let catalog = await actor.scanCatalog(transactionClass: .maintenance)
        XCTAssertTrue(catalog.entries.isEmpty)
        do {
            _ = try await actor.prepareRelayTransfer(
                seeded.entry,
                bundleURL: seeded.bundleURL,
                attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
            )
            XCTFail("directory-shaped source should fail preparation")
        } catch let conflict as WatchCaptureStorageConflict {
            XCTAssertEqual(conflict, .contentWitnessChanged(id: seeded.entry.id))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: seeded.bundleURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: seeded.directory.appendingPathComponent(WatchRelayAttemptRecord.filename).path
        ))
    }

    func testPostwriteSourceMutationFailsWithoutReceiptOrAttempt() async throws {
        let writer = RelayPreparationFaultWriter()
        let actor = WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: self.root),
            fileWriter: writer
        )
        let seeded = try await self.seedTransferringSegment(actor: actor)
        await writer.mutate(
            seeded.audioURL,
            afterWriting: seeded.bundleURL,
            data: Data("audio-mutated-after-bundle-write".utf8)
        )

        do {
            _ = try await actor.prepareRelayTransfer(
                seeded.entry,
                bundleURL: seeded.bundleURL,
                attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
            )
            XCTFail("postwrite source mutation should fail preparation")
        } catch let conflict as WatchCaptureStorageConflict {
            XCTAssertEqual(conflict, .contentWitnessChanged(id: seeded.entry.id))
        }

        let receiptURL = WatchCaptureStoragePaths(rootURL: self.root).relayReceiptURL(
            directory: seeded.directory
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: seeded.directory.appendingPathComponent(WatchRelayAttemptRecord.filename).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: seeded.bundleURL.path))
    }

    func testPostwriteManifestMutationFailsWithoutReceiptOrAttempt() async throws {
        let writer = RelayPreparationFaultWriter()
        let actor = WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: self.root),
            fileWriter: writer
        )
        let seeded = try await self.seedTransferringSegment(actor: actor)
        await writer.mutate(
            seeded.entry.manifestURL,
            afterWriting: seeded.bundleURL,
            data: Data("manifest-mutated-after-bundle-write".utf8)
        )

        do {
            _ = try await actor.prepareRelayTransfer(
                seeded.entry,
                bundleURL: seeded.bundleURL,
                attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
            )
            XCTFail("postwrite manifest mutation should fail preparation")
        } catch let conflict as WatchCaptureStorageConflict {
            XCTAssertEqual(conflict, .contentWitnessChanged(id: seeded.entry.id))
        }

        let receiptURL = WatchCaptureStoragePaths(rootURL: self.root).relayReceiptURL(
            directory: seeded.directory
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: seeded.directory.appendingPathComponent(WatchRelayAttemptRecord.filename).path
        ))
    }

    func testSourceMutationDuringBundleFingerprintFailsWithoutReceiptOrAttempt() async throws {
        let writer = RelayPreparationFaultWriter()
        let actor = WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: self.root),
            fileWriter: writer
        )
        let seeded = try await self.seedTransferringSegment(actor: actor)
        await writer.mutate(
            seeded.audioURL,
            whileFingerprinting: seeded.bundleURL,
            data: Data("audio-mutated-during-bundle-fingerprint".utf8)
        )

        do {
            _ = try await actor.prepareRelayTransfer(
                seeded.entry,
                bundleURL: seeded.bundleURL,
                attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
            )
            XCTFail("source mutation during bundle fingerprint should fail preparation")
        } catch let conflict as WatchCaptureStorageConflict {
            XCTAssertEqual(conflict, .contentWitnessChanged(id: seeded.entry.id))
        }

        let receiptURL = WatchCaptureStoragePaths(rootURL: self.root).relayReceiptURL(
            directory: seeded.directory
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: seeded.directory.appendingPathComponent(WatchRelayAttemptRecord.filename).path
        ))
    }

    func testMissingSourceModificationDateFailsBeforeBundleBuild() async throws {
        let writer = RelayPreparationFaultWriter()
        await writer.stripAllModificationDates()
        let actor = WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: self.root),
            fileWriter: writer
        )
        let seeded = try await self.seedTransferringSegment(actor: actor)

        do {
            _ = try await actor.prepareRelayTransfer(
                seeded.entry,
                bundleURL: seeded.bundleURL,
                attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
            )
            XCTFail("missing source modification date should fail preparation")
        } catch let conflict as WatchCaptureStorageConflict {
            XCTAssertEqual(conflict, .contentWitnessChanged(id: seeded.entry.id))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: seeded.bundleURL.path))
    }

    func testMissingBundleModificationDateEnqueuesUnreceiptedPartial() async throws {
        let writer = RelayPreparationFaultWriter()
        let actor = WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: self.root),
            fileWriter: writer
        )
        let seeded = try await self.seedTransferringSegment(actor: actor)
        await writer.stripModificationDate(at: seeded.bundleURL)

        let preparation = try await actor.prepareRelayTransfer(
            seeded.entry,
            bundleURL: seeded.bundleURL,
            attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
        )

        let receiptURL = WatchCaptureStoragePaths(rootURL: self.root).relayReceiptURL(
            directory: seeded.directory
        )
        XCTAssertTrue(preparation.receiptPersistenceFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: seeded.bundleURL.path))
        XCTAssertNotNil(preparation.attempt)
    }

    func testReceiptAndBundleKindFailuresPreserveDerivedPaths() async throws {
        let writer = RelayPreparationFaultWriter()
        let actor = WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: self.root),
            fileWriter: writer
        )
        let seeded = try await self.seedTransferringSegment(actor: actor)
        let paths = WatchCaptureStoragePaths(rootURL: self.root)
        let receiptURL = paths.relayReceiptURL(directory: seeded.directory)
        let receiptMarker = Data("receipt-marker".utf8)
        try receiptMarker.write(to: receiptURL, options: .atomic)

        await writer.overrideItemKind(.other, at: receiptURL)
        do {
            _ = try await actor.prepareRelayTransfer(
                seeded.entry,
                bundleURL: seeded.bundleURL,
                attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
            )
            XCTFail("other-shaped receipt should fail")
        } catch let conflict as WatchCaptureStorageConflict {
            XCTAssertEqual(conflict, .relayReceiptUnexpectedShape(id: seeded.entry.id))
        }
        XCTAssertEqual(try Data(contentsOf: receiptURL), receiptMarker)
        await writer.clearItemKindOverride(at: receiptURL)
        try FileManager.default.removeItem(at: receiptURL)

        let bundleMarker = Data("bundle-marker".utf8)
        try bundleMarker.write(to: seeded.bundleURL, options: .atomic)
        await writer.overrideItemKind(.other, at: seeded.bundleURL)
        do {
            _ = try await actor.prepareRelayTransfer(
                seeded.entry,
                bundleURL: seeded.bundleURL,
                attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
            )
            XCTFail("other-shaped bundle should fail")
        } catch let conflict as WatchCaptureStorageConflict {
            XCTAssertEqual(conflict, .relayBundleUnexpectedShape(id: seeded.entry.id))
        }
        XCTAssertEqual(try Data(contentsOf: seeded.bundleURL), bundleMarker)
        await writer.clearItemKindOverride(at: seeded.bundleURL)
        try FileManager.default.removeItem(at: seeded.bundleURL)

        await writer.failItemKind(at: receiptURL)
        do {
            _ = try await actor.prepareRelayTransfer(
                seeded.entry,
                bundleURL: seeded.bundleURL,
                attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
            )
            XCTFail("receipt kind lookup failure should fail")
        } catch let conflict as WatchCaptureStorageConflict {
            XCTAssertEqual(conflict, .relayReceiptUnexpectedShape(id: seeded.entry.id))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: seeded.bundleURL.path))
    }

    func testFoundationItemKindRecognizesAbsentURL() async throws {
        let missingURL = self.root.appendingPathComponent("not-created", isDirectory: false)
        let kind = try await FoundationWatchFileWriter().itemKind(at: missingURL)
        XCTAssertEqual(kind, .missing)
    }

    func testFailedRelayBundlePreparationReportsCompletedWholeFileReads() async throws {
        let sink = WatchStorageSignpostTestSink()
        let writer = RelayPreparationFaultWriter()
        let actor = WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: self.root),
            fileWriter: writer,
            storageSignposter: WatchStorageSignposter(sink: sink)
        )
        let seeded = try await self.seedTransferringSegment(actor: actor)
        await writer.failRead(at: seeded.locationURL)
        let expectedBytes = seeded.entry.witness.manifestData.count
            + (try Data(contentsOf: seeded.audioURL).count)

        do {
            _ = try await actor.prepareRelayTransfer(
                seeded.entry,
                bundleURL: seeded.bundleURL,
                attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
            )
            XCTFail("location read failure should fail preparation")
        } catch {
            // The failed interval below is the contract under test.
        }

        let event = try XCTUnwrap(sink.snapshot().events.last {
            $0.kind == .end && $0.boundary == .relayBundlePreparation
        })
        XCTAssertEqual(event.fields.result, .failed)
        XCTAssertEqual(event.fields.wholeFileReadCount, 2)
        XCTAssertEqual(event.fields.wholeFileReadByteCount, expectedBytes)
    }

    func testRelayBundlePreparationSignpostBeginsAfterTransactionAdmission() async throws {
        let seedActor = self.actor()
        let seeded = try await self.seedTransferringSegment(actor: seedActor)
        let writer = BlockingStorageWriter()
        let sink = WatchStorageSignpostTestSink()
        let actor = WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: self.root),
            fileWriter: writer,
            storageSignposter: WatchStorageSignposter(sink: sink)
        )
        let queuedAttempt = self.attempt(id: seeded.manifest.id, attemptID: UUID())

        async let held: Void = actor.prepareRoot()
        await writer.waitUntilEntered()
        async let queued = actor.prepareRelayTransfer(
            seeded.entry,
            bundleURL: seeded.bundleURL,
            attempt: queuedAttempt
        )
        try await Task.sleep(for: .milliseconds(30))

        let heldSnapshot = sink.snapshot()
        XCTAssertEqual(heldSnapshot.openBoundaries, [.storageActorTransactionElapsed])
        XCTAssertFalse(heldSnapshot.openBoundaries.contains(.relayBundlePreparation))

        await writer.release()
        try await held
        _ = try await queued

        let completedSnapshot = sink.snapshot()
        XCTAssertTrue(completedSnapshot.hasBalancedIntervals)
        XCTAssertEqual(completedSnapshot.openIntervalCount, 0)
        XCTAssertEqual(
            completedSnapshot.events.filter {
                $0.kind == .begin && $0.boundary == .relayBundlePreparation
            }.count,
            1
        )
    }

    func testRelayBundlePreparationSignpostReportsWholeFileReads() async throws {
        let sink = WatchStorageSignpostTestSink()
        let actor = WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: self.root),
            fileWriter: FoundationWatchFileWriter(),
            storageSignposter: WatchStorageSignposter(sink: sink)
        )
        let seeded = try await self.seedTransferringSegment(actor: actor)
        let expectedBuildBytes = seeded.entry.witness.manifestData.count
            + (try Data(contentsOf: seeded.audioURL).count)
            + (try Data(contentsOf: seeded.locationURL).count)

        let built = try await actor.prepareRelayTransfer(
            seeded.entry,
            bundleURL: seeded.bundleURL,
            attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
        )
        XCTAssertEqual(built.wholeFileReads.count, 3)
        XCTAssertEqual(built.wholeFileReads.byteCount, expectedBuildBytes)
        let buildEvent = try XCTUnwrap(sink.snapshot().events.last {
            $0.kind == .end && $0.boundary == .relayBundlePreparation
        })
        XCTAssertEqual(buildEvent.fields.result, .completed)
        XCTAssertEqual(buildEvent.fields.wholeFileReadCount, 3)
        XCTAssertEqual(buildEvent.fields.wholeFileReadByteCount, expectedBuildBytes)

        let receiptURL = WatchCaptureStoragePaths(rootURL: self.root).relayReceiptURL(
            directory: seeded.directory
        )
        let receiptBytes = try Data(contentsOf: receiptURL).count
        let catalog = await actor.scanCatalog(transactionClass: .maintenance)
        let entry = try XCTUnwrap(catalog.entries.first { $0.manifest.id == seeded.manifest.id })
        let reused = try await actor.prepareRelayTransfer(
            entry,
            bundleURL: seeded.bundleURL,
            attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
        )
        XCTAssertEqual(reused.wholeFileReads.count, 2)
        XCTAssertEqual(
            reused.wholeFileReads.byteCount,
            entry.witness.manifestData.count + receiptBytes
        )
        let reuseEvent = try XCTUnwrap(sink.snapshot().events.last {
            $0.kind == .end && $0.boundary == .relayBundlePreparation
        })
        XCTAssertEqual(reuseEvent.fields.result, .cached)
        XCTAssertEqual(reuseEvent.fields.wholeFileReadCount, 2)
    }

    func testReceiptPathDirectoryAndSymlinkHazardsDoNotMutate() async throws {
        let scratch = URL(fileURLWithPath: "/var/tmp")
            .appendingPathComponent("WatchCaptureReceiptHazard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let actor = WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: scratch),
            fileWriter: FoundationWatchFileWriter()
        )
        let seeded = try await self.seedTransferringSegment(actor: actor, root: scratch)
        _ = try await actor.prepareRelayTransfer(
            seeded.entry,
            bundleURL: seeded.bundleURL,
            attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
        )
        let receiptURL = WatchCaptureStoragePaths(rootURL: scratch).relayReceiptURL(directory: seeded.directory)
        let originalBundle = try Data(contentsOf: seeded.bundleURL)
        try FileManager.default.removeItem(at: receiptURL)

        let markerDir = scratch.appendingPathComponent("marker-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: markerDir, withIntermediateDirectories: true)
        let marker = markerDir.appendingPathComponent("marker.txt")
        try Data("keep".utf8).write(to: marker)

        try FileManager.default.createDirectory(at: receiptURL, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: receiptURL.appendingPathComponent("marker.txt"))
        let catalog = await actor.scanCatalog(transactionClass: .maintenance)
        let entry = try XCTUnwrap(catalog.entries.first)
        do {
            _ = try await actor.prepareRelayTransfer(
                entry,
                bundleURL: seeded.bundleURL,
                attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
            )
            XCTFail("directory-shaped receipt should throw")
        } catch let conflict as WatchCaptureStorageConflict {
            XCTAssertEqual(conflict, .relayReceiptUnexpectedShape(id: entry.id))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptURL.appendingPathComponent("marker.txt").path))
        XCTAssertEqual(try Data(contentsOf: seeded.bundleURL), originalBundle)

        try FileManager.default.removeItem(at: receiptURL)
        try FileManager.default.createSymbolicLink(at: receiptURL, withDestinationURL: marker)
        let linkedCatalog = await actor.scanCatalog(transactionClass: .maintenance)
        let linkedEntry = try XCTUnwrap(linkedCatalog.entries.first)
        do {
            _ = try await actor.prepareRelayTransfer(
                linkedEntry,
                bundleURL: seeded.bundleURL,
                attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
            )
            XCTFail("symlink receipt should throw")
        } catch let conflict as WatchCaptureStorageConflict {
            XCTAssertEqual(conflict, .relayReceiptUnexpectedShape(id: linkedEntry.id))
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: receiptURL.path), marker.path)
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf: seeded.bundleURL), originalBundle)

        try FileManager.default.removeItem(at: receiptURL)
        try FileManager.default.createSymbolicLink(at: receiptURL, withDestinationURL: markerDir)
        let dirLinkCatalog = await actor.scanCatalog(transactionClass: .maintenance)
        let dirLinkEntry = try XCTUnwrap(dirLinkCatalog.entries.first)
        do {
            _ = try await actor.prepareRelayTransfer(
                dirLinkEntry,
                bundleURL: seeded.bundleURL,
                attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
            )
            XCTFail("symlink-to-directory receipt should throw")
        } catch let conflict as WatchCaptureStorageConflict {
            XCTAssertEqual(conflict, .relayReceiptUnexpectedShape(id: dirLinkEntry.id))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try Data(contentsOf: seeded.bundleURL), originalBundle)
    }

    func testReceiptInvalidationFailureStopsBeforeBundleMutation() async throws {
        let writer = FailingWatchFileWriter(failAppend: false)
        let actor = WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: self.root),
            fileWriter: writer
        )
        let seeded = try await self.seedTransferringSegment(actor: actor)
        _ = try await actor.prepareRelayTransfer(
            seeded.entry,
            bundleURL: seeded.bundleURL,
            attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
        )
        let originalBundle = try Data(contentsOf: seeded.bundleURL)
        try Data("audio-changed-again".utf8).write(to: seeded.audioURL, options: .atomic)
        let receiptURL = WatchCaptureStoragePaths(rootURL: self.root).relayReceiptURL(directory: seeded.directory)
        writer.failRemoveItem(at: receiptURL)
        let catalog = await actor.scanCatalog(transactionClass: .maintenance)
        let entry = try XCTUnwrap(catalog.entries.first)
        do {
            _ = try await actor.prepareRelayTransfer(
                entry,
                bundleURL: seeded.bundleURL,
                attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
            )
            XCTFail("invalidation failure should stop preparation")
        } catch {
            XCTAssertEqual(try Data(contentsOf: seeded.bundleURL), originalBundle)
        }
    }

    func testReceiptWriteFailureStillReturnsRebuiltPreparation() async throws {
        let writer = FailingWatchFileWriter(failAppend: false)
        let actor = WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(rootURL: self.root),
            fileWriter: writer
        )
        let seeded = try await self.seedTransferringSegment(actor: actor)
        let receiptURL = WatchCaptureStoragePaths(rootURL: self.root).relayReceiptURL(directory: seeded.directory)
        writer.failNextWriteData(at: receiptURL)
        let preparation = try await actor.prepareRelayTransfer(
            seeded.entry,
            bundleURL: seeded.bundleURL,
            attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
        )
        XCTAssertEqual(preparation.disposition, .rebuilt)
        XCTAssertTrue(preparation.receiptPersistenceFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: seeded.bundleURL.path))
    }

    func testACKRemovesSourceReceiptAndBundle() async throws {
        let actor = self.actor()
        let seeded = try await self.seedTransferringSegment(actor: actor)
        _ = try await actor.prepareRelayTransfer(
            seeded.entry,
            bundleURL: seeded.bundleURL,
            attempt: self.attempt(id: seeded.manifest.id, attemptID: UUID())
        )
        let catalog = await actor.scanCatalog(transactionClass: .maintenance)
        let entry = try XCTUnwrap(catalog.entries.first)
        let acknowledged = try await actor.acknowledgeRelaySegment(entry)
        let safe = try await actor.markRelaySegmentSafeToDelete(acknowledged.entry)
        try await actor.deleteAcknowledgedRelaySegment(safe.entry, bundleURL: seeded.bundleURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: seeded.directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: seeded.bundleURL.path))
    }

    // Same-size replacement that also restores the prior modification instant is
    // unsupported: fingerprints compare byte count + mtime, not content, so that
    // substitution is not detected and may reuse the previous bundle.

    private func storage(named name: String) -> WatchCaptureStorageActor {
        WatchCaptureStorageActor(
            paths: WatchCaptureStoragePaths(
                rootURL: self.root.appendingPathComponent(name, isDirectory: true)
            ),
            fileWriter: FoundationWatchFileWriter()
        )
    }

    private func terminalRecord(
        id: String,
        startedAt: Date,
        reason: WatchCaptureTerminalReason?,
        disposition: WatchCaptureTerminalDisposition?,
        terminalAt: Date?,
        noticeOwed: Bool,
        state: WatchCaptureSessionRecordState = .terminal
    ) -> WatchCaptureSessionRecord {
        WatchCaptureSessionRecord(
            sessionID: id,
            startedAt: startedAt,
            state: state,
            terminalReason: reason,
            terminalDisposition: disposition,
            terminalAt: terminalAt,
            noticeOwed: noticeOwed
        )
    }

    private func terminalTuple(
        id: String,
        startedAt: Date,
        reason: WatchCaptureTerminalReason? = nil,
        disposition: WatchCaptureTerminalDisposition? = nil,
        terminalAt: Date? = nil,
        noticeOwed: Bool
    ) -> WatchCaptureTerminalTuple {
        WatchCaptureTerminalTuple(
            sessionID: id,
            startedAt: startedAt,
            reason: reason,
            disposition: disposition,
            terminalAt: terminalAt,
            noticeOwed: noticeOwed
        )
    }

    private func terminalHistoryEntry(
        id: String,
        startedAt: Date,
        reason: WatchCaptureTerminalReason?,
        disposition: WatchCaptureTerminalDisposition?,
        terminalAt: Date?,
        noticeOwed: Bool
    ) -> WatchCaptureSessionHistoryEntry {
        WatchCaptureSessionHistoryEntry(
            sessionID: id,
            startedAt: startedAt,
            terminalAt: terminalAt,
            terminalReason: reason,
            terminalDisposition: disposition,
            startRefusalReason: nil,
            settingsRoute: nil,
            noticeOwed: noticeOwed,
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

    private func writeRawHistory(
        _ entries: [WatchCaptureSessionHistoryEntry],
        malformedLine: Data?,
        to url: URL
    ) async throws {
        let encoder = WatchRelayDiagnosticsEnvelope.makeEncoder()
        var data = Data()
        for entry in entries {
            data.append(try encoder.encode(entry))
            data.append(0x0A)
        }
        if let malformedLine {
            data.append(malformedLine)
            data.append(0x0A)
        }
        try await FoundationWatchFileWriter().writeData(data, to: url, options: .atomic)
    }

    private func rawHistoryEntries(from data: Data) -> [WatchCaptureSessionHistoryEntry] {
        let decoder = WatchRelayDiagnosticsEnvelope.makeDecoder()
        return data
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { try? decoder.decode(WatchCaptureSessionHistoryEntry.self, from: Data($0)) }
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

    private struct SeededRelaySegment {
        let manifest: WatchSegmentManifest
        let entry: WatchCaptureCatalogEntry
        let directory: URL
        let bundleURL: URL
        let audioURL: URL
        let locationURL: URL
    }

    private func seedTransferringSegment(
        actor: WatchCaptureStorageActor,
        root: URL? = nil,
        id: UUID = UUID()
    ) async throws -> SeededRelaySegment {
        let rootURL = root ?? self.root!
        let paths = WatchCaptureStoragePaths(rootURL: rootURL)
        let segment = String(format: "%06d_300", abs(id.hashValue % 100_000))
        let manifest = self.manifest(id: id, segment: segment, state: .transferring)
        let directory = try await actor.prepareSegmentDirectory(day: manifest.day, segment: manifest.segment)
        let audioURL = paths.audioURL(directory: directory)
        let locationURL = paths.locationURL(directory: directory)
        try Data("audio-\(id.uuidString)".utf8).write(to: audioURL, options: .atomic)
        try Data("location-\(id.uuidString)".utf8).write(to: locationURL, options: .atomic)
        try await actor.writeManifest(manifest, ensuringDirectory: false, transactionClass: .captureSafety)
        let catalog = await actor.scanCatalog(transactionClass: .maintenance)
        let entry = try XCTUnwrap(catalog.entries.first { $0.manifest.id == id })
        let bundleURL = rootURL
            .appendingPathComponent(".relay-bundles", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).watchrelay", isDirectory: false)
        return SeededRelaySegment(
            manifest: manifest,
            entry: entry,
            directory: directory,
            bundleURL: bundleURL,
            audioURL: audioURL,
            locationURL: locationURL
        )
    }

    private func attempt(id: UUID, attemptID: UUID) -> WatchRelayAttemptRecord {
        WatchRelayAttemptRecord(
            segmentID: id,
            generation: 0,
            attemptID: attemptID,
            attemptStartedAt: Date(timeIntervalSince1970: 1_735_689_600)
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
        let fields: WatchSignpostFields
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

    func begin(
        _ boundary: WatchSignpostBoundary,
        fields: WatchSignpostFields
    ) -> WatchStorageSignpostInvocation {
        self.state.withLock { state in
            state.beginCallCount += 1
            state.openBoundaries.append(boundary)
            state.events.append(Event(
                kind: .begin,
                boundary: boundary,
                ordinal: state.beginCallCount,
                at: Date(),
                fields: fields
            ))
        }
        return WatchStorageSignpostInvocation(boundary: boundary, state: nil)
    }

    func end(
        _ invocation: WatchStorageSignpostInvocation,
        fields: WatchSignpostFields
    ) {
        self.state.withLock { state in
            precondition(state.openBoundaries.last == invocation.boundary)
            state.openBoundaries.removeLast()
            state.events.append(Event(
                kind: .end,
                boundary: invocation.boundary,
                ordinal: state.beginCallCount,
                at: Date(),
                fields: fields
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

private actor RelayPreparationFaultWriter: WatchFileWriting {
    private let base = FoundationWatchFileWriter()
    private var stripAllDates = false
    private var strippedDatePaths: Set<String> = []
    private var itemKindOverrides: [String: WatchCaptureStorageItemKind] = [:]
    private var itemKindFailures: Set<String> = []
    private var readFailures: Set<String> = []
    private var mutation: (sourceURL: URL, bundleURL: URL, data: Data)?
    private var fingerprintMutation: (sourceURL: URL, fingerprintURL: URL, data: Data)?
    private var writeCounts: [String: Int] = [:]

    func stripAllModificationDates() {
        self.stripAllDates = true
    }

    func stripModificationDate(at url: URL) {
        self.strippedDatePaths.insert(url.path)
    }

    func overrideItemKind(_ kind: WatchCaptureStorageItemKind, at url: URL) {
        self.itemKindOverrides[url.path] = kind
    }

    func clearItemKindOverride(at url: URL) {
        self.itemKindOverrides.removeValue(forKey: url.path)
    }

    func failItemKind(at url: URL) {
        self.itemKindFailures.insert(url.path)
    }

    func failRead(at url: URL) {
        self.readFailures.insert(url.path)
    }

    func mutate(_ sourceURL: URL, afterWriting bundleURL: URL, data: Data) {
        self.mutation = (sourceURL, bundleURL, data)
    }

    func mutate(_ sourceURL: URL, whileFingerprinting fingerprintURL: URL, data: Data) {
        self.fingerprintMutation = (sourceURL, fingerprintURL, data)
    }

    func resetWriteCount(at url: URL) {
        self.writeCounts[url.path] = 0
    }

    func writeCount(at url: URL) -> Int {
        self.writeCounts[url.path, default: 0]
    }

    func createDirectory(at url: URL) async throws { try await self.base.createDirectory(at: url) }
    func createFileIfNeeded(at url: URL) async throws { try await self.base.createFileIfNeeded(at: url) }
    func fileExists(at url: URL) async -> Bool { await self.base.fileExists(at: url) }

    func itemKind(at url: URL) async throws -> WatchCaptureStorageItemKind {
        if self.itemKindFailures.contains(url.path) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        if let override = self.itemKindOverrides[url.path] {
            return override
        }
        return try await self.base.itemKind(at: url)
    }

    func fileSize(at url: URL) async throws -> Int64 { try await self.base.fileSize(at: url) }

    func fileFingerprint(at url: URL) async throws -> WatchCaptureStorageFileFingerprint? {
        guard let fingerprint = try await self.base.fileFingerprint(at: url) else { return nil }
        if let mutation = self.fingerprintMutation, mutation.fingerprintURL == url {
            self.fingerprintMutation = nil
            try await self.base.writeData(mutation.data, to: mutation.sourceURL, options: .atomic)
        }
        guard self.stripAllDates || self.strippedDatePaths.contains(url.path) else {
            return fingerprint
        }
        return WatchCaptureStorageFileFingerprint(
            byteCount: fingerprint.byteCount,
            modificationDate: nil
        )
    }

    func readData(from url: URL) async throws -> Data {
        if self.readFailures.contains(url.path) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        return try await self.base.readData(from: url)
    }

    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) async throws {
        try await self.base.writeData(data, to: url, options: options)
        self.writeCounts[url.path, default: 0] += 1
        if let mutation = self.mutation, mutation.bundleURL == url {
            self.mutation = nil
            try await self.base.writeData(mutation.data, to: mutation.sourceURL, options: .atomic)
        }
    }

    func appendLine(_ line: Data, to url: URL) async throws {
        try await self.base.appendLine(line, to: url)
    }

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
    private var operationToBlock: String? = "createDirectory"
    private var operationLog: [String] = []
    private var failingReadURLs: Set<URL> = []

    func createDirectory(at url: URL) async throws {
        await self.enter("createDirectory")
        defer { self.active -= 1 }
        try await self.base.createDirectory(at: url)
    }

    func itemKind(at url: URL) async throws -> WatchCaptureStorageItemKind {
        await self.enter("itemKind")
        defer { self.active -= 1 }
        return try await self.base.itemKind(at: url)
    }

    func readData(from url: URL) async throws -> Data {
        if self.failingReadURLs.contains(url) {
            throw CocoaError(.fileReadUnknown)
        }
        return try await self.base.readData(from: url)
    }

    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) async throws {
        await self.enter("writeData:\(url.lastPathComponent)")
        defer { self.active -= 1 }
        try await self.base.writeData(data, to: url, options: options)
    }

    private func enter(_ operation: String) async {
        self.active += 1
        self.maximum = max(self.maximum, self.active)
        self.entered += 1
        self.operationLog.append(operation)
        let waiters = self.enteredWaiters
        self.enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if self.operationToBlock == operation {
            self.operationToBlock = nil
            await withCheckedContinuation { self.releaseWaiters.append($0) }
        }
    }

    func fileExists(at url: URL) async -> Bool { await self.base.fileExists(at: url) }
    func createFileIfNeeded(at url: URL) async throws { try await self.base.createFileIfNeeded(at: url) }
    func fileSize(at url: URL) async throws -> Int64 { try await self.base.fileSize(at: url) }
    func fileFingerprint(at url: URL) async throws -> WatchCaptureStorageFileFingerprint? {
        try await self.base.fileFingerprint(at: url)
    }
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
    func holdNextOperation(_ operation: String) { self.operationToBlock = operation }
    func operations() -> [String] { self.operationLog }
    func failReads(at url: URL) { self.failingReadURLs.insert(url) }
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
