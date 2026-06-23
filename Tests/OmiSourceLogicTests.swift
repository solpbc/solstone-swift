// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
@preconcurrency import CoreBluetooth
import Foundation
import XCTest

nonisolated final class OmiSourceLogicTests: XCTestCase {
    func testReconnectDecisionManualDisconnectStaysDisconnected() {
        XCTAssertEqual(
            OmiSourceLogic.reconnectDecision(isManualDisconnect: true, isReconnecting: false),
            .stayDisconnected
        )
        XCTAssertEqual(
            OmiSourceLogic.reconnectDecision(isManualDisconnect: true, isReconnecting: true),
            .stayDisconnected
        )
    }

    func testReconnectDecisionUnexpectedDropRearmsConnect() {
        XCTAssertEqual(
            OmiSourceLogic.reconnectDecision(isManualDisconnect: false, isReconnecting: false),
            .rearmConnect
        )
    }

    func testReconnectDecisionSystemReconnectWaitsForIOS() {
        XCTAssertEqual(
            OmiSourceLogic.reconnectDecision(isManualDisconnect: false, isReconnecting: true),
            .systemReconnecting
        )
    }

    func testAttentionMapsDeadEndManagerStates() {
        XCTAssertEqual(OmiSourceLogic.attention(for: .poweredOff), .bluetoothOff)
        XCTAssertEqual(OmiSourceLogic.attention(for: .unauthorized), .unauthorized)
        XCTAssertEqual(OmiSourceLogic.attention(for: .unsupported), .unsupported)
    }

    func testAttentionIgnoresReadyAndTransientManagerStates() {
        XCTAssertNil(OmiSourceLogic.attention(for: .poweredOn))
        XCTAssertNil(OmiSourceLogic.attention(for: .unknown))
        XCTAssertNil(OmiSourceLogic.attention(for: .resetting))
    }

    func testUptimeAccumulatorCountsClosedAndOpenSegments() {
        let start = Date(timeIntervalSince1970: 100)
        let firstDisconnect = start.addingTimeInterval(12)
        let secondConnect = start.addingTimeInterval(20)
        let now = start.addingTimeInterval(35)

        var uptime = OmiUptimeAccumulator()
        uptime.noteConnected(at: start)
        uptime.noteDisconnected(at: firstDisconnect)
        uptime.noteConnected(at: secondConnect)

        XCTAssertEqual(uptime.connectedSeconds(asOf: now), 27, accuracy: 0.001)
    }

    func testUptimeAccumulatorDoubleConnectAndDisconnectAreIdempotent() {
        let start = Date(timeIntervalSince1970: 200)
        var uptime = OmiUptimeAccumulator()

        uptime.noteConnected(at: start)
        uptime.noteConnected(at: start.addingTimeInterval(5))
        uptime.noteDisconnected(at: start.addingTimeInterval(10))
        uptime.noteDisconnected(at: start.addingTimeInterval(20))

        XCTAssertEqual(uptime.connectedSeconds(asOf: start.addingTimeInterval(30)), 10, accuracy: 0.001)
    }

    func testUptimeAccumulatorConnectedFractionUsesWallClock() throws {
        let start = Date(timeIntervalSince1970: 300)
        var uptime = OmiUptimeAccumulator()

        uptime.noteConnected(at: start.addingTimeInterval(10))
        uptime.noteDisconnected(at: start.addingTimeInterval(40))

        XCTAssertEqual(
            try XCTUnwrap(uptime.connectedFraction(since: start, asOf: start.addingTimeInterval(60))),
            0.5,
            accuracy: 0.001
        )
        XCTAssertNil(uptime.connectedFraction(since: start, asOf: start))
        XCTAssertNil(uptime.connectedFraction(since: start, asOf: start.addingTimeInterval(-1)))
    }

    func testEventRingDropsOldestPastCapacity() {
        var ring = OmiEventRing()

        for index in 0...OmiEventRing.capacity {
            ring.append(Self.event(index))
        }

        XCTAssertEqual(ring.events.count, OmiEventRing.capacity)
        XCTAssertEqual(ring.events.first?.reason, "drop 1")
        XCTAssertEqual(ring.events.last?.reason, "drop 50")
    }

    func testEventRingBackfillsMostRecentUnresolvedReconnect() {
        var ring = OmiEventRing()
        ring.append(Self.event(0))
        ring.append(OmiSourceEvent(
            timestamp: Date(timeIntervalSince1970: 1),
            reason: "resolved",
            appStateAtDrop: "foreground",
            timeToReconnect: 1.25
        ))
        ring.append(Self.event(2))

        ring.backfillMostRecentReconnect(timeToReconnect: 3.5)

        XCTAssertNil(ring.events[0].timeToReconnect)
        XCTAssertEqual(ring.events[1].timeToReconnect, 1.25)
        XCTAssertEqual(ring.events[2].timeToReconnect, 3.5)
    }

    func testEventRingBackfillNoOpsWhenNoUnresolvedEventExists() {
        var ring = OmiEventRing()
        ring.append(OmiSourceEvent(
            timestamp: Date(timeIntervalSince1970: 1),
            reason: "resolved",
            appStateAtDrop: "foreground",
            timeToReconnect: 1.25
        ))

        ring.backfillMostRecentReconnect(timeToReconnect: 3.5)

        XCTAssertEqual(ring.events.first?.timeToReconnect, 1.25)
    }

    func testEmitDecodedFramesCallsSinkForSuccessfulFrames() {
        let frames = [Data([0]), Data([1]), Data([2])]
        var batches: [[Int16]] = []

        let result = OmiSourceLogic.emitDecodedFrames(frames, decode: { frame in
            frame.first == 1 ? nil : [Int16(frame.first ?? 0)]
        }, sink: { samples in
            batches.append(samples)
        })

        XCTAssertEqual(result.decodeOK, 2)
        XCTAssertEqual(result.decodeErrors, 1)
        XCTAssertEqual(batches, [[0], [2]])
    }

    func testEmitDecodedFramesWithNilSinkStillCounts() {
        let result = OmiSourceLogic.emitDecodedFrames([Data([0]), Data([1])], decode: { frame in
            [Int16(frame.first ?? 0)]
        }, sink: nil)

        XCTAssertEqual(result.decodeOK, 2)
        XCTAssertEqual(result.decodeErrors, 0)
    }

    func testEmitDecodedFramesAllFailDoesNotCallSink() {
        var sinkCalls = 0

        let result = OmiSourceLogic.emitDecodedFrames([Data([0]), Data([1])], decode: { _ in
            nil
        }, sink: { _ in
            sinkCalls += 1
        })

        XCTAssertEqual(result.decodeOK, 0)
        XCTAssertEqual(result.decodeErrors, 2)
        XCTAssertEqual(sinkCalls, 0)
    }

    func testAudioCounterSnapshotCopiesReassemblerAndDecodeCounts() {
        var reassembler = BLEAudioReassembler()
        _ = reassembler.ingest(Self.packet(0, index: 0, payload: Data("lost".utf8)))
        _ = reassembler.ingest(Self.packet(2, index: 0, payload: Data("fresh".utf8)))
        _ = reassembler.ingest(Self.packet(3, index: 0, payload: Data("next".utf8)))

        let snapshot = OmiSourceLogic.audioCounterSnapshot(
            reassembler: reassembler,
            decodeOK: 4,
            decodeErrors: 2
        )

        XCTAssertEqual(snapshot.packets, 3)
        XCTAssertEqual(snapshot.frames, 1)
        XCTAssertEqual(snapshot.gaps, 1)
        XCTAssertEqual(snapshot.outOfOrder, 0)
        XCTAssertEqual(snapshot.malformed, 0)
        XCTAssertEqual(snapshot.markers, 0)
        XCTAssertEqual(snapshot.decodeOK, 4)
        XCTAssertEqual(snapshot.decodeErrors, 2)
    }

    func testPersistedPeripheralIDRoundTrip() throws {
        let id = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000123"))
        let storedValue = OmiSourceLogic.storedPeripheralIDValue(for: id)

        XCTAssertEqual(OmiSourceLogic.persistedPeripheralID(from: storedValue), id)
    }

    func testPersistedPeripheralIDRejectsInvalidAndNilStrings() {
        XCTAssertNil(OmiSourceLogic.persistedPeripheralID(from: nil))
        XCTAssertNil(OmiSourceLogic.persistedPeripheralID(from: "not-a-uuid"))
    }

    func testSurfacedBatteryPrefersLiveThenLastKnownThenFallback() {
        let timestamp = Date(timeIntervalSince1970: 600)
        let lastKnown = TimedReading(value: 72, at: timestamp)

        XCTAssertEqual(
            OmiSourceLogic.surfacedBattery(live: .value(91), lastKnown: lastKnown),
            .live(91)
        )
        XCTAssertEqual(
            OmiSourceLogic.surfacedBattery(live: .notRead, lastKnown: lastKnown),
            .lastKnown(value: 72, at: timestamp)
        )
        XCTAssertEqual(
            OmiSourceLogic.surfacedBattery(live: .notRead, lastKnown: nil),
            .missing(.notRead)
        )
        XCTAssertEqual(
            OmiSourceLogic.surfacedBattery(live: .unavailable, lastKnown: nil),
            .missing(.unknown)
        )
    }

    func testSurfacedSignalPrefersLiveThenLastKnownThenUnknown() {
        let timestamp = Date(timeIntervalSince1970: 700)
        let lastKnown = TimedReading(value: -64, at: timestamp)

        XCTAssertEqual(
            OmiSourceLogic.surfacedSignal(live: -58, lastKnown: lastKnown),
            .live(-58)
        )
        XCTAssertEqual(
            OmiSourceLogic.surfacedSignal(live: nil, lastKnown: lastKnown),
            .lastKnown(value: -64, at: timestamp)
        )
        XCTAssertEqual(
            OmiSourceLogic.surfacedSignal(live: nil, lastKnown: nil),
            .missing(.unknown)
        )
    }

    func testSurfacedReadingsRetainLastKnownValueAndTimestampAfterLiveReset() {
        let batteryAt = Date(timeIntervalSince1970: 720)
        let signalAt = Date(timeIntervalSince1970: 740)
        let lastKnownBattery = TimedReading(value: 81, at: batteryAt)
        let lastKnownSignal = TimedReading(value: -59, at: signalAt)

        XCTAssertEqual(
            OmiSourceLogic.surfacedBattery(live: .notRead, lastKnown: lastKnownBattery),
            .lastKnown(value: 81, at: batteryAt)
        )
        XCTAssertEqual(
            OmiSourceLogic.surfacedBattery(live: .unavailable, lastKnown: lastKnownBattery),
            .lastKnown(value: 81, at: batteryAt)
        )
        XCTAssertEqual(
            OmiSourceLogic.surfacedSignal(live: nil, lastKnown: lastKnownSignal),
            .lastKnown(value: -59, at: signalAt)
        )
    }

    func testSurfacedReadingTextIncludesLastKnownAge() {
        let timestamp = Date(timeIntervalSince1970: 800)
        let now = timestamp.addingTimeInterval(12 * 60)
        let battery = OmiSurfacedReading<Int>.lastKnown(value: 87, at: timestamp)
        let signal = OmiSurfacedReading<Int>.lastKnown(value: -61, at: timestamp)

        XCTAssertEqual(
            OmiSourceLogic.pendantBatteryText(reading: battery, now: now),
            "87% (as of 12m ago)"
        )
        XCTAssertEqual(
            OmiSourceLogic.pendantSignalText(reading: signal, now: now),
            "-61 (as of 12m ago)"
        )
        XCTAssertEqual(
            OmiSourceLogic.sourceReadingSubtext(battery: battery, signal: signal, now: now),
            "battery 87% as of 12m ago, signal -61 as of 12m ago"
        )
    }

    func testShouldReReadBatteryRequiresConnectedAndCachedReadableCharacteristic() {
        XCTAssertTrue(OmiSourceLogic.shouldReReadBattery(connected: true, hasCachedReadableCharacteristic: true))
        XCTAssertFalse(OmiSourceLogic.shouldReReadBattery(connected: false, hasCachedReadableCharacteristic: true))
        XCTAssertFalse(OmiSourceLogic.shouldReReadBattery(connected: true, hasCachedReadableCharacteristic: false))
        XCTAssertFalse(OmiSourceLogic.shouldReReadBattery(connected: false, hasCachedReadableCharacteristic: false))
    }

    func testAudioHealthMirrorsConnectedSilentFallback() {
        let start = Date(timeIntervalSince1970: 900)

        XCTAssertEqual(
            OmiSourceLogic.audioHealth(
                connectionState: .disconnected,
                lastAudioAt: start,
                connectedSince: start,
                now: start.addingTimeInterval(420)
            ),
            .idle
        )
        XCTAssertEqual(
            OmiSourceLogic.audioHealth(
                connectionState: .connected,
                lastAudioAt: nil,
                connectedSince: nil,
                now: start
            ),
            .idle
        )
        XCTAssertEqual(
            OmiSourceLogic.audioHealth(
                connectionState: .connected,
                lastAudioAt: nil,
                connectedSince: start,
                now: start.addingTimeInterval(20)
            ),
            .receiving
        )
        XCTAssertEqual(
            OmiSourceLogic.audioHealth(
                connectionState: .connected,
                lastAudioAt: start,
                connectedSince: start,
                now: start
            ),
            .receiving
        )
        XCTAssertEqual(
            OmiSourceLogic.audioHealth(
                connectionState: .connected,
                lastAudioAt: start,
                connectedSince: start,
                now: start.addingTimeInterval(31)
            ),
            .silentWhileConnected(since: start)
        )
        XCTAssertEqual(
            OmiSourceLogic.audioHealth(
                connectionState: .connected,
                lastAudioAt: nil,
                connectedSince: start,
                now: start.addingTimeInterval(420 * 60)
            ),
            .silentWhileConnected(since: start)
        )
        XCTAssertEqual(
            OmiSourceLogic.audioHealthText(.silentWhileConnected(since: start), now: start.addingTimeInterval(420 * 60)),
            "connected, none for 420m"
        )
    }

    func testShouldAttemptResubscribeRequiresSilentSubscribedAndUnfired() {
        let start = Date(timeIntervalSince1970: 1_000)
        let silent = OmiAudioHealth.silentWhileConnected(since: start)

        XCTAssertTrue(OmiSourceLogic.shouldAttemptResubscribe(
            health: silent,
            isAudioSubscribed: true,
            alreadyFired: false
        ))
        XCTAssertFalse(OmiSourceLogic.shouldAttemptResubscribe(
            health: silent,
            isAudioSubscribed: false,
            alreadyFired: false
        ))
        XCTAssertFalse(OmiSourceLogic.shouldAttemptResubscribe(
            health: silent,
            isAudioSubscribed: true,
            alreadyFired: true
        ))
        XCTAssertFalse(OmiSourceLogic.shouldAttemptResubscribe(
            health: .receiving,
            isAudioSubscribed: true,
            alreadyFired: false
        ))
    }

    func testAudioHealthStaysSilentAfterRecoveryAttemptFlagChanges() {
        let start = Date(timeIntervalSince1970: 1_100)
        let now = start.addingTimeInterval(90)
        let healthBeforeAttempt = OmiSourceLogic.audioHealth(
            connectionState: .connected,
            lastAudioAt: start,
            connectedSince: start,
            now: now
        )
        let healthAfterAttempt = OmiSourceLogic.audioHealth(
            connectionState: .connected,
            lastAudioAt: start,
            connectedSince: start,
            now: now
        )

        XCTAssertEqual(healthBeforeAttempt, .silentWhileConnected(since: start))
        XCTAssertEqual(healthAfterAttempt, .silentWhileConnected(since: start))
        XCTAssertTrue(OmiSourceLogic.shouldAttemptResubscribe(
            health: healthBeforeAttempt,
            isAudioSubscribed: true,
            alreadyFired: false
        ))
        XCTAssertFalse(OmiSourceLogic.shouldAttemptResubscribe(
            health: healthAfterAttempt,
            isAudioSubscribed: true,
            alreadyFired: true
        ))
    }

    private static func event(_ index: Int) -> OmiSourceEvent {
        OmiSourceEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
            reason: "drop \(index)",
            appStateAtDrop: "foreground",
            timeToReconnect: nil
        )
    }

    private static func packet(_ packetNumber: UInt16, index: UInt8, payload: Data) -> Data {
        var data = Data([
            UInt8(packetNumber & 0x00FF),
            UInt8(packetNumber >> 8),
            index
        ])
        data.append(payload)
        return data
    }
}
