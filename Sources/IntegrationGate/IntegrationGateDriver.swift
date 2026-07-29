// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel
import os

#if DEBUG && targetEnvironment(simulator)
private let log = Logger(subsystem: "app.solstone.swift", category: "integration-gate-driver")

@MainActor
struct IntegrationGateDependencies {
    let keychainStore: SPLKeychainStore
    let tunnelManager: TunnelManager
    let transport: CFTunnelTransport
    let connectionSyncModel: ConnectionSyncModel

    func probeLiveness() async -> Bool {
        guard let result = await tunnelManager.probeConnection() else {
            return false
        }
        return result.alive
    }
}

@MainActor
final class IntegrationGateDriver {
    private let dependencies: IntegrationGateDependencies
    private let fileStore: IntegrationGateFileStore
    private let pairingLoader: IntegrationGatePairingSnapshotLoader
    private let now: @Sendable () -> Date

    init(
        dependencies: IntegrationGateDependencies,
        fileStore: IntegrationGateFileStore = IntegrationGateFileStore(),
        pairingLoader: IntegrationGatePairingSnapshotLoader = IntegrationGatePairingSnapshotLoader(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.dependencies = dependencies
        self.fileStore = fileStore
        self.pairingLoader = pairingLoader
        self.now = now
    }

    static func shouldRun(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(IntegrationGateConstants.launchArgument)
    }

    func run() async {
        let startedAt = Self.unixMillis(now())
        do {
            let manifestData = try fileStore.readManifestData()
            let manifest = try IntegrationGateManifest.decodeAndValidate(manifestData)
            await self.run(manifest: manifest, startedAtUnixMillis: startedAt)
        } catch let error as IntegrationGateValidationError {
            let updatedAt = Self.unixMillis(now())
            self.writeBestEffortError(
                sequence: nil,
                nonce: nil,
                correlationID: "unavailable",
                reasonCode: error.reasonCode,
                routeLabel: nil,
                startedAtUnixMillis: startedAt,
                updatedAtUnixMillis: updatedAt
            )
        } catch {
            let updatedAt = Self.unixMillis(now())
            self.writeBestEffortError(
                sequence: nil,
                nonce: nil,
                correlationID: "unavailable",
                reasonCode: .manifestMalformed,
                routeLabel: nil,
                startedAtUnixMillis: startedAt,
                updatedAtUnixMillis: updatedAt
            )
        }
    }

    private func run(manifest: IntegrationGateManifest, startedAtUnixMillis: Int64) async {
        do {
            try self.validateReplay(manifest: manifest)
            try self.validateExpiration(manifest: manifest)
            try self.validateBuild(manifest: manifest)

            let (_, snapshot) = try pairingLoader.loadValidatedPairing(
                for: manifest,
                keychainStore: dependencies.keychainStore
            )
            _ = try pairingLoader.revalidate(
                original: snapshot,
                manifest: manifest,
                keychainStore: dependencies.keychainStore
            )
            dependencies.tunnelManager.installIntegrationGateRelayOnlyCandidatePolicy()
            defer {
                dependencies.tunnelManager.clearIntegrationGateRelayOnlyCandidatePolicy()
            }

            let httpClient = IntegrationGateHTTPClient(
                tunnelManager: dependencies.tunnelManager,
                now: { self.now() }
            )
            let clock = SystemObserverClock()
            let sampler = IntegrationGateSampler(
                tunnelManager: dependencies.tunnelManager,
                connectionSyncModel: dependencies.connectionSyncModel,
                httpClient: httpClient,
                clock: clock
            )
            let actions = IntegrationGateActions(
                tunnelManager: dependencies.tunnelManager,
                httpClient: httpClient,
                sampler: sampler,
                clock: clock,
                writeRunning: { actionResult in
                    try self.writeActionResult(
                        manifest: manifest,
                        snapshot: snapshot,
                        actionResult: actionResult,
                        recordState: .running,
                        startedAtUnixMillis: startedAtUnixMillis,
                        updatedAtUnixMillis: Self.unixMillis(self.now())
                    )
                }
            )
            let actionResult = await actions.run(manifest: manifest)
            try self.writeActionResult(
                manifest: manifest,
                snapshot: snapshot,
                actionResult: actionResult,
                recordState: .terminal,
                startedAtUnixMillis: startedAtUnixMillis,
                updatedAtUnixMillis: Self.unixMillis(now())
            )
        } catch let error as IntegrationGateValidationError {
            let updatedAt = Self.unixMillis(now())
            self.writeBestEffortError(
                sequence: manifest.sequence,
                nonce: manifest.nonce,
                correlationID: manifest.correlationID,
                reasonCode: error.reasonCode,
                routeLabel: manifest.action.routeLabel,
                startedAtUnixMillis: startedAtUnixMillis,
                updatedAtUnixMillis: updatedAt
            )
        } catch {
            let updatedAt = Self.unixMillis(now())
            self.writeBestEffortError(
                sequence: manifest.sequence,
                nonce: manifest.nonce,
                correlationID: manifest.correlationID,
                reasonCode: .manifestMalformed,
                routeLabel: manifest.action.routeLabel,
                startedAtUnixMillis: startedAtUnixMillis,
                updatedAtUnixMillis: updatedAt
            )
        }
    }

    private func validateReplay(manifest: IntegrationGateManifest) throws {
        guard let priorData = try fileStore.readPriorResultData() else {
            return
        }
        let prior = try JSONDecoder().decode(IntegrationGatePriorResult.self, from: priorData)
        if let priorSequence = prior.sequence, priorSequence >= manifest.sequence {
            throw IntegrationGateValidationError(.staleSequence)
        }
        if let priorNonce = prior.nonce, priorNonce == manifest.nonce {
            throw IntegrationGateValidationError(.repeatedNonce)
        }
    }

    private func validateExpiration(manifest: IntegrationGateManifest) throws {
        guard Self.unixMillis(now()) <= manifest.expiresAtUnixMillis else {
            throw IntegrationGateValidationError(.expiredManifest)
        }
    }

    private func validateBuild(manifest: IntegrationGateManifest) throws {
        let current = IntegrationGateBuildMetadata.current
        guard current.sourceCommit == manifest.expectedBuild.sourceCommit,
              current.splSwiftRevision == manifest.expectedBuild.splSwiftRevision
        else {
            throw IntegrationGateValidationError(.buildMismatch)
        }
    }

    private func writeActionResult(
        manifest: IntegrationGateManifest,
        snapshot: IntegrationGatePairingSnapshot,
        actionResult: IntegrationGateActionRunResult,
        recordState: IntegrationGateRecordState,
        startedAtUnixMillis: Int64,
        updatedAtUnixMillis: Int64
    ) throws {
        let isTerminal = recordState == .terminal
        let finishedAtUnixMillis = isTerminal ? updatedAtUnixMillis : nil
        let durationMillis = finishedAtUnixMillis.map {
            UInt64(max(0, $0 - startedAtUnixMillis))
        }
        let result = IntegrationGateResult(
            schemaVersion: IntegrationGateConstants.schemaVersion,
            sequence: manifest.sequence,
            nonce: manifest.nonce,
            correlationID: manifest.correlationID,
            recordState: recordState,
            verdict: isTerminal ? actionResult.verdict : nil,
            reasonCode: actionResult.reasonCode,
            startedAtUnixMillis: startedAtUnixMillis,
            updatedAtUnixMillis: updatedAtUnixMillis,
            finishedAtUnixMillis: finishedAtUnixMillis,
            durationMillis: durationMillis,
            buildMetadata: .current,
            pairingSnapshot: snapshot.resultSnapshot,
            routeLabel: manifest.action.routeLabel,
            generation: actionResult.generation,
            httpOutcome: actionResult.httpOutcome,
            accounting: actionResult.accounting,
            samples: actionResult.samples,
            transportStages: actionResult.transportStages,
            reconnectReasonBuckets: actionResult.reconnectReasonBuckets
        )
        try fileStore.writeResult(result)
    }

    private func writeBestEffortError(
        sequence: UInt64?,
        nonce: String?,
        correlationID: String,
        reasonCode: IntegrationGateReasonCode,
        routeLabel: IntegrationGateRouteLabel?,
        startedAtUnixMillis: Int64,
        updatedAtUnixMillis: Int64
    ) {
        var result = IntegrationGateResult.terminalError(
            sequence: sequence,
            nonce: nonce,
            correlationID: correlationID,
            reasonCode: reasonCode,
            startedAtUnixMillis: startedAtUnixMillis,
            updatedAtUnixMillis: updatedAtUnixMillis
        )
        result.routeLabel = routeLabel
        do {
            try fileStore.writeResult(result)
        } catch {
            log.error("integration gate result write failed reason=\(String(describing: reasonCode), privacy: .public)")
        }
    }

    private static func unixMillis(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }
}
#endif
