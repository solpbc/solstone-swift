// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class JournalLinkTests: XCTestCase {
    func testBothFormsPreserveTheOpaqueTarget() throws {
        for prefix in ["https://go.solstone.app/j#", "solstone://open#"] {
            for sealed in ["a", "AbC-_0123", String(repeating: "z", count: 512)] {
                for suffix in ["", "~173012", "~999999"] {
                    let target = sealed + suffix
                    XCTAssertEqual(JournalLink.route(try XCTUnwrap(URL(string: prefix + target))), .open(path: "/app/open/" + target))
                }
            }
        }
    }

    func testRejectsMalformedTargetsWithoutDecodingThem() throws {
        let targets = ["", "~123456", "abc~", "abc~12345", "abc~1234567", "abc~123456~123456",
                       "abc~１２３４５６", "abc=", "abc+", "abc/def", "%41bc", "abc%7E123456",
                       "abc?x", "abc#def", String(repeating: "a", count: 513)]
        for prefix in ["https://go.solstone.app/j#", "solstone://open#"] {
            for target in targets {
                XCTAssertEqual(JournalLink.route(try XCTUnwrap(URL(string: prefix + target))), .invalid)
            }
        }
    }

    func testRefusesExtraURLPartsAndLeavesOtherRoutesAlone() throws {
        for raw in ["https://go.solstone.app:443/j#abc", "https://u:p@go.solstone.app/j#abc",
                    "https://go.solstone.app/j?x#abc", "solstone://open/extra#abc",
                    "solstone://open?x#abc", "solstone://open:123#abc"] {
            XCTAssertEqual(JournalLink.route(try XCTUnwrap(URL(string: raw))), .invalid)
        }
        for raw in ["https://elsewhere.example/j#abc", "http://go.solstone.app/j#abc",
                    "https://go.solstone.app/p#abc", "solstone://pair#abc", "solstone://journal"] {
            XCTAssertNil(JournalLink.route(try XCTUnwrap(URL(string: raw))))
        }
    }

    @MainActor
    func testPendingTargetSurvivesPairingAndRepeatedOpensAreDistinct() throws {
        let pending = PendingJournalOpenState()
        pending.open(path: "/app/open/AbC-_~123456")
        let first = try XCTUnwrap(pending.request)
        XCTAssertNil(pending.consume(pairingPresented: true))
        XCTAssertEqual(pending.request, first)
        XCTAssertEqual(pending.consume(pairingPresented: false)?.path, first.path)
        XCTAssertNil(pending.request)
        pending.open(path: first.path)
        XCTAssertNotEqual(pending.request?.id, first.id)
        XCTAssertEqual(pending.consume(pairingPresented: false)?.path, first.path)
        pending.open()
        XCTAssertEqual(pending.consume(pairingPresented: false)?.path, "/")
    }
}
