// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class PairingCredentialRecoveryCoordinatorTests: XCTestCase {
    private actor Recorder {
        private var values: [String] = []

        func append(_ value: String) {
            self.values.append(value)
        }

        func snapshot() -> [String] {
            self.values
        }
    }

    private enum Failure: Error {
        case expected
    }

    func testConfirmedPairingRefreshesEachSourceAndRetriesOnlySuccessfulChanges() async {
        let refreshed = Recorder()
        let retried = Recorder()
        let readiness = Readiness(false)
        let coordinator = PairingCredentialRecoveryCoordinator(
            operations: [
                .init(sourceKey: "mobile-segment") {
                    await refreshed.append("mobile-segment")
                    return .replaced
                },
                .init(sourceKey: "omi") {
                    await refreshed.append("omi")
                    throw Failure.expected
                },
                .init(sourceKey: "watch") {
                    await refreshed.append("watch")
                    return .minted
                },
            ],
            isReady: { readiness.value },
            retryAuthenticationAttention: { sourceKey in
                await retried.append(sourceKey)
            }
        )

        coordinator.confirmedPairingCompleted()
        readiness.value = true
        await coordinator.recoverIfPending()

        let refreshedValues = await refreshed.snapshot()
        let retriedValues = await retried.snapshot()
        XCTAssertEqual(refreshedValues, ["mobile-segment", "omi", "watch"])
        XCTAssertEqual(retriedValues, ["mobile-segment", "watch"])
    }

    func testUnchangedCredentialRemainsPendingWithoutRetry() async {
        var persisted: [PairingCredentialRecoveryState] = []
        let retried = Recorder()
        let readiness = Readiness(false)
        let coordinator = PairingCredentialRecoveryCoordinator(
            operations: [
                .init(sourceKey: "mobile-segment") { .unchanged },
            ],
            isReady: { readiness.value },
            persist: { state in
                persisted.append(state)
            },
            retryAuthenticationAttention: { sourceKey in
                await retried.append(sourceKey)
            }
        )

        coordinator.confirmedPairingCompleted()
        readiness.value = true
        await coordinator.recoverIfPending()

        let retriedValues = await retried.snapshot()
        XCTAssertEqual(retriedValues, [])
        XCTAssertEqual(persisted.last?.generation, 1)
        XCTAssertEqual(
            persisted.last?.sourcePhases,
            ["mobile-segment": .needsCredentialRefresh]
        )
    }

    func testPendingRecoverySurvivesRelaunchBeforeConnection() async {
        var persistedState = PairingCredentialRecoveryState()
        let first = PairingCredentialRecoveryCoordinator(
            operations: [
                .init(sourceKey: "mobile-segment") { .replaced },
            ],
            isReady: { false },
            persist: { state in
                persistedState = state
            },
            retryAuthenticationAttention: { _ in
                XCTFail("disconnected recovery must not retry")
            }
        )

        first.confirmedPairingCompleted()
        await Task.yield()
        XCTAssertEqual(persistedState.generation, 1)
        XCTAssertEqual(
            persistedState.sourcePhases,
            ["mobile-segment": .needsCredentialRefresh]
        )

        let retried = Recorder()
        let relaunched = PairingCredentialRecoveryCoordinator(
            operations: [
                .init(sourceKey: "mobile-segment") { .replaced },
            ],
            initialState: persistedState,
            persist: { state in
                persistedState = state
            },
            retryAuthenticationAttention: { sourceKey in
                await retried.append(sourceKey)
            }
        )

        await relaunched.recoverIfPending()

        let retriedValues = await retried.snapshot()
        XCTAssertEqual(retriedValues, ["mobile-segment"])
        XCTAssertEqual(persistedState.generation, 1)
        XCTAssertTrue(persistedState.sourcePhases.isEmpty)
    }

    func testRelaunchAfterCredentialCommitRetriesAttentionWithoutRefreshingAgain() async {
        var persistedState = PairingCredentialRecoveryState(
            generation: 3,
            sourcePhases: ["mobile-segment": .needsCredentialRefresh]
        )
        let interrupted = PairingCredentialRecoveryCoordinator(
            operations: [
                .init(sourceKey: "mobile-segment") { .replaced },
            ],
            initialState: persistedState,
            persist: { state in
                persistedState = state
            },
            retryAuthenticationAttention: { _ in
                throw Failure.expected
            }
        )

        await interrupted.recoverIfPending()

        XCTAssertEqual(
            persistedState.sourcePhases,
            ["mobile-segment": .credentialReadyNeedsAttentionRetry]
        )

        let retried = Recorder()
        let relaunched = PairingCredentialRecoveryCoordinator(
            operations: [
                .init(sourceKey: "mobile-segment") {
                    XCTFail("credential-ready recovery must not refresh again")
                    return .unchanged
                },
            ],
            initialState: persistedState,
            persist: { state in
                persistedState = state
            },
            retryAuthenticationAttention: { sourceKey in
                await retried.append(sourceKey)
            }
        )

        await relaunched.recoverIfPending()

        let retriedValues = await retried.snapshot()
        XCTAssertEqual(retriedValues, ["mobile-segment"])
        XCTAssertEqual(persistedState.generation, 3)
        XCTAssertTrue(persistedState.sourcePhases.isEmpty)
    }

    func testServerConfirmedCurrentCredentialRepairsLostReadyPhase() async {
        var persistedState = PairingCredentialRecoveryState(
            generation: 4,
            sourcePhases: ["mobile-segment": .needsCredentialRefresh]
        )
        let retried = Recorder()
        let coordinator = PairingCredentialRecoveryCoordinator(
            operations: [
                .init(sourceKey: "mobile-segment") { .confirmedCurrent },
            ],
            initialState: persistedState,
            persist: { state in
                persistedState = state
            },
            retryAuthenticationAttention: { sourceKey in
                await retried.append(sourceKey)
            }
        )

        await coordinator.recoverIfPending()

        let retriedValues = await retried.snapshot()
        XCTAssertEqual(retriedValues, ["mobile-segment"])
        XCTAssertTrue(persistedState.sourcePhases.isEmpty)
    }

    func testRepairDuringRecoveryCoalescesIntoNewestGeneration() async {
        let refreshed = Recorder()
        let retried = Recorder()
        let gate = AsyncGate()
        let coordinator = PairingCredentialRecoveryCoordinator(
            operations: [
                .init(sourceKey: "mobile-segment") {
                    await refreshed.append("refresh")
                    if await refreshed.snapshot().count == 1 {
                        await gate.wait()
                    }
                    return .replaced
                },
            ],
            retryAuthenticationAttention: { sourceKey in
                await retried.append(sourceKey)
            }
        )

        coordinator.confirmedPairingCompleted()
        while await refreshed.snapshot().isEmpty {
            await Task.yield()
        }
        coordinator.confirmedPairingCompleted()
        await gate.open()

        while await retried.snapshot().isEmpty {
            await Task.yield()
        }

        let refreshedValues = await refreshed.snapshot()
        let retriedValues = await retried.snapshot()
        XCTAssertEqual(refreshedValues, ["refresh", "refresh"])
        XCTAssertEqual(retriedValues, ["mobile-segment"])
    }
}

@MainActor
private final class Readiness {
    var value: Bool

    init(_ value: Bool) {
        self.value = value
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !self.isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        self.isOpen = true
        self.continuation?.resume()
        self.continuation = nil
    }
}
