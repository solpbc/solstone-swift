// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

struct RaceResult<Value: Sendable>: Sendable {
    let endpoint: TransportEndpoint
    let value: Value
}

struct RaceAttemptProgress: Sendable {
    static let none = RaceAttemptProgress(onWaiting: {})

    private let onWaiting: @Sendable () -> Void

    init(onWaiting: @escaping @Sendable () -> Void) {
        self.onWaiting = onWaiting
    }

    func reportWaiting() {
        onWaiting()
    }
}

private final class RaceWaitingTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var waitingOrders = Set<Int>()

    var hasWaiting: Bool {
        lock.withLock { !waitingOrders.isEmpty }
    }

    func markWaiting(order: Int) {
        lock.withLock {
            waitingOrders.insert(order)
        }
    }

    func clearWaiting(order: Int) {
        lock.withLock {
            waitingOrders.remove(order)
        }
    }
}

struct RaceCoordinator<Value: Sendable>: Sendable {
    private enum Event: Sendable {
        case success(order: Int, endpoint: TransportEndpoint, value: Value)
        case failure(order: Int, error: SessionError)
        case budgetExpired
        case graceExpired
    }

    private let stagger: Duration
    private let loserGrace: Duration
    private let budget: Duration
    private let close: @Sendable (Value) async -> Void
    private let dial: @Sendable (TransportEndpoint, RaceAttemptProgress) async throws -> Value

    init(
        stagger: Duration = .milliseconds(50),
        loserGrace: Duration = .milliseconds(250),
        budget: Duration = .seconds(8),
        close: @escaping @Sendable (Value) async -> Void = { _ in },
        dial: @escaping @Sendable (TransportEndpoint, RaceAttemptProgress) async throws -> Value
    ) {
        self.stagger = stagger
        self.loserGrace = loserGrace
        self.budget = budget
        self.close = close
        self.dial = dial
    }

    func connect(endpoints: [TransportEndpoint]) async throws -> RaceResult<Value> {
        guard !endpoints.isEmpty else {
            throw SessionError.unreachable
        }

        let sorted = Self.sorted(endpoints)
        guard sorted.count > 1 else {
            do {
                let endpoint = sorted[0]
                return RaceResult(endpoint: endpoint, value: try await dial(endpoint, .none))
            } catch {
                throw Self.sessionError(from: error)
            }
        }

        let waitingTracker = RaceWaitingTracker()
        return try await withThrowingTaskGroup(of: Event.self, returning: RaceResult<Value>.self) { group in
            for (order, endpoint) in sorted.enumerated() {
                group.addTask {
                    if order > 0 {
                        do {
                            try await Task.sleep(for: stagger * order)
                        } catch {
                            return .failure(order: order, error: .unreachable)
                        }
                    }

                    do {
                        let progress = RaceAttemptProgress {
                            waitingTracker.markWaiting(order: order)
                        }
                        let value = try await dial(endpoint, progress)
                        return .success(order: order, endpoint: endpoint, value: value)
                    } catch {
                        return .failure(order: order, error: Self.sessionError(from: error))
                    }
                }
            }

            group.addTask {
                do {
                    try await Task.sleep(for: budget)
                } catch {
                    return .budgetExpired
                }
                return .budgetExpired
            }

            var failures = 0
            var successes: [(order: Int, endpoint: TransportEndpoint, value: Value)] = []
            var graceStarted = false
            var sawRevocation = false
            var sawTokenExpired = false

            while let event = try await group.next() {
                switch event {
                case .success(let order, let endpoint, let value):
                    waitingTracker.clearWaiting(order: order)
                    successes.append((order, endpoint, value))
                    if !graceStarted {
                        graceStarted = true
                        group.addTask {
                            do {
                                try await Task.sleep(for: loserGrace)
                            } catch {
                                return .graceExpired
                            }
                            return .graceExpired
                        }
                    }

                case .failure(let order, let error):
                    waitingTracker.clearWaiting(order: order)
                    failures += 1
                    if error == .revoked {
                        sawRevocation = true
                    }
                    if error == .tokenExpired {
                        sawTokenExpired = true
                    }
                    if failures == sorted.count, successes.isEmpty {
                        group.cancelAll()
                        throw Self.aggregateFailure(sawRevocation: sawRevocation, sawTokenExpired: sawTokenExpired)
                    }

                case .budgetExpired:
                    if waitingTracker.hasWaiting {
                        continue
                    }
                    if successes.isEmpty {
                        group.cancelAll()
                        throw Self.aggregateFailure(sawRevocation: sawRevocation, sawTokenExpired: sawTokenExpired)
                    }

                case .graceExpired:
                    guard let winner = successes.min(by: { $0.order < $1.order }) else {
                        group.cancelAll()
                        throw Self.aggregateFailure(sawRevocation: sawRevocation, sawTokenExpired: sawTokenExpired)
                    }
                    group.cancelAll()
                    var closedOrders = Set<Int>()
                    for success in successes where success.order != winner.order {
                        if closedOrders.insert(success.order).inserted {
                            await close(success.value)
                        }
                    }
                    while let event = try? await group.next() {
                        switch event {
                        case .success(let order, _, let value):
                            if order != winner.order, closedOrders.insert(order).inserted {
                                await close(value)
                            }
                        case .failure, .budgetExpired, .graceExpired:
                            break
                        }
                    }
                    return RaceResult(endpoint: winner.endpoint, value: winner.value)
                }
            }

            guard let winner = successes.min(by: { $0.order < $1.order }) else {
                throw Self.aggregateFailure(sawRevocation: sawRevocation, sawTokenExpired: sawTokenExpired)
            }
            return RaceResult(endpoint: winner.endpoint, value: winner.value)
        }
    }

    static func sorted(_ endpoints: [TransportEndpoint]) -> [TransportEndpoint] {
        endpoints.enumerated()
            .sorted { lhs, rhs in
                let leftRank = rank(lhs.element)
                let rightRank = rank(rhs.element)
                if leftRank == rightRank {
                    return lhs.offset < rhs.offset
                }
                return leftRank < rightRank
            }
            .map(\.element)
    }

    private static func rank(_ endpoint: TransportEndpoint) -> Int {
        switch endpoint {
        case .lan(let host, _, _):
            if isIPv6ULA(host) {
                return 0
            }
            if isRFC1918(host) {
                return 1
            }
            return 2
        case .relay:
            return 3
        }
    }

    private static func isIPv6ULA(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return normalized.hasPrefix("fc") || normalized.hasPrefix("fd")
    }

    private static func isRFC1918(_ host: String) -> Bool {
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ 0...255 ~= $0 }) else {
            return false
        }
        switch (octets[0], octets[1]) {
        case (10, _), (172, 16...31), (192, 168):
            return true
        default:
            return false
        }
    }

    private static func sessionError(from error: any Error) -> SessionError {
        if let sessionError = error as? SessionError {
            return sessionError
        }
        if let dialError = error as? DialError, dialError == .relayUnauthorized {
            return .revoked
        }
        if let dialError = error as? DialError, dialError == .relayTokenExpired {
            return .tokenExpired
        }
        if let tlsError = error as? InnerTLSError {
            return .tlsFailed(String(describing: tlsError))
        }
        return .unreachable
    }

    private static func aggregateFailure(sawRevocation: Bool, sawTokenExpired: Bool) -> SessionError {
        if sawRevocation {
            return .revoked
        }
        if sawTokenExpired {
            return .tokenExpired
        }
        return .unreachable
    }
}

private func * (duration: Duration, multiplier: Int) -> Duration {
    let components = duration.components
    let milliseconds = Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    return .milliseconds(milliseconds * multiplier)
}
