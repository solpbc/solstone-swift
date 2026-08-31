// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

private let watchRelayReceiverLog = Logger(subsystem: "app.solstone.swift", category: "watch-relay")

@MainActor
@Observable
final class WatchRelayReceiver {
    static let rootDirectoryName = ["watch", "relay"].map(\.capitalized).joined()
    static let stagingDirectoryName = "staging"
    static let incomingDirectoryName = ".incoming"

    let stagingRootURL: URL
    private(set) var lastReceivedAt: Date?
    private(set) var lastStagingError: String?
    @ObservationIgnored
    var onSegmentStaged: ((UUID) -> Void)?

    private let session: any WatchConnectivitySession
    private let ledger: WatchSegmentLedger
    private let fileWriter: any WatchFileWriting
    private let facts: WatchSourceFacts

    init(
        session: any WatchConnectivitySession,
        ledger: WatchSegmentLedger,
        stagingRootURL: URL? = nil,
        fileWriter: any WatchFileWriting = FoundationWatchFileWriter(),
        fileManager: FileManager = .default,
        facts: WatchSourceFacts
    ) throws {
        self.session = session
        self.ledger = ledger
        self.fileWriter = fileWriter
        self.facts = facts
        self.stagingRootURL = try stagingRootURL
            ?? AppGroupContainer.rootURL(fileManager: fileManager)
                .appendingPathComponent(Self.rootDirectoryName, isDirectory: true)
                .appendingPathComponent(Self.stagingDirectoryName, isDirectory: true)
        self.session.onReceiveFile = { [weak self] url, metadata in
            Task { @MainActor in
                await self?.receiveFile(url, metadata: metadata)
            }
        }
    }

    func receiveFile(_ scratchURL: URL, metadata: [String: Any]) async {
        guard let idString = metadata["id"] as? String,
              let id = UUID(uuidString: idString)
        else {
            watchRelayReceiverLog.error("watch relay payload missing id")
            try? await self.fileWriter.removeItem(at: scratchURL)
            return
        }

        if self.ledger.isTerminal(id: id) {
            watchRelayReceiverLog.info("watch relay terminal duplicate id=\(id.uuidString, privacy: .public)")
            self.lastReceivedAt = Date()
            self.facts.noteSegmentFileReceived()
            self.sendACK(id: id)
            try? await self.fileWriter.removeItem(at: scratchURL)
            return
        }

        let committedURL = self.committedURL(for: id)
        if await self.fileWriter.fileExists(at: committedURL) {
            watchRelayReceiverLog.info("watch relay duplicate staged id=\(id.uuidString, privacy: .public)")
            self.lastReceivedAt = Date()
            self.facts.noteSegmentFileReceived()
            self.sendACK(id: id)
            self.onSegmentStaged?(id)
            try? await self.fileWriter.removeItem(at: scratchURL)
            return
        }

        let incomingURL = self.incomingURL(for: id)
        do {
            try await self.fileWriter.removeItem(at: incomingURL)
            try await WatchSegmentBundleCodec.decode(
                bundleURL: scratchURL,
                expectedID: id,
                destinationDirectory: incomingURL,
                fileWriter: self.fileWriter
            )
            try await self.fileWriter.moveItem(at: incomingURL, to: committedURL)
            self.ledger.recordReceived(id: id)
            self.lastReceivedAt = Date()
            self.facts.noteSegmentFileReceived()
            self.lastStagingError = nil
            self.sendACK(id: id)
            self.onSegmentStaged?(id)
            watchRelayReceiverLog.info("watch relay staged id=\(id.uuidString, privacy: .public)")
        } catch {
            try? await self.fileWriter.removeItem(at: incomingURL)
            self.lastStagingError = String(describing: error)
            watchRelayReceiverLog.error("watch relay staging failed id=\(id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        try? await self.fileWriter.removeItem(at: scratchURL)
    }

    func replayACKsForCommittedSegments() {
        for id in self.ledger.committedOrTerminalSegmentIDs {
            self.sendACK(id: id)
        }
    }
}

private extension WatchRelayReceiver {
    func incomingURL(for id: UUID) -> URL {
        self.stagingRootURL
            .appendingPathComponent(Self.incomingDirectoryName, isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func committedURL(for id: UUID) -> URL {
        self.stagingRootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func sendACK(id: UUID) {
        let ack = WatchRelayACK.userInfo(id: id)
        self.session.transferUserInfo(ack)
        if self.session.isReachable {
            self.session.sendMessage(ack)
        }
    }
}
