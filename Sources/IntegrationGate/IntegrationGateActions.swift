// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

#if DEBUG && targetEnvironment(simulator)
private let log = Logger(subsystem: "app.solstone.swift", category: "integration-gate-actions")

struct IntegrationGateActionRunResult: Sendable, Equatable {
    var verdict: IntegrationGateVerdict
    var reasonCode: IntegrationGateReasonCode
    var httpOutcome: IntegrationGateHTTPOutcome?
    var accounting: IntegrationGateAccounting
    var samples: [IntegrationGateSample]
    var generation: IntegrationGateResultGeneration
    var transportStages: [String]
    var reconnectReasonBuckets: [String]
}

struct IntegrationGateG1Facts: Sendable, Equatable {
    var endpointKind: String
    var managerConnectionEpoch: UInt64
    var activeGeneration: UInt64?
    var httpStatusCode: Int?
    var accounting: IntegrationGateAccounting
    var sample: IntegrationGateSampleObservation?
}

struct IntegrationGateG2Facts: Sendable, Equatable {
    var response: IntegrationGateRangeResponse
    var expectedContentLength: UInt64
    var expectedSHA256Hex: String
}

struct IntegrationGateG3Facts: Sendable, Equatable {
    var oldGeneration: UInt64?
    var firstProgressBytes: UInt64
    var expectedContentLength: UInt64
    var firstAttemptCompleted: Bool
    var firstAttemptTerminated: Bool
    var activeGateIssuedRequestBaseline: Int
    var activeGateIssuedRequestAfterFirstAttempt: Int
    var lastClosedGeneration: UInt64?
    var retryStartedActiveRequestCount: Int
    var retryGeneration: UInt64?
    var retryResponse: IntegrationGateRangeResponse?
    var activeGateIssuedRequestFinal: Int
    var expectedSHA256Hex: String
}

struct IntegrationGateWindowFacts: Sendable, Equatable {
    var observations: [IntegrationGateSampleObservation]
}

enum IntegrationGateActionClassifiers {
    static func classifyG1(_ facts: IntegrationGateG1Facts) -> (IntegrationGateVerdict, IntegrationGateReasonCode) {
        if facts.endpointKind == "lan" {
            return (.fail, .selectedLanEndpoint)
        }
        guard facts.endpointKind == "remote", facts.managerConnectionEpoch > 0 else {
            return (.fail, .noActiveConnection)
        }
        guard facts.activeGeneration != nil else {
            return (.fail, .noActiveGeneration)
        }
        guard facts.httpStatusCode == 200 else {
            return (.fail, .canaryFailed)
        }
        guard facts.accounting.activeGateIssuedRequestReturnedToBaseline else {
            return (.fail, .accountingLeak)
        }
        guard let sample = facts.sample else {
            return (.fail, .missingPositiveTransition)
        }
        if let failure = sample.coBoundFailure {
            return (.fail, failure)
        }
        guard sample.sample.rawConnectionSyncStatus.integrationGateStatusIsPositive ||
              sample.sample.publishedConnectionSyncStatus.integrationGateStatusIsPositive
        else {
            return (.fail, .missingPositiveTransition)
        }
        return (.pass, .none)
    }

    static func classifyG2(_ facts: IntegrationGateG2Facts) -> (IntegrationGateVerdict, IntegrationGateReasonCode) {
        if let errorBucket = facts.response.outcome.errorBucket,
           let reason = IntegrationGateReasonCode(rawValue: errorBucket) {
            return (.fail, reason)
        }
        guard facts.response.outcome.statusCode == 206 else {
            return (.fail, .rangeStatusMismatch)
        }
        guard let contentRange = facts.response.contentRange else {
            return (.fail, .contentRangeMalformed)
        }
        guard contentRange.total == facts.expectedContentLength else {
            return (.fail, .contentRangeMismatch)
        }
        guard facts.response.outcome.byteCount == contentRange.byteCount else {
            return (.fail, .byteCountMismatch)
        }
        guard facts.response.outcome.byteCount > UInt64(IntegrationGateConstants.gateMuxInitialCreditBytes) else {
            return (.fail, .rangeTooSmall)
        }
        guard facts.response.sha256Hex == facts.expectedSHA256Hex else {
            return (.fail, .digestMismatch)
        }
        return (.pass, .none)
    }

