// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class LinkedDeviceIngestClientTests: XCTestCase {
    override func tearDown() {
        LinkedDeviceIngestURLProtocol.reset()
        super.tearDown()
    }

    func testStrictReadRouteDecoding() async {
        let client = self.client
        let day = "20260603"

        LinkedDeviceIngestURLProtocol.handler = { request in
            let response = Self.response(for: request)
            switch request.url?.path {
            case "/app/devices/ingest/manifest":
                return (response, Data(#"{"days":{"20260603":{"segments":1}}}"#.utf8))
            case "/app/devices/ingest/manifest/20260603":
                return (response, Data(#"{"version":1,"day":"20260603","segments":{"meeting":{"files":[{"name":"audio.m4a","size":42,"sha256":"abc","status":"present"}]}}}"#.utf8))
            case "/app/devices/ingest/segments/20260603":
                return (response, Self.validSegmentsData)
            default:
                XCTFail("unexpected path \(request.url?.path ?? "nil")")
                return (response, Data())
            }
        }

        let days = await client.listDays(localPort: 7071, source: "mobile-segment")
        XCTAssertEqual(
            days,
            .success(LinkedDeviceIngestDaysResponse(days: [
                day: LinkedDeviceIngestDaySummary(segments: 1, error: nil),
            ]))
        )
        let manifestDay = await client.fetchManifestDay(localPort: 7071, source: "mobile-segment", day: day)
        XCTAssertEqual(
            manifestDay,
            .success(LinkedDeviceIngestManifestDayResponse(
                version: 1,
                day: day,
                segments: ["meeting": LinkedDeviceIngestManifestSegment(files: [
                    LinkedDeviceIngestFile(name: "audio.m4a", size: 42, sha256: "abc", status: .present, submittedName: nil),
                ])]
            ))
        )
        let validSegments = await client.fetchSegments(localPort: 7071, source: "mobile-segment", day: day)
        XCTAssertEqual(validSegments, .success(Self.validSegments))

        LinkedDeviceIngestURLProtocol.handler = { request in
            (Self.response(for: request), Data(#"[{"items":[]}]"#.utf8))
        }
        let bareArray = await client.fetchSegments(localPort: 7071, source: "mobile-segment", day: day)
        XCTAssertEqual(bareArray, .failure(.malformedResponse))

        LinkedDeviceIngestURLProtocol.handler = { request in
            (Self.response(for: request), Data(#"{"protocol_version":3,"total":1,"items":[{"key":"x","observed":true,"files":[{"name":"audio.m4a","size":1,"status":"present"}]}]}"#.utf8))
        }
        let incomplete = await client.fetchSegments(localPort: 7071, source: "mobile-segment", day: day)
        XCTAssertEqual(incomplete, .failure(.malformedResponse))

        LinkedDeviceIngestURLProtocol.handler = { request in
            (Self.response(for: request), Data("not json".utf8))
        }
        let malformed = await client.fetchSegments(localPort: 7071, source: "mobile-segment", day: day)
        XCTAssertEqual(malformed, .failure(.malformedResponse))

        LinkedDeviceIngestURLProtocol.handler = { request in
            (Self.response(for: request), Data(#"{"days":{"20260603":{"error":"journal_read_failed"}}}"#.utf8))
        }
        let dayError = await client.listDays(localPort: 7071, source: "mobile-segment")
        XCTAssertEqual(dayError, .failure(.dayError(day: day, reason: "journal_read_failed")))

        LinkedDeviceIngestURLProtocol.handler = { request in
            (Self.response(for: request), Data(#"{"protocol_version":3,"total":1,"items":[{"key":"x","observed":true,"files":[{"name":"audio.m4a","size":1,"sha256":"a","status":"missing"}]}]}"#.utf8))
        }
        let missing = await client.fetchSegments(localPort: 7071, source: "mobile-segment", day: day)
        XCTAssertEqual(missing, .failure(.missingCustody))
    }

    func testSourceQueriesAreIsolatedAndPresentOnEveryRoute() async {
        let client = self.client
        let day = "20260603"
        LinkedDeviceIngestURLProtocol.handler = { request in
            switch request.url?.path {
            case "/app/devices/ingest/manifest":
                return (Self.response(for: request), Data(#"{"days":{}}"#.utf8))
            case "/app/devices/ingest/manifest/20260603":
                return (Self.response(for: request), Data(#"{"version":1,"day":"20260603","segments":{}}"#.utf8))
            case "/app/devices/ingest/segments/20260603":
                if request.url?.query?.contains("source=mobile-segment") == true {
                    return (Self.response(for: request), Self.validSegmentsData)
                }
                return (Self.response(for: request), Data(#"{"protocol_version":3,"total":0,"items":[]}"#.utf8))
            default:
                XCTFail("unexpected path")
                return (Self.response(for: request), Data())
            }
        }

        _ = await client.listDays(localPort: 7071, source: "mobile-segment")
        _ = await client.fetchManifestDay(localPort: 7071, source: "mobile-segment", day: day)
        let sourceA = await client.fetchSegments(localPort: 7071, source: "mobile-segment", day: day)
        let sourceB = await client.fetchSegments(localPort: 7071, source: "omi-audio", day: day)

        XCTAssertEqual(sourceA, .success(Self.validSegments))
        XCTAssertEqual(sourceB, .success(LinkedDeviceIngestSegmentsResponse(protocolVersion: 3, total: 0, items: [])))
        XCTAssertEqual(LinkedDeviceIngestViewMapper.observerManifestResult(sourceB), .loadedEmpty)
        XCTAssertTrue(LinkedDeviceIngestURLProtocol.requests.allSatisfy {
            $0.url?.query?.contains("source=") == true
                && $0.value(forHTTPHeaderField: "Authorization") == nil
                && $0.value(forHTTPHeaderField: ObserverServerURL.protocolVersionHeaderName) == "3"
        })
    }

    private var client: LinkedDeviceIngestClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LinkedDeviceIngestURLProtocol.self]
        return LinkedDeviceIngestClient(session: URLSession(configuration: configuration))
    }

    private static let validSegments = LinkedDeviceIngestSegmentsResponse(
        protocolVersion: 3,
        total: 1,
        items: [LinkedDeviceIngestSegment(
            key: "20260603-150000_300",
            observed: true,
            files: [
                LinkedDeviceIngestFile(name: "audio.m4a", size: 42, sha256: "abc", status: .present, submittedName: "audio-original.m4a"),
                LinkedDeviceIngestFile(name: "location.jsonl", size: 12, sha256: "def", status: .processed, submittedName: nil),
            ],
            originalKey: nil
        )]
    )

    private static let validSegmentsData = Data(
        #"{"protocol_version":3,"total":1,"items":[{"key":"20260603-150000_300","observed":true,"files":[{"name":"audio.m4a","size":42,"sha256":"abc","status":"present","submitted_name":"audio-original.m4a"},{"name":"location.jsonl","size":12,"sha256":"def","status":"processed"}]}]}"#.utf8
    )

    private static func response(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}
