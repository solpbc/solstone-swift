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
            case "/app/devices/ingest/segments/20260603":
                return (response, Self.validSegmentsData)
            default:
                XCTFail("unexpected path \(request.url?.path ?? "nil")")
                return (response, Data())
            }
        }

        let validSegments = await client.fetchSegments(localPort: 7071, source: "mobile-segment", day: day)
        XCTAssertEqual(validSegments, .success(Self.validSegments))

        LinkedDeviceIngestURLProtocol.handler = { request in
            (Self.response(for: request), Data(#"[{"items":[]}]"#.utf8))
        }
        let bareArray = await client.fetchSegments(localPort: 7071, source: "mobile-segment", day: day)
        XCTAssertEqual(bareArray, .failure(.malformedResponse))

        LinkedDeviceIngestURLProtocol.handler = { request in
            (Self.response(for: request), Data(#"{"protocol_version":3,"total":1,"items":[{"key":"x","files":[{"name":"audio.m4a","size":1,"status":"present"}]}]}"#.utf8))
        }
        let incomplete = await client.fetchSegments(localPort: 7071, source: "mobile-segment", day: day)
        XCTAssertEqual(incomplete, .failure(.malformedResponse))

        LinkedDeviceIngestURLProtocol.handler = { request in
            (Self.response(for: request), Data("not json".utf8))
        }
        let malformed = await client.fetchSegments(localPort: 7071, source: "mobile-segment", day: day)
        XCTAssertEqual(malformed, .failure(.malformedResponse))

        LinkedDeviceIngestURLProtocol.handler = { request in
            (Self.response(for: request), Data(#"{"protocol_version":3,"total":1,"items":[{"key":"x","files":[{"name":"audio.m4a","size":1,"sha256":"a","status":"missing"}]}]}"#.utf8))
        }
        let missing = await client.fetchSegments(localPort: 7071, source: "mobile-segment", day: day)
        XCTAssertEqual(missing, .failure(.missingCustody))
    }

    func testSourceQueriesAreIsolatedAndPresentOnEveryRoute() async {
        let client = self.client
        let day = "20260603"
        LinkedDeviceIngestURLProtocol.handler = { request in
            switch request.url?.path {
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

        let sourceA = await client.fetchSegments(localPort: 7071, source: "mobile-segment", day: day)
        let sourceB = await client.fetchSegments(localPort: 7071, source: "watch-audio", day: day)

        XCTAssertEqual(sourceA, .success(Self.validSegments))
        XCTAssertEqual(sourceB, .success(LinkedDeviceIngestSegmentsResponse(protocolVersion: 3, total: 0, items: [])))
        XCTAssertEqual(LinkedDeviceIngestViewMapper.observerManifestResult(sourceB, day: day, fileName: "audio.m4a"), .loadedEmpty)
        XCTAssertTrue(LinkedDeviceIngestURLProtocol.requests.allSatisfy {
            $0.url?.query?.contains("source=") == true
                && $0.value(forHTTPHeaderField: "Authorization") == nil
                && $0.value(forHTTPHeaderField: ObserverServerURL.protocolVersionHeaderName) == "3"
        })
    }

    func testSegmentsResponseWithoutObservedDecodesAndClassifiesFiles() async {
        let client = self.client
        let day = "20260603"
        let jsonWithoutObserved = Data(#"{"protocol_version":3,"total":1,"items":[{"key":"150000_300","files":[{"name":"audio.m4a","size":42,"sha256":"abc","status":"present","submitted_name":"audio-original.m4a"},{"name":"location.jsonl","size":12,"sha256":"def","status":"processed"}]}]}"#.utf8)

        LinkedDeviceIngestURLProtocol.handler = { request in
            (Self.response(for: request), jsonWithoutObserved)
        }

        let result = await client.fetchSegments(localPort: 7071, source: "mobile-segment", day: day)
        guard case .success(let response) = result else {
            XCTFail("expected successful segments response")
            return
        }
        XCTAssertEqual(response.total, 1)
        XCTAssertEqual(response.items.first?.key, "150000_300")
        XCTAssertEqual(response.items.first?.files.count, 2)
        let manifestResult = LinkedDeviceIngestViewMapper.observerManifestResult(
            result,
            day: day,
            fileName: "audio.m4a",
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC")!
        )
        guard case .loaded(let items) = manifestResult else {
            XCTFail("expected loaded manifest result")
            return
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, "150000_300")
        XCTAssertEqual(items.first?.title, Self.shortTime("2026-06-03T15:00:00Z"))
        XCTAssertEqual(items.first?.subtitle, "5m 0s")
    }

    /// A recent row reads as a time and a length, never the raw `HHmmss_seconds` key, and each
    /// source lists only the segments that carry its own file.
    func testRecentRowsReadAsTimeAndLengthAndStayWithTheirSource() {
        let response = LinkedDeviceIngestSegmentsResponse(protocolVersion: 3, total: 3, items: [
            LinkedDeviceIngestSegment(key: "140535_3", files: [Self.file("audio.m4a")], originalKey: nil),
            LinkedDeviceIngestSegment(key: "141210_55", files: [Self.file("location.jsonl")], originalKey: nil),
            LinkedDeviceIngestSegment(key: "141305_122", files: [Self.file("screen.mp4")], originalKey: nil),
        ])
        let utc = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")

        let audio = LinkedDeviceIngestViewMapper.observerManifestResult(
            .success(response), day: "20260925", fileName: "audio.m4a", locale: locale, timeZone: utc
        )
        XCTAssertEqual(audio, .loaded([ObserverManifestItem(id: "140535_3", title: Self.shortTime("2026-09-25T14:05:35Z"), subtitle: "3s")]))

        let screen = LinkedDeviceIngestViewMapper.observerManifestResult(
            .success(response), day: "20260925", fileName: "screen.mp4", locale: locale, timeZone: utc
        )
        XCTAssertEqual(screen, .loaded([ObserverManifestItem(id: "141305_122", title: Self.shortTime("2026-09-25T14:13:05Z"), subtitle: "2m 2s")]))

        let location = LinkedDeviceIngestViewMapper.locationRecentResult(
            .success(response), day: "20260925", locale: locale, timeZone: utc
        )
        XCTAssertEqual(location, .loaded([LocationRecentItem(id: "141210_55", timeLabel: Self.shortTime("2026-09-25T14:12:10Z"))]))

        XCTAssertEqual(
            LinkedDeviceIngestViewMapper.timeLabel(forSegmentKey: "not-a-key", day: "20260925"),
            "not-a-key"
        )
    }

    func testDeleteSourceUsesCertificateOnlyDeleteContract() async {
        let client = self.client

        LinkedDeviceIngestURLProtocol.handler = { request in
            (Self.response(for: request), Self.deleteReceiptData)
        }
        let decoded = await client.deleteSource(localPort: 7071, source: "location")
        XCTAssertEqual(decoded, .success(Self.deleteReceipt))

        LinkedDeviceIngestURLProtocol.handler = { request in
            (Self.response(for: request), Data())
        }
        let empty = await client.deleteSource(localPort: 7071, source: "location")
        XCTAssertEqual(empty, .success(nil))

        LinkedDeviceIngestURLProtocol.handler = { request in
            (Self.response(for: request), Data("not a receipt".utf8))
        }
        let undecodable = await client.deleteSource(localPort: 7071, source: "location")
        XCTAssertEqual(undecodable, .success(nil))

        LinkedDeviceIngestURLProtocol.handler = { request in
            (Self.response(for: request, status: 503), Data())
        }
        let httpFailure = await client.deleteSource(localPort: 7071, source: "location")
        XCTAssertEqual(httpFailure, .failure(.httpStatus(503)))

        LinkedDeviceIngestURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let transportFailure = await client.deleteSource(localPort: 7071, source: "location")
        XCTAssertEqual(transportFailure, .failure(.malformedResponse))

        XCTAssertEqual(LinkedDeviceIngestURLProtocol.requests.count, 5)
        XCTAssertTrue(LinkedDeviceIngestURLProtocol.requests.allSatisfy { request in
            request.url?.path == "/app/devices/source/location"
                && request.httpMethod == "DELETE"
                && request.timeoutInterval == 10
                && request.value(forHTTPHeaderField: "Authorization") == nil
                && request.value(forHTTPHeaderField: ObserverServerURL.protocolVersionHeaderName) == nil
                && !(request.allHTTPHeaderFields ?? [:]).keys.contains { $0.localizedCaseInsensitiveContains("observer") }
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
            key: "150000_300",
            files: [
                LinkedDeviceIngestFile(name: "audio.m4a", size: 42, sha256: "abc", status: .present, submittedName: "audio-original.m4a"),
                LinkedDeviceIngestFile(name: "location.jsonl", size: 12, sha256: "def", status: .processed, submittedName: nil),
            ],
            originalKey: nil
        )]
    )

    private static let validSegmentsData = Data(
        #"{"protocol_version":3,"total":1,"items":[{"key":"150000_300","files":[{"name":"audio.m4a","size":42,"sha256":"abc","status":"present","submitted_name":"audio-original.m4a"},{"name":"location.jsonl","size":12,"sha256":"def","status":"processed"}]}]}"#.utf8
    )

    private static let deleteReceipt = DeleteSourceReceipt(
        removed: DeleteSourceReceipt.Removed(
            originals: 1,
            segments: 2,
            inSegmentDerived: 3,
            indexChunks: 4,
            streamIdentity: 5,
            historyRows: 6,
            days: 7
        ),
        notConfirmed: [],
        notRemoved: [],
        backupHosted: "kept"
    )

    private static let deleteReceiptData = Data(
        #"{"removed":{"originals":1,"segments":2,"in_segment_derived":3,"index_chunks":4,"stream_identity":5,"history_rows":6,"days":7},"not_confirmed":[],"not_removed":[],"backup_hosted":"kept"}"#.utf8
    )

    private static func response(for request: URLRequest, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

private extension LinkedDeviceIngestClientTests {
    static func shortTime(_ iso: String) -> String {
        OnThisPhoneItemDetailPresentation.shortTimeLabel(
            for: ISO8601DateFormatter().date(from: iso)!,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC")!
        )
    }

    static func file(_ name: String) -> LinkedDeviceIngestFile {
        LinkedDeviceIngestFile(name: name, size: 1, sha256: "abc", status: .present, submittedName: nil)
    }
}