    static func classifyG3(_ facts: IntegrationGateG3Facts) -> (IntegrationGateVerdict, IntegrationGateReasonCode) {
        guard let oldGeneration = facts.oldGeneration else {
            return (.fail, .noActiveGeneration)
        }
        if facts.firstAttemptCompleted {
            return (.fail, .completedFirstAttempt)
        }
        guard facts.firstProgressBytes > UInt64(IntegrationGateConstants.gateMuxInitialCreditBytes),
              facts.firstProgressBytes < facts.expectedContentLength
        else {
            return (.fail, .earlyFault)
        }
        guard facts.firstAttemptTerminated else {
            return (.fail, .hungInterruption)
        }
        guard facts.activeGateIssuedRequestAfterFirstAttempt == facts.activeGateIssuedRequestBaseline else {
            return (.fail, .releaseProofMissing)
        }
        guard facts.lastClosedGeneration == oldGeneration else {
            return (.fail, .oldGenerationNotClosed)
        }
        guard facts.retryStartedActiveRequestCount == facts.activeGateIssuedRequestBaseline else {
            return (.fail, .overlappingRetry)
        }
        guard let retryGeneration = facts.retryGeneration, retryGeneration > oldGeneration else {
            return (.fail, .sameGenerationRetry)
        }
        guard let retryResponse = facts.retryResponse else {
            return (.fail, .recoveryFailed)
        }
        let retryVerdict = Self.classifyG2(
            IntegrationGateG2Facts(
                response: retryResponse,
                expectedContentLength: facts.expectedContentLength,
                expectedSHA256Hex: facts.expectedSHA256Hex
            )
        )
        guard retryVerdict.0 == .pass else {
            return retryVerdict
        }
        guard facts.activeGateIssuedRequestFinal == facts.activeGateIssuedRequestBaseline else {
            return (.fail, .accountingLeak)
        }
        return (.pass, .none)
    }

    static func classifyG4(_ facts: IntegrationGateWindowFacts) -> (IntegrationGateVerdict, IntegrationGateReasonCode) {
        let samples = facts.observations
        if let failure = Self.firstCoBoundFailure(in: samples) {
            return (.fail, failure)
        }
        guard samples.allSatisfy({ $0.sample.rawConnectionSyncStatus.integrationGateStatusIsKnown }) else {
            return (.fail, .unknownConnectionSyncStatus)
        }
        guard let healthyIndex = samples.firstIndex(where: { $0.sample.rawConnectionSyncStatus.integrationGateStatusIsPositive }) else {
            return (.fail, .missingHealthyTransition)
        }
        guard let degradedIndex = samples[healthyIndex...].firstIndex(where: { $0.sample.rawConnectionSyncStatus == "reconnecting" }) else {
            return (.fail, .missingDegradedTransition)
        }
        guard samples[degradedIndex...].contains(where: { $0.sample.rawConnectionSyncStatus.integrationGateStatusIsPositive }) else {
            return (.fail, .missingRecoveredTransition)
        }
        return (.pass, .none)
    }

    static func classifyG5(_ facts: IntegrationGateWindowFacts) -> (IntegrationGateVerdict, IntegrationGateReasonCode) {
        let samples = facts.observations
        if let failure = Self.firstCoBoundFailure(in: samples) {
            return (.fail, failure)
        }
        guard samples.allSatisfy({ $0.sample.rawConnectionSyncStatus.integrationGateStatusIsKnown }) else {
            return (.fail, .unknownConnectionSyncStatus)
        }
        guard let healthyIndex = samples.firstIndex(where: { $0.sample.rawConnectionSyncStatus == "connectedTransferring" }) else {
            return (.fail, .missingHealthyTransition)
        }
        guard samples[healthyIndex...].last?.sample.rawConnectionSyncStatus == "connectedWaiting" else {
            return (.fail, .terminalDegradedMissing)
        }
        return (.pass, .none)
    }

    private static func firstCoBoundFailure(in observations: [IntegrationGateSampleObservation]) -> IntegrationGateReasonCode? {
        for observation in observations where observation.coBoundFailure != nil {
            return observation.coBoundFailure
        }
        return nil
    }
}

