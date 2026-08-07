// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

#if DEBUG && targetEnvironment(simulator)
private let log = Logger(subsystem: "app.solstone.swift", category: "integration-gate-sampler")

struct IntegrationGateCanaryRecord: Sendable, Equatable {
    var generationBefore: UInt64?
    var generationAfter: UInt64?
    var statusCode: Int?
    var completedAtMonotonicMillis: UInt64
    var durationMillis: UInt64
}

struct IntegrationGateSampleObservation: Sendable, Equatable {
    var sample: IntegrationGateSample
    var coBoundFailure: IntegrationGateReasonCode?
}

@MainActor
final class IntegrationGateSampler {
    private let tunnelManager: TunnelManager
    private let connectionSyncModel: ConnectionSyncModel
    private let httpClient: IntegrationGateHTTPClient
    private let clock: any ObserverClock
    private let monotonicStart: Date

    init(
        tunnelManager: TunnelManager,
        connectionSyncModel: ConnectionSyncModel,
        httpClient: IntegrationGateHTTPClient,
        clock: any ObserverClock = SystemObserverClock()
    ) {
        self.tunnelManager = tunnelManager
        self.connectionSyncModel = connectionSyncModel
        self.httpClient = httpClient
        self.clock = clock
        self.monotonicStart = clock.now()
    }

    func captureSample(
        sampleIndex: UInt64,
        httpOutcome: IntegrationGateHTTPOutcome? = nil,
        boundCanary: IntegrationGateCanaryRecord? = nil
    ) async -> IntegrationGateSampleObservation {
        let generationBeforeCanary = tunnelManager.transportGenerationSnapshot.activeGeneration
        let inputs = connectionSyncModel.integrationGateCurrentInputs()
        let rawStatus = ConnectionSyncStatus.derive(inputs)
        let publishedStatus = connectionSyncModel.status
        let sampleGeneration = tunnelManager.transportGenerationSnapshot.activeGeneration
        let sampleMonotonic = self.monotonicMillis()
        let needsCanary = rawStatus.integrationGateIsPositive || publishedStatus.integrationGateIsPositive

        var canary = boundCanary
        if needsCanary, canary == nil {
            let outcome = await httpClient.canary(routeLabel: .networkStatus)
            canary = IntegrationGateCanaryRecord(
                generationBefore: generationBeforeCanary,
                generationAfter: tunnelManager.transportGenerationSnapshot.activeGeneration,
                statusCode: outcome.statusCode,
                completedAtMonotonicMillis: self.monotonicMillis(),
                durationMillis: outcome.durationMillis
            )
        }
        let coBoundFailure = needsCanary
            ? Self.coBoundFailure(canary: canary, sampleGeneration: sampleGeneration, sampleMonotonic: sampleMonotonic)
            : nil

        return IntegrationGateSampleObservation(
            sample: IntegrationGateSample(
                sampleIndex: sampleIndex,
                wallClockUnixMillis: Self.unixMillis(clock.now()),
                monotonicMillis: sampleMonotonic,
                managerConnectionEpoch: tunnelManager.connectionEpoch,
                transportGeneration: sampleGeneration,
                endpointKind: tunnelManager.state.integrationGateEndpointKind,
                rawConnectionSyncStatus: rawStatus.integrationGateExportLabel,
                publishedConnectionSyncStatus: publishedStatus.integrationGateExportLabel,
                httpStatusCode: httpOutcome?.statusCode,
                httpErrorBucket: httpOutcome?.errorBucket,
                requestDurationMillis: httpOutcome?.durationMillis,
                reconnectCount: UInt64(max(tunnelManager.reconnectCount, 0)),
                activeGateIssuedRequestCount: httpClient.activeGateIssuedRequestCount,
                activeProductionUploadCount: tunnelManager.integrationGateActiveProductionUploadCount,
                transportStage: tunnelManager.integrationGateLastTransportStage?.integrationGateExportLabel,
                reconnectReasonBucket: tunnelManager.integrationGateLastReconnectReasonBucket?.exportLabel,
                canaryGeneration: canary?.generationBefore,
                canaryStatusCode: canary?.statusCode,
                canarySkewMillis: canary.map {
                    Self.distanceMillis($0.completedAtMonotonicMillis, sampleMonotonic)
                }
            ),
            coBoundFailure: coBoundFailure
        )
    }

