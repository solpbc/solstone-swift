// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class ServerSentEventParserTests: XCTestCase {
    func testParsesDataEventAtBlankLineBoundary() {
        var parser = ServerSentEventParser()

        let events = parser.append(Data("event: message\ndata: {\"ok\":true}\n\n".utf8))

        XCTAssertEqual(events, [ServerSentEvent(event: "message", data: #"{"ok":true}"#)])
    }

    func testSkipsHeartbeatComments() {
        var parser = ServerSentEventParser()

        let events = parser.append(Data(": heartbeat\n\ndata: one\n\n".utf8))

        XCTAssertEqual(events, [ServerSentEvent(event: nil, data: "one")])
    }

    func testJoinsMultiLineDataWithNewlines() {
        var parser = ServerSentEventParser()

        let events = parser.append(Data("data: one\ndata: two\n\n".utf8))

        XCTAssertEqual(events, [ServerSentEvent(event: nil, data: "one\ntwo")])
    }

    func testRetainsPartialLineAcrossAppendsAndParsesMultipleEvents() {
        var parser = ServerSentEventParser()

        XCTAssertEqual(parser.append(Data("data: on".utf8)), [])
        let events = parser.append(Data("e\n\ndata: two\n\n".utf8))

        XCTAssertEqual(events, [
            ServerSentEvent(event: nil, data: "one"),
            ServerSentEvent(event: nil, data: "two"),
        ])
    }

    func testFinishFlushesPendingEvent() {
        var parser = ServerSentEventParser()

        XCTAssertEqual(parser.append(Data("data: pending".utf8)), [])

        XCTAssertEqual(parser.finish(), [ServerSentEvent(event: nil, data: "pending")])
    }

    func testDecodesMultibyteStreamedOneBytePerAppend() {
        let payload = "café — 日本語 🎉"
        let bytes = Data("data: \(payload)\n\n".utf8)
        var parser = ServerSentEventParser()
        var events: [ServerSentEvent] = []

        for byte in bytes {
            events.append(contentsOf: parser.append(Data([byte])))
        }

        XCTAssertEqual(events, [ServerSentEvent(event: nil, data: payload)])
        XCTAssertFalse(events.first?.data.contains("\u{FFFD}") ?? true)
    }

    func testDecodesMultibyteAcrossEveryTwoAppendSplit() {
        let payload = "café — 日本語 🎉"
        let bytes = Array(Data("data: \(payload)\n\n".utf8))

        for splitIndex in 0...bytes.count {
            var parser = ServerSentEventParser()
            var events: [ServerSentEvent] = []

            events.append(contentsOf: parser.append(Data(bytes[..<splitIndex])))
            events.append(contentsOf: parser.append(Data(bytes[splitIndex...])))

            XCTAssertEqual(events, [ServerSentEvent(event: nil, data: payload)], "split \(splitIndex)")
            XCTAssertFalse(events.first?.data.contains("\u{FFFD}") ?? true, "split \(splitIndex)")
        }
    }

    func testLineFramingIsNearLinearUnderByteAtATimeFragmentation() {
        let nBytes = Self.singleLineEventBytes(payloadSize: 4_096)
        let twoNBytes = Self.singleLineEventBytes(payloadSize: 8_192)
        let feed: ([UInt8]) -> Duration = { bytes in
            var parser = ServerSentEventParser()
            let start = ContinuousClock.now
            for byte in bytes {
                _ = parser.append(Data([byte]))
            }
            _ = parser.finish()
            return ContinuousClock.now - start
        }

        _ = feed(nBytes)
        _ = feed(twoNBytes)

        var ratios: [Double] = []
        var nDurations: [Double] = []
        var twoNDurations: [Double] = []
        for _ in 0..<7 {
            let nSeconds = Self.seconds(feed(nBytes))
            let twoNSeconds = Self.seconds(feed(twoNBytes))
            nDurations.append(nSeconds)
            twoNDurations.append(twoNSeconds)
            ratios.append(twoNSeconds / nSeconds)
        }

        let median = ratios.sorted()[3]
        let medianN = nDurations.sorted()[3]
        let medianTwoN = twoNDurations.sorted()[3]
        XCTAssertLessThan(
            median,
            3.0,
            "2N/N ratio \(median) indicates super-linear framing; N median \(medianN), 2N median \(medianTwoN), ratios \(ratios)"
        )
    }

    func testLargeMultibyteFragmentedEventEmittedOnceExactly() {
        let payload = String(repeating: "café — 日本語 🎉 ", count: 128)
        let bytes = Data("data: \(payload)\n\n".utf8)
        var parser = ServerSentEventParser()
        var events: [ServerSentEvent] = []

        for byte in bytes {
            events.append(contentsOf: parser.append(Data([byte])))
        }

        XCTAssertEqual(events, [ServerSentEvent(event: nil, data: payload)])
        XCTAssertFalse(events.first?.data.contains("\u{FFFD}") ?? true)
    }

    func testPreservesExplicitEventSemantics() {
        var emptyDataParser = ServerSentEventParser()
        XCTAssertEqual(emptyDataParser.append(Data("data:\n\n".utf8)), [ServerSentEvent(event: nil, data: "")])

        var eventOnlyParser = ServerSentEventParser()
        XCTAssertEqual(eventOnlyParser.append(Data("event: foo\n\n".utf8)), [])
        XCTAssertEqual(eventOnlyParser.finish(), [])

        var commentOnlyParser = ServerSentEventParser()
        XCTAssertEqual(commentOnlyParser.append(Data(": comment only\n\n".utf8)), [])
        XCTAssertEqual(commentOnlyParser.finish(), [])

        var unknownOnlyParser = ServerSentEventParser()
        XCTAssertEqual(unknownOnlyParser.append(Data("id: 123\n\n".utf8)), [])
        XCTAssertEqual(unknownOnlyParser.finish(), [])

        var emptyInputParser = ServerSentEventParser()
        XCTAssertEqual(emptyInputParser.append(Data()), [])
        XCTAssertEqual(emptyInputParser.finish(), [])

        var crlfParser = ServerSentEventParser()
        XCTAssertEqual(crlfParser.append(Data("data: hi\r\n\r\n".utf8)), [ServerSentEvent(event: nil, data: "hi")])

        var splitCRLFParser = ServerSentEventParser()
        XCTAssertEqual(splitCRLFParser.append(Data("data: hi\r".utf8)), [])
        XCTAssertEqual(splitCRLFParser.append(Data("\n\r\n".utf8)), [ServerSentEvent(event: nil, data: "hi")])

        var namedMultilineParser = ServerSentEventParser()
        XCTAssertEqual(
            namedMultilineParser.append(Data("event: m\ndata: a\ndata: b\n\n".utf8)),
            [ServerSentEvent(event: "m", data: "a\nb")]
        )

        var multipleEventsParser = ServerSentEventParser()
        XCTAssertEqual(
            multipleEventsParser.append(Data("data: one\n\ndata: two\n\n".utf8)),
            [
                ServerSentEvent(event: nil, data: "one"),
                ServerSentEvent(event: nil, data: "two"),
            ]
        )

        var finalLineParser = ServerSentEventParser()
        XCTAssertEqual(finalLineParser.append(Data("data: tail".utf8)), [])
        XCTAssertEqual(finalLineParser.finish(), [ServerSentEvent(event: nil, data: "tail")])
    }

    func testExhaustiveTwoWaySplitPreservesEvents() {
        let stream = ": hb\n" +
            "event: greet\ndata: café\ndata: 日本語\n\n" +
            "id: ignore-me\n" +
            "data: crlf-line\r\n\r\n" +
            "data: tail 🎉"
        let bytes = Array(Data(stream.utf8))
        let expected = [
            ServerSentEvent(event: "greet", data: "café\n日本語"),
            ServerSentEvent(event: nil, data: "crlf-line"),
            ServerSentEvent(event: nil, data: "tail 🎉"),
        ]

        XCTAssertEqual(Self.parse(bytes), expected)

        for splitIndex in 0...bytes.count {
            var parser = ServerSentEventParser()
            var events: [ServerSentEvent] = []

            events.append(contentsOf: parser.append(Data(bytes[..<splitIndex])))
            events.append(contentsOf: parser.append(Data(bytes[splitIndex...])))
            events.append(contentsOf: parser.finish())

            XCTAssertEqual(events, expected, "split \(splitIndex)")
            XCTAssertFalse(events.contains { $0.data.contains("\u{FFFD}") }, "split \(splitIndex)")
        }
    }

    private static func singleLineEventBytes(payloadSize: Int) -> [UInt8] {
        Array(Data(("data: " + String(repeating: "a", count: payloadSize) + "\n\n").utf8))
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static func parse(_ bytes: [UInt8]) -> [ServerSentEvent] {
        var parser = ServerSentEventParser()
        var events = parser.append(Data(bytes))
        events.append(contentsOf: parser.finish())
        return events
    }
}
