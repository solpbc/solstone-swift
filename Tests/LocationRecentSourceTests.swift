// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

nonisolated final class LocationRecentSourceTests: XCTestCase {
    private let fixedLocale = Locale(identifier: "en_US_POSIX")
    private let fixedTimeZone = TimeZone(secondsFromGMT: 0)!

    override func tearDown() {
        LocationRecentURLProtocol.handler = nil
        super.tearDown()
    }

    func testFetchTodayFiltersLocationSegmentsNewestFirst() async {
        LocationRecentURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(
                    #"""
                    {
                      "items": [
                        {
                          "key": "20260603-160000_300",
                          "observed": true,
                          "files": [
                            {"name":"audio.m4a","size":42,"sha256":"abc123","status":"ready"}
                          ]
                        },
                        {
                          "key": "20260603-150000_300",
                          "observed": true,
                          "files": [
                            {"name":"location.jsonl","size":42,"sha256":"abc123","status":"ready"}
                          ]
                        },
                        {
                          "key": "20260603-145000_300",
                          "observed": true,
                          "files": []
                        },
                        {
                          "key": "20260603-154212_300",
                          "observed": true,
                          "files": [
                            {"name":"location.jsonl","size":42,"sha256":"abc123","status":"ready"}
                          ],
                          "original_key": "20260603-154212_300"
                        }
                      ],
                      "total": 4,
                      "protocol_version": 2
                    }
                    """#.utf8
                )
            )
        }

        let result = await self.client.fetchToday(localPort: 7071, handle: "observer-key")

        XCTAssertEqual(result, .loaded([
            LocationRecentItem(
                id: "20260603-154212_300",
                timeLabel: self.timeLabel(for: "20260603-154212_300")
            ),
            LocationRecentItem(
                id: "20260603-150000_300",
                timeLabel: self.timeLabel(for: "20260603-150000_300")
            ),
        ]))
    }

    func testFetchTodayReturnsLoadedEmptyForEmptyAndLocationFreeManifests() async {
        LocationRecentURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"items":[],"total":0,"protocol_version":2}"#.utf8)
            )
        }

        var result = await self.client.fetchToday(localPort: 7071, handle: "observer-key")
        XCTAssertEqual(result, .loadedEmpty)

        LocationRecentURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(
                    #"""
                    {
                      "items": [
                        {
                          "key": "20260603-150000_300",
                          "observed": true,
                          "files": [
                            {"name":"audio.m4a","size":42,"sha256":"abc123","status":"ready"}
                          ]
                        }
                      ],
                      "total": 1,
                      "protocol_version": 2
                    }
                    """#.utf8
                )
            )
        }

        result = await self.client.fetchToday(localPort: 7071, handle: "observer-key")
        XCTAssertEqual(result, .loadedEmpty)
    }

    func testFetchTodayReturnsFailedForHTTPErrorAndGarbageBody() async {
        LocationRecentURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        var result = await self.client.fetchToday(localPort: 7071, handle: "observer-key")
        XCTAssertEqual(result, .failed)

        LocationRecentURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("not json".utf8)
            )
        }

        result = await self.client.fetchToday(localPort: 7071, handle: "observer-key")
        XCTAssertEqual(result, .failed)
    }

    func testFetchTodayDecodesBareArrayForm() async {
        LocationRecentURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(
                    #"""
                    [
                      {
                        "key": "20260603-154212_300",
                        "observed": true,
                        "files": [
                          {"name":"location.jsonl","size":42,"sha256":"abc123","status":"ready"}
                        ]
                      }
                    ]
                    """#.utf8
                )
            )
        }

        let result = await self.client.fetchToday(localPort: 7071, handle: "observer-key")

        XCTAssertEqual(result, .loaded([
            LocationRecentItem(
                id: "20260603-154212_300",
                timeLabel: self.timeLabel(for: "20260603-154212_300")
            )
        ]))
    }

    func testSegmentDateParserParsesComponents() throws {
        let date = try XCTUnwrap(
            LocationRecentSource.date(forSegmentKey: "20260603-154212_300", timeZone: self.fixedTimeZone)
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = self.fixedTimeZone
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 6)
        XCTAssertEqual(components.day, 3)
        XCTAssertEqual(components.hour, 15)
        XCTAssertEqual(components.minute, 42)
        XCTAssertEqual(components.second, 12)
    }

    func testTimeLabelParserFormatsValidSegmentAndFallsBackForMalformedSegmentKeys() {
        let rawKey = "20260603-154212_300"
        let label = LocationRecentSource.timeLabel(
            forSegmentKey: rawKey,
            locale: self.fixedLocale,
            timeZone: self.fixedTimeZone
        )

        XCTAssertFalse(label.isEmpty)
        XCTAssertNotEqual(label, rawKey)
        XCTAssertEqual(
            LocationRecentSource.timeLabel(
                forSegmentKey: "not-a-location-segment",
                locale: self.fixedLocale,
                timeZone: self.fixedTimeZone
            ),
            "not-a-location-segment"
        )
    }

    private var client: LocationRecentSource {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocationRecentURLProtocol.self]
        return LocationRecentSource(
            session: URLSession(configuration: configuration),
            locale: self.fixedLocale,
            timeZone: self.fixedTimeZone
        )
    }

    private func timeLabel(for segmentKey: String) -> String {
        LocationRecentSource.timeLabel(
            forSegmentKey: segmentKey,
            locale: self.fixedLocale,
            timeZone: self.fixedTimeZone
        )
    }
}

private final class LocationRecentURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    static var handler: Handler? {
        get { self.handlerBox.withLock { $0 } }
        set { self.handlerBox.withLock { $0 = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        XCTAssertEqual(self.request.value(forHTTPHeaderField: "Authorization"), "Bearer observer-key")
        XCTAssertEqual(self.request.value(forHTTPHeaderField: ObserverServerURL.protocolVersionHeaderName), "2")
        XCTAssertEqual(self.request.url?.path, "/app/observer/ingest/segments/\(locationRecentTestDayString())")
        guard let handler = Self.handler else {
            XCTFail("LocationRecentURLProtocol handler not set")
            return
        }

        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

nonisolated private func locationRecentTestDayString() -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "yyyyMMdd"
    return formatter.string(from: Date())
}
