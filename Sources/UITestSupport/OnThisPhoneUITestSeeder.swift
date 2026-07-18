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
    private static let audioMagicSeedFlag = "--ui-test-seed-audio-magic"
    private static let audioMagicDurationPrefix = "--ui-test-seed-audio-magic-duration="
    private static let largeBacklogSeedFlag = "--ui-test-seed-large-backlog"
    private static let largeBacklogCountPrefix = "--ui-test-seed-large-backlog-count="
    private static let resetAudioL5Flag = "--ui-test-reset-audio-l5"
    private static let resetNudgeDismissalFlag = "--ui-test-reset-nudge-dismissal"
    private static let resetOnThisPhoneFlag = "--ui-test-reset-on-this-phone"
    private static let largeBacklogDefaultCount = 800
    private static let largeBacklogMaxCount = 2_000

    static func runIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        fileManager: FileManager = .default
    ) {
        guard arguments.contains("--ui-test") else { return }

        if arguments.contains(Self.resetNudgeDismissalFlag) {
            UserSettings.onThisPhoneBacklogNudgeDismissed = false
        }
        if arguments.contains(Self.resetAudioL5Flag) {
            Self.resetAudioL5State()
        }

        let seedDefault = arguments.contains(Self.defaultSeedFlag)
        let seedAgedBacklog = arguments.contains(Self.agedBacklogSeedFlag)
        let seedAudioMagic = arguments.contains(Self.audioMagicSeedFlag)
        let seedLargeBacklog = arguments.contains(Self.largeBacklogSeedFlag)
        let resetOnThisPhone = arguments.contains(Self.resetOnThisPhoneFlag)
        guard resetOnThisPhone || seedDefault || seedAgedBacklog || seedAudioMagic || seedLargeBacklog else { return }

        do {
            let roots = try Self.roots(fileManager: fileManager)
            try Self.reset(roots: roots, fileManager: fileManager)
            guard seedDefault || seedAgedBacklog || seedAudioMagic || seedLargeBacklog else {
                onThisPhoneUITestSeedLog.info("on-this-phone ui-test reset complete")
                return
            }
            if seedAudioMagic {
                try Self.seedAudioMagic(
                    roots: roots,
                    durationS: Self.audioMagicDuration(arguments: arguments),
                    fileManager: fileManager
                )
            } else if seedLargeBacklog {
                let requested = Self.largeBacklogCount(arguments: arguments)
                let summary = try Self.seedLargeBacklog(
                    transferRoot: roots.transfer,
                    requestedCount: requested,
                    fileManager: fileManager
                )
                onThisPhoneUITestSeedLog.info(
                    "on-this-phone large backlog seed mobile=\(summary.mobile, privacy: .public) omi=\(summary.omi, privacy: .public) total=\(summary.total, privacy: .public)"
                )
                if summary.total != requested {
                    onThisPhoneUITestSeedLog.error(
                        "on-this-phone large backlog seed count mismatch requested=\(requested, privacy: .public) total=\(summary.total, privacy: .public)"
                    )
                    throw SeedError.largeBacklogCountMismatch(requested: requested, actual: summary.total)
                }
            } else if seedAgedBacklog {
                try Self.seedAgedBacklog(roots: roots, fileManager: fileManager)
            } else {
                try Self.seedDefault(roots: roots, fileManager: fileManager)
            }
            if !seedAudioMagic {
                UserDefaults.standard.set(true, forKey: AudioStorageKey.magicMomentFirstSeen)
            }
            onThisPhoneUITestSeedLog.info("on-this-phone ui-test seed complete")
        } catch {
            let detail = String(describing: error)
            onThisPhoneUITestSeedLog.error("on-this-phone ui-test seed failed: \(detail, privacy: .public)")
        }
    }
}

extension OnThisPhoneUITestSeeder {
    static let observerRootName = "observer".capitalized
    static let locationRootName = "location".capitalized
    static let importQueueRootName = ["import", "queue"].map { $0.capitalized }.joined()

        struct Roots {
            let observer: URL
            let omi: URL
            let transfer: URL
            let location: URL
            let mobileSegment: URL
            let importQueue: URL
        }

    struct LargeBacklogSeedSummary: Equatable {
        let mobile: Int
        let omi: Int
        let total: Int
    }

    enum SeedError: Error, CustomStringConvertible {
        case largeBacklogCountMismatch(requested: Int, actual: Int)

        var description: String {
            switch self {
            case .largeBacklogCountMismatch(let requested, let actual):
                "large backlog seed count mismatch requested=\(requested) actual=\(actual)"
            }
        }
    }

