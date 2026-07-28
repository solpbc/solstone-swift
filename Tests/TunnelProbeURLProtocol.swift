// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

final class TunnelProbeURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    typealias AsyncHandler = @Sendable (URLRequest) async throws -> (HTTPURLResponse, Data)

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    private static let asyncHandlerBox = OSAllocatedUnfairLock<AsyncHandler?>(initialState: nil)
    private static let capturedRequestsBox = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])

    static var handler: Handler? {
        get { self.handlerBox.withLock { $0 } }
        set { self.handlerBox.withLock { $0 = newValue } }
    }

    static var asyncHandler: AsyncHandler? {
        get { self.asyncHandlerBox.withLock { $0 } }
        set { self.asyncHandlerBox.withLock { $0 = newValue } }
    }

    static var capturedRequests: [URLRequest] {
        get { self.capturedRequestsBox.withLock { $0 } }
        set { self.capturedRequestsBox.withLock { $0 = newValue } }
    }

    static func reset() {
        self.handler = nil
        self.asyncHandler = nil
        self.capturedRequests = []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.capturedRequestsBox.withLock { $0.append(self.request) }
        if let asyncHandler = Self.asyncHandler {
            Task { [request = self.request] in
                do {
                    let (response, data) = try await asyncHandler(request)
                    self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    self.client?.urlProtocol(self, didLoad: data)
                    self.client?.urlProtocolDidFinishLoading(self)
                } catch {
                    self.client?.urlProtocol(self, didFailWithError: error)
                }
            }
            return
        }

        // why: a liveness probe can still be in flight when a test's teardown nils the handler.
        // This is a test-lifecycle race, not a product defect, and XCTFail here is attributed to
        // whichever test happens to be running next — so it fails an unrelated test at random.
        // Fail gracefully; if you need to observe the leak, count it, don't assert on it.
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
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
