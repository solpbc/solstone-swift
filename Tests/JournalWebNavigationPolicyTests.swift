// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class JournalWebNavigationPolicyTests: XCTestCase {
    func testAuthorityUsesEffectiveDefaultPorts() throws {
        let portlessHTTP = try XCTUnwrap(
            JournalWebNavigationPolicy.authority(for: try XCTUnwrap(URL(string: "http://127.0.0.1/")))
        )
        XCTAssertEqual(portlessHTTP.port, 80)

        let portlessHTTPS = try XCTUnwrap(
            JournalWebNavigationPolicy.authority(for: try XCTUnwrap(URL(string: "https://127.0.0.1/")))
        )
        XCTAssertEqual(portlessHTTPS.port, 443)

        let authority = try XCTUnwrap(
            JournalWebNavigationPolicy.authority(for: try XCTUnwrap(URL(string: "http://127.0.0.1:8080/")))
        )
        XCTAssertEqual(authority.scheme, "http")
        XCTAssertEqual(authority.host, "127.0.0.1")
        XCTAssertEqual(authority.port, 8080)
        XCTAssertNil(JournalWebNavigationPolicy.authority(for: try XCTUnwrap(URL(string: "about:blank"))))
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
            frame: .main,
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
            frame: .main,
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
            frame: .main,
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
            frame: .main,
            liveAuthority: liveAuthority
        )

        XCTAssertEqual(decision, .allow)
    }

    func testOpensLookalikeHostExternally() throws {
        let requestURL = try XCTUnwrap(URL(string: "https://127.0.0.1.evil.test:8080/"))
        let decision = JournalWebNavigationPolicy.decision(
            requestURL: requestURL,
            httpMethod: "GET",
            frame: .main,
            liveAuthority: try self.liveAuthority()
        )

        XCTAssertEqual(decision, .openExternally(requestURL))
    }

    func testCancelsPortOffByOne() throws {
        let decision = JournalWebNavigationPolicy.decision(
            requestURL: try XCTUnwrap(URL(string: "https://127.0.0.1:8081/")),
            httpMethod: "GET",
            frame: .main,
            liveAuthority: try self.liveAuthority()
        )

        XCTAssertEqual(decision, .cancel)
    }

    func testAllowsPostToLiveAuthority() throws {
        let decision = JournalWebNavigationPolicy.decision(
            requestURL: try XCTUnwrap(URL(string: "https://127.0.0.1:8080/")),
            httpMethod: "POST",
            frame: .main,
            liveAuthority: try self.liveAuthority()
        )

        XCTAssertEqual(decision, .allow)
    }

    func testAllowsAlreadyHTTPNavigation() throws {
        let decision = JournalWebNavigationPolicy.decision(
            requestURL: try XCTUnwrap(URL(string: "http://127.0.0.1:8080/")),
            httpMethod: "GET",
            frame: .main,
            liveAuthority: try self.liveAuthority()
        )

        XCTAssertEqual(decision, .allow)
    }

    func testOpensExternalHTTPSHostExternally() throws {
        let requestURL = try XCTUnwrap(URL(string: "https://example.test:8080/"))
        let decision = JournalWebNavigationPolicy.decision(
            requestURL: requestURL,
            httpMethod: "GET",
            frame: .main,
            liveAuthority: try self.liveAuthority()
        )

        XCTAssertEqual(decision, .openExternally(requestURL))
    }

    func testOpensExternalHTTPPostExternally() throws {
        let requestURL = try XCTUnwrap(URL(string: "http://example.test/form"))
        let decision = JournalWebNavigationPolicy.decision(
            requestURL: requestURL,
            httpMethod: "POST",
            frame: .main,
            liveAuthority: try self.liveAuthority()
        )

        XCTAssertEqual(decision, .openExternally(requestURL))
    }

    func testCancelsMainAndNoTargetNonWebSchemesAndAllowsExternalSubframe() throws {
        XCTAssertEqual(
            JournalWebNavigationPolicy.decision(
                requestURL: try XCTUnwrap(URL(string: "https://example.test/")),
                httpMethod: "GET",
                frame: .subframe,
                liveAuthority: try self.liveAuthority()
            ),
            .allow
        )
        XCTAssertEqual(
            JournalWebNavigationPolicy.decision(
                requestURL: try XCTUnwrap(URL(string: "about:blank")),
                httpMethod: "GET",
                frame: .main,
                liveAuthority: try self.liveAuthority()
            ),
            .cancel
        )
        XCTAssertEqual(
            JournalWebNavigationPolicy.decision(
                requestURL: try XCTUnwrap(URL(string: "about:blank")),
                httpMethod: "GET",
                frame: .noTarget,
                liveAuthority: try self.liveAuthority()
            ),
            .cancel
        )
        XCTAssertEqual(
            JournalWebNavigationPolicy.decision(
                requestURL: try XCTUnwrap(URL(string: "mailto:hello@example.test")),
                httpMethod: "GET",
                frame: .main,
                liveAuthority: try self.liveAuthority()
            ),
            .cancel
        )
        XCTAssertEqual(
            JournalWebNavigationPolicy.decision(
                requestURL: nil,
                httpMethod: "GET",
                frame: .main,
                liveAuthority: try self.liveAuthority()
            ),
            .cancel
        )
    }

    func testCancelsStaleLoopbackAuthoritiesForMainAndNoTarget() throws {
        let staleURL = try XCTUnwrap(URL(string: "http://localhost:9090/"))
        for frame in [JournalWebNavigationPolicy.Frame.main, .noTarget] {
            XCTAssertEqual(
                JournalWebNavigationPolicy.decision(
                    requestURL: staleURL,
                    httpMethod: "GET",
                    frame: frame,
                    liveAuthority: try self.liveAuthority()
                ),
                .cancel
            )
        }
        for url in ["http://[::1]:8080/", "http://127.0.0.1/"] {
            XCTAssertEqual(
                JournalWebNavigationPolicy.decision(
                    requestURL: try XCTUnwrap(URL(string: url)),
                    httpMethod: "GET",
                    frame: .main,
                    liveAuthority: try self.liveAuthority()
                ),
                .cancel
            )
        }
    }

    func testCancelsUserinfoAtLiveAuthorityForMainAndNoTarget() throws {
        let requestURL = try XCTUnwrap(URL(string: "https://user:secret@127.0.0.1:8080/"))
        for frame in [JournalWebNavigationPolicy.Frame.main, .noTarget] {
            XCTAssertEqual(
                JournalWebNavigationPolicy.decision(
                    requestURL: requestURL,
                    httpMethod: "GET",
                    frame: frame,
                    liveAuthority: try self.liveAuthority()
                ),
                .cancel
            )
        }
    }

    func testAllowsSubframeNavigation() throws {
        let decision = JournalWebNavigationPolicy.decision(
            requestURL: try XCTUnwrap(URL(string: "https://127.0.0.1:8080/")),
            httpMethod: "GET",
            frame: .subframe,
            liveAuthority: try self.liveAuthority()
        )

        XCTAssertEqual(decision, .allow)
    }

    func testNoTargetOutsideHTTPSSameURLOpensExternallyAndSubframeStaysInPlace() throws {
        let requestURL = try XCTUnwrap(URL(string: "https://example.test/leave?day=today"))
        XCTAssertEqual(
            JournalWebNavigationPolicy.decision(
                requestURL: requestURL,
                httpMethod: "GET",
                frame: .noTarget,
                liveAuthority: try self.liveAuthority()
            ),
            .openExternally(requestURL)
        )
        XCTAssertEqual(
            JournalWebNavigationPolicy.decision(
                requestURL: requestURL,
                httpMethod: "GET",
                frame: .subframe,
                liveAuthority: try self.liveAuthority()
            ),
            .allow
        )
    }

    func testLoopbackIsAllowedWithoutLiveAuthority() throws {
        XCTAssertEqual(
            JournalWebNavigationPolicy.decision(
                requestURL: try XCTUnwrap(URL(string: "http://127.0.0.1/")),
                httpMethod: "GET",
                frame: .main,
                liveAuthority: nil
            ),
            .allow
        )
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
