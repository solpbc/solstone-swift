// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class OmiSegmentMetadataTests: XCTestCase {
    func testNamespaceRoundTripUsesClosedWireShape() throws {
        let processID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        let start = Date(timeIntervalSince1970: 1_713_624_000)
        let metadata = OmiSegmentMetadata(
            connectionState: "reconnecting",
            processID: processID,
            processStartedAt: start,
            pendantBatteryLevel: 78,
            pendantBatteryAt: start,
            phoneBatteryLevel: 0.42,
            phoneBatteryAt: start,
            phoneBatteryState: "unplugged",
            phoneThermalState: "nominal",
            firmware: "1.2.3",
            connectToFirstAudioSeconds: 1.25,
            reconnectCount: 4,
            reconnectEvents: [OmiSegmentMetadata.ReconnectEvent(
                processID: processID,
                sequence: 3,
                revision: 2,
                disconnectedAt: start,
                appState: "foreground",
                latencySeconds: 5
            )],
            subscribeEvents: [OmiSegmentMetadata.SubscribeEvent(
                processID: processID,
                sequence: 4,
                revision: 2,
                connectedAt: start,
                subscribedAt: start.addingTimeInterval(1),
                latencySeconds: 1.25,
                appState: "foreground"
            )]
        )

        let meta = OmiSegmentMetadata.attaching(metadata, to: .object(["source": .string("omi")]))
        let roundTripped = try XCTUnwrap(OmiSegmentMetadata.from(meta: meta))

        XCTAssertEqual(roundTripped, metadata)
        guard case .object(let root) = meta,
              case .object(let omi)? = root[OmiSegmentMetadata.key]
        else {
            return XCTFail("missing omi namespace")
        }
        XCTAssertEqual(root["source"], .string("omi"))
        XCTAssertEqual(omi["connection_state"], .string("reconnecting"))
        XCTAssertEqual(omi["process_id"], .string(processID.uuidString))
        XCTAssertEqual(omi["reconnect_events"], .array([.object([
            "process_id": .string(processID.uuidString),
            "sequence": .int(3),
            "revision": .int(2),
            "disconnected_at": .string(ISO8601DateFormatter().string(from: start)),
            "app_state": .string("foreground"),
                    "latency_s": .int(5),
            "reconnected_at": .string(ISO8601DateFormatter().string(from: start.addingTimeInterval(5))),
        ])]))
    }

    func testOmissionFiltersBadOptionalValuesWithoutRemovingOtherFields() {
        let metadata = OmiSegmentMetadata(
            connectionState: "connected",
            phoneBatteryLevel: .nan,
            phoneBatteryState: "",
            firmware: "",
            connectToFirstAudioSeconds: .infinity,
            reconnectEvents: [],
            subscribeEvents: []
        )
        let meta = OmiSegmentMetadata.attaching(metadata, to: .object([:]))

        guard case .object(let root) = meta,
              case .object(let omi)? = root[OmiSegmentMetadata.key]
        else {
            return XCTFail("missing omi namespace")
        }
        XCTAssertEqual(omi["connection_state"], .string("connected"))
        XCTAssertNil(omi["phone_battery_level"])
        XCTAssertNil(omi["phone_battery_state"])
        XCTAssertNil(omi["firmware"])
        XCTAssertNil(omi["connect_to_first_audio_s"])
        XCTAssertNil(omi["reconnect_events"])
        XCTAssertNil(omi["subscribe_events"])
    }

    func testConnectionStateMappingUsesClosedWireValues() {
        XCTAssertEqual(OmiSourceLogic.segmentConnectionState(.connected), "connected")
        XCTAssertEqual(OmiSourceLogic.segmentConnectionState(.connecting), "reconnecting")
        XCTAssertEqual(OmiSourceLogic.segmentConnectionState(.reconnecting), "reconnecting")
        XCTAssertEqual(OmiSourceLogic.segmentConnectionState(.disconnected), "disconnected")
        XCTAssertEqual(
            OmiSourceLogic.segmentConnectionState(.needsAttention(.connectFailed("owner text"))),
            "disconnected"
        )
    }

    func testWireDataExcludesReconnectReason() throws {
        let processID = UUID()
        let metadata = OmiSegmentMetadata(
            connectionState: "disconnected",
            reconnectEvents: [OmiSegmentMetadata.ReconnectEvent(
                processID: processID,
                sequence: 9,
                revision: 1,
                disconnectedAt: Date(timeIntervalSince1970: 1_713_624_000),
                appState: "locked",
                latencySeconds: nil
            )]
        )
        let encoded = try JSONEncoder().encode(OmiSegmentMetadata.attaching(metadata, to: .object([:])))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("owner-only-reason"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("reason"))
    }
}
