// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated protocol TransferClock: Sendable {
    func wallNow() -> Date
    func monotonicNow() -> ContinuousClock.Instant
    func sleep(for duration: Duration) async
}

nonisolated struct LiveTransferClock: TransferClock {
    private let clock = ContinuousClock()

    func wallNow() -> Date {
        Date()
    }

    func monotonicNow() -> ContinuousClock.Instant {
        self.clock.now
    }

    func sleep(for duration: Duration) async {
        try? await self.clock.sleep(for: duration)
    }
}

nonisolated struct TransferPacerDefaults: Equatable, Sendable {
    static let standard = TransferPacerDefaults()

    var ladderSeconds: [TimeInterval]
    var maxDelay: TimeInterval
    var jitterSalt: UInt64

    init(
        ladderSeconds: [TimeInterval] = [1, 2, 5, 10, 20, 40, 80, 160, 240],
        maxDelay: TimeInterval = 300,
        jitterSalt: UInt64 = 0x51A7_2026
    ) {
        self.ladderSeconds = ladderSeconds
        self.maxDelay = maxDelay
        self.jitterSalt = jitterSalt
    }
}

nonisolated struct TransferPacerInput: Equatable, Sendable {
    var itemID: UUID
    var source: String
    var attemptCount: Int
    var lastOutcome: TransferTransientReason

    init(itemID: UUID, source: String, attemptCount: Int, lastOutcome: TransferTransientReason) {
        self.itemID = itemID
        self.source = source
        self.attemptCount = attemptCount
        self.lastOutcome = lastOutcome
    }
}

nonisolated struct TransferPacerDecision: Equatable, Sendable {
    var delay: TimeInterval
}

nonisolated struct TransferPacer: Equatable, Sendable {
    var defaults: TransferPacerDefaults

    init(defaults: TransferPacerDefaults = .standard) {
        self.defaults = defaults
    }

    func delay(for input: TransferPacerInput) -> TransferPacerDecision {
        let index = max(0, min(input.attemptCount - 1, self.defaults.ladderSeconds.count - 1))
        let base = self.defaults.ladderSeconds.isEmpty ? 1 : self.defaults.ladderSeconds[index]
        let jittered = base * self.jitterFactor(for: input)
        return TransferPacerDecision(delay: min(jittered, self.defaults.maxDelay))
    }

    func jitterFactor(for input: TransferPacerInput) -> Double {
        var hash = UInt64(14_695_981_039_346_656_037) ^ self.defaults.jitterSalt
        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        for byte in Array(input.itemID.uuidString.utf8) + Array(input.source.utf8) {
            mix(byte)
        }
        var attempt = UInt64(max(0, input.attemptCount))
        for _ in 0..<8 {
            mix(UInt8(truncatingIfNeeded: attempt))
            attempt >>= 8
        }
        let unit = Double(hash % 10_000) / 9_999.0
        return 0.75 + (unit * 0.5)
    }
}

nonisolated enum TransferClockMath {
    static func retryEligible(nextAttemptAt: Date?, wallNow: Date, maxDelay: TimeInterval = 300) -> Bool {
        guard let nextAttemptAt else { return true }
        if nextAttemptAt <= wallNow { return true }
        return nextAttemptAt > wallNow.addingTimeInterval(maxDelay)
    }

    static func sleepDurationUntil(nextAttemptAt: Date, wallNow: Date, maxDelay: TimeInterval = 300) -> TimeInterval {
        min(max(nextAttemptAt.timeIntervalSince(wallNow), 0), maxDelay)
    }
}
