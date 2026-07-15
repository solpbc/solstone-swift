// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import WatchConnectivity

nonisolated private let watchConnectivityLog = Logger(subsystem: "app.solstone.swift", category: "watch-connectivity")

@MainActor
struct OutstandingFileTransfer {
    let id: UUID?
    let cancel: @MainActor () -> Void
}

nonisolated struct WatchConnectivityProgressSnapshot: Codable, Equatable, Sendable {
    let isIndeterminate: Bool
    let isFinished: Bool
    let isCancelled: Bool
    let completedUnitCount: Int64
    let totalUnitCount: Int64
    let fractionCompleted: Double?
    let throughputBytesPerSecond: Int?
    let estimatedTimeRemainingSeconds: TimeInterval?
    let kind: String?
    let fileTotalCount: Int?
    let fileCompletedCount: Int?
}

nonisolated struct WatchConnectivityFileTransferSnapshot: Codable, Equatable, Sendable {
    let asOf: Date
    let segmentID: UUID?
    let idState: WatchRelayTransferIDState
    let isTransferring: Bool
    let progress: WatchConnectivityProgressSnapshot
}

nonisolated struct WatchConnectivityUserInfoTransferSnapshot: Codable, Equatable, Sendable {
    let asOf: Date
    let recognizedType: WatchConnectivityUserInfoTransferType?
    let isTransferring: Bool
}

nonisolated enum WatchConnectivityUserInfoTransferType: String, Codable, Equatable, Sendable {
    case watchSegmentACK
}

@MainActor
protocol WatchConnectivitySession: AnyObject {
    var isSupported: Bool { get }
    var isReachable: Bool { get }
    var isPaired: Bool { get }
    var isWatchAppInstalled: Bool { get }
    var activationState: WCSessionActivationState { get }
    var hasContentPending: Bool { get }
    var receivedApplicationContext: [String: Any] { get }
    var outstandingFileTransfers: [OutstandingFileTransfer] { get }
    var outstandingFileTransferSnapshots: [WatchConnectivityFileTransferSnapshot] { get }
    var outstandingUserInfoTransferSnapshots: [WatchConnectivityUserInfoTransferSnapshot] { get }
    var isCompanionAppInstalledForDiagnostics: DiagnosticAvailability<Bool> { get }
    var iOSDeviceNeedsUnlockAfterRebootForDiagnostics: DiagnosticAvailability<Bool> { get }
    var onActivationChanged: (@Sendable (Bool) -> Void)? { get set }
    var onReachabilityChanged: (@Sendable (Bool) -> Void)? { get set }
    var onWatchStateChanged: (@Sendable () -> Void)? { get set }
    var onReceiveFile: ((URL, [String: Any]) -> Void)? { get set }
    var onReceiveUserInfo: (([String: Any]) -> Void)? { get set }
    var onReceiveApplicationContext: (([String: Any]) -> Void)? { get set }
    var onFileTransferFinished: ((UUID, WatchConnectivityTransferFailureSnapshot?) -> Void)? { get set }
    var onSessionEvent: (() -> Void)? { get set }

    func activate()
    func transferFile(_ url: URL, metadata: [String: Any])
    func transferUserInfo(_ userInfo: [String: Any])
    func sendMessage(_ message: [String: Any])
    func updateApplicationContext(_ applicationContext: [String: Any]) throws
}

@MainActor
final class LiveWatchConnectivitySession: NSObject, WatchConnectivitySession, WCSessionDelegate {
    var onActivationChanged: (@Sendable (Bool) -> Void)?
    var onReachabilityChanged: (@Sendable (Bool) -> Void)?
    var onWatchStateChanged: (@Sendable () -> Void)?
    var onReceiveFile: ((URL, [String: Any]) -> Void)?
    var onReceiveUserInfo: (([String: Any]) -> Void)?
    var onReceiveApplicationContext: (([String: Any]) -> Void)?
    var onFileTransferFinished: ((UUID, WatchConnectivityTransferFailureSnapshot?) -> Void)?
    var onSessionEvent: (() -> Void)?

    private let session: WCSession?
    private let messageSend: @MainActor ([String: Any], @escaping @Sendable (any Error) -> Void) -> Void

    var isSupported: Bool {
        self.session != nil
    }

    var isReachable: Bool {
        self.session?.isReachable ?? false
    }

    var activationState: WCSessionActivationState {
        self.session?.activationState ?? .notActivated
    }

    var hasContentPending: Bool {
        self.session?.hasContentPending ?? false
    }

    var receivedApplicationContext: [String: Any] {
        self.session?.receivedApplicationContext ?? [:]
    }

    var outstandingFileTransfers: [OutstandingFileTransfer] {
        (self.session?.outstandingFileTransfers ?? []).map { transfer in
            let id: UUID?
            if let idString = transfer.file.metadata?["id"] as? String {
                id = UUID(uuidString: idString)
            } else {
                id = nil
            }
            return OutstandingFileTransfer(id: id) {
                transfer.cancel()
            }
        }
    }

    var outstandingFileTransferSnapshots: [WatchConnectivityFileTransferSnapshot] {
        let asOf = Date()
        return (self.session?.outstandingFileTransfers ?? []).map { transfer in
            Self.fileTransferSnapshot(from: transfer, asOf: asOf)
        }
    }

    var outstandingUserInfoTransferSnapshots: [WatchConnectivityUserInfoTransferSnapshot] {
        let asOf = Date()
        return (self.session?.outstandingUserInfoTransfers ?? []).map { transfer in
            Self.userInfoTransferSnapshot(from: transfer, asOf: asOf)
        }
    }

#if os(iOS)
    var isPaired: Bool {
        self.session?.isPaired ?? false
    }

    var isWatchAppInstalled: Bool {
        self.session?.isWatchAppInstalled ?? false
    }

