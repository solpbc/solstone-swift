// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class LinkedDeviceIngestReconciliationTests: XCTestCase {
    override func tearDown() {
        LinkedDeviceIngestURLProtocol.reset()
        super.tearDown()
    }

    @MainActor
    func testNilPortFailsBothResultsWithoutRequest() async {
        let observerResult = await self.reconciler(ports: [nil]).reconcileObserverManifest(day: Self.day)
        let locationResult = await self.reconciler(ports: [nil]).reconcileLocationRecent(day: Self.day)

        XCTAssertEqual(observerResult, .failed)
        XCTAssertNotEqual(observerResult, .loadedEmpty)
        XCTAssertEqual(locationResult, .failed)
        XCTAssertNotEqual(locationResult, .loadedEmpty)
        XCTAssertTrue(LinkedDeviceIngestURLProtocol.requests.isEmpty)
        self.assertNoAuthorizationHeader()
    }

    @MainActor
    func testValidEmptyResponsesStayLoadedEmpty() async {
        LinkedDeviceIngestURLProtocol.handler = { request in
            (Self.response(for: request), Self.emptySegmentsData)
        }

        let observerResult = await self.reconciler(ports: [7001, 7001])
            .reconcileObserverManifest(day: Self.day)
        XCTAssertEqual(observerResult, .loadedEmpty)

        LinkedDeviceIngestURLProtocol.reset()
        LinkedDeviceIngestURLProtocol.handler = { request in
            (Self.response(for: request), Self.audioOnlySegmentsData)
        }

        let locationResult = await self.reconciler(ports: [7001, 7001])
            .reconcileLocationRecent(day: Self.day)
        XCTAssertEqual(locationResult, .loadedEmpty)
        self.assertNoAuthorizationHeader()
    }

    @MainActor
    func testClientFailuresStayFailedForBothResults() async {
        await self.assertBothResultsFail(named: "transport") { _ in
            throw URLError(.notConnectedToInternet)
        }
        await self.assertBothResultsFail(named: "http status") { request in
            (Self.response(for: request, statusCode: 503), Data())
        }
        await self.assertBothResultsFail(named: "malformed body") { request in
            (Self.response(for: request), Data("not json".utf8))
        }
        await self.assertBothResultsFail(named: "total mismatch") { request in
            (Self.response(for: request), Self.totalMismatchSegmentsData)
        }
        await self.assertBothResultsFail(named: "missing custody") { request in
            (Self.response(for: request), Self.missingCustodySegmentsData)
        }
    }

    @MainActor
    func testNilPortAfterFetchDiscardsObserverEvidence() async {
        LinkedDeviceIngestURLProtocol.handler = { request in
            (Self.response(for: request), Self.audioOnlySegmentsData)
        }

        let result = await self.reconciler(ports: [7001, nil])
            .reconcileObserverManifest(day: Self.day)

        XCTAssertEqual(result, .failed)
        XCTAssertNotEqual(result, .loadedEmpty)
        XCTAssertEqual(LinkedDeviceIngestURLProtocol.requests.count, 1)
        self.assertNoAuthorizationHeader()
    }

    @MainActor
    func testChangedPortAfterFetchDiscardsLocationEvidence() async {
        LinkedDeviceIngestURLProtocol.handler = { request in
            (Self.response(for: request), Self.locationSegmentsData)
        }

        let result = await self.reconciler(ports: [7001, 7002])
            .reconcileLocationRecent(day: Self.day)

        XCTAssertEqual(result, .failed)
        XCTAssertNotEqual(result, .loadedEmpty)
        XCTAssertEqual(LinkedDeviceIngestURLProtocol.requests.count, 1)
        self.assertNoAuthorizationHeader()
    }
}

private extension LinkedDeviceIngestReconciliationTests {
    static let day = "20260603"

    static let emptySegmentsData = Data(#"{"protocol_version":3,"total":0,"items":[]}"#.utf8)
    static let audioOnlySegmentsData = Data(
        #"{"protocol_version":3,"total":1,"items":[{"key":"20260603-150000_300","observed":true,"files":[{"name":"audio.m4a","size":42,"sha256":"abc","status":"present"}]}]}"#.utf8
    )
    static let locationSegmentsData = Data(
        #"{"protocol_version":3,"total":1,"items":[{"key":"20260603-150000_300","observed":true,"files":[{"name":"location.jsonl","size":12,"sha256":"def","status":"processed"}]}]}"#.utf8
    )
    static let totalMismatchSegmentsData = Data(
        #"{"protocol_version":3,"total":2,"items":[{"key":"20260603-150000_300","observed":true,"files":[{"name":"audio.m4a","size":42,"sha256":"abc","status":"present"}]}]}"#.utf8
    )
    static let missingCustodySegmentsData = Data(
        #"{"protocol_version":3,"total":1,"items":[{"key":"20260603-150000_300","observed":true,"files":[{"name":"audio.m4a","size":42,"sha256":"abc","status":"missing"}]}]}"#.utf8
    )

    @MainActor
    func reconciler(ports: [Int?]) -> LinkedDeviceIngestReconciler {
        let reader = PortReader(ports: ports)
        return LinkedDeviceIngestReconciler(
            client: self.client,
            activeLocalPort: { reader.next() }
        )
    }

    @MainActor
    func assertBothResultsFail(
        named name: String,
        handler: @escaping LinkedDeviceIngestURLProtocol.Handler
    ) async {
        LinkedDeviceIngestURLProtocol.reset()
        LinkedDeviceIngestURLProtocol.handler = handler

        let observerResult = await self.reconciler(ports: [7001, 7001])
            .reconcileObserverManifest(day: Self.day)
        let locationResult = await self.reconciler(ports: [7001, 7001])
            .reconcileLocationRecent(day: Self.day)

        XCTAssertEqual(observerResult, .failed, name)
        XCTAssertNotEqual(observerResult, .loadedEmpty, name)
        XCTAssertEqual(locationResult, .failed, name)
        XCTAssertNotEqual(locationResult, .loadedEmpty, name)
        self.assertNoAuthorizationHeader()
    }

    var client: LinkedDeviceIngestClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LinkedDeviceIngestURLProtocol.self]
        return LinkedDeviceIngestClient(session: URLSession(configuration: configuration))
    }

    func assertNoAuthorizationHeader() {
        XCTAssertTrue(LinkedDeviceIngestURLProtocol.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == nil
        })
    }

    static func response(for request: URLRequest, statusCode: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }
}

@MainActor
private final class PortReader {
    private let ports: [Int?]
    private var index = 0

    init(ports: [Int?]) {
        self.ports = ports
    }

    func next() -> Int? {
        guard !self.ports.isEmpty else { return nil }
        defer { self.index += 1 }
        return self.ports[min(self.index, self.ports.count - 1)]
    }
}