@MainActor
final class IntegrationGateActions {
    private let tunnelManager: TunnelManager
    private let httpClient: IntegrationGateHTTPClient
    private let sampler: IntegrationGateSampler
    private let clock: any ObserverClock
    private let writeRunning: @MainActor (IntegrationGateActionRunResult) throws -> Void

    init(
        tunnelManager: TunnelManager,
        httpClient: IntegrationGateHTTPClient,
        sampler: IntegrationGateSampler,
        clock: any ObserverClock = SystemObserverClock(),
        writeRunning: @escaping @MainActor (IntegrationGateActionRunResult) throws -> Void
    ) {
        self.tunnelManager = tunnelManager
        self.httpClient = httpClient
        self.sampler = sampler
        self.clock = clock
        self.writeRunning = writeRunning
    }

    func run(manifest: IntegrationGateManifest) async -> IntegrationGateActionRunResult {
        switch manifest.action {
        case .canary:
            return await self.runG1()
        case .rangeHash:
            return await self.runG2(manifest: manifest)
        case .generationRetry:
            return await self.runG3(manifest: manifest)
        case .syncReconnectWindow:
            return await self.runG4()
        case .syncTransferWindow:
            return await self.runG5()
        }
    }

    private func runG1() async -> IntegrationGateActionRunResult {
        let baseline = httpClient.activeGateIssuedRequestCount
        await self.ensureConnected()
        if let candidateFailure = self.relayOnlyIntegrityFailure() {
            return self.result(verdict: .fail, reason: candidateFailure, accountingBaseline: baseline)
        }
        let generation = tunnelManager.transportGenerationSnapshot.activeGeneration
        let (canaryRecord, outcome) = await sampler.canaryRecord()
        let final = httpClient.activeGateIssuedRequestCount
        let accounting = self.accounting(baseline: baseline, final: final)
        let sample = await sampler.captureSample(sampleIndex: 0, httpOutcome: outcome, boundCanary: canaryRecord)
        let facts = IntegrationGateG1Facts(
            endpointKind: tunnelManager.state.integrationGateEndpointKind,
            managerConnectionEpoch: tunnelManager.connectionEpoch,
            activeGeneration: generation,
            httpStatusCode: outcome.statusCode,
            accounting: accounting,
            sample: sample
        )
        let classified = IntegrationGateActionClassifiers.classifyG1(facts)
        return self.result(
            verdict: classified.0,
            reason: classified.1,
            httpOutcome: outcome,
            accounting: accounting,
            samples: [sample.sample]
        )
    }

    private func runG2(manifest: IntegrationGateManifest) async -> IntegrationGateActionRunResult {
        let baseline = httpClient.activeGateIssuedRequestCount
        await self.ensureConnected()
        if let candidateFailure = self.relayOnlyIntegrityFailure() {
            return self.result(verdict: .fail, reason: candidateFailure, accountingBaseline: baseline)
        }
        guard let rangeStart = manifest.rangeStart,
              let rangeLength = manifest.rangeLength,
              let expectedLength = manifest.expectedContentLength,
              let expectedDigest = manifest.expectedSHA256Hex
        else {
            return self.result(verdict: .fail, reason: .invalidRange, accountingBaseline: baseline)
        }
        do {
            let response = try await httpClient.rangedStreamingRequest(
                routeLabel: manifest.action.routeLabel,
                rangeStart: rangeStart,
                rangeLength: rangeLength,
                expectedTotal: expectedLength
            )
            let accounting = self.accounting(baseline: baseline, final: httpClient.activeGateIssuedRequestCount)
            let classified = IntegrationGateActionClassifiers.classifyG2(
                IntegrationGateG2Facts(
                    response: response,
                    expectedContentLength: expectedLength,
                    expectedSHA256Hex: expectedDigest
                )
            )
            return self.result(
                verdict: classified.0,
                reason: classified.1,
                httpOutcome: response.outcome,
                accounting: accounting
            )
        } catch let error as IntegrationGateValidationError {
            return self.result(verdict: .fail, reason: error.reasonCode, accountingBaseline: baseline)
        } catch is CancellationError {
            return self.result(verdict: .fail, reason: .requestTimedOut, accountingBaseline: baseline)
        } catch {
            return self.result(verdict: .fail, reason: .requestFailed, accountingBaseline: baseline)
        }
    }

