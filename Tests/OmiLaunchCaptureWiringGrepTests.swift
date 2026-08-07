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
        let start = try XCTUnwrap(text.range(of: "func handleAudioData(\n        _ input:"))
        let remainder = text[start.lowerBound...]
        let end = remainder.dropFirst().range(of: "\n    func ")?.lowerBound ?? text.endIndex
        let captureBody = text[start.lowerBound..<end]
        let routePredicate = try XCTUnwrap(captureBody.range(of: "self.audioRoute == .launchCapture"))
        let route = try XCTUnwrap(captureBody.range(of: "launchCaptureIngress.ingest(input)"))
        let captureReturn = try XCTUnwrap(captureBody[route.upperBound...].range(of: "return"))
        let decode = try XCTUnwrap(captureBody.range(of: "self.reassembler.ingest(data, acquiredAt: observedAt, recordSequence: nil)"))
        XCTAssertLessThan(captureBody.distance(from: captureBody.startIndex, to: routePredicate.lowerBound), captureBody.distance(from: captureBody.startIndex, to: route.lowerBound))
        XCTAssertLessThan(captureBody.distance(from: captureBody.startIndex, to: route.lowerBound), captureBody.distance(from: captureBody.startIndex, to: decode.lowerBound))
        XCTAssertLessThan(captureBody.distance(from: captureBody.startIndex, to: captureReturn.lowerBound), captureBody.distance(from: captureBody.startIndex, to: decode.lowerBound))
    }

    func testIngressRequestsDurableGapForFailedAppend() throws {
        let root = StringLiteralGrepSupport.worktreeRoot()
        let text = try String(
            contentsOf: root.appendingPathComponent("Sources/Omi/OmiLaunchCaptureIngress.swift"),
            encoding: .utf8
        )
        let route = try Self.functionSlice(named: "routeAppend", in: text)
        let notRetained = try XCTUnwrap(route.range(of: "case .notRetained:"))
        let visibleGap = try XCTUnwrap(route.range(of: "case .visibleGap"))
        XCTAssertTrue(route[notRetained.lowerBound..<visibleGap.lowerBound].contains("self.routeReservation(writer.reserveGap()"))

        let rejected = try XCTUnwrap(route.range(of: "case .rejected"))
        let pending = try XCTUnwrap(route[rejected.lowerBound...].range(of: "if case .pendingSlotOccupied = reason {"))
        let pendingCall = try XCTUnwrap(route[pending.upperBound...].range(of: "self.routeReservation(writer.reserveGap()"))
        let pendingClose = try XCTUnwrap(route[pending.upperBound...].range(of: "\n            }"))
        XCTAssertLessThan(route.distance(from: route.startIndex, to: pendingCall.lowerBound), route.distance(from: route.startIndex, to: pendingClose.lowerBound))
    }
}

private extension OmiLaunchCaptureWiringGrepTests {
    static func functionSlice(named name: String, in text: String) throws -> Substring {
        let start = try XCTUnwrap(text.range(of: "func \(name)"))
        let remainder = text[start.lowerBound...]
        let end = remainder.dropFirst().range(
            of: #"\n    (?:(?:private|fileprivate|internal|public|open|static|class|final)\s+)*func "#,
            options: .regularExpression
        )?.lowerBound ?? text.endIndex
        return text[start.lowerBound..<end]
    }
}
