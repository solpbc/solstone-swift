// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
@testable import SPLTunnel
import XCTest

private struct CapturedRefreshRequest: Sendable {
    let url: String
    let method: String?
    let headers: [String: String]
    let body: Data
}

private final class DeviceTokenRefreshURLProtocol: URLProtocol, @unchecked Sendable {
    struct State: Sendable {
        var responseData = Data()
        var statusCode = 200
        var error: URLError?
        var requests: [CapturedRefreshRequest] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func configure(responseData: Data = Data(), statusCode: Int = 200, error: URLError? = nil) {
        state.withLock {
            $0.responseData = responseData
            $0.statusCode = statusCode
            $0.error = error
            $0.requests = []
        }
    }

    static func requests() -> [CapturedRefreshRequest] {
        state.withLock { $0.requests }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.body(from: request)
        let current = Self.state.withLock { state in
            state.requests.append(CapturedRefreshRequest(
                url: request.url?.absoluteString ?? "",
                method: request.httpMethod,
                headers: request.allHTTPHeaderFields ?? [:],
                body: body
            ))
            return state
        }

        if let error = current.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: current.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: current.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(from request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }
}

nonisolated final class DeviceTokenRefresherTests: XCTestCase {
    func testRefreshRequestShapeAndSuccessResult() async throws {
        let oldToken = Self.token(iat: 1_000, exp: 1_500)
        let session = Self.session(responseData: Self.refreshSuccessData(deviceToken: "new-token"))
        let refresher = DeviceTokenRefresher(session: session)

        let result = await refresher.refreshNow(pairing: Self.pairing(deviceToken: oldToken))

        guard case .refreshed(let updated) = result else {
            return XCTFail("expected refreshed result")
        }
        XCTAssertEqual(updated.relayEnrollment, .enrolled(deviceToken: "new-token", expiresAt: "2036-01-01T00:00:00Z"))

        let request = try XCTUnwrap(DeviceTokenRefreshURLProtocol.requests().first)
        XCTAssertEqual(request.url, "https://relay.example.com/token/refresh")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertNotNil(request.headers["User-Agent"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: String])
        XCTAssertEqual(json["device_token"], oldToken)
    }

    func testDefinitiveAuthFailures() async {
        await assertRefreshResult(
            .definitiveAuthFailure,
            statusCode: 401,
            responseData: Data(#"{"reason":"expired"}"#.utf8)
        )
        await assertRefreshResult(
            .definitiveAuthFailure,
            statusCode: 403,
            responseData: Data(#"{"error":"instance revoked"}"#.utf8)
        )
    }

    func testTransientFailures() async {
        await assertRefreshResult(.transientFailure(Self.pairing()), error: URLError(.cannotConnectToHost))
        await assertRefreshResult(.transientFailure(Self.pairing()), statusCode: 403)
        await assertRefreshResult(.transientFailure(Self.pairing()), statusCode: 404)
        await assertRefreshResult(.transientFailure(Self.pairing()), statusCode: 500)
        await assertRefreshResult(.transientFailure(Self.pairing()), responseData: Data("bad-json".utf8))
    }

    func testRefreshIfNeededSkipsWhenTokenIsUnderBoundary() async {
        let token = Self.token(iat: 1_000, exp: 2_000)
        let pairing = Self.pairing(deviceToken: token)
        let refresher = DeviceTokenRefresher(session: Self.session(responseData: Self.refreshSuccessData()))

        let result = await refresher.refreshIfNeeded(pairing: pairing, now: Date(timeIntervalSince1970: 1_700))

        XCTAssertEqual(result, .notNeeded(pairing))
        XCTAssertEqual(DeviceTokenRefreshURLProtocol.requests().count, 0)
    }

    private func assertRefreshResult(
        _ expected: DeviceTokenRefreshResult,
        statusCode: Int = 200,
        responseData: Data = Data(),
        error: URLError? = nil
    ) async {
        let pairing = Self.pairing()
        let refresher = DeviceTokenRefresher(session: Self.session(responseData: responseData, statusCode: statusCode, error: error))

        let result = await refresher.refreshNow(pairing: pairing)

        XCTAssertEqual(result, expected)
    }

    private static func session(responseData: Data = Data(), statusCode: Int = 200, error: URLError? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeviceTokenRefreshURLProtocol.self]
        DeviceTokenRefreshURLProtocol.configure(responseData: responseData, statusCode: statusCode, error: error)
        return URLSession(configuration: configuration)
    }

    private static func pairing(deviceToken: String? = nil) -> StoredPairing {
        let deviceToken = deviceToken ?? token(iat: 1_000, exp: 1_500)
        return StoredPairing(
            instanceID: "instance-123",
            homeLabel: "sol",
            relayEndpoint: "wss://relay.example.com",
            fingerprint: "sha256:\(String(repeating: "a", count: 64))",
            clientCertPEM: "cert",
            clientKeyPEM: "key",
            caChainPEM: "ca",
            relayEnrollment: .enrolled(deviceToken: deviceToken, expiresAt: nil),
            localEndpoints: [],
            pairedAt: Date(timeIntervalSince1970: 1_776_144_000)
        )
    }

    private static func refreshSuccessData(deviceToken: String = "device-token") -> Data {
        Data(#"{"device_token":"\#(deviceToken)","expires_at":"2036-01-01T00:00:00Z"}"#.utf8)
    }

    private static func token(iat: Double, exp: Double) -> String {
        "e30.\(base64URL(["iat": iat, "exp": exp])).sig"
    }

    private static func base64URL(_ object: [String: Double]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
