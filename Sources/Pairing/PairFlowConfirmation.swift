// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum PairFlowPhase: Equatable, Sendable {
    case pairing
    case connecting
    case confirm(JournalMark)
    case couldNotVerify
    case mismatch
    /// The answer was no, or a cancel, on a ceremony that was replacing a pairing.
    case notChanged
}

/// Ending a pairing from an answer screen. Separate from the pairing screen's error line, which
/// other paths write to while these screens are up.
nonisolated enum PairFlowTeardownState: Equatable, Sendable {
    case idle
    case inProgress
    case failed
}

@MainActor
final class PairFlowCompletionGate {
    private var didComplete = false

    func completeOnce(_ action: @MainActor () -> Void) {
        guard !self.didComplete else {
            return
        }
        self.didComplete = true
        action()
    }
}

/// Records the owner's answer. `false` means it wasn't saved, and the screen has to say so.
@MainActor
func completeJournalSend(
    release: JournalSendRelease,
    appConfig: AppConfig,
    gate: PairFlowCompletionGate,
    onComplete: @MainActor () -> Void
) -> Bool {
    do {
        try release.authorize(appConfig, writeMarker: false)
    } catch {
        return false
    }
    gate.completeOnce(onComplete)
    return true
}

@MainActor
@discardableResult
func tearDownMismatchedPairing(
    appConfig: AppConfig,
    tunnelManager: TunnelManager,
    coordinator: PairFlowCoordinator,
    transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = OwnerUnpairTransport.live,
    timeout: Duration = .seconds(10)
) async -> Bool {
    let snapshot = appConfig.store.snapshot()
    guard let pairing = snapshot.pairing,
          let ownerID = snapshot.deviceOwnerID,
          (try? appConfig.store.migrationStore.owns(ownerID: ownerID, pairing: pairing)) == true else {
        return false
    }
    let expectedFlowGeneration = coordinator.pairingFlowGeneration
    let expectedClearedPairingGeneration = snapshot.pairingGeneration &+ 2
    guard await ownerUnpair(
        appConfig: appConfig,
        tunnelManager: tunnelManager,
        transport: transport,
        timeout: timeout,
        expectedOwnerID: ownerID,
        expectedPairingGeneration: snapshot.pairingGeneration
    ) else { return false }
    return coordinator.reflectUnpairedIfClear(
        expectedFlowGeneration: expectedFlowGeneration,
        expectedPairingGeneration: expectedClearedPairingGeneration
    )
}