    var isCompanionAppInstalledForDiagnostics: DiagnosticAvailability<Bool> {
        .unavailable(reason: "not available on iphone")
    }

    var iOSDeviceNeedsUnlockAfterRebootForDiagnostics: DiagnosticAvailability<Bool> {
        .unavailable(reason: "not available on iphone")
    }
#else
    var isPaired: Bool {
        false
    }

    var isWatchAppInstalled: Bool {
        false
    }

    var isCompanionAppInstalledForDiagnostics: DiagnosticAvailability<Bool> {
        guard let session else {
            return .unavailable(reason: "watch connectivity unavailable")
        }
        return .available(session.isCompanionAppInstalled)
    }

    var iOSDeviceNeedsUnlockAfterRebootForDiagnostics: DiagnosticAvailability<Bool> {
        guard let session else {
            return .unavailable(reason: "watch connectivity unavailable")
        }
        return .available(session.iOSDeviceNeedsUnlockAfterRebootForReachability)
    }
#endif

    override init() {
        let session = WCSession.isSupported() ? WCSession.default : nil
        self.session = session
        self.messageSend = { message, errorHandler in
            guard let session else {
                watchConnectivityLog.error("watch connectivity message send unavailable")
                return
            }
            session.sendMessage(message, replyHandler: nil, errorHandler: errorHandler)
        }
        super.init()
        session?.delegate = self
    }

    init(messageSend: @escaping @MainActor ([String: Any], @escaping @Sendable (any Error) -> Void) -> Void) {
        self.session = nil
        self.messageSend = messageSend
        super.init()
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
        self.messageSend(message) { @Sendable error in
            watchConnectivityLog.error("watch connectivity message send failed: \(String(describing: error), privacy: .public)")
        }
    }

    func updateApplicationContext(_ applicationContext: [String: Any]) throws {
        guard let session else {
            watchConnectivityLog.error("watch connectivity application context unavailable")
            return
        }
        try session.updateApplicationContext(applicationContext)
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let didActivate = activationState == .activated && error == nil
        Task { @MainActor [weak self] in
            self?.onActivationChanged?(didActivate)
            self?.onSessionEvent?()
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

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.onWatchStateChanged?()
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
            self?.onSessionEvent?()
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
        let idString = fileTransfer.file.metadata?["id"] as? String
        let failure = error.map { WatchConnectivityTransferFailureSnapshot(error: $0) }
        Task { @MainActor [weak self] in
            defer {
                self?.onSessionEvent?()
            }
            guard let idString else {
                watchConnectivityLog.info("watch connectivity file transfer finished without segment id")
                return
            }
            guard let id = UUID(uuidString: idString) else {
                watchConnectivityLog.error("watch connectivity file transfer finished with invalid segment id")
                return
            }
            self?.onFileTransferFinished?(id, failure)
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
            self?.onSessionEvent?()
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
            self?.onSessionEvent?()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let contextData: Data
        do {
            contextData = try Self.propertyListData(from: applicationContext)
        } catch {
            watchConnectivityLog.error("watch connectivity incoming application context snapshot failed: \(String(describing: error), privacy: .public)")
            return
        }
        Task { @MainActor [weak self] in
            self?.onReceiveApplicationContext?(Self.propertyListDictionary(from: contextData))
            self?.onSessionEvent?()
        }
    }
}

private extension LiveWatchConnectivitySession {
    nonisolated static func fileTransferSnapshot(
        from transfer: WCSessionFileTransfer,
        asOf: Date
    ) -> WatchConnectivityFileTransferSnapshot {
        let idParse = Self.segmentID(from: transfer.file.metadata?["id"])
        return WatchConnectivityFileTransferSnapshot(
            asOf: asOf,
            segmentID: idParse.id,
            idState: idParse.state,
            isTransferring: transfer.isTransferring,
            progress: Self.progressSnapshot(from: transfer.progress)
        )
    }

    nonisolated static func progressSnapshot(from progress: Progress) -> WatchConnectivityProgressSnapshot {
        WatchConnectivityProgressSnapshot(
            isIndeterminate: progress.isIndeterminate,
            isFinished: progress.isFinished,
            isCancelled: progress.isCancelled,
            completedUnitCount: progress.completedUnitCount,
            totalUnitCount: progress.totalUnitCount,
            fractionCompleted: progress.isIndeterminate ? nil : progress.fractionCompleted,
            throughputBytesPerSecond: progress.throughput,
            estimatedTimeRemainingSeconds: progress.estimatedTimeRemaining,
            kind: progress.kind?.rawValue,
            fileTotalCount: progress.fileTotalCount,
            fileCompletedCount: progress.fileCompletedCount
        )
    }

    nonisolated static func userInfoTransferSnapshot(
        from transfer: WCSessionUserInfoTransfer,
        asOf: Date
    ) -> WatchConnectivityUserInfoTransferSnapshot {
        WatchConnectivityUserInfoTransferSnapshot(
            asOf: asOf,
            recognizedType: Self.userInfoType(from: transfer.userInfo["type"]),
            isTransferring: transfer.isTransferring
        )
    }

    nonisolated static func segmentID(from rawValue: Any?) -> (id: UUID?, state: WatchRelayTransferIDState) {
        guard let idString = rawValue as? String else {
            return (nil, .missing)
        }
        guard let id = UUID(uuidString: idString) else {
            return (nil, .unparseable)
        }
        return (id, .parseable)
    }

    nonisolated static func userInfoType(from rawValue: Any?) -> WatchConnectivityUserInfoTransferType? {
        guard let type = rawValue as? String else { return nil }
        switch type {
        case WatchRelayACK.type:
            return .watchSegmentACK
        default:
            return nil
        }
    }

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
