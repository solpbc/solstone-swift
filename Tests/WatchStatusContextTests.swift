// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class WatchStatusContextTests: XCTestCase {
    func testApplicationContextRoundTripsThroughJSONData() throws {
        let context = WatchStatusContext(
            phase: .observing,
            sessionID: "session-1",
            startedAt: Date(timeIntervalSince1970: 1_000),
            asOf: Date(timeIntervalSince1970: 1_015),
            seq: 7,
            queuedCount: 2,
            transferringCount: 1,
            audioTerminalReason: .audioInterrupted,
            audioTerminalDisposition: .detectedStoppedItself
        )

        let applicationContext = context.applicationContext()

        XCTAssertTrue(applicationContext[WatchStatusContext.applicationContextKey] is Data)
        XCTAssertEqual(WatchStatusContext(applicationContext: applicationContext), context)
    }

    func testOldShapeApplicationContextDefaultsCountsToZero() throws {
        let applicationContext = [
            WatchStatusContext.applicationContextKey: try Self.encode(
                LegacyContext(
                    phase: .observing,
                    sessionID: "session-1",
                    startedAt: Date(timeIntervalSince1970: 1_000),
                    asOf: Date(timeIntervalSince1970: 1_015),
                    seq: 7
                )
            ),
        ]

        let decoded = try XCTUnwrap(WatchStatusContext(applicationContext: applicationContext))

        XCTAssertEqual(decoded.queuedCount, 0)
        XCTAssertEqual(decoded.transferringCount, 0)
        XCTAssertNil(decoded.audioTerminalReason)
        XCTAssertNil(decoded.audioTerminalDisposition)
    }

    func testNegativeDecodedCountsClampToZero() throws {
        let applicationContext = [
            WatchStatusContext.applicationContextKey: try Self.encode(
                WireContext(
                    phase: .observing,
                    sessionID: "session-1",
                    startedAt: Date(timeIntervalSince1970: 1_000),
                    asOf: Date(timeIntervalSince1970: 1_015),
                    seq: 7,
                    queuedCount: -2,
                    transferringCount: -1
                )
            ),
        ]

        let decoded = try XCTUnwrap(WatchStatusContext(applicationContext: applicationContext))

        XCTAssertEqual(decoded.queuedCount, 0)
        XCTAssertEqual(decoded.transferringCount, 0)
    }

    func testFrozenLegacyStatusPayloadDecodesTerminalUnknown() throws {
        let payload = try Self.encode(
            LegacyContext(
                phase: .idle,
                sessionID: "legacy-session",
                startedAt: Date(timeIntervalSince1970: 1_000),
                asOf: Date(timeIntervalSince1970: 1_015),
                seq: 7
            )
        )

        let decoded = try XCTUnwrap(WatchStatusContext(applicationContext: [
            WatchStatusContext.applicationContextKey: payload,
        ]))

        XCTAssertEqual(decoded.phase, .idle)
        XCTAssertNil(decoded.audioTerminalReason)
        XCTAssertNil(decoded.audioTerminalDisposition)
        XCTAssertEqual(
            Set(["idle", "observing", "stopping"]),
            Set([
                WatchStatusContext.Phase.idle.rawValue,
                WatchStatusContext.Phase.observing.rawValue,
                WatchStatusContext.Phase.stopping.rawValue,
            ])
        )
    }

    func testMissingContextReturnsNil() {
        XCTAssertNil(WatchStatusContext(applicationContext: [:]))
    }

    func testNonDataContextReturnsNil() {
        XCTAssertNil(WatchStatusContext(applicationContext: [
            WatchStatusContext.applicationContextKey: "not data",
        ]))
    }

    func testGarbageDataReturnsNil() {
        XCTAssertNil(WatchStatusContext(applicationContext: [
            WatchStatusContext.applicationContextKey: Data("garbage".utf8),
        ]))
    }
}

private extension WatchStatusContextTests {
    struct LegacyContext: Encodable {
        let phase: WatchStatusContext.Phase
        let sessionID: String?
        let startedAt: Date?
        let asOf: Date
        let seq: Int
    }

    struct WireContext: Encodable {
        let phase: WatchStatusContext.Phase
        let sessionID: String?
        let startedAt: Date?
        let asOf: Date
        let seq: Int
        let queuedCount: Int
        let transferringCount: Int
    }

    static func encode(_ context: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(context)
    }
}
