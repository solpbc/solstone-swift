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
}
