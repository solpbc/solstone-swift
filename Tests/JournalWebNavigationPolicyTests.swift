// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class JournalWebNavigationPolicyTests: XCTestCase {
    func testAuthorityRequiresExplicitPort() throws {
        XCTAssertNil(JournalWebNavigationPolicy.authority(for: try XCTUnwrap(URL(string: "http://127.0.0.1/"))))

        let authority = try XCTUnwrap(
            JournalWebNavigationPolicy.authority(for: try XCTUnwrap(URL(string: "http://127.0.0.1:8080/")))
        )
        XCTAssertEqual(authority.scheme, "http")
        XCTAssertEqual(authority.host, "127.0.0.1")
        XCTAssertEqual(authority.port, 8080)
    }

    func testAuthorityNormalizesCaseTrailingDotAndIPv6Host() throws {
        let hostAuthority = try XCTUnwrap(
            JournalWebNavigationPolicy.authority(for: try XCTUnwrap(URL(string: "HTTP://Example.COM.:7071/")))
        )
        XCTAssertEqual(hostAuthority.scheme, "http")
        XCTAssertEqual(hostAuthority.host, "example.com")
        XCTAssertEqual(hostAuthority.port, 7071)

        let ipv6Authority = try XCTUnwrap(
            JournalWebNavigationPolicy.authority(for: try XCTUnwrap(URL(string: "http://[::1]:7071/")))
        )
        XCTAssertEqual(ipv6Authority.host, "::1")
        XCTAssertEqual(ipv6Authority.port, 7071)
    }

    func testRewritesHTTPSMainFrameGETForLiveAuthorityToHTTP() throws {
        let authority = try self.liveAuthority()
        let requestURL = try XCTUnwrap(URL(string: "https://127.0.0.1:8080/app/home?day=today#entry"))

        let decision = JournalWebNavigationPolicy.decision(
            requestURL: requestURL,
            httpMethod: "GET",
            isMainFrame: true,
            liveAuthority: authority
        )

        guard case .rewrite(let rewrittenURL) = decision else {
            XCTFail("expected rewrite")
            return
        }
        XCTAssertEqual(rewrittenURL.scheme, "http")
        XCTAssertEqual(rewrittenURL.host, "127.0.0.1")
        XCTAssertEqual(rewrittenURL.port, 8080)
        XCTAssertEqual(rewrittenURL.path, "/app/home")
        XCTAssertEqual(rewrittenURL.query, "day=today")
        XCTAssertEqual(rewrittenURL.fragment, "entry")
    }

    func testRewritesHTTPSMainFrameHEADForLiveAuthorityToHTTP() throws {
        let authority = try self.liveAuthority()
        let requestURL = try XCTUnwrap(URL(string: "https://127.0.0.1:8080/"))

        let decision = JournalWebNavigationPolicy.decision(
            requestURL: requestURL,
            httpMethod: "HEAD",
            isMainFrame: true,
            liveAuthority: authority
        )

        guard case .rewrite(let rewrittenURL) = decision else {
            XCTFail("expected rewrite")
            return
        }
        XCTAssertEqual(rewrittenURL.scheme, "http")
    }

    func testNilMethodIsTreatedAsGET() throws {
        let authority = try self.liveAuthority()
        let requestURL = try XCTUnwrap(URL(string: "https://127.0.0.1:8080/"))

        let decision = JournalWebNavigationPolicy.decision(
            requestURL: requestURL,
            httpMethod: nil,
            isMainFrame: true,
            liveAuthority: authority
        )

        guard case .rewrite = decision else {
            XCTFail("expected rewrite")
            return
        }
    }

    func testAllowsMatchingHTTPSWhenLiveAuthorityIsHTTPS() throws {
        let liveAuthority = try XCTUnwrap(
            JournalWebNavigationPolicy.authority(for: try XCTUnwrap(URL(string: "https://live.example.test:8443/")))
        )

        let decision = JournalWebNavigationPolicy.decision(
            requestURL: try XCTUnwrap(URL(string: "https://live.example.test:8443/app/home")),
            httpMethod: "GET",
            isMainFrame: true,
            liveAuthority: liveAuthority
        )

        XCTAssertEqual(decision, .allow)
    }

    func testAllowsLookalikeHost() throws {
        let decision = JournalWebNavigationPolicy.decision(
            requestURL: try XCTUnwrap(URL(string: "https://127.0.0.1.evil.test:8080/")),
            httpMethod: "GET",
            isMainFrame: true,
            liveAuthority: try self.liveAuthority()
        )

        XCTAssertEqual(decision, .allow)
    }

    func testAllowsPortOffByOne() throws {
        let decision = JournalWebNavigationPolicy.decision(
            requestURL: try XCTUnwrap(URL(string: "https://127.0.0.1:8081/")),
            httpMethod: "GET",
            isMainFrame: true,
            liveAuthority: try self.liveAuthority()
        )

        XCTAssertEqual(decision, .allow)
    }

    func testAllowsPostToLiveAuthority() throws {
        let decision = JournalWebNavigationPolicy.decision(
            requestURL: try XCTUnwrap(URL(string: "https://127.0.0.1:8080/")),
            httpMethod: "POST",
            isMainFrame: true,
            liveAuthority: try self.liveAuthority()
        )

        XCTAssertEqual(decision, .allow)
    }

    func testAllowsAlreadyHTTPNavigation() throws {
        let decision = JournalWebNavigationPolicy.decision(
            requestURL: try XCTUnwrap(URL(string: "http://127.0.0.1:8080/")),
            httpMethod: "GET",
            isMainFrame: true,
            liveAuthority: try self.liveAuthority()
        )

        XCTAssertEqual(decision, .allow)
    }

    func testAllowsExternalHTTPSHost() throws {
        let decision = JournalWebNavigationPolicy.decision(
            requestURL: try XCTUnwrap(URL(string: "https://example.test:8080/")),
            httpMethod: "GET",
            isMainFrame: true,
            liveAuthority: try self.liveAuthority()
        )

        XCTAssertEqual(decision, .allow)
    }

    func testAllowsUserinfoAtLiveAuthority() throws {
        let decision = JournalWebNavigationPolicy.decision(
            requestURL: try XCTUnwrap(URL(string: "https://user:secret@127.0.0.1:8080/")),
            httpMethod: "GET",
            isMainFrame: true,
            liveAuthority: try self.liveAuthority()
        )

        XCTAssertEqual(decision, .allow)
    }

    func testAllowsSubframeNavigation() throws {
        let decision = JournalWebNavigationPolicy.decision(
            requestURL: try XCTUnwrap(URL(string: "https://127.0.0.1:8080/")),
            httpMethod: "GET",
            isMainFrame: false,
            liveAuthority: try self.liveAuthority()
        )

        XCTAssertEqual(decision, .allow)
    }

    func testReplacementRequestCarriesMethodHeadersCachePolicyAndTimeout() throws {
        var original = URLRequest(
            url: try XCTUnwrap(URL(string: "https://127.0.0.1:8080/source?x=1#fragment")),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 12
        )
        original.httpMethod = "HEAD"
        original.allHTTPHeaderFields = ["Accept": "text/html"]
        let rewrittenURL = try XCTUnwrap(URL(string: "http://127.0.0.1:8080/source?x=1#fragment"))

        let replacement = JournalWebNavigationPolicy.replacementRequest(from: original, rewrittenURL: rewrittenURL)

        XCTAssertEqual(replacement.url, rewrittenURL)
        XCTAssertEqual(replacement.httpMethod, "HEAD")
        XCTAssertEqual(replacement.allHTTPHeaderFields?["Accept"], "text/html")
        XCTAssertEqual(replacement.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(replacement.timeoutInterval, 12)
    }

    private func liveAuthority() throws -> JournalWebNavigationPolicy.Authority {
        try XCTUnwrap(
            JournalWebNavigationPolicy.authority(for: try XCTUnwrap(URL(string: "http://127.0.0.1:8080/")))
        )
    }
}
