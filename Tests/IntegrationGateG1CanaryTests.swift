// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

// criterion 5: G1 canary action classification.
@MainActor
final class IntegrationGateG1CanaryTests: XCTestCase {
    func testRemoteConnectedCanaryPassesWithPositiveCoBoundSampleAndBalancedAccounting() {
        let facts = Self.facts()
        let classified = IntegrationGateActionClassifiers.classifyG1(facts)

        XCTAssertEqual(classified.0, .pass)
        XCTAssertEqual(classified.1, .none)
    }

    func testCanaryActionUsesRealHomePulseRoute() {
        XCTAssertEqual(IntegrationGateAction.canary.routeLabel, .homePulse)
        XCTAssertEqual(IntegrationGateAction.canary.routeLabel.path, IntegrationGateConstants.homePulsePath)
    }

    func testLanEndpointFailsClosed() {
        let classified = IntegrationGateActionClassifiers.classifyG1(Self.facts(endpointKind: "lan"))

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .selectedLanEndpoint)
    }

    func testNonTwoHundredCanaryFailsClosed() {
        let classified = IntegrationGateActionClassifiers.classifyG1(Self.facts(httpStatusCode: 503))

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .canaryFailed)
    }

    func testMissingGenerationFailsClosed() {
        let classified = IntegrationGateActionClassifiers.classifyG1(Self.facts(activeGeneration: nil))

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .noActiveGeneration)
    }

    func testUnbalancedGateIssuedRequestCountFailsClosed() {
        let classified = IntegrationGateActionClassifiers.classifyG1(
            Self.facts(
                accounting: IntegrationGateAccounting(
                    activeGateIssuedRequestBaseline: 0,
                    activeGateIssuedRequestFinal: 1,
                    activeGateIssuedRequestReturnedToBaseline: false
                )
            )
        )

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .accountingLeak)
    }

    func testMissingPositiveOwnerTransitionFailsClosed() {
        let classified = IntegrationGateActionClassifiers.classifyG1(
            Self.facts(sample: Self.observation(rawStatus: "reconnecting", publishedStatus: "reconnecting"))
        )

        XCTAssertEqual(classified.0, .fail)
        XCTAssertEqual(classified.1, .missingPositiveTransition)
    }

    private static func facts(
        endpointKind: String = "remote",
        managerConnectionEpoch: UInt64 = 1,
        activeGeneration: UInt64? = 7,
        httpStatusCode: Int? = 200,
        accounting: IntegrationGateAccounting = .zero,
        sample: IntegrationGateSampleObservation? = nil
    ) -> IntegrationGateG1Facts {
        IntegrationGateG1Facts(
            endpointKind: endpointKind,
            managerConnectionEpoch: managerConnectionEpoch,
            activeGeneration: activeGeneration,
            httpStatusCode: httpStatusCode,
            accounting: accounting,
            sample: sample ?? Self.observation()
        )
    }

    private static func observation(
        rawStatus: String = "connectedIdle",
        publishedStatus: String = "connectedIdle",
        coBoundFailure: IntegrationGateReasonCode? = nil
    ) -> IntegrationGateSampleObservation {
        IntegrationGateSampleObservation(
            sample: IntegrationGateSample(
                sampleIndex: 0,
                wallClockUnixMillis: 1,
                monotonicMillis: 1,
                managerConnectionEpoch: 1,
                transportGeneration: 7,
                endpointKind: "remote",
                rawConnectionSyncStatus: rawStatus,
                publishedConnectionSyncStatus: publishedStatus,
                httpStatusCode: 200,
                httpErrorBucket: nil,
                requestDurationMillis: 1,
                reconnectCount: 0,
                activeGateIssuedRequestCount: 0,
                activeProductionUploadCount: 0,
                transportStage: "loopbackReady",
                reconnectReasonBucket: nil,
                canaryGeneration: 7,
                canaryStatusCode: 200,
                canarySkewMillis: 1
            ),
            coBoundFailure: coBoundFailure
        )
    }
}
