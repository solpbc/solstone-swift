// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let confirmationLog = Logger(subsystem: "app.solstone.swift", category: "journal-mark")

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
func resolveConfirmation(
    timeout: Duration = .seconds(6),
    step: Duration = .milliseconds(125),
    connectedPort: @MainActor @Sendable @escaping () -> Int?,
    fetchMark: @Sendable @escaping (_ port: Int) async -> JournalMark?
) async -> ConfirmOutcome {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while clock.now < deadline {
        if Task.isCancelled {
            confirmationLog.debug("journal mark confirm fallback: cancelled before connected port")
            return .fallback(.cancelled)
        }

        if let port = connectedPort() {
            let mark = await fetchMark(port)
            if Task.isCancelled {
                confirmationLog.debug("journal mark confirm fallback: cancelled during fetch")
                return .fallback(.cancelled)
            }
            guard let mark else {
                confirmationLog.info("journal mark confirm fallback: missing or invalid mark")
                return .fallback(.missingOrInvalidMark)
            }
            return .confirm(mark)
        }

        do {
            try await Task.sleep(for: step)
        } catch {
            confirmationLog.debug("journal mark confirm fallback: cancelled while waiting for connected port")
            return .fallback(.cancelled)
        }
    }

    if Task.isCancelled {
        confirmationLog.debug("journal mark confirm fallback: cancelled at deadline")
        return .fallback(.cancelled)
    }

    confirmationLog.info("journal mark confirm fallback: connected port timeout")
    return .fallback(.timeout)
}

@MainActor
func tearDownMismatchedPairing(
    appConfig: AppConfig,
    tunnelManager: TunnelManager,
    coordinator: PairFlowCoordinator
) async {
    appConfig.clearPairing()
    await tunnelManager.disconnect()
    await coordinator.unpair()
}
