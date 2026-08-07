// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

private let pairingCredentialRecoveryLog = Logger(
    subsystem: "app.solstone.swift",
    category: "pairing-credential-recovery"
)

nonisolated enum PairingCredentialRecoveryPhase: String, Codable, Equatable, Sendable {
    case needsCredentialRefresh
    case credentialReadyNeedsAttentionRetry
}

nonisolated struct PairingCredentialRecoveryState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var generation: Int
    var sourcePhases: [String: PairingCredentialRecoveryPhase]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        generation: Int = 0,
        sourcePhases: [String: PairingCredentialRecoveryPhase] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.sourcePhases = sourcePhases
    }
}

@MainActor
@Observable
final class PairingCredentialRecoveryCoordinator {
    struct Operation {
        let sourceKey: String
        let refresh: @MainActor @Sendable () async throws -> ObserverRegistrationRefreshChange
    }

    @ObservationIgnored private let operations: [Operation]
    @ObservationIgnored private let isReady: @MainActor @Sendable () -> Bool
    @ObservationIgnored private let retryAuthenticationAttention: @Sendable (String) async throws -> Void
    @ObservationIgnored private let persist: @MainActor (PairingCredentialRecoveryState) -> Void
    @ObservationIgnored private var recoveryState: PairingCredentialRecoveryState
    @ObservationIgnored private var isRecovering = false
    @ObservationIgnored private var rerunRequested = false

    private enum DefaultsKey {
        static let state = "pairingCredentialRecovery.state"
    }

    convenience init(
        observerRegistration: ObserverRegistration,
        omiRegistration: ObserverRegistration,
        watchRegistration: ObserverRegistration,
        transferEngine: TransferEngine
    ) {
        let defaults = UserDefaults(suiteName: AppGroupContainer.identifier)
        let persistedState = defaults?
            .data(forKey: DefaultsKey.state)
            .flatMap { try? JSONDecoder().decode(PairingCredentialRecoveryState.self, from: $0) }
            ?? PairingCredentialRecoveryState()
        self.init(
            operations: [
                Operation(sourceKey: ObserverAudioTransferSource.mobileSegment) {
                    try await observerRegistration.refreshRegistrationResult().change
                },
                Operation(sourceKey: ObserverAudioTransferSource.omi) {
                    try await omiRegistration.refreshRegistrationResult().change
                },
                Operation(sourceKey: ObserverAudioTransferSource.watch) {
                    try await watchRegistration.refreshRegistrationResult().change
                },
            ],
            isReady: {
                observerRegistration.activeLocalPort != nil
            },
            initialState: persistedState,
            persist: { state in
                guard let defaults else {
                    pairingCredentialRecoveryLog.error(
                        "pairing credential recovery persistence unavailable"
                    )
                    return
                }
                do {
                    defaults.set(try JSONEncoder().encode(state), forKey: DefaultsKey.state)
                } catch {
                    pairingCredentialRecoveryLog.error(
                        "pairing credential recovery persistence failed"
                    )
                }
            },
            retryAuthenticationAttention: { sourceKey in
                try await transferEngine.retryAuthenticationAttention(source: sourceKey)
            }
        )
    }

    init(
        operations: [Operation],
        isReady: @escaping @MainActor @Sendable () -> Bool = { true },
        initialState: PairingCredentialRecoveryState = PairingCredentialRecoveryState(),
        persist: @escaping @MainActor (PairingCredentialRecoveryState) -> Void = { _ in },
        retryAuthenticationAttention: @escaping @Sendable (String) async throws -> Void
    ) {
        self.operations = operations
        self.isReady = isReady
        var recoveredState = initialState
        let knownSources = Set(operations.map(\.sourceKey))
        recoveredState.sourcePhases = recoveredState.sourcePhases.filter { knownSources.contains($0.key) }
        self.recoveryState = recoveredState
        self.persist = persist
        self.retryAuthenticationAttention = retryAuthenticationAttention
    }

    func isPending(sourceKey: String) -> Bool {
        self.recoveryState.sourcePhases[sourceKey] != nil
    }

    func confirmedPairingCompleted() {
        self.recoveryState.generation &+= 1
        self.recoveryState.sourcePhases = Dictionary(
            uniqueKeysWithValues: self.operations.map {
                ($0.sourceKey, PairingCredentialRecoveryPhase.needsCredentialRefresh)
            }
        )
        self.persistState()
        self.rerunRequested = true
        Task { await self.recoverIfPending() }
    }

    func recoverIfPending() async {
        guard !self.recoveryState.sourcePhases.isEmpty, self.isReady() else { return }
        guard !self.isRecovering else {
            pairingCredentialRecoveryLog.notice("pairing credential recovery already in progress")
            return
        }
        self.isRecovering = true
        defer { self.isRecovering = false }

        repeat {
            self.rerunRequested = false
            let generation = self.recoveryState.generation
            let sourcesForPass = Set(self.recoveryState.sourcePhases.keys)

            for operation in self.operations where sourcesForPass.contains(operation.sourceKey) {
                guard generation == self.recoveryState.generation else {
                    self.rerunRequested = true
                    break
                }
                do {
                    guard let phase = self.recoveryState.sourcePhases[operation.sourceKey] else {
                        continue
                    }
                    if phase == .needsCredentialRefresh {
                        let change = try await operation.refresh()
                        guard change != .unchanged else {
                            pairingCredentialRecoveryLog.error(
                                "pairing credential recovery deferred source=\(operation.sourceKey, privacy: .public) error=credential_unchanged"
                            )
                            continue
                        }
                        guard generation == self.recoveryState.generation else {
                            self.rerunRequested = true
                            break
                        }
                        self.recoveryState.sourcePhases[operation.sourceKey] = .credentialReadyNeedsAttentionRetry
                        self.persistState()
                    }
                    guard generation == self.recoveryState.generation else {
                        self.rerunRequested = true
                        break
                    }
                    try await self.retryAuthenticationAttention(operation.sourceKey)
                    guard generation == self.recoveryState.generation else {
                        self.rerunRequested = true
                        break
                    }
                    self.recoveryState.sourcePhases.removeValue(forKey: operation.sourceKey)
                    self.persistState()
                    pairingCredentialRecoveryLog.notice(
                        "pairing credential recovered source=\(operation.sourceKey, privacy: .public)"
                    )
                } catch {
                    pairingCredentialRecoveryLog.error(
                        "pairing credential recovery deferred source=\(operation.sourceKey, privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                }
            }
        } while self.rerunRequested && self.isReady() && !self.recoveryState.sourcePhases.isEmpty
    }

    private func persistState() {
        self.persist(self.recoveryState)
    }
}
