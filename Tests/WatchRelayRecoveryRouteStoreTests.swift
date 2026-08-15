// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class WatchRelayRecoveryRouteStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchRelayRecoveryRouteStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    func testIndependentRouteGenerationsSurviveRelaunchAndFailuresDoNotAdvance() throws {
        let storage = try WatchCaptureStorage(rootURL: self.tempDirectory)
        let store = WatchRelayRecoveryRouteStore(storage: storage)

        let initial = try XCTUnwrap(store.establishRecord())
        XCTAssertEqual(initial.successfulTransferGeneration, 0)
        XCTAssertEqual(initial.durableACKGeneration, 0)
        XCTAssertTrue(store.recordSuccessfulTransfer())
        XCTAssertTrue(store.recordDurableACK())

        let relaunched = WatchRelayRecoveryRouteStore(storage: storage)
        let firstRelaunch = try XCTUnwrap(relaunched.establishRecord())
        XCTAssertEqual(firstRelaunch.eraID, initial.eraID)
        XCTAssertEqual(firstRelaunch.successfulTransferGeneration, 1)
        XCTAssertEqual(firstRelaunch.durableACKGeneration, 1)
        XCTAssertTrue(relaunched.recordSuccessfulTransfer())

        let secondRelaunch = try XCTUnwrap(WatchRelayRecoveryRouteStore(storage: storage).establishRecord())
        XCTAssertEqual(secondRelaunch.eraID, initial.eraID)
        XCTAssertEqual(secondRelaunch.successfulTransferGeneration, 2)
        XCTAssertEqual(secondRelaunch.durableACKGeneration, 1)
    }

    func testInvalidAndExhaustedRecordsEstablishFreshZeroEra() throws {
        let storage = try WatchCaptureStorage(rootURL: self.tempDirectory)
        let store = WatchRelayRecoveryRouteStore(storage: storage)
        let oldEra = UUID()
        let cases = [
            Data("not-json".utf8),
            Data("{\"version\":2,\"eraID\":\"\(oldEra.uuidString)\",\"successfulTransferGeneration\":1,\"durableACKGeneration\":1}".utf8),
            Data("{\"version\":1,\"eraID\":\"\(oldEra.uuidString)\",\"successfulTransferGeneration\":-1,\"durableACKGeneration\":1}".utf8),
            Data("{\"version\":1,\"eraID\":\"\(oldEra.uuidString)\",\"successfulTransferGeneration\":\(Int.max),\"durableACKGeneration\":1}".utf8),
        ]

        for data in cases {
            try storage.fileWriter.writeData(data, to: store.recordURL(), options: .atomic)
            let record = try XCTUnwrap(store.establishRecord())
            XCTAssertNotEqual(record.eraID, oldEra)
            XCTAssertEqual(record.successfulTransferGeneration, 0)
            XCTAssertEqual(record.durableACKGeneration, 0)
        }
    }

    func testEventOnInvalidRecordStartsNewEraWithOnlyThatGeneration() throws {
        let storage = try WatchCaptureStorage(rootURL: self.tempDirectory)
        let store = WatchRelayRecoveryRouteStore(storage: storage)
        try storage.fileWriter.writeData(Data("truncated".utf8), to: store.recordURL(), options: .atomic)

        XCTAssertTrue(store.recordDurableACK())

        let record = try XCTUnwrap(WatchRelayRecoveryRouteStore(storage: storage).establishRecord())
        XCTAssertEqual(record.successfulTransferGeneration, 0)
        XCTAssertEqual(record.durableACKGeneration, 1)
    }

    func testFailedReplacementPreservesCommittedBytesAndNextEventUsesCommittedState() throws {
        let writer = FailingWatchFileWriter(failAppend: false)
        let storage = try WatchCaptureStorage(rootURL: self.tempDirectory, fileWriter: writer)
        let store = WatchRelayRecoveryRouteStore(storage: storage)
        XCTAssertNotNil(store.establishRecord())
        XCTAssertTrue(store.recordSuccessfulTransfer())
        let url = store.recordURL()
        let committed = try writer.readData(from: url)
        writer.failNextWriteData(at: url)

        XCTAssertFalse(store.recordDurableACK())
        XCTAssertEqual(try writer.readData(from: url), committed)

        let relaunched = WatchRelayRecoveryRouteStore(storage: storage)
        let afterFailure = try XCTUnwrap(relaunched.establishRecord())
        XCTAssertEqual(afterFailure.successfulTransferGeneration, 1)
        XCTAssertEqual(afterFailure.durableACKGeneration, 0)
        XCTAssertTrue(relaunched.recordDurableACK())
        let afterRecovery = try XCTUnwrap(WatchRelayRecoveryRouteStore(storage: storage).establishRecord())
        XCTAssertEqual(afterRecovery.successfulTransferGeneration, 1)
        XCTAssertEqual(afterRecovery.durableACKGeneration, 1)
    }

    func testAttemptTimestampDecodesLiteralIdentityCommitBytesAndRoundTripsSubseconds() throws {
        let legacy = Data(#"{"attemptID":"00000000-0000-0000-0000-000000000002","attemptStartedAt":"2033-05-18T03:33:20Z","generation":0,"segmentID":"00000000-0000-0000-0000-000000000001","version":1}"#.utf8)
        let legacyRecord = try WatchRelayAttemptRecord.makeDecoder().decode(WatchRelayAttemptRecord.self, from: legacy)
        XCTAssertEqual(legacyRecord.attemptStartedAt, Date(timeIntervalSince1970: 2_000_000_000))

        let startedAt = Date(timeIntervalSince1970: 2_000_000_000.125)
        let record = WatchRelayAttemptRecord(
            segmentID: UUID(),
            generation: 0,
            attemptID: UUID(),
            attemptStartedAt: startedAt
        )
        let encoded = try WatchRelayAttemptRecord.makeEncoder().encode(record)
        XCTAssertEqual(
            try WatchRelayAttemptRecord.makeDecoder().decode(WatchRelayAttemptRecord.self, from: encoded),
            record
        )
    }

    func testAttemptMetadataParsesIdentityCommitStringAndNewSubseconds() throws {
        let id = UUID()
        let old = LiveWatchConnectivitySession.fileTransferCompletion(
            metadata: ["id": id.uuidString, "attempt_started_at": "2033-05-18T03:33:20Z"],
            fileURL: URL(fileURLWithPath: "/mock/old.watchrelay"),
            error: nil
        )
        XCTAssertEqual(old.attemptStartedAt, Date(timeIntervalSince1970: 2_000_000_000))

        let startedAt = Date(timeIntervalSince1970: 2_000_000_000.125)
        let new = LiveWatchConnectivitySession.fileTransferCompletion(
            metadata: ["id": id.uuidString, "attempt_started_at": startedAt.timeIntervalSince1970],
            fileURL: URL(fileURLWithPath: "/mock/new.watchrelay"),
            error: nil
        )
        XCTAssertEqual(new.attemptStartedAt, startedAt)
    }
}
