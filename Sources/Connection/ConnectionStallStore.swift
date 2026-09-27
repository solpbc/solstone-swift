// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct ConnectionStallSnapshot: Equatable, Sendable {
    var lastHeardFromJournalAt: Date?
    var lastHeardPairingIdentity: String?
    var stallClockSeededAt: Date?
    var carriedStall: Bool
}

@MainActor
protocol ConnectionStallStoring: AnyObject {
    func load() -> ConnectionStallSnapshot
    func setLastHeard(at: Date, pairingIdentity: String)
    func setStallClockSeededAt(_ date: Date)
    func setCarriedStall(_ carried: Bool)
}

@MainActor
final class InMemoryConnectionStallStore: ConnectionStallStoring {
    private var snapshot: ConnectionStallSnapshot

    init(snapshot: ConnectionStallSnapshot = ConnectionStallSnapshot(
        lastHeardFromJournalAt: nil,
        lastHeardPairingIdentity: nil,
        stallClockSeededAt: nil,
        carriedStall: false
    )) {
        self.snapshot = snapshot
    }

    func load() -> ConnectionStallSnapshot {
        self.snapshot
    }

    func setLastHeard(at: Date, pairingIdentity: String) {
        self.snapshot.lastHeardFromJournalAt = at
        self.snapshot.lastHeardPairingIdentity = pairingIdentity
    }

    func setStallClockSeededAt(_ date: Date) {
        self.snapshot.stallClockSeededAt = date
    }

    func setCarriedStall(_ carried: Bool) {
        self.snapshot.carriedStall = carried
    }
}

@MainActor
final class UserDefaultsConnectionStallStore: ConnectionStallStoring {
    private let defaults: UserDefaults

    private enum Keys {
        static let lastHeardFromJournalAt = "connectionStall.lastHeardFromJournalAt"
        static let lastHeardPairingIdentity = "connectionStall.lastHeardPairingIdentity"
        static let stallClockSeededAt = "connectionStall.stallClockSeededAt"
        static let carriedStall = "connectionStall.carriedStall"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ConnectionStallSnapshot {
        let lastHeardInterval = self.defaults.object(forKey: Keys.lastHeardFromJournalAt) as? TimeInterval
        let lastHeardDate = lastHeardInterval.map { Date(timeIntervalSince1970: $0) }
        let lastHeardIdentity = self.defaults.string(forKey: Keys.lastHeardPairingIdentity)

        let seededInterval = self.defaults.object(forKey: Keys.stallClockSeededAt) as? TimeInterval
        let seededDate = seededInterval.map { Date(timeIntervalSince1970: $0) }

        let carried = self.defaults.bool(forKey: Keys.carriedStall)

        return ConnectionStallSnapshot(
            lastHeardFromJournalAt: lastHeardDate,
            lastHeardPairingIdentity: lastHeardIdentity,
            stallClockSeededAt: seededDate,
            carriedStall: carried
        )
    }

    func setLastHeard(at: Date, pairingIdentity: String) {
        self.defaults.set(at.timeIntervalSince1970, forKey: Keys.lastHeardFromJournalAt)
        self.defaults.set(pairingIdentity, forKey: Keys.lastHeardPairingIdentity)
    }

    func setStallClockSeededAt(_ date: Date) {
        self.defaults.set(date.timeIntervalSince1970, forKey: Keys.stallClockSeededAt)
    }

    func setCarriedStall(_ carried: Bool) {
        self.defaults.set(carried, forKey: Keys.carriedStall)
    }
}

enum ConnectionStallStoreFactory {
    static func make(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any ConnectionStallStoring {
#if DEBUG
        let lowercasedEnvKeys = Set(environment.keys.map { $0.lowercased() })
        if arguments.contains("--ui-test")
            || arguments.contains("--integration-test")
            || arguments.contains("--integration-test-live")
            || lowercasedEnvKeys.contains("xctestconfigurationfilepath")
        {
            return InMemoryConnectionStallStore()
        }
        return UserDefaultsConnectionStallStore(defaults: .standard)
#else
        return UserDefaultsConnectionStallStore(defaults: .standard)
#endif
    }
}