    private func runG3(manifest: IntegrationGateManifest) async -> IntegrationGateActionRunResult {
        let baseline = httpClient.activeGateIssuedRequestCount
        await self.ensureConnected()
        if let candidateFailure = self.relayOnlyIntegrityFailure() {
            return self.result(verdict: .fail, reason: candidateFailure, accountingBaseline: baseline)
        }
        guard let expectedLength = manifest.expectedContentLength,
              let expectedDigest = manifest.expectedSHA256Hex
        else {
            return self.result(verdict: .fail, reason: .invalidDigest, accountingBaseline: baseline)
        }
        let oldGeneration = tunnelManager.transportGenerationSnapshot.activeGeneration
        var firstProgressBytes: UInt64 = 0
        var runningPublished = false
        var firstCompleted = false
        do {
            _ = try await httpClient.rangedStreamingRequest(
                routeLabel: manifest.action.routeLabel,
                rangeStart: 0,
                rangeLength: expectedLength,
                expectedTotal: expectedLength,
                progress: { [weak self] byteCount in
                    guard let self, !runningPublished else { return }
                    guard byteCount > UInt64(IntegrationGateConstants.gateMuxInitialCreditBytes),
                          byteCount < expectedLength
                    else {
                        return
                    }
                    firstProgressBytes = byteCount
                    runningPublished = true
                    try? self.writeRunning(
                        self.result(
                            verdict: .error,
                            reason: .none,
                            httpOutcome: IntegrationGateHTTPOutcome(
                                statusCode: nil,
                                errorBucket: nil,
                                byteCount: byteCount,
                                durationMillis: 0
                            ),
                            accounting: self.accounting(baseline: baseline, final: self.httpClient.activeGateIssuedRequestCount)
                        )
                    )
                }
            )
            firstCompleted = true
        } catch {
            if firstProgressBytes == 0, runningPublished {
                firstProgressBytes = UInt64(IntegrationGateConstants.gateMuxInitialCreditBytes) + 1
            }
        }
        let afterFirstCount = httpClient.activeGateIssuedRequestCount
        let oldClosed = tunnelManager.transportGenerationSnapshot.lastClosedGeneration
        let retryGeneration = await self.waitForNewGeneration(after: oldGeneration)
        let retryStartedCount = httpClient.activeGateIssuedRequestCount
        let retryResponse: IntegrationGateRangeResponse?
        do {
            retryResponse = try await httpClient.rangedStreamingRequest(
                routeLabel: manifest.action.routeLabel,
                rangeStart: 0,
                rangeLength: expectedLength,
                expectedTotal: expectedLength
            )
        } catch {
            retryResponse = nil
        }
        let final = httpClient.activeGateIssuedRequestCount
        let facts = IntegrationGateG3Facts(
            oldGeneration: oldGeneration,
            firstProgressBytes: firstProgressBytes,
            expectedContentLength: expectedLength,
            firstAttemptCompleted: firstCompleted,
            firstAttemptTerminated: !firstCompleted && runningPublished,
            activeGateIssuedRequestBaseline: baseline,
            activeGateIssuedRequestAfterFirstAttempt: afterFirstCount,
            lastClosedGeneration: oldClosed,
            retryStartedActiveRequestCount: retryStartedCount,
            retryGeneration: retryGeneration,
            retryResponse: retryResponse,
            activeGateIssuedRequestFinal: final,
            expectedSHA256Hex: expectedDigest
        )
        let classified = IntegrationGateActionClassifiers.classifyG3(facts)
        return self.result(
            verdict: classified.0,
            reason: classified.1,
            httpOutcome: retryResponse?.outcome,
            accounting: self.accounting(baseline: baseline, final: final)
        )
    }

    private func runG4() async -> IntegrationGateActionRunResult {
        let observations = await sampler.collectObservationWindow(
            sampleCount: Int(IntegrationGateConstants.observationWindowMilliseconds / 1_000)
        )
        let classified = IntegrationGateActionClassifiers.classifyG4(IntegrationGateWindowFacts(observations: observations))
        return self.result(
            verdict: classified.0,
            reason: classified.1,
            samples: observations.map(\.sample)
        )
    }