    func collectObservationWindow(sampleCount: Int, cadence: Duration = .seconds(1)) async -> [IntegrationGateSampleObservation] {
        var observations: [IntegrationGateSampleObservation] = []
        observations.reserveCapacity(sampleCount)
        for index in 0..<sampleCount {
            observations.append(await self.captureSample(sampleIndex: UInt64(index)))
            if index < sampleCount - 1 {
                try? await clock.sleep(for: cadence)
            }
        }
        return observations
    }

    private func monotonicMillis() -> UInt64 {
        UInt64(max(0, Int64((clock.now().timeIntervalSince1970 - monotonicStart.timeIntervalSince1970) * 1_000)))
    }

    private static func unixMillis(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }

    private static func distanceMillis(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs >= rhs ? lhs - rhs : rhs - lhs
    }

    private static func coBoundFailure(
        canary: IntegrationGateCanaryRecord?,
        sampleGeneration: UInt64?,
        sampleMonotonic: UInt64
    ) -> IntegrationGateReasonCode? {
        guard let canary else {
            return .canaryMissing
        }
        guard canary.statusCode == 200 else {
            return .canaryFailed
        }
        guard canary.generationBefore == sampleGeneration,
              canary.generationAfter == sampleGeneration
        else {
            return .canaryGenerationMismatch
        }
        guard Self.distanceMillis(canary.completedAtMonotonicMillis, sampleMonotonic) <= IntegrationGateConstants.canarySkewMilliseconds else {
            return .canarySkewExceeded
        }
        return nil
    }
}

extension ConnectionSyncStatus {
    var integrationGateExportLabel: String {
        switch self {
        case .offline:
            return "offline"
        case .connecting:
            return "connecting"
        case .waitingForHome:
            return "waitingForHome"
        case .reconnecting:
            return "reconnecting"
        case .unreachable:
            return "unreachable"
        case .connectedIdle:
            return "connectedIdle"
        case .connectedWaiting:
            return "connectedWaiting"
        case .connectedTransferring:
            return "connectedTransferring"
        }
    }

    var integrationGateIsPositive: Bool {
        switch self {
        case .connectedIdle, .connectedWaiting, .connectedTransferring:
            return true
        case .offline, .connecting, .waitingForHome, .reconnecting, .unreachable:
            return false
        }
    }
}

extension TunnelState {
    var integrationGateEndpointKind: String {
        switch self {
        case .connected(_, let endpoint):
            return endpoint.integrationGateExportLabel
        case .disconnected, .connecting, .waitingForHome, .error:
            return "none"
        }
    }
}

extension ConnectionEndpoint {
    var integrationGateExportLabel: String {
        switch self {
        case .lan:
            return "lan"
        case .remote:
            return "remote"
        }
    }
}

extension TransportStage {
    var integrationGateExportLabel: String {
        switch self {
        case .preparingCandidates:
            return "preparingCandidates"
        case .racing:
            return "racing"
        case .awaitingBroker:
            return "awaitingBroker"
        case .tlsHandshaking:
            return "tlsHandshaking"
        case .muxReady:
            return "muxReady"
        case .loopbackReady:
            return "loopbackReady"
        case .failed:
            return "failed"
        case .attemptEvent:
            return "attemptEvent"
        case .attemptUpdatesFinished:
            return "attemptUpdatesFinished"
        case .attemptUpdatesUnavailable:
            return "attemptUpdatesUnavailable"
        }
    }
}
#endif
