// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import WatchConnectivity

nonisolated private let watchConnectivityLog = Logger(subsystem: "app.solstone.swift", category: "watch-connectivity")

@MainActor
protocol WatchConnectivitySession: AnyObject {
    var isSupported: Bool { get }
    var isReachable: Bool { get }
    var onActivationChanged: (@Sendable (Bool) -> Void)? { get set }
    var onReachabilityChanged: (@Sendable (Bool) -> Void)? { get set }
    var onReceiveFile: ((URL, [String: Any]) -> Void)? { get set }
    var onReceiveUserInfo: (([String: Any]) -> Void)? { get set }

    func activate()
    func transferFile(_ url: URL, metadata: [String: Any])
    func transferUserInfo(_ userInfo: [String: Any])
    func sendMessage(_ message: [String: Any])
}

@MainActor
final class LiveWatchConnectivitySession: NSObject, WatchConnectivitySession, WCSessionDelegate {
    var onActivationChanged: (@Sendable (Bool) -> Void)?
    var onReachabilityChanged: (@Sendable (Bool) -> Void)?
    var onReceiveFile: ((URL, [String: Any]) -> Void)?
    var onReceiveUserInfo: (([String: Any]) -> Void)?

    private let session: WCSession?

    var isSupported: Bool {
        self.session != nil
    }

    var isReachable: Bool {
        self.session?.isReachable ?? false
    }

    override init() {
        self.session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
        self.session?.delegate = self
    }

    func activate() {
        guard let session else {
            self.onActivationChanged?(false)
            return
        }
        session.delegate = self
        session.activate()
    }

    func transferFile(_ url: URL, metadata: [String: Any]) {
        guard let session else {
            watchConnectivityLog.error("watch connectivity file transfer unavailable")
            return
        }
        _ = session.transferFile(url, metadata: metadata)
    }

    func transferUserInfo(_ userInfo: [String: Any]) {
        guard let session else {
            watchConnectivityLog.error("watch connectivity user info transfer unavailable")
            return
        }
        _ = session.transferUserInfo(userInfo)
    }

    func sendMessage(_ message: [String: Any]) {
        guard let session else {
            watchConnectivityLog.error("watch connectivity message send unavailable")
            return
        }
        session.sendMessage(message, replyHandler: nil, errorHandler: { error in
            watchConnectivityLog.error("watch connectivity message send failed: \(String(describing: error), privacy: .public)")
        })
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let didActivate = activationState == .activated && error == nil
        Task { @MainActor [weak self] in
            self?.onActivationChanged?(didActivate)
        }
    }

#if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.onActivationChanged?(false)
        }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.activate()
        }
    }
#endif

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.onReachabilityChanged?(isReachable)
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadataData: Data
        do {
            metadataData = try Self.propertyListData(from: file.metadata ?? [:])
        } catch {
            watchConnectivityLog.error("watch connectivity incoming metadata snapshot failed: \(String(describing: error), privacy: .public)")
            return
        }
        let scratchURL: URL
        do {
            scratchURL = try Self.moveIncomingFileToScratch(file.fileURL)
        } catch {
            watchConnectivityLog.error("watch connectivity incoming file move failed: \(String(describing: error), privacy: .public)")
            return
        }
        Task { @MainActor [weak self] in
            let metadata = Self.propertyListDictionary(from: metadataData)
            self?.onReceiveFile?(scratchURL, metadata)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        let messageData: Data
        do {
            messageData = try Self.propertyListData(from: message)
        } catch {
            watchConnectivityLog.error("watch connectivity incoming message snapshot failed: \(String(describing: error), privacy: .public)")
            return
        }
        Task { @MainActor [weak self] in
            self?.onReceiveUserInfo?(Self.propertyListDictionary(from: messageData))
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        let userInfoData: Data
        do {
            userInfoData = try Self.propertyListData(from: userInfo)
        } catch {
            watchConnectivityLog.error("watch connectivity incoming user info snapshot failed: \(String(describing: error), privacy: .public)")
            return
        }
        Task { @MainActor [weak self] in
            self?.onReceiveUserInfo?(Self.propertyListDictionary(from: userInfoData))
        }
    }
}

private extension LiveWatchConnectivitySession {
    nonisolated static func moveIncomingFileToScratch(_ fileURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let scratchDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(["watch", "connectivity", "inbox"].map(\.capitalized).joined(), isDirectory: true)
        try fileManager.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        let fileExtension = fileURL.pathExtension
        let scratchName = fileExtension.isEmpty
            ? UUID().uuidString
            : "\(UUID().uuidString).\(fileExtension)"
        let scratchURL = scratchDirectory.appendingPathComponent(scratchName, isDirectory: false)
        if fileManager.fileExists(atPath: scratchURL.path) {
            try fileManager.removeItem(at: scratchURL)
        }
        try fileManager.moveItem(at: fileURL, to: scratchURL)
        return scratchURL
    }

    nonisolated static func propertyListData(from dictionary: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .binary,
            options: 0
        )
    }

    nonisolated static func propertyListDictionary(from data: Data) -> [String: Any] {
        guard let dictionary = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            return [:]
        }
        return dictionary
    }
}
