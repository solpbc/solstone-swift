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
    case mismatch
}

nonisolated enum ConfirmFallbackReason: Equatable, Sendable {
    case timeout
    case missingOrInvalidMark
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
                confirmationLog.info("journal mark confirm fallback: missing or invalid mark")
                return .fallback(.missingOrInvalidMark)
            case .instanceMismatch:
                break
            }
        }

        if let activeDeadline = deadline, clock.now >= activeDeadline {
            confirmationLog.info("journal mark confirm fallback: connected port or instance match timeout")
            return .fallback(.timeout)
        }

        do {
            try await Task.sleep(for: step)
        } catch {
            confirmationLog.debug("journal mark confirm fallback: cancelled while waiting for connected port")
            return .fallback(.cancelled)
        }

        if let activeDeadline = deadline, clock.now >= activeDeadline {
            confirmationLog.info("journal mark confirm fallback: deadline reached after step")
            return .fallback(.timeout)
        }
    }
}

@MainActor
func tearDownMismatchedPairing(
    appConfig: AppConfig,
    tunnelManager: TunnelManager,
    coordinator: PairFlowCoordinator,
    notice: JournalUnpairNoticeStore = JournalUnpairNoticeStore(),
    transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = OwnerUnpairTransport.live,
    timeout: Duration = .seconds(10)
) async {
    await ownerUnpair(
        appConfig: appConfig,
        tunnelManager: tunnelManager,
        notice: notice,
        transport: transport,
        timeout: timeout
    )
    await tunnelManager.disconnect()
    await coordinator.unpair()
}
