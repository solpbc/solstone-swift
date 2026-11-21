// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if DEBUG && SOLSTONE_AGE_SIGNAL
import Foundation

/// A scripted store for proving the launch check on a simulator, where Apple's age range
/// service does not answer: `--age-signal-proof=<scenario>` on a build with the check turned on.
///
/// - `not-eligible`: the law does not apply here; nothing is asked.
/// - `adult`, `teen`, `under13`: the person shares that range; a teen has no consent rule.
/// - `teen-update`: a teen whose parent must consent, on an install from an earlier rating.
///   The parent answers the first request 20 seconds after it is raised, and any later one at once.
@MainActor
final class AgeSignalProofPlatform: AgeSignalPlatform {
    static let argumentPrefix = "--age-signal-proof="

    enum Scenario: String {
        case notEligible = "not-eligible"
        case adult
        case teen
        case under13
        case teenUpdate = "teen-update"
    }

    let scenario: Scenario
    private var asks = 0
    private var continuation: AsyncStream<Bool>.Continuation?

    static func requested(arguments: [String] = ProcessInfo.processInfo.arguments) -> AgeSignalProofPlatform? {
        guard let raw = arguments.first(where: { $0.hasPrefix(Self.argumentPrefix) }),
              let scenario = Scenario(rawValue: String(raw.dropFirst(Self.argumentPrefix.count))) else { return nil }
        return AgeSignalProofPlatform(scenario: scenario)
    }

    init(scenario: Scenario) {
        self.scenario = scenario
    }

    func isEligible() async throws -> Bool {
        self.scenario != .notEligible
    }

    func requestCategory() async throws -> AgeSignalCategory? {
        switch self.scenario {
        case .notEligible: nil
        case .adult: AgeSignalCategory(lowerBound: 18, upperBound: nil)
        case .teen, .teenUpdate: AgeSignalCategory(lowerBound: 13, upperBound: 17)
        case .under13: AgeSignalCategory(lowerBound: nil, upperBound: 12)
        }
    }

    func requiresParentalConsentForSignificantChange() async throws -> Bool {
        self.scenario == .teenUpdate
    }

    func currentRatingCode() async -> Int? { 13 }

    func installedThisBuild() async throws -> Bool { false }

    func askParent() async throws {
        self.asks += 1
        guard self.asks == 1 else {
            self.continuation?.yield(true)
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(20))
            self.continuation?.yield(true)
        }
    }

    func parentAnswers() -> AsyncStream<Bool> {
        AsyncStream { self.continuation = $0 }
    }
}
#endif
