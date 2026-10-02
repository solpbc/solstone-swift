// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import WebKit
import XCTest

@MainActor
final class JournalWebHostContractTests: XCTestCase {
    func testAppBundleContractConfiguresUserAgentAndDocumentStartScript() throws {
        let bundle = Bundle(for: AppDelegate.self)
        let contractURL = try XCTUnwrap(bundle.url(forResource: "host-contract", withExtension: "json"))
        let data = try Data(contentsOf: contractURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let expectedProduct = try XCTUnwrap(json["user_agent_product"] as? String)
        let expectedScript = try XCTUnwrap(json["initialization_script"] as? String)

        let configuration = JournalWebHostContractConfiguration.make(bundle: bundle)
        XCTAssertEqual(configuration.applicationNameForUserAgent, expectedProduct)
        let scripts = configuration.userContentController.userScripts
        XCTAssertEqual(scripts.count, 1)
        XCTAssertEqual(scripts.first?.source, expectedScript)
        XCTAssertEqual(scripts.first?.injectionTime, .atDocumentStart)
        XCTAssertEqual(scripts.first?.isForMainFrameOnly, true)
    }

    func testTestBundleWithoutContractUsesEmptyConfigurationAndOneDiagnostic() {
        let bundle = Bundle(for: JournalWebHostContractTests.self)
        XCTAssertNil(bundle.url(forResource: "host-contract", withExtension: "json"))
        let log = DiagnosticLog()

        let configuration = JournalWebHostContractConfiguration.make(bundle: bundle, diagnosticLog: log)

        XCTAssertNil(configuration.applicationNameForUserAgent)
        XCTAssertTrue(configuration.userContentController.userScripts.isEmpty)
        XCTAssertEqual(log.events.count, 1)
        XCTAssertEqual(log.events.first?.category, .journal)
        XCTAssertEqual(log.events.first?.message, "contract_unavailable")
        XCTAssertEqual(log.events.first?.detail, "reason=missing")
    }

    func testMalformedAndUnsupportedPayloadsInstallNothingAndLogOnce() {
        let versionTwo = Data(
            #"{"version":2,"user_agent_product":"x","javascript_capability":"x","initialization_script":"x"}"#.utf8
        )
        let payloads: [(Data, String)] = [
            (Data("{".utf8), "reason=malformed"),
            (versionTwo, "reason=unsupported"),
        ]

        for (data, expectedReason) in payloads {
            let log = DiagnosticLog()
            let configuration = JournalWebHostContractConfiguration.decode(data, diagnosticLog: log)

            XCTAssertNil(configuration.applicationNameForUserAgent)
            XCTAssertTrue(configuration.userContentController.userScripts.isEmpty)
            XCTAssertEqual(log.events.count, 1)
            XCTAssertEqual(log.events.first?.category, .journal)
            XCTAssertEqual(log.events.first?.message, "contract_unavailable")
            XCTAssertEqual(log.events.first?.detail, expectedReason)
        }
    }
}
