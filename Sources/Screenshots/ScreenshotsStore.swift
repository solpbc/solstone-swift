// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

nonisolated private let screenshotsStoreLog = Logger(subsystem: "app.solstone.swift", category: "screenshots")

nonisolated struct ScreenshotsItem: Codable, Equatable, Sendable, Identifiable {
    var localIdentifier: String
    var created: Date
    var phase: ScreenshotsPhase
    var hash: String?
    var deliveredTo: String?
    var inFrozen: Bool
    var countedInProgress: Bool
    var exportAttempts: Int

    var id: String { self.localIdentifier }
}

nonisolated struct ScreenshotsDocument: Codable, Equatable, Sendable {
    var schema: Int = 1
    var everOn = false
    var enabled = false
    var paused = false
    var needsSpan = false
    var fullAccessWasHeld = false
    var journalIdentity: String?
    var pauseWindows: [ScreenshotsPauseWindow] = []
    var changeToken: Data?
    var lastChecked: Date?
    var items: [ScreenshotsItem] = []
    var receivedHashes: [String: [String]] = [:]
    var receivedLocalIDs: [String: [String]] = [:]
    var progressDone = 0
    var progressTotal = 0
    var selectedSpan: ScreenshotsSpan = .last30Days
    var countedSpan: ScreenshotsSpan?
    var countedIDs: [String] = []
    var countFailed = false
    var isCounting = false

    func receivedHashSet(_ journal: String) -> Set<String> {
        Set(self.receivedHashes[journal] ?? [])
    }

    func receivedLocalSet(_ journal: String) -> Set<String> {
        Set(self.receivedLocalIDs[journal] ?? [])
    }

    mutating func remember(hash: String, localIdentifier: String, journal: String) {
        var hashes = self.receivedHashes[journal] ?? []
        if !hashes.contains(hash) { hashes.append(hash) }
        self.receivedHashes[journal] = hashes
        var locals = self.receivedLocalIDs[journal] ?? []
        if !locals.contains(localIdentifier) { locals.append(localIdentifier) }
        self.receivedLocalIDs[journal] = locals
    }
}

@MainActor
final class ScreenshotsStore {
    let fileURL: URL
    private let fileManager: FileManager
    var document = ScreenshotsDocument()

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.load()
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("Screenshots", isDirectory: true).appendingPathComponent("state.json")
    }

    func load() {
        guard self.fileManager.fileExists(atPath: self.fileURL.path),
              let data = try? Data(contentsOf: self.fileURL),
              let document = try? JSONDecoder().decode(ScreenshotsDocument.self, from: data),
              document.schema == 1
        else { return }
        self.document = document
    }

    func save() {
        do {
            try self.fileManager.createDirectory(
                at: self.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(self.document)
            try data.write(to: self.fileURL, options: .atomic)
            try? self.fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: self.fileURL.path
            )
            var written = self.fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? written.setResourceValues(values)
        } catch {
            screenshotsStoreLog.error("screenshots record write failed")
        }
    }
}
