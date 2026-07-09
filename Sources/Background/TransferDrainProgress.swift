// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct DrainRoundInput: Equatable, Sendable {
    var previousTotal: Int
    var currentTotal: Int
    var inFlight: Int
    var stalledRounds: Int
    var backoffPendingCount: Int
    var endpointHeld: Bool
}

nonisolated enum DrainRoundDecision: Equatable, Sendable {
    case finished
    case stalled
    case keepGoing(previousTotal: Int, stalledRounds: Int)
}

nonisolated func evaluateDrainRound(_ input: DrainRoundInput, stallLimit: Int = 2) -> DrainRoundDecision {
    if input.currentTotal == 0 {
        return .finished
    }
    if input.currentTotal < input.previousTotal {
        return .keepGoing(previousTotal: input.currentTotal, stalledRounds: 0)
    }
    if input.inFlight > 0 {
        return .keepGoing(previousTotal: input.previousTotal, stalledRounds: 0)
    }
    if input.backoffPendingCount > 0 && !input.endpointHeld {
        return .keepGoing(previousTotal: input.previousTotal, stalledRounds: 0)
    }
    let next = input.stalledRounds + 1
    return next >= stallLimit
        ? .stalled
        : .keepGoing(previousTotal: input.previousTotal, stalledRounds: next)
}