    private func runG5() async -> IntegrationGateActionRunResult {
        let observations = await sampler.collectObservationWindow(
            sampleCount: Int(IntegrationGateConstants.observationWindowMilliseconds / 1_000)
        )
        let classified = IntegrationGateActionClassifiers.classifyG5(IntegrationGateWindowFacts(observations: observations))
        return self.result(
            verdict: classified.0,
            reason: classified.1,
            samples: observations.map(\.sample)
        )
    }

    private func ensureConnected() async {
        guard tunnelManager.activeConnection == nil else { return }
        await tunnelManager.connect()
        let maxPolls = Int(IntegrationGateConstants.connectCeilingMilliseconds / 1_000)
        for _ in 0..<maxPolls {
            if tunnelManager.activeConnection != nil {
                return
            }
            try? await clock.sleep(for: .seconds(1))
        }
    }

    private func waitForNewGeneration(after oldGeneration: UInt64?) async -> UInt64? {
        let maxPolls = Int(IntegrationGateConstants.reconnectCeilingMilliseconds / 1_000)
        for _ in 0..<maxPolls {
            let activeGeneration = tunnelManager.transportGenerationSnapshot.activeGeneration
            if let oldGeneration, let activeGeneration, activeGeneration > oldGeneration {
                return activeGeneration
            }
            try? await clock.sleep(for: .seconds(1))
        }
        return tunnelManager.transportGenerationSnapshot.activeGeneration
    }

    private func relayOnlyIntegrityFailure() -> IntegrationGateReasonCode? {
        if let summary = tunnelManager.integrationGateCandidateBuildSummary,
           (summary.postConnectCachedDirectCandidateCount ?? 0) > 0 {
            return .runtimeLanRepopulation
        }
        if tunnelManager.state.integrationGateEndpointKind == "lan" {
            return .selectedLanEndpoint
        }
        return nil
    }

    private func accounting(baseline: Int, final: Int) -> IntegrationGateAccounting {
        IntegrationGateAccounting(
            activeGateIssuedRequestBaseline: baseline,
            activeGateIssuedRequestFinal: final,
            activeGateIssuedRequestReturnedToBaseline: baseline == final
        )
    }

    private func result(
        verdict: IntegrationGateVerdict,
        reason: IntegrationGateReasonCode,
        httpOutcome: IntegrationGateHTTPOutcome? = nil,
        accounting: IntegrationGateAccounting? = nil,
        accountingBaseline: Int? = nil,
        samples: [IntegrationGateSample] = []
    ) -> IntegrationGateActionRunResult {
        let baseline = accountingBaseline ?? 0
        let finalAccounting = accounting ?? self.accounting(
            baseline: baseline,
            final: httpClient.activeGateIssuedRequestCount
        )
        let snapshot = tunnelManager.transportGenerationSnapshot
        return IntegrationGateActionRunResult(
            verdict: verdict,
            reasonCode: reason,
            httpOutcome: httpOutcome,
            accounting: finalAccounting,
            samples: samples,
            generation: IntegrationGateResultGeneration(
                currentGeneration: snapshot.currentGeneration,
                activeGeneration: snapshot.activeGeneration,
                lastClosedGeneration: snapshot.lastClosedGeneration
            ),
            transportStages: tunnelManager.integrationGateLastTransportStage.map { [$0.integrationGateExportLabel] } ?? [],
            reconnectReasonBuckets: tunnelManager.reconnectReasonCounts
                .filter { $0.value > 0 }
                .map { $0.key.exportLabel }
                .sorted()
        )
    }
}

private extension String {
    var integrationGateStatusIsKnown: Bool {
        switch self {
        case "offline", "connecting", "waitingForHome", "reconnecting", "unreachable",
             "connectedIdle", "connectedWaiting", "connectedTransferring":
            return true
        default:
            return false
        }
    }

    var integrationGateStatusIsPositive: Bool {
        switch self {
        case "connectedIdle", "connectedWaiting", "connectedTransferring":
            return true
        case "offline", "connecting", "waitingForHome", "reconnecting", "unreachable":
            return false
        default:
            return false
        }
    }
}
#endif
