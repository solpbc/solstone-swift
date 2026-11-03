// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let confirmationLog = Logger(subsystem: "app.solstone.swift", category: "journal-mark")

nonisolated enum PairFlowPhase: Equatable, Sendable {
    case pairing
    case connecting
    case confirm(JournalMark)
    case couldNotVerify
    case noCommittedMark
    case mismatch

    /// The mark state drawn above `continue anyway` and `cancel pairing`. A journal with an
    /// identity whose mark could not be read is unavailable; one that reports no committed mark
    /// has no identity yet. The two answers stay the same; the claim above them does not.
    var goAheadIdentity: JournalIdentity? {
        switch self {
        case .couldNotVerify: .unavailable
        case .noCommittedMark: .generic
        case .pairing, .connecting, .confirm, .mismatch: nil
        }
    }
}

/// Ending a pairing from an answer screen. Separate from the pairing screen's error line, which
/// other paths write to while these screens are up.
nonisolated enum PairFlowTeardownState: Equatable, Sendable {
    case idle
    case inProgress
    case failed
}

nonisolated enum ConfirmFallbackReason: Equatable, Sendable {
    case timeout
    case missingOrInvalidMark
    case noCommittedMark
    case cancelled
}

nonisolated enum ConfirmOutcome: Equatable, Sendable {
    case confirm(JournalMark)
    case fallback(ConfirmFallbackReason)
}

@MainActor
final class PairFlowConfirmationApplicator {
    var phase: PairFlowPhase
    private let completionGate: PairFlowCompletionGate
    private let tearDown: @MainActor () async -> Void

    init(
        initialPhase: PairFlowPhase = .connecting,
        completionGate: PairFlowCompletionGate = PairFlowCompletionGate(),
        tearDown: @escaping @MainActor () async -> Void
    ) {
        self.phase = initialPhase
        self.completionGate = completionGate
        self.tearDown = tearDown
    }

    func apply(_ outcome: ConfirmOutcome) {
        guard self.phase == .connecting else { return }
        switch outcome {
        case .confirm(let mark):
            self.phase = .confirm(mark)
        case .fallback(.timeout), .fallback(.missingOrInvalidMark):
            self.phase = .couldNotVerify
        case .fallback(.noCommittedMark):
            self.phase = .noCommittedMark
        case .fallback(.cancelled):
            break
        }
    }

    func continueAnyway(onComplete: @MainActor () -> Void) {
        self.completionGate.completeOnce(onComplete)
    }

    func cancelPairing() async {
        await self.tearDown()
        self.phase = .pairing
    }
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

@MainActor
func completeJournalSend(
    mark: JournalMark,
    markStore: JournalMarkStore,
    release: JournalSendRelease,
    appConfig: AppConfig,
    gate: PairFlowCompletionGate,
    onComplete: @MainActor () -> Void
) throws {
    try release.authorize(appConfig, writeMarker: false)
    markStore.save(mark)
    gate.completeOnce(onComplete)
}

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
func resolveConfirmation(
    timeout: Duration = .seconds(6),
    step: Duration = .milliseconds(125),
    startDeadlineWhenConnected: Bool = false,
    connectedPort: @MainActor @Sendable @escaping () -> Int?,
    fetchResult: @Sendable @escaping (_ port: Int) async -> JournalIdentityFetchResult
) async -> ConfirmOutcome {
    let clock = ContinuousClock()
    var deadline: ContinuousClock.Instant? = startDeadlineWhenConnected ? nil : clock.now.advanced(by: timeout)
    // One short read on a new tunnel is easy to miss, and giving up on it would offer the owner a
    // go-ahead with no comparison. So every failed read tries again until the deadline, and the
    // deadline reports the last thing the journal said.
    var reasonAtDeadline = ConfirmFallbackReason.timeout

    while true {
        if Task.isCancelled {
            confirmationLog.debug("journal mark confirm fallback: cancelled before connected port")
            return .fallback(.cancelled)
        }

        if let port = connectedPort() {
            if deadline == nil {
                deadline = clock.now.advanced(by: timeout)
            }

            let result = await fetchResult(port)
            if Task.isCancelled {
                confirmationLog.debug("journal mark confirm fallback: cancelled during fetch")
                return .fallback(.cancelled)
            }

            switch result {
            case .match(let mark):
                return .confirm(mark)
            case .missingOrInvalid:
                reasonAtDeadline = .missingOrInvalidMark
            case .notCommitted:
                reasonAtDeadline = .noCommittedMark
            case .instanceMismatch:
                reasonAtDeadline = .timeout
            }
        }

        if let activeDeadline = deadline, clock.now >= activeDeadline {
            confirmationLog.info("journal mark confirm fallback at deadline: \(String(describing: reasonAtDeadline), privacy: .public)")
            return .fallback(reasonAtDeadline)
        }

        do {
            try await Task.sleep(for: step)
        } catch {
            confirmationLog.debug("journal mark confirm fallback: cancelled while waiting for connected port")
            return .fallback(.cancelled)
        }

        if let activeDeadline = deadline, clock.now >= activeDeadline {
            confirmationLog.info("journal mark confirm fallback after step: \(String(describing: reasonAtDeadline), privacy: .public)")
            return .fallback(reasonAtDeadline)
        }
    }
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
