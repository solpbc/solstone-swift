// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class OmiLaunchCaptureWiringGrepTests: XCTestCase {
    func testProductionConstructionArmsBeforeManagerConstruction() throws {
        let root = StringLiteralGrepSupport.worktreeRoot()
        let text = try String(
            contentsOf: root.appendingPathComponent("Sources/Omi/OmiLaunchCaptureIngressFactory.swift"),
            encoding: .utf8
        )
        let arm = try XCTUnwrap(text.range(of: "_ = ingress.arm()"))
        let construct = try XCTUnwrap(text.range(of: "return OmiSourceManager("))
        XCTAssertLessThan(text.distance(from: text.startIndex, to: arm.lowerBound), text.distance(from: text.startIndex, to: construct.lowerBound))
    }

    func testManagerRoutesAudioToLaunchCaptureBeforeDecode() throws {
        let root = StringLiteralGrepSupport.worktreeRoot()
        let text = try String(
            contentsOf: root.appendingPathComponent("Sources/Omi/OmiSourceManager.swift"),
            encoding: .utf8
        )
        let body = try Self.functionSlice(named: "handleAudioData", in: text)
        let route = try XCTUnwrap(body.range(of: "launchCaptureIngress.ingest(data)"))
        let decode = try XCTUnwrap(body.range(of: "self.reassembler.ingest(data)"))
        XCTAssertLessThan(body.distance(from: body.startIndex, to: route.lowerBound), body.distance(from: body.startIndex, to: decode.lowerBound))
    }

    func testIngressRequestsDurableGapForFailedAppend() throws {
        let root = StringLiteralGrepSupport.worktreeRoot()
        let text = try String(
            contentsOf: root.appendingPathComponent("Sources/Omi/OmiLaunchCaptureIngress.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(text.contains("_ = writer.reserveGap()"))
        XCTAssertTrue(text.contains("case .notRetained:"))
        XCTAssertTrue(text.contains("case .pendingSlotOccupied"))
    }
}

private extension OmiLaunchCaptureWiringGrepTests {
    static func functionSlice(named name: String, in text: String) throws -> Substring {
        let start = try XCTUnwrap(text.range(of: "func \(name)"))
        let remainder = text[start.lowerBound...]
        let end = remainder.dropFirst().range(of: "\n    func ")?.lowerBound ?? text.endIndex
        return text[start.lowerBound..<end]
    }
}
