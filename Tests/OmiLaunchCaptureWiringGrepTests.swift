// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class OmiLaunchCaptureWiringGrepTests: XCTestCase {
    func testProductionConstructionArmsBeforeManagerConstruction() throws {
        let root = StringLiteralGrepSupport.worktreeRoot()
        let factoryText = try String(
            contentsOf: root.appendingPathComponent("Sources/Omi/OmiLaunchCaptureIngressFactory.swift"),
            encoding: .utf8
        )
        let arm = try XCTUnwrap(factoryText.range(of: "_ = ingress.arm()"))
        let construct = try XCTUnwrap(factoryText.range(of: "return OmiSourceManager("))
        XCTAssertLessThan(factoryText.distance(from: factoryText.startIndex, to: arm.lowerBound), factoryText.distance(from: factoryText.startIndex, to: construct.lowerBound))

        let appText = try String(
            contentsOf: root.appendingPathComponent("Sources/SolstoneSwiftApp.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(appText.contains("makeOmiSourceManager("))
        XCTAssertNil(appText.range(of: "(?<!make)OmiSourceManager\\(", options: .regularExpression))
    }

    func testManagerRoutesAudioToLaunchCaptureBeforeDecode() throws {
        let root = StringLiteralGrepSupport.worktreeRoot()
        let text = try String(
            contentsOf: root.appendingPathComponent("Sources/Omi/OmiSourceManager.swift"),
            encoding: .utf8
        )
        let body = try Self.functionSlice(named: "handleAudioData", in: text)
        let route = try XCTUnwrap(body.range(of: "launchCaptureIngress.ingest(data)"))
        let captureReturn = try XCTUnwrap(body[route.upperBound...].range(of: "return"))
        let decode = try XCTUnwrap(body.range(of: "self.reassembler.ingest(data, acquiredAt: observedAt, recordSequence: nil)"))
        XCTAssertLessThan(body.distance(from: body.startIndex, to: route.lowerBound), body.distance(from: body.startIndex, to: decode.lowerBound))
        XCTAssertLessThan(body.distance(from: body.startIndex, to: captureReturn.lowerBound), body.distance(from: body.startIndex, to: decode.lowerBound))
    }

    func testIngressRequestsDurableGapForFailedAppend() throws {
        let root = StringLiteralGrepSupport.worktreeRoot()
        let text = try String(
            contentsOf: root.appendingPathComponent("Sources/Omi/OmiLaunchCaptureIngress.swift"),
            encoding: .utf8
        )
        let route = try Self.functionSlice(named: "route", in: text)
        let notRetained = try XCTUnwrap(route.range(of: "case .notRetained:"))
        let visibleGap = try XCTUnwrap(route.range(of: "case .visibleGap:"))
        XCTAssertTrue(route[notRetained.lowerBound..<visibleGap.lowerBound].contains("_ = writer.reserveGap()"))

        let rejected = try XCTUnwrap(route.range(of: "case .rejected"))
        let pending = try XCTUnwrap(route[rejected.lowerBound...].range(of: "if case .pendingSlotOccupied = reason {"))
        let pendingCall = try XCTUnwrap(route[pending.upperBound...].range(of: "_ = writer.reserveGap()"))
        let pendingClose = try XCTUnwrap(route[pending.upperBound...].range(of: "\n            }"))
        XCTAssertLessThan(route.distance(from: route.startIndex, to: pendingCall.lowerBound), route.distance(from: route.startIndex, to: pendingClose.lowerBound))
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
