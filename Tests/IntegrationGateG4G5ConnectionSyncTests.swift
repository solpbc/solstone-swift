// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

// criterion 8: G4/G5 connection-sync observation and co-bound canary classification.
@MainActor
final class IntegrationGateG4G5ConnectionSyncTests: XCTestCase {
    func testReachabilityMappingCoversAllConnectionSyncStatuses() {
        XCTAssertFalse(isJournalReachable(.offline))
        XCTAssertFalse(isJournalReachable(.connecting))
        XCTAssertFalse(isJournalReachable(.waitingForHome))
        XCTAssertFalse(isJournalReachable(.reconnecting))
        XCTAssertFalse(isJournalReachable(.unreachable))
        XCTAssertTrue(isJournalReachable(.connectedIdle))
        XCTAssertTrue(isJournalReachable(.connectedWaiting))
        XCTAssertTrue(isJournalReachable(.connectedTransferring))
    }

    func testReconnectWindowHealthyDegradedRecoveredPasses() {
        let classified = IntegrationGateActionClassifiers.classifyG4(
            IntegrationGateWindowFacts(observations: [
                Self.observation("connectedIdle"),
                Self.observation("reconnecting"),
                Self.observation("connectedIdle"),
            ])
        )

        XCTAssertEqual(classified.0, .pass)
        XCTAssertEqual(classified.1, .none)
    }

    func testReconnectWindowAcceptsNamedOfflineDegradation() {
        let classified = IntegrationGateActionClassifiers.classifyG4(
            IntegrationGateWindowFacts(observations: [
                Self.observation("connectedIdle"),
                Self.observation("offline"),
                Self.observation("connectedIdle"),
            ])
        )

        XCTAssertEqual(classified.0, .pass)
        XCTAssertEqual(classified.1, .none)
    }

    func testTransferWindowTruthBackedHealthyObservationPasses() {
        let classified = IntegrationGateActionClassifiers.classifyG5(
            IntegrationGateWindowFacts(observations: [
                Self.observation("connectedIdle"),
            ])
        )

        XCTAssertEqual(classified.0, .pass)
        XCTAssertEqual(classified.1, .none)
    }

    func testTransferWindowWithoutHealthyObservationFails() {
        let classified = IntegrationGateActionClassifiers.classifyG5(
            IntegrationGateWindowFacts(observations: [
                Self.observation("offline"),
            ])
        )

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .missingHealthyTransition)
    }

    func testUnknownStateFailsClosedInsteadOfDefaultingNonhealthy() {
        let classified = IntegrationGateActionClassifiers.classifyG4(
            IntegrationGateWindowFacts(observations: [
                Self.observation("connectedPaused"),
            ])
        )

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .unknownConnectionSyncStatus)
    }

    func testReconnectWindowFailsClosedWhenLanEndpointIsSelected() {
        let classified = IntegrationGateActionClassifiers.classifyG4(
            IntegrationGateWindowFacts(observations: [
                Self.observation("connectedIdle", endpointKind: "lan"),
                Self.observation("reconnecting", endpointKind: "lan"),
                Self.observation("connectedIdle", endpointKind: "lan"),
            ])
        )

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .selectedLanEndpoint)
    }

    func testTransferWindowFailsClosedWhenLanEndpointIsSelected() {
        let classified = IntegrationGateActionClassifiers.classifyG5(
            IntegrationGateWindowFacts(observations: [
                Self.observation("connectedTransferring", endpointKind: "lan"),
                Self.observation("connectedWaiting", endpointKind: "lan"),
            ])
        )

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .selectedLanEndpoint)
    }

    func testPositiveSampleRequiresSameGenerationTwoHundredCanaryInsideSkew() {
        for reason in [IntegrationGateReasonCode.canaryMissing, .canaryGenerationMismatch, .canarySkewExceeded] {
            let classified = IntegrationGateActionClassifiers.classifyG4(
                IntegrationGateWindowFacts(observations: [
                    Self.observation("connectedIdle", coBoundFailure: reason),
                ])
            )
            XCTAssertEqual(classified.0, .fail)
            XCTAssertEqual(classified.1, reason)
        }
    }

    func testOwnerVisibleConnectionCopyUsesConnectionSyncModel() throws {
        let rootShell = try Self.sourceText("Sources/RootShellView.swift")
        XCTAssertTrue(rootShell.contains("private var dayHomeJournalState: DayHomeJournalState"))
        XCTAssertTrue(rootShell.contains("switch self.connectionSyncModel.status"))
        XCTAssertTrue(rootShell.contains("case .connectedIdle, .connectedWaiting, .connectedTransferring:"))
        XCTAssertTrue(rootShell.contains("return .linkedOnline"))

        let diagnostics = try Self.sourceText("Sources/Diagnostics/DiagnosticsView.swift")
        XCTAssertTrue(diagnostics.contains("connectionSyncModel.status"))
    }

    func testReconnectWindowPublishesProgressForCoordinatorFaultTiming() throws {
        let actions = try Self.sourceText("Sources/IntegrationGate/IntegrationGateActions.swift")
        let start = try XCTUnwrap(actions.range(of: "private func runG4()"))
        let end = try XCTUnwrap(
            actions.range(of: "private func runG5()", range: start.upperBound..<actions.endIndex)
        )
        let runG4 = actions[start.lowerBound..<end.lowerBound]

        XCTAssertTrue(runG4.contains("try self.writeRunning("))
        XCTAssertTrue(runG4.contains("samples: observations.map(\\.sample)"))
        XCTAssertTrue(runG4.contains("reason: .runningRecordWriteFailed"))
    }

    private static func observation(
        _ rawStatus: String,
        publishedStatus: String? = nil,
        endpointKind: String = "remote",
        coBoundFailure: IntegrationGateReasonCode? = nil
    ) -> IntegrationGateSampleObservation {
        let published = publishedStatus ?? rawStatus
        return IntegrationGateSampleObservation(
            sample: IntegrationGateSample(
                sampleIndex: 0,
                wallClockUnixMillis: 1,
                monotonicMillis: 1,
                managerConnectionEpoch: 1,
                transportGeneration: 2,
                endpointKind: endpointKind,
                rawConnectionSyncStatus: rawStatus,
                publishedConnectionSyncStatus: published,
                httpStatusCode: nil,
                httpErrorBucket: nil,
                requestDurationMillis: nil,
                reconnectCount: 0,
                activeGateIssuedRequestCount: 0,
                activeProductionUploadCount: 0,
                transportStage: nil,
                reconnectReasonBucket: nil,
                canaryGeneration: rawStatus.hasPrefix("connected") ? 2 : nil,
                canaryStatusCode: rawStatus.hasPrefix("connected") ? 200 : nil,
                canarySkewMillis: rawStatus.hasPrefix("connected") ? 1 : nil
            ),
            coBoundFailure: coBoundFailure
        )
    }

    private static func sourceText(_ relativePath: String) throws -> String {
        let url = StringLiteralGrepSupport.worktreeRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
