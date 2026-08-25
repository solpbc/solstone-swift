// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import WidgetKit
import os

nonisolated private let appGroupMirrorLog = Logger(subsystem: "app.solstone.swift", category: "app-group-mirror")

@MainActor
protocol AppGroupTimelineReloading {
    func reloadTimelines(ofKind kind: String)
}

@MainActor
struct AppGroupWidgetTimelineReloader: AppGroupTimelineReloading {
    func reloadTimelines(ofKind kind: String) {
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }
}

@MainActor
@Observable
final class AppGroupMirror {
    struct PairingSnapshot: Codable, Equatable, Sendable {
        let journalName: String?
        let isPaired: Bool
    }

    enum MicrophonePermissionSnapshot: Codable, Equatable, Sendable {
        case granted
        case undetermined
        case denied
    }

    enum SessionState: Codable, Equatable, Sendable {
        case notLive
        case live(mode: ObserverMode, startedAt: Date)
    }

    struct Snapshot: Codable, Equatable, Sendable {
        static let currentSchemaVersion = 1
        static let maximumAge: Duration = .seconds(60)
        static let activeSessionHeartbeatInterval: Duration = .seconds(30)
        static let widgetKind = "SolstoneObserverStatus"

        static let fileName = "observer-status.json"

        var schemaVersion: Int
        var writtenAt: Date
        var pairing: PairingSnapshot
        var microphonePermission: MicrophonePermissionSnapshot?
        var session: SessionState
        var sourceStates: [SourceKind: SourceState]
        var backlogCount: Int
    }

    enum StorageError: Error, Equatable, Sendable {
        case containerUnavailable
        case encodingFailed
        case writeFailed
    }

    @ObservationIgnored private let rootURLProvider: @Sendable () throws -> URL
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let timelineReloader: any AppGroupTimelineReloading

    init(
        rootURLProvider: @escaping @Sendable () throws -> URL = { try AppGroupContainer.rootURL() },
        now: @escaping @Sendable () -> Date = Date.init,
        timelineReloader: any AppGroupTimelineReloading = AppGroupWidgetTimelineReloader()
    ) {
        self.rootURLProvider = rootURLProvider
        self.now = now
        self.timelineReloader = timelineReloader
    }

    /// A missing, unreadable, malformed, or stale file is one uniform unknown.
    func snapshot() -> Snapshot? {
        let now = self.now()
        guard let snapshot = self.readStoredSnapshot(), self.isFresh(snapshot, now: now) else {
            return nil
        }
        return snapshot
    }

    @discardableResult
    func writePairing(journalName: String) -> Result<Void, StorageError> {
        self.write { snapshot, now in
            snapshot.pairing = PairingSnapshot(journalName: journalName, isPaired: true)
            snapshot.writtenAt = now
        }
    }

    @discardableResult
    func clearPairing() -> Result<Void, StorageError> {
        self.write { snapshot, now in
            snapshot.pairing = PairingSnapshot(journalName: nil, isPaired: false)
            snapshot.writtenAt = now
        }
    }

    @discardableResult
    func updateSessionAndSources(
        pairing: PairingSnapshot,
        microphonePermission: MicrophonePermissionSnapshot,
        session: SessionState,
        sourceStates: [SourceKind: SourceState],
        backlogCount: Int
    ) -> Result<Void, StorageError> {
        let now = self.now()
        let existing = self.freshSnapshotOrDefault(now: now)
        if existing.isStoredSnapshot,
           existing.snapshot.session == session,
           existing.snapshot.sourceStates == sourceStates,
           existing.snapshot.backlogCount == backlogCount,
           existing.snapshot.pairing == pairing,
           existing.snapshot.microphonePermission == microphonePermission,
           self.isWithinHeartbeatInterval(existing.snapshot, now: now)
        {
            return .success(())
        }

        var snapshot = existing.snapshot
        snapshot.pairing = pairing
        snapshot.microphonePermission = microphonePermission
        snapshot.session = session
        snapshot.sourceStates = sourceStates
        snapshot.backlogCount = backlogCount
        snapshot.writtenAt = now

        switch self.write(snapshot) {
        case .success:
            self.timelineReloader.reloadTimelines(ofKind: Snapshot.widgetKind)
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }
}

private extension AppGroupMirror {
    func write(_ update: (inout Snapshot, Date) -> Void) -> Result<Void, StorageError> {
        let now = self.now()
        var snapshot = self.freshSnapshotOrDefault(now: now).snapshot
        update(&snapshot, now)
        return self.write(snapshot)
    }

    func write(_ snapshot: Snapshot) -> Result<Void, StorageError> {
        let rootURL: URL
        do {
            rootURL = try self.rootURLProvider()
        } catch {
            appGroupMirrorLog.error("app group snapshot write failed: container unavailable")
            return .failure(.containerUnavailable)
        }

        let data: Data
        do {
            data = try JSONEncoder().encode(snapshot)
        } catch {
            appGroupMirrorLog.error("app group snapshot write failed: encoding failed")
            return .failure(.encodingFailed)
        }

        let destinationURL = rootURL.appendingPathComponent(Snapshot.fileName)
        let temporaryURL = rootURL.appendingPathComponent(".\(Snapshot.fileName).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporaryURL)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: temporaryURL.path
            )
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            }
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destinationURL.path
            )
            return .success(())
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            appGroupMirrorLog.error("app group snapshot write failed: file write failed")
            return .failure(.writeFailed)
        }
    }

    func readStoredSnapshot() -> Snapshot? {
        let rootURL: URL
        do {
            rootURL = try self.rootURLProvider()
        } catch {
            return nil
        }
        let url = rootURL.appendingPathComponent(Snapshot.fileName)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.schemaVersion == Snapshot.currentSchemaVersion
        else {
            return nil
        }
        return snapshot
    }

    func freshSnapshotOrDefault(now: Date) -> (snapshot: Snapshot, isStoredSnapshot: Bool) {
        guard let snapshot = self.readStoredSnapshot(), self.isFresh(snapshot, now: now) else {
            return (self.defaultSnapshot(writtenAt: now), false)
        }
        return (snapshot, true)
    }

    func defaultSnapshot(writtenAt: Date) -> Snapshot {
        Snapshot(
            schemaVersion: Snapshot.currentSchemaVersion,
            writtenAt: writtenAt,
            pairing: PairingSnapshot(journalName: nil, isPaired: false),
            microphonePermission: nil,
            session: .notLive,
            sourceStates: [:],
            backlogCount: 0
        )
    }

    func isFresh(_ snapshot: Snapshot, now: Date) -> Bool {
        now <= snapshot.writtenAt.addingTimeInterval(Self.seconds(Snapshot.maximumAge))
    }

    func isWithinHeartbeatInterval(_ snapshot: Snapshot, now: Date) -> Bool {
        now <= snapshot.writtenAt.addingTimeInterval(Self.seconds(Snapshot.activeSessionHeartbeatInterval))
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
