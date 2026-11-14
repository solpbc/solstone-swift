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
    var pauseWindows: [ScreenshotsPauseWindow] = []
    var changeToken: Data?
    /// The start of what the owner chose at the last confirm. A screenshot the source has
    /// not seen and that was taken before it stays out when Photos reports a change to it.
    var liveFloor: Date?
    var lastChecked: Date?
    /// What the journal paired now has is the items in `.delivered`. A new pairing drops them.
    var items: [ScreenshotsItem] = []
    var progressDone = 0
    var progressTotal = 0
    var selectedSpan: ScreenshotsSpan = .last30Days
    var countedSpan: ScreenshotsSpan?
    var countedIDs: [String] = []
    var countFailed = false
    var isCounting = false

    var deliveredLocalIDs: Set<String> {
        Set(self.items.filter { $0.phase == .delivered }.map(\.localIdentifier))
    }

    func hasDelivered(hash: String) -> Bool {
        self.items.contains { $0.phase == .delivered && $0.hash == hash }
    }
}

@MainActor
final class ScreenshotsStore {
    let fileURL: URL
    private let fileManager: FileManager
    var document = ScreenshotsDocument()
    /// What the file holds now, as last loaded or written.
    private var persisted: ScreenshotsDocument?

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
        self.persisted = document
    }

    /// Photos reports a change for every edit, sync and new photo, and each one moves the
    /// check time and the change token. Neither needs the file rewritten: the check time is
    /// shown from memory, and a relaunch that reads an older token replays changes this
    /// source already handled, which changes nothing. Both are written with the next real change.
    func save() {
        if var unchanged = self.persisted {
            unchanged.lastChecked = self.document.lastChecked
            unchanged.changeToken = self.document.changeToken
            if unchanged == self.document { return }
        }
        do {
            try self.fileManager.createDirectory(
                at: self.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(self.document)
            try data.write(to: self.fileURL, options: .atomic)
            self.persisted = self.document
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
