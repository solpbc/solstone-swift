// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Synchronization

/// The only form the store's answer takes inside the app. The platform adapter reduces the
/// answer to one of these before it returns, so no age or range is ever held past that call.
nonisolated enum AgeSignalCategory: Sendable, Equatable {
    case adultOrUnknown
    case teen
    case under13

    /// The store may answer with narrower ranges than the gates asked for (13–15, 16–17), or
    /// with a range that does not settle which side of a gate the person is on. Only a range
    /// wholly under 13 is under 13, and only one wholly inside 13 to 17 is a teen.
    init(lowerBound: Int?, upperBound: Int?) {
        if let upperBound, upperBound < 13 {
            self = .under13
        } else if let lowerBound, lowerBound >= 13, let upperBound, upperBound < 18 {
            self = .teen
        } else {
            self = .adultOrUnknown
        }
    }
}

/// The store calls a launch check makes. The live adapter is Apple's frameworks; tests and
/// simulator proofs use a double. A call throws only for an error worth retrying; an answer
/// that settles nothing (a declined prompt, no account, an API the system refuses) returns
/// as no signal.
@MainActor
protocol AgeSignalPlatform: AnyObject {
    /// Whether the law requires this app to ask, for this person, where they are.
    func isEligible() async throws -> Bool
    /// The person's category, or nil when they shared nothing.
    func requestCategory() async throws -> AgeSignalCategory?
    /// Whether a significant change needs a parent's consent before a teen keeps using the app.
    func requiresParentalConsentForSignificantChange() async throws -> Bool
    /// The App Store's current age rating code for the app, nil when it is unavailable.
    func currentRatingCode() async -> Int?
    /// Whether this install began on this very build, so it never ran under an earlier rating.
    func installedThisBuild() async throws -> Bool
    /// Raises the system's request asking a parent to approve the significant change.
    func askParent() async throws
    /// Each parent's answer to that request as it arrives: true approves.
    func parentAnswers() -> AsyncStream<Bool>
}

/// The decision a launch check makes from the store's answers.
@MainActor
struct AgeSignalCheck {
    static let attempts = 3

    let platform: any AgeSignalPlatform
    let store: AgeSignalStore
    let pause: @Sendable (Duration) async -> Void
    /// How long a call that shows nothing to the person may take before it counts as an error.
    let deadline: Duration

    init(
        platform: any AgeSignalPlatform,
        store: AgeSignalStore,
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        deadline: Duration = .seconds(10)
    ) {
        self.platform = platform
        self.store = store
        self.pause = pause
        self.deadline = deadline
    }

    /// The outcome. An error that outlasts its retries is treated like no signal: the app runs,
    /// and any outcome an earlier check left is cleared.
    func run() async -> AgeSignalOutcome {
        guard let eligible = await self.retrying(timed: true, { try await self.platform.isEligible() }) else {
            return .run
        }
        guard eligible else { return .run }
        // The age prompt waits on the person, so it has no deadline.
        guard let answer = await self.retrying(timed: false, { try await self.platform.requestCategory() }) else {
            return .run
        }
        switch answer {
        case nil, .adultOrUnknown?:
            return .run
        case .under13?:
            return .stopped
        case .teen?:
            return await self.teenOutcome()
        }
    }

    /// A teen runs unless a significant change is waiting on a parent. The change this tracks
    /// is the App Store rating: one the parent has not approved, on an install that ran under
    /// an earlier rating, holds the app.
    private func teenOutcome() async -> AgeSignalOutcome {
        guard let consent = await self.retrying(timed: true, {
            try await self.platform.requiresParentalConsentForSignificantChange()
        }) else { return .run }
        guard consent else { return .run }
        guard let current = await self.retrying(timed: true, { await self.platform.currentRatingCode() }) else {
            return .run
        }
        // No rating to compare: nothing shows a change.
        guard let current else { return .run }
        if let approved = self.store.approvedRatingCode() {
            return approved == current ? .run : .held
        }
        guard let installedHere = await self.retrying(timed: true, { try await self.platform.installedThisBuild() }) else {
            return .run
        }
        guard installedHere else { return .held }
        // A first install never saw an earlier rating, so this one is the baseline.
        self.store.saveApprovedRatingCode(current)
        return .run
    }

    /// At most `attempts` tries, a second then two seconds apart; nil once they all fail.
    func retrying<T: Sendable>(timed: Bool, _ operation: @escaping @MainActor () async throws -> T) async -> T? {
        for attempt in 1...Self.attempts {
            do {
                return try await timed ? self.withinDeadline(operation) : operation()
            } catch {
                guard attempt < Self.attempts else { break }
                await self.pause(.seconds(attempt))
            }
        }
        return nil
    }

    private struct Overdue: Error {}

    /// The call's answer, or an error once the deadline passes. A call that never returns is
    /// left behind rather than awaited.
    private func withinDeadline<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let deadline = self.deadline
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            let once = AgeSignalOnce(continuation)
            Task { @MainActor in
                do { once.resume(.success(try await operation())) } catch { once.resume(.failure(error)) }
            }
            Task {
                try? await Task.sleep(for: deadline)
                once.resume(.failure(Overdue()))
            }
        }
    }
}

/// Resumes a continuation the first time only.
private final class AgeSignalOnce<T: Sendable>: Sendable {
    private let state: Mutex<CheckedContinuation<T, any Error>?>

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.state = Mutex(continuation)
    }

    func resume(_ result: Result<T, any Error>) {
        self.state.withLock { continuation in
            continuation?.resume(with: result)
            continuation = nil
        }
    }
}