    static func roots(fileManager: FileManager) throws -> Roots {
        let cachesRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return Roots(
                observer: cachesRoot.appendingPathComponent(Self.observerRootName, isDirectory: true),
                omi: cachesRoot.appendingPathComponent(OmiSegmentWriter.cacheDirectoryName, isDirectory: true),
                transfer: try AppGroupContainer.rootURL(fileManager: fileManager)
                    .appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true),
                location: cachesRoot.appendingPathComponent(Self.locationRootName, isDirectory: true),
                mobileSegment: try AppGroupContainer.rootURL(fileManager: fileManager)
                    .appendingPathComponent(MobileSegmentStore.directoryName, isDirectory: true),
                importQueue: try AppGroupContainer.rootURL(fileManager: fileManager)
                    .appendingPathComponent(Self.importQueueRootName, isDirectory: true)
        )
    }

    static func reset(roots: Roots, fileManager: FileManager) throws {
        for root in [roots.observer, roots.omi, roots.transfer, roots.location, roots.mobileSegment, roots.importQueue] where fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        UserDefaults.standard.removeObject(forKey: "didMigrateLegacyMobileSegmentsV1")
        UserDefaults.standard.removeObject(forKey: ShareImportTransferSpoolMigrator.flagKey)
        Self.resetAudioL5State()
    }

    static func largeBacklogCount(arguments: [String]) -> Int {
        guard let rawArgument = arguments.first(where: { $0.hasPrefix(Self.largeBacklogCountPrefix) }) else {
            return Self.largeBacklogDefaultCount
        }
        let rawValue = rawArgument.dropFirst(Self.largeBacklogCountPrefix.count)
        guard let parsed = Int(rawValue) else {
            return Self.largeBacklogDefaultCount
        }
        return min(max(parsed, 1), Self.largeBacklogMaxCount)
    }

    static func seedLargeBacklog(
        transferRoot: URL,
        requestedCount: Int,
        fileManager: FileManager
    ) throws -> LargeBacklogSeedSummary {
        let count = min(max(requestedCount, 1), Self.largeBacklogMaxCount)
        let mobileCount = (count + 1) / 2
        let omiCount = count / 2
        let baseDate = Date(timeIntervalSince1970: 1_780_500_000)

        for index in 0..<mobileCount {
            try Self.writeLargeBacklogMobileTransferItem(
                root: transferRoot,
                itemID: Self.largeBacklogSessionID(prefix: "10000000", index: index),
                segmentID: Self.largeBacklogSessionID(prefix: "11000000", index: index),
                startedAt: baseDate.addingTimeInterval(Double(index)),
                durationS: TimeInterval(30 + (index % 90)),
                fileManager: fileManager
            )
        }

        for index in 0..<omiCount {
            try Self.writeLargeBacklogOmiTransferItem(
                root: transferRoot,
                itemID: Self.largeBacklogSessionID(prefix: "20000000", index: index),
                sessionID: Self.largeBacklogSessionID(prefix: "20000000", index: index),
                chunkID: Self.largeBacklogChunkID(source: "omi", index: index),
                startedAt: baseDate.addingTimeInterval(Double(mobileCount + index)),
                durationS: TimeInterval(30 + ((mobileCount + index) % 90)),
                fileManager: fileManager
            )
        }

        return LargeBacklogSeedSummary(mobile: mobileCount, omi: omiCount, total: mobileCount + omiCount)
    }

    private static func largeBacklogSessionID(prefix: String, index: Int) -> UUID {
        UUID(uuidString: String(format: "%@-0000-0000-0000-%012d", prefix, index))!
    }

    private static func largeBacklogChunkID(source: String, index: Int) -> String {
        String(format: "ui-test-large-backlog-%@-%04d", source, index)
    }

    static func seedDefault(roots: Roots, fileManager: FileManager) throws {
        try Self.writeMobileSegment(
            root: roots.mobileSegment,
            segmentID: UUID(uuidString: "edb611fc-5f2c-5218-98bf-7d8006dd36ef")!,
            source: .audio,
            lifecycle: .pending,
            startedAt: Date(timeIntervalSince1970: 1_780_480_800),
            durationS: 75,
            fixCount: nil,
            fileManager: fileManager
        )
        try Self.writeMobileSegment(
            root: roots.mobileSegment,
            segmentID: UUID(uuidString: "c8f5cc35-4783-54d2-9b70-8f6677e8e37d")!,
            source: .audio,
            lifecycle: .pending,
            startedAt: Date(timeIntervalSince1970: 1_780_480_500),
            durationS: 142,
            fixCount: nil,
            fileManager: fileManager
        )

        try Self.writeMobileSegment(
            root: roots.mobileSegment,
            segmentID: UUID(uuidString: "9f4e02bb-2b23-5fc5-90f7-c291755e44f2")!,
            source: .location,
            lifecycle: .pending,
            startedAt: Date(timeIntervalSince1970: 1_780_477_200),
            durationS: 300,
            fixCount: 2,
            fileManager: fileManager
        )
        try Self.writeMobileSegment(
            root: roots.mobileSegment,
            segmentID: UUID(uuidString: "6725b42c-a9d9-5960-8a2c-b73e704170e9")!,
            source: .location,
            lifecycle: .pending,
            startedAt: Date(timeIntervalSince1970: 1_780_477_800),
            durationS: 300,
            fixCount: 4,
            fileManager: fileManager
        )
        try Self.writeMobileSegment(
            root: roots.mobileSegment,
            segmentID: UUID(uuidString: "763c6f54-286b-545a-b4f3-3b90f47782f1")!,
            source: .location,
            lifecycle: .failed,
            startedAt: Date(timeIntervalSince1970: 1_780_478_400),
            durationS: 300,
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
        let baseDate = Date(timeIntervalSince1970: 1_577_836_800)
        for index in 0..<51 {
            let hour = index / 12
            let minute = (index % 12) * 5
            try Self.writeMobileSegment(
                root: roots.mobileSegment,
                segmentID: UUID(uuidString: String(format: "51000000-0000-0000-0000-%012d", index))!,
                source: .location,
                lifecycle: .pending,
                startedAt: baseDate.addingTimeInterval(TimeInterval((hour * 60 + minute) * 60)),
                durationS: 300,
                fixCount: 1,
                fileManager: fileManager
            )
        }
    }

    static func seedAudioMagic(roots: Roots, durationS: TimeInterval, fileManager: FileManager) throws {
        try Self.writeMobileSegment(
            root: roots.mobileSegment,
            segmentID: UUID(uuidString: "a4c3e712-809a-578f-83ed-c903935d5b14")!,
            source: .audio,
            lifecycle: .pending,
            startedAt: Date(timeIntervalSince1970: 1_780_480_900),
            durationS: durationS,
            fixCount: nil,
            fileManager: fileManager
        )
        UserDefaults.standard.set(true, forKey: AudioStorageKey.enrolled)
        UserDefaults.standard.set(false, forKey: AudioStorageKey.magicMomentFirstSeen)
    }

    static func resetAudioL5State() {
        UserDefaults.standard.removeObject(forKey: AudioStorageKey.enrolled)
        UserDefaults.standard.removeObject(forKey: AudioStorageKey.magicMomentFirstSeen)
    }

    static func audioMagicDuration(arguments: [String]) -> TimeInterval {
        guard let rawArgument = arguments.first(where: { $0.hasPrefix(Self.audioMagicDurationPrefix) }) else {
            return 75
        }
        let rawValue = rawArgument.dropFirst(Self.audioMagicDurationPrefix.count)
        return TimeInterval(String(rawValue)) ?? 75
    }

    static func writeLargeBacklogMobileTransferItem(
        root: URL,
        itemID: UUID,
        segmentID: UUID,
        startedAt: Date,
        durationS: TimeInterval,
        fileManager: FileManager
    ) throws {
        let endedAt = startedAt.addingTimeInterval(durationS)
        var mobileManifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.audio],
            activeSourceSetVersion: 0
        )
        mobileManifest.day = Self.dayString(for: startedAt)
        mobileManifest.segment = ChunkSidecar.segmentString(for: startedAt, durationSeconds: durationS)
        mobileManifest.endedAt = endedAt
        mobileManifest.durationS = durationS
        mobileManifest.upload = .pending
        mobileManifest.audio = MobileSegmentSourceResolution(
            state: .finalizedArtifact,
            artifactFilename: "audio.m4a",
            bytes: Int64(Data("audio".utf8).count),
            startedAt: startedAt,
            endedAt: endedAt,
            durationS: durationS,
            mode: .meeting
        )
        let manifest = ObserverAudioTransferEnqueuer.makeMobileSegmentManifest(
            itemID: itemID,
            manifest: mobileManifest,
            now: endedAt,
            sources: [.audio],
            payloadParts: [ObserverAudioTransferEnqueuer.audioPart()]
        )
        try Self.writeTransferItem(root: root, manifest: manifest, payloads: ["audio": Data("audio".utf8)], fileManager: fileManager)
    }

    static func writeLargeBacklogOmiTransferItem(
        root: URL,
        itemID: UUID,
        sessionID: UUID,
        chunkID: String,
        startedAt: Date,
        durationS: TimeInterval,
        fileManager: FileManager
    ) throws {
        let sidecar = ChunkSidecar(
            segment: "120000_300",
            day: "20260603",
            chunkIndex: 0,
            startedAt: startedAt,
            durationS: durationS,
            sessionID: sessionID,
            mode: .meeting,
            locationJSONL: nil
        )
        let manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: itemID, sidecar: sidecar)
        try Self.writeTransferItem(root: root, manifest: manifest, payloads: ["audio": Data("audio-\(chunkID)".utf8)], fileManager: fileManager)
    }

    static func writeTransferItem(
        root: URL,
        manifest: TransferManifest,
        payloads: [String: Data],
        fileManager: FileManager
    ) throws {
        let directory = root
            .appendingPathComponent(TransferSpool.queuedDirectoryName, isDirectory: true)
            .appendingPathComponent(manifest.itemID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for part in manifest.payloadParts {
            guard let data = payloads[part.partID] else { continue }
            let payloadURL = directory.appendingPathComponent(part.relativePath, isDirectory: false)
            try fileManager.createDirectory(at: payloadURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: payloadURL, options: .atomic)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest.replacingDiskState(.queued))
            .write(to: directory.appendingPathComponent(TransferSpool.manifestFilename, isDirectory: false), options: .atomic)
    }

    static func writeMobileSegment(
        root: URL,
        segmentID: UUID,
        source: MobileSegmentSource,
        lifecycle: MobileSegmentLifecycle,
        startedAt: Date,
        durationS: TimeInterval,
        fixCount: Int?,
        fileManager: FileManager
    ) throws {
        let store = MobileSegmentStore(rootURL: root, fileManager: fileManager)
        let endedAt = startedAt.addingTimeInterval(durationS)
        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: Set([source]),
            activeSourceSetVersion: 0
        )
        manifest.day = Self.dayString(for: startedAt)
        manifest.segment = ChunkSidecar.segmentString(for: startedAt, durationSeconds: durationS)
        manifest.endedAt = endedAt
        manifest.durationS = durationS
        manifest.upload = lifecycle == .failed ? .failed : .pending
        let directory = try store.createActive(manifest: manifest)

        switch source {
        case .audio:
            let url = store.audioURL(in: directory)
            try Data("audio".utf8).write(to: url, options: .atomic)
            let resolution = MobileSegmentSourceResolution(
                state: .finalizedArtifact,
                artifactFilename: url.lastPathComponent,
                bytes: store.fileSize(at: url),
                startedAt: startedAt,
                endedAt: endedAt,
                durationS: durationS,
                mode: .meeting
            )
            try store.writeOutcome(resolution, source: .audio, manifest: &manifest, in: directory, now: endedAt)
        case .location:
            let url = store.locationURL(in: directory)
            try Self.locationPayload(fixCount: fixCount ?? 0).write(to: url, options: .atomic)
            let resolution = MobileSegmentSourceResolution(
                state: .finalizedArtifact,
                artifactFilename: url.lastPathComponent,
                bytes: store.fileSize(at: url),
                startedAt: startedAt,
                endedAt: endedAt,
                durationS: durationS,
                fixCount: fixCount
            )
            try store.writeOutcome(resolution, source: .location, manifest: &manifest, in: directory, now: endedAt)
        case .screencast:
            let url = store.screenURL(in: directory)
            try Data("screen".utf8).write(to: url, options: .atomic)
            let resolution = MobileSegmentSourceResolution(
                state: .finalizedArtifact,
                artifactFilename: url.lastPathComponent,
                bytes: store.fileSize(at: url),
                startedAt: startedAt,
                endedAt: endedAt,
                durationS: durationS
            )
            try store.writeOutcome(resolution, source: .screencast, manifest: &manifest, in: directory, now: endedAt)
        }

        if lifecycle == .failed {
            try store.writeFailure(
                MobileSegmentFailureSidecar(
                    reason: "ui test seed failure",
                    httpStatus: nil,
                    transportError: nil,
                    attemptCount: 1,
                    stage: "ui-test-seed",
                    lastAttemptAt: endedAt
                ),
                in: directory
            )
        }
        _ = try store.move(segmentID: segmentID, from: .active, to: lifecycle)
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

    static func locationPayload(fixCount: Int) throws -> Data {
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
        return data
    }

    static func writeShareItem(
        root: URL,
        itemID: String,
        itemTime: Date,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let ledger = [
            itemID: ShareImportStore.LedgerEntry(
                itemID: itemID,
                basis: "sent",
                contentType: "application/pdf",
                targetJournal: "ui-test",
                serverPath: "/ui-test/share/\(itemID)",
                serverTimestamp: Self.iso8601String(for: itemTime.addingTimeInterval(60)),
                deliveredAt: itemTime.addingTimeInterval(60),
                filename: "seed-share.pdf",
                originApp: nil,
                itemTime: Self.iso8601String(for: itemTime)
            ),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(ledger)
            .write(to: root.appendingPathComponent("ledger.json"), options: .atomic)
    }

    static func iso8601String(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}
#endif
