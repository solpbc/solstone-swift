// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class WatchCaptureSessionHistoryStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        self.root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.root)
    }

    func testRingPrunesToFortyAndPreservesCounterEpoch() async throws {
        let storage = try WatchCaptureTestStorage(rootURL: self.root)
        let store = self.storageActor(for: storage)
        let now = Date(timeIntervalSince1970: 1_784_073_600)
        for index in 0..<41 {
            try await store.upsertSessionHistory(
                self.entry(index, at: now.addingTimeInterval(TimeInterval(index))),
                asOf: now.addingTimeInterval(41),
                transactionClass: .captureSafety
            )
        }
        guard case let .available(entries) = await store.readSessionHistory(asOf: now.addingTimeInterval(41)) else {
            return XCTFail("history should be readable")
        }
        XCTAssertEqual(entries.count, 40)
        XCTAssertEqual(Set(entries.map(\.sessionID)), Set((1...40).map { "session-\($0)" }))
        try await store.upsertSessionHistory(
            self.entry(99, at: now.addingTimeInterval(-8 * 24 * 60 * 60)),
            asOf: now,
            transactionClass: .captureSafety
        )
        guard case let .available(retained) = await store.readSessionHistory(asOf: now) else { return XCTFail("history should be readable") }
        XCTAssertFalse(retained.contains { $0.sessionID == "session-99" })
        XCTAssertTrue(retained.contains { $0.sessionID == "session-40" })
        let firstCounter = try await store.incrementLifetimeSessionCounter()
        let first = try XCTUnwrap(firstCounter)
        let secondCounter = try await store.incrementLifetimeSessionCounter()
        let second = try XCTUnwrap(secondCounter)
        XCTAssertEqual(second.lifetimeSessionsStarted, 2)
        XCTAssertEqual(first.epoch, second.epoch)
        try await storage.fileWriter.removeItem(at: storage.rootURL.appendingPathComponent(WatchCaptureStorageActor.counterFileName))
        let recreatedCounter = try await store.incrementLifetimeSessionCounter()
        let recreated = try XCTUnwrap(recreatedCounter)
        XCTAssertEqual(recreated.lifetimeSessionsStarted, 1)
        XCTAssertNotEqual(recreated.epoch, second.epoch)
    }

    func testDamagedTailKeepsRecoverableEntriesAndReportsUnreadableWhenNoneRecover() async throws {
        let storage = try WatchCaptureTestStorage(rootURL: self.root)
        let store = self.storageActor(for: storage)
        let now = Date()
        try await store.upsertSessionHistory(
            self.entry(1, at: now),
            asOf: now,
            transactionClass: .captureSafety
        )
        let url = storage.rootURL.appendingPathComponent(WatchCaptureStorageActor.historyFileName)
        var data = try await storage.fileWriter.readData(from: url)
        data.append(Data("bad tail\n".utf8))
        try await storage.fileWriter.atomicReplaceFile(at: url, with: data)
        guard case let .available(entries) = await store.readSessionHistory(asOf: now) else { return XCTFail("recoverable entry lost") }
        XCTAssertEqual(entries.map(\.sessionID), ["session-1"])
        try await storage.fileWriter.atomicReplaceFile(at: url, with: Data("bad tail\n".utf8))
        let unreadable = await store.readSessionHistory(asOf: now)
        XCTAssertEqual(unreadable, .unreadable)
    }

    func testReadPrunesExpiredEntriesFromFileWithoutSubsequentUpsert() async throws {
        let storage = try WatchCaptureTestStorage(rootURL: self.root)
        let store = self.storageActor(for: storage)
        let now = Date(timeIntervalSince1970: 1_784_073_600)
        let expired = self.entry(1, at: now.addingTimeInterval(-8 * 24 * 60 * 60))
        let fresh = self.entry(2, at: now)
        let encoder = WatchRelayDiagnosticsEnvelope.makeEncoder()
        let data = try encoder.encode(expired) + Data([0x0A]) + encoder.encode(fresh) + Data([0x0A])
        let url = storage.rootURL.appendingPathComponent(WatchCaptureStorageActor.historyFileName)
        try await storage.fileWriter.atomicReplaceFile(at: url, with: data)

        let pruned = await store.readSessionHistory(asOf: now)
        XCTAssertEqual(pruned, .available([fresh]))

        let remaining = String(decoding: try await storage.fileWriter.readData(from: url), as: UTF8.self)
        XCTAssertFalse(remaining.contains(expired.sessionID))
        XCTAssertTrue(remaining.contains(fresh.sessionID))
    }

    func testSessionRecordRoundTripsThroughStorageActor() async throws {
        let storage = try WatchCaptureTestStorage(rootURL: self.root)
        let actor = self.storageActor(for: storage)
        let record = WatchCaptureSessionRecord(
            sessionID: "session-record",
            startedAt: Date(timeIntervalSince1970: 1_784_073_600),
            state: .terminal,
            terminalReason: .ownerStopped,
            terminalDisposition: .ownerStopped,
            terminalAt: Date(timeIntervalSince1970: 1_784_073_900),
            noticeOwed: false,
            segmentsProduced: 3
        )

        let missing = try await actor.readSessionRecord(transactionClass: .captureSafety)
        XCTAssertNil(missing)
        try await actor.writeSessionRecord(record, transactionClass: .captureSafety)
        let restored = try await actor.readSessionRecord(transactionClass: .captureSafety)
        XCTAssertEqual(restored, record)
    }

    func testHistoryEntryCodingUsesCompactKeys() throws {
        let data = try WatchRelayDiagnosticsEnvelope.makeEncoder().encode(self.entry(1, at: Date()))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"id\""))
        XCTAssertFalse(json.contains("sessionID"))
    }

    private func entry(_ index: Int, at date: Date) -> WatchCaptureSessionHistoryEntry {
        WatchCaptureSessionHistoryEntry(
            sessionID: "session-\(index)", startedAt: date, terminalAt: date,
            terminalReason: .audioClockStalled, terminalDisposition: .detectedStoppedItself,
            startRefusalReason: nil, settingsRoute: nil, noticeOwed: false, noticeDecision: "schedule",
            noticeDelivered: true, notificationAuthorizationStatus: .authorized, notificationAlertSetting: .enabled,
            wristAlertAssurance: .willTap, audioArmed: true, audioSessionIsActive: true, locationArmed: false,
            segmentsProduced: 1, batteryLevelAtEnd: 0.75, batteryStateAtEnd: "unplugged",
            lowPowerModeEnabledAtEnd: false, thermalStateAtEnd: "nominal", lastVerifiedAudioAt: date,
            lastAudioCurrentTime: 1.23456789, zeroAudioCurrentTimeObservationCount: 3,
            locationAdvisory: nil, persistenceAdvisory: nil
        )
    }

    private func storageActor(for storage: WatchCaptureTestStorage) -> WatchCaptureStorageActor {
        WatchCaptureStorageActor(
            paths: storage.paths,
            fileWriter: storage.fileWriter
        )
    }
}
