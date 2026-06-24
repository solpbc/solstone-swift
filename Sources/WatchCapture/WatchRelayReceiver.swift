// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let watchRelayReceiverLog = Logger(subsystem: "app.solstone.swift", category: "watch-relay")

@MainActor
final class WatchRelayReceiver {
    static let rootDirectoryName = ["watch", "relay"].map(\.capitalized).joined()
    static let stagingDirectoryName = "staging"
    static let incomingDirectoryName = ".incoming"

    let stagingRootURL: URL
    var onSegmentStaged: ((UUID) -> Void)?

    private let session: any WatchConnectivitySession
    private let fileWriter: any WatchFileWriting

    init(
        session: any WatchConnectivitySession,
        stagingRootURL: URL? = nil,
        fileWriter: any WatchFileWriting = FoundationWatchFileWriter(),
        fileManager: FileManager = .default
    ) throws {
        self.session = session
        self.fileWriter = fileWriter
        self.stagingRootURL = try stagingRootURL
            ?? AppGroupContainer.rootURL(fileManager: fileManager)
                .appendingPathComponent(Self.rootDirectoryName, isDirectory: true)
                .appendingPathComponent(Self.stagingDirectoryName, isDirectory: true)
        try self.fileWriter.createDirectory(at: self.stagingRootURL)
        self.session.onReceiveFile = { [weak self] url, metadata in
            self?.receiveFile(url, metadata: metadata)
        }
    }

    func receiveFile(_ scratchURL: URL, metadata: [String: Any]) {
        defer {
            try? self.fileWriter.removeItem(at: scratchURL)
        }

        guard let idString = metadata["id"] as? String,
              let id = UUID(uuidString: idString)
        else {
            watchRelayReceiverLog.error("watch relay payload missing id")
            return
        }

        let committedURL = self.committedURL(for: id)
        if self.fileWriter.fileExists(at: committedURL) {
            watchRelayReceiverLog.info("watch relay duplicate staged id=\(id.uuidString, privacy: .public)")
            self.sendACK(id: id)
            self.onSegmentStaged?(id)
            return
        }

        let incomingURL = self.incomingURL(for: id)
        do {
            try self.fileWriter.removeItem(at: incomingURL)
            try WatchSegmentBundleCodec.decode(
                bundleURL: scratchURL,
                expectedID: id,
                destinationDirectory: incomingURL,
                fileWriter: self.fileWriter
            )
            try self.fileWriter.moveItem(at: incomingURL, to: committedURL)
            self.sendACK(id: id)
            self.onSegmentStaged?(id)
            watchRelayReceiverLog.info("watch relay staged id=\(id.uuidString, privacy: .public)")
        } catch {
            try? self.fileWriter.removeItem(at: incomingURL)
            watchRelayReceiverLog.error("watch relay staging failed id=\(id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
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
