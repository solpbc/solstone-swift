// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

nonisolated private let watchRelayRecoveryLeaseLog = Logger(
    subsystem: "app.solstone.swift",
    category: "watch-relay-recovery"
)

nonisolated enum WatchRelayRecoveryLeaseKind: String, Codable, Equatable, Sendable {
    case tagged
    case legacy
}

nonisolated struct WatchRelayRecoveryLeaseRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let filename = "relay-recovery-lease.json"

    let version: Int
    let segmentID: UUID
    let kind: WatchRelayRecoveryLeaseKind
    let generation: Int?
    let attemptID: UUID?
    let attemptStartedAt: Date?
    let legacyLatestEnqueuedAt: Date?
    let legacyAttemptCount: Int?
    let leaseStartedAt: Date
    let routeEraID: UUID
    let successfulTransferBaseline: Int
    let durableACKBaseline: Int

    init(
        version: Int = Self.currentVersion,
        segmentID: UUID,
        kind: WatchRelayRecoveryLeaseKind,
        generation: Int? = nil,
        attemptID: UUID? = nil,
        attemptStartedAt: Date? = nil,
        legacyLatestEnqueuedAt: Date? = nil,
        legacyAttemptCount: Int? = nil,
        leaseStartedAt: Date,
        routeEraID: UUID,
        successfulTransferBaseline: Int,
        durableACKBaseline: Int
    ) {
        self.version = version
        self.segmentID = segmentID
        self.kind = kind
        self.generation = generation
        self.attemptID = attemptID
        self.attemptStartedAt = attemptStartedAt
        self.legacyLatestEnqueuedAt = legacyLatestEnqueuedAt
        self.legacyAttemptCount = legacyAttemptCount
        self.leaseStartedAt = leaseStartedAt
        self.routeEraID = routeEraID
        self.successfulTransferBaseline = successfulTransferBaseline
        self.durableACKBaseline = durableACKBaseline
    }

    static func tagged(
        segmentID: UUID,
        attempt: WatchRelayAttemptRecord,
        route: WatchRelayRecoveryRouteRecord
    ) -> Self {
        Self(
            segmentID: segmentID,
            kind: .tagged,
            generation: attempt.generation,
            attemptID: attempt.attemptID,
            attemptStartedAt: attempt.attemptStartedAt,
            leaseStartedAt: attempt.attemptStartedAt,
            routeEraID: route.eraID,
            successfulTransferBaseline: route.successfulTransferGeneration,
            durableACKBaseline: route.durableACKGeneration
        )
    }

    static func legacy(
        segmentID: UUID,
        latestEnqueuedAt: Date,
        attemptCount: Int,
        leaseStartedAt: Date,
        route: WatchRelayRecoveryRouteRecord
    ) -> Self {
        Self(
            segmentID: segmentID,
            kind: .legacy,
            legacyLatestEnqueuedAt: latestEnqueuedAt,
            legacyAttemptCount: attemptCount,
            leaseStartedAt: leaseStartedAt,
            routeEraID: route.eraID,
            successfulTransferBaseline: route.successfulTransferGeneration,
            durableACKBaseline: route.durableACKGeneration
        )
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

@MainActor
struct WatchRelayRecoveryLeaseCandidate {
    let lease: WatchRelayRecoveryLeaseRecord
    let observation: WatchConnectivityFileTransferObservation
}

@MainActor
final class WatchRelayRecoveryLeaseStore {
    private enum LeaseReadResult {
        case missing
        case valid(WatchRelayRecoveryLeaseRecord)
        case invalid
        case unavailable(any Error)
    }

    private enum CurrentIdentity: Equatable {
        case tagged(WatchRelayAttemptRecord)
        case legacy(latestEnqueuedAt: Date, attemptCount: Int)
    }

    private let storage: WatchCaptureStorage
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(storage: WatchCaptureStorage) {
        self.storage = storage
        self.encoder = WatchRelayRecoveryLeaseRecord.makeEncoder()
        self.decoder = WatchRelayRecoveryLeaseRecord.makeDecoder()
    }

    func leaseURL(directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent(WatchRelayRecoveryLeaseRecord.filename, isDirectory: false)
    }

    @discardableResult
    func recordNewTaggedLease(
        manifest: WatchSegmentManifest,
        directoryURL: URL,
        attempt: WatchRelayAttemptRecord,
        route: WatchRelayRecoveryRouteRecord
    ) -> Bool {
        let lease = WatchRelayRecoveryLeaseRecord.tagged(
            segmentID: manifest.id,
            attempt: attempt,
            route: route
        )
        do {
            try self.write(lease, directoryURL: directoryURL)
            return true
        } catch {
            self.logFailure("write", segmentID: manifest.id, error: error)
            return false
        }
    }

    func reconcile(
        manifest: WatchSegmentManifest,
        directoryURL: URL,
        observations: [WatchConnectivityFileTransferObservation],
        route: WatchRelayRecoveryRouteRecord,
        diagnosticsStore: WatchRelayDiagnosticsStore?,
        now: Date
    ) -> WatchRelayRecoveryLeaseCandidate? {
        guard observations.count == 1, let observation = observations.first,
              observation.snapshot.segmentID == manifest.id,
              observation.snapshot.idState == .parseable,
              let identity = self.currentIdentity(
                  manifest: manifest,
                  directoryURL: directoryURL,
                  observation: observation,
                  diagnosticsStore: diagnosticsStore
              )
        else {
            return nil
        }

        switch self.readLease(
            directoryURL: directoryURL,
            expectedSegmentID: manifest.id,
            currentRoute: route
        ) {
        case let .valid(lease) where self.matches(lease: lease, identity: identity, route: route):
            return WatchRelayRecoveryLeaseCandidate(lease: lease, observation: observation)
        case .valid, .missing, .invalid:
            let replacement = self.makeLease(
                segmentID: manifest.id,
                identity: identity,
                leaseStartedAt: self.safeLeaseStartedAt(now: now, identity: identity),
                route: route
            )
            do {
                try self.write(replacement, directoryURL: directoryURL)
                return WatchRelayRecoveryLeaseCandidate(lease: replacement, observation: observation)
            } catch {
                self.logFailure("write", segmentID: manifest.id, error: error)
                return nil
            }
        case let .unavailable(error):
            self.logFailure("read", segmentID: manifest.id, error: error)
            return nil
        }
    }
}

private extension WatchRelayRecoveryLeaseStore {
    private func currentIdentity(
        manifest: WatchSegmentManifest,
        directoryURL: URL,
        observation: WatchConnectivityFileTransferObservation,
        diagnosticsStore: WatchRelayDiagnosticsStore?
    ) -> CurrentIdentity? {
        let states = [
            observation.generationState,
            observation.attemptIDState,
            observation.attemptStartedAtState,
        ]
        if states.allSatisfy({ $0 == .parseable }) {
            guard let generation = observation.generation,
                  let attemptID = observation.attemptID,
                  let attemptStartedAt = observation.attemptStartedAt,
                  let attempt = self.readValidAttempt(
                      expectedSegmentID: manifest.id,
                      directoryURL: directoryURL
                  ),
                  attempt.generation == generation,
                  attempt.attemptID == attemptID,
                  attempt.attemptStartedAt == attemptStartedAt
            else {
                return nil
            }
            return .tagged(attempt)
        }

        guard states.allSatisfy({ $0 == .missing }),
              let diagnosticsStore,
              case let .available(sidecar) = diagnosticsStore.readSidecar(
                  manifest: manifest,
                  directoryURL: directoryURL
              ),
              let latestEnqueuedAt = sidecar.latestEnqueuedAt,
              latestEnqueuedAt.timeIntervalSince1970.isFinite,
              sidecar.attemptCount > 0,
              sidecar.attemptCount < Int.max
        else {
            return nil
        }
        return .legacy(latestEnqueuedAt: latestEnqueuedAt, attemptCount: sidecar.attemptCount)
    }

    func readValidAttempt(
        expectedSegmentID: UUID,
        directoryURL: URL
    ) -> WatchRelayAttemptRecord? {
        let url = directoryURL.appendingPathComponent(WatchRelayAttemptRecord.filename, isDirectory: false)
        guard self.storage.fileWriter.fileExists(at: url) else { return nil }
        do {
            let attempt = try WatchRelayAttemptRecord.makeDecoder().decode(
                WatchRelayAttemptRecord.self,
                from: self.storage.fileWriter.readData(from: url)
            )
            guard attempt.version == WatchRelayAttemptRecord.currentVersion,
                  attempt.segmentID == expectedSegmentID,
                  attempt.generation >= 0,
                  attempt.attemptStartedAt.timeIntervalSince1970.isFinite
            else {
                return nil
            }
            return attempt
        } catch {
            return nil
        }
    }

    private func readLease(
        directoryURL: URL,
        expectedSegmentID: UUID,
        currentRoute: WatchRelayRecoveryRouteRecord
    ) -> LeaseReadResult {
        let url = self.leaseURL(directoryURL: directoryURL)
        guard self.storage.fileWriter.fileExists(at: url) else { return .missing }
        let data: Data
        do {
            data = try self.storage.fileWriter.readData(from: url)
        } catch {
            return .unavailable(error)
        }
        do {
            let lease = try self.decoder.decode(WatchRelayRecoveryLeaseRecord.self, from: data)
            guard self.isSemanticallyValid(
                lease,
                expectedSegmentID: expectedSegmentID,
                currentRoute: currentRoute
            ) else {
                return .invalid
            }
            return .valid(lease)
        } catch {
            return .invalid
        }
    }

    func isSemanticallyValid(
        _ lease: WatchRelayRecoveryLeaseRecord,
        expectedSegmentID: UUID,
        currentRoute: WatchRelayRecoveryRouteRecord
    ) -> Bool {
        guard lease.version == WatchRelayRecoveryLeaseRecord.currentVersion,
              lease.segmentID == expectedSegmentID,
              lease.leaseStartedAt.timeIntervalSince1970.isFinite,
              lease.successfulTransferBaseline >= 0,
              lease.successfulTransferBaseline < Int.max,
              lease.durableACKBaseline >= 0,
              lease.durableACKBaseline < Int.max
        else {
            return false
        }
        if lease.routeEraID == currentRoute.eraID {
            guard lease.successfulTransferBaseline <= currentRoute.successfulTransferGeneration,
                  lease.durableACKBaseline <= currentRoute.durableACKGeneration
            else {
                return false
            }
        }
        switch lease.kind {
        case .tagged:
            return lease.generation.map { $0 >= 0 } == true
                && lease.attemptID != nil
                && lease.attemptStartedAt?.timeIntervalSince1970.isFinite == true
                && lease.attemptStartedAt.map { lease.leaseStartedAt >= $0 } == true
                && lease.legacyLatestEnqueuedAt == nil
                && lease.legacyAttemptCount == nil
        case .legacy:
            return lease.generation == nil
                && lease.attemptID == nil
                && lease.attemptStartedAt == nil
                && lease.legacyLatestEnqueuedAt?.timeIntervalSince1970.isFinite == true
                && lease.legacyAttemptCount.map { $0 > 0 && $0 < Int.max } == true
                && lease.legacyLatestEnqueuedAt.map { lease.leaseStartedAt >= $0 } == true
        }
    }

    private func safeLeaseStartedAt(now: Date, identity: CurrentIdentity) -> Date {
        switch identity {
        case let .tagged(attempt):
            return max(now, attempt.attemptStartedAt)
        case let .legacy(latestEnqueuedAt, _):
            return max(now, latestEnqueuedAt)
        }
    }

    private func matches(
        lease: WatchRelayRecoveryLeaseRecord,
        identity: CurrentIdentity,
        route: WatchRelayRecoveryRouteRecord
    ) -> Bool {
        guard lease.routeEraID == route.eraID else { return false }
        switch identity {
        case let .tagged(attempt):
            return lease.kind == .tagged
                && lease.generation == attempt.generation
                && lease.attemptID == attempt.attemptID
                && lease.attemptStartedAt == attempt.attemptStartedAt
        case let .legacy(latestEnqueuedAt, attemptCount):
            return lease.kind == .legacy
                && lease.legacyLatestEnqueuedAt == latestEnqueuedAt
                && lease.legacyAttemptCount == attemptCount
        }
    }

    private func makeLease(
        segmentID: UUID,
        identity: CurrentIdentity,
        leaseStartedAt: Date,
        route: WatchRelayRecoveryRouteRecord
    ) -> WatchRelayRecoveryLeaseRecord {
        switch identity {
        case let .tagged(attempt):
            return WatchRelayRecoveryLeaseRecord(
                segmentID: segmentID,
                kind: .tagged,
                generation: attempt.generation,
                attemptID: attempt.attemptID,
                attemptStartedAt: attempt.attemptStartedAt,
                leaseStartedAt: leaseStartedAt,
                routeEraID: route.eraID,
                successfulTransferBaseline: route.successfulTransferGeneration,
                durableACKBaseline: route.durableACKGeneration
            )
        case let .legacy(latestEnqueuedAt, attemptCount):
            return WatchRelayRecoveryLeaseRecord.legacy(
                segmentID: segmentID,
                latestEnqueuedAt: latestEnqueuedAt,
                attemptCount: attemptCount,
                leaseStartedAt: leaseStartedAt,
                route: route
            )
        }
    }

    func write(_ lease: WatchRelayRecoveryLeaseRecord, directoryURL: URL) throws {
        let data = try self.encoder.encode(lease)
        try self.storage.fileWriter.writeData(
            data,
            to: self.leaseURL(directoryURL: directoryURL),
            options: .atomic
        )
    }

    func logFailure(_ operation: String, segmentID: UUID, error: any Error) {
        watchRelayRecoveryLeaseLog.error(
            "watch relay recovery lease \(operation, privacy: .public) failed id=\(segmentID.uuidString, privacy: .public): \(String(describing: error), privacy: .private)"
        )
    }
}
