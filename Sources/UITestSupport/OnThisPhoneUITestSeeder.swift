// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if DEBUG
import Foundation
import os

private let onThisPhoneUITestSeedLog = Logger(subsystem: "app.solstone.swift", category: "ui-test-seed")

@MainActor
enum OnThisPhoneUITestSeeder {
    private static let defaultSeedFlag = "--ui-test-seed-on-this-phone"
    private static let agedBacklogSeedFlag = "--ui-test-seed-aged-backlog"
    private static let resetNudgeDismissalFlag = "--ui-test-reset-nudge-dismissal"

    static func runIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        fileManager: FileManager = .default
    ) {
        guard arguments.contains("--ui-test") else { return }

        if arguments.contains(Self.resetNudgeDismissalFlag) {
            UserSettings.onThisPhoneBacklogNudgeDismissed = false
        }

        let seedDefault = arguments.contains(Self.defaultSeedFlag)
        let seedAgedBacklog = arguments.contains(Self.agedBacklogSeedFlag)
        guard seedDefault || seedAgedBacklog else { return }

        do {
            let roots = try Self.roots(fileManager: fileManager)
            try Self.reset(roots: roots, fileManager: fileManager)
            if seedAgedBacklog {
                try Self.seedAgedBacklog(roots: roots, fileManager: fileManager)
            } else {
                try Self.seedDefault(roots: roots, fileManager: fileManager)
            }
            onThisPhoneUITestSeedLog.info("on-this-phone ui-test seed complete")
        } catch {
            let detail = String(describing: error)
            onThisPhoneUITestSeedLog.error("on-this-phone ui-test seed failed: \(detail, privacy: .public)")
        }
    }
}

private extension OnThisPhoneUITestSeeder {
    static let observerRootName = "observer".capitalized
    static let locationRootName = "location".capitalized
    static let importQueueRootName = ["import", "queue"].map { $0.capitalized }.joined()

    struct Roots {
        let observer: URL
        let location: URL
        let importQueue: URL
    }

    static func roots(fileManager: FileManager) throws -> Roots {
        let cachesRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return Roots(
            observer: cachesRoot.appendingPathComponent(Self.observerRootName, isDirectory: true),
            location: cachesRoot.appendingPathComponent(Self.locationRootName, isDirectory: true),
            importQueue: try AppGroupContainer.rootURL(fileManager: fileManager)
                .appendingPathComponent(Self.importQueueRootName, isDirectory: true)
        )
    }

    static func reset(roots: Roots, fileManager: FileManager) throws {
        for root in [roots.observer, roots.location, roots.importQueue] where fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
    }

    static func seedDefault(roots: Roots, fileManager: FileManager) throws {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        try Self.writeObserverChunk(
            root: roots.observer,
            sessionID: sessionID,
            chunkID: "seed-audio-1",
            startedAt: Date(timeIntervalSince1970: 1_780_480_800),
            durationS: 75,
            fileManager: fileManager
        )
        try Self.writeObserverChunk(
            root: roots.observer,
            sessionID: sessionID,
            chunkID: "seed-audio-2",
            startedAt: Date(timeIntervalSince1970: 1_780_480_500),
            durationS: 142,
            fileManager: fileManager
        )

        try Self.writeLocationSegment(
            root: roots.location,
            status: "pending",
            fileID: "20260603-110000_300",
            fixCount: 2,
            fileManager: fileManager
        )
        try Self.writeLocationSegment(
            root: roots.location,
            status: "pending",
            fileID: "20260603-111000_300",
            fixCount: 4,
            fileManager: fileManager
        )
        try Self.writeLocationSegment(
            root: roots.location,
            status: "failed",
            fileID: "20260603-112000_300",
            fixCount: 5,
            fileManager: fileManager
        )

        try Self.writeShareItem(
            root: roots.importQueue,
            itemID: "11111111-1111-1111-1111-111111111111",
            itemTime: Date(timeIntervalSince1970: 1_780_477_200),
            fileManager: fileManager
        )
    }

    static func seedAgedBacklog(roots: Roots, fileManager: FileManager) throws {
        for index in 0..<51 {
            let hour = index / 12
            let minute = (index % 12) * 5
            let fileID = String(format: "20200101-%02d%02d00_300", hour, minute)
            try Self.writeLocationSegment(
                root: roots.location,
                status: "pending",
                fileID: fileID,
                fixCount: 1,
                fileManager: fileManager
            )
        }
    }

    static func writeObserverChunk(
        root: URL,
        sessionID: UUID,
        chunkID: String,
        startedAt: Date,
        durationS: TimeInterval,
        fileManager: FileManager
    ) throws {
        let directory = root
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("pending", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: directory.appendingPathComponent("\(chunkID).m4a"), options: .atomic)

        let sidecar = ChunkSidecar(
            segment: "120000_300",
            day: "20260603",
            chunkIndex: 0,
            startedAt: startedAt,
            durationS: durationS,
            sessionID: sessionID,
            mode: .meeting
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(sidecar).write(to: directory.appendingPathComponent("\(chunkID).json"), options: .atomic)
    }

    static func writeLocationSegment(
        root: URL,
        status: String,
        fileID: String,
        fixCount: Int,
        fileManager: FileManager
    ) throws {
        let directory = root.appendingPathComponent(status, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let header = [
            "accuracy": "full",
            "fix_count": fixCount,
            "gap": false,
            "kind": "location",
            "platform": "ios",
            "schema": "solstone.location.segment/1",
            "source": "location",
            "tier": "balanced",
        ] as [String: Any]
        var data = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        data.append(0x0A)
        try data.write(to: directory.appendingPathComponent("\(fileID).jsonl"), options: .atomic)
    }

    static func writeShareItem(
        root: URL,
        itemID: String,
        itemTime: Date,
        fileManager: FileManager
    ) throws {
        let pendingRoot = root.appendingPathComponent("pending", isDirectory: true)
        let failedRoot = root.appendingPathComponent("failed", isDirectory: true)
        let itemDirectory = pendingRoot.appendingPathComponent(itemID, isDirectory: true)
        try fileManager.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: failedRoot, withIntermediateDirectories: true)

        let rawData = Data("seed share".utf8)
        try rawData.write(to: itemDirectory.appendingPathComponent("raw.bin"), options: .atomic)

        let note: [String: Any] = [
            "basis": "sent",
            "bytes": rawData.count,
            "content_type": "application/pdf",
            "filename": "seed-share.pdf",
            "item_id": itemID,
            "item_time": Self.iso8601String(for: itemTime),
            "kind": "raw",
            "origin_app": NSNull(),
            "schema": "solstone.source.item/1",
            "source": "share-sheet",
            "target_journal": "ui-test",
        ]
        try JSONSerialization.data(withJSONObject: note, options: [.sortedKeys])
            .write(to: itemDirectory.appendingPathComponent("item.json"), options: .atomic)

        let descriptor: [String: Any] = [
            "content_type": "application/pdf",
            "day": "20260603",
            "filename": "document.pdf",
            "segment": "100000_0",
            "stream": "import.share",
        ]
        try JSONSerialization.data(withJSONObject: descriptor, options: [.sortedKeys])
            .write(to: itemDirectory.appendingPathComponent("request.json"), options: .atomic)
    }

    static func iso8601String(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
#endif
