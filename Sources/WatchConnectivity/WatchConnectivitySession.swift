// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import WatchConnectivity

nonisolated private let watchConnectivityLog = Logger(subsystem: "app.solstone.swift", category: "watch-connectivity")

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

nonisolated struct WatchConnectivityFileTransferRuntimeToken: Sendable {
    let value: Int
}

@MainActor
struct WatchConnectivityFileTransferObservation {
    let runtimeToken: WatchConnectivityFileTransferRuntimeToken
    let snapshot: WatchConnectivityFileTransferSnapshot
    let generation: Int?
    let generationState: WatchRelayTransferIDState
    let attemptID: UUID?
    let attemptIDState: WatchRelayTransferIDState
    let attemptStartedAt: Date?
    let attemptStartedAtState: WatchRelayTransferIDState
    let cancel: @MainActor () -> Void
}

nonisolated struct WatchConnectivityFileTransferCompletion: Sendable {
    let segmentID: UUID?
    let segmentIDState: WatchRelayTransferIDState
    let generation: Int?
    let generationState: WatchRelayTransferIDState
    let attemptID: UUID?
    let attemptIDState: WatchRelayTransferIDState
    let attemptStartedAt: Date?
    let attemptStartedAtState: WatchRelayTransferIDState
    let fileURL: URL
    let failure: WatchConnectivityTransferFailureSnapshot?
}

nonisolated struct WatchConnectivityUserInfoTransferSnapshot: Codable, Equatable, Sendable {
    let asOf: Date
    let recognizedType: WatchConnectivityUserInfoTransferType?
    let segmentID: UUID?
    let idState: WatchRelayTransferIDState
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
    var outstandingFileTransfers: [WatchConnectivityFileTransferObservation] { get }
    var outstandingUserInfoTransferSnapshots: [WatchConnectivityUserInfoTransferSnapshot] { get }
    var isCompanionAppInstalledForDiagnostics: DiagnosticAvailability<Bool> { get }
    var iOSDeviceNeedsUnlockAfterRebootForDiagnostics: DiagnosticAvailability<Bool> { get }
    var onActivationChanged: (@Sendable (Bool) -> Void)? { get set }
    var onReachabilityChanged: (@Sendable (Bool) -> Void)? { get set }
    var onWatchStateChanged: (@Sendable () -> Void)? { get set }
    var onReceiveFile: ((URL, [String: Any]) -> Void)? { get set }
    var onReceiveUserInfo: (([String: Any]) -> Void)? { get set }
    var onReceiveApplicationContext: (([String: Any]) -> Void)? { get set }
    var onFileTransferFinished: ((WatchConnectivityFileTransferCompletion) -> Void)? { get set }
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
    var onFileTransferFinished: ((WatchConnectivityFileTransferCompletion) -> Void)?
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

    var outstandingFileTransfers: [WatchConnectivityFileTransferObservation] {
        let asOf = Date()
        return (self.session?.outstandingFileTransfers ?? []).enumerated().map { index, transfer in
            let metadata = transfer.file.metadata ?? [:]
            let identity = Self.fileTransferIdentity(from: metadata)
            let snapshot = WatchConnectivityFileTransferSnapshot(
                asOf: asOf,
                segmentID: identity.segmentID,
                idState: identity.segmentIDState,
                isTransferring: transfer.isTransferring,
                progress: Self.progressSnapshot(from: transfer.progress)
            )
            return WatchConnectivityFileTransferObservation(
                runtimeToken: WatchConnectivityFileTransferRuntimeToken(value: index),
                snapshot: snapshot,
                generation: identity.generation,
                generationState: identity.generationState,
                attemptID: identity.attemptID,
                attemptIDState: identity.attemptIDState,
                attemptStartedAt: identity.attemptStartedAt,
                attemptStartedAtState: identity.attemptStartedAtState
            ) {
                transfer.cancel()
            }
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
        let merged = session.applicationContext.merging(applicationContext) { _, new in new }
        try session.updateApplicationContext(merged)
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
        let completion = Self.fileTransferCompletion(
            metadata: fileTransfer.file.metadata,
            fileURL: fileTransfer.file.fileURL,
            error: error
        )
        Task { @MainActor [weak self] in
            defer {
                self?.onSessionEvent?()
            }
            guard completion.segmentIDState != .missing else {
                watchConnectivityLog.info("watch connectivity file transfer finished without segment id")
                return
            }
            guard completion.segmentIDState == .parseable else {
                watchConnectivityLog.error("watch connectivity file transfer finished with invalid segment id")
                return
            }
            self?.onFileTransferFinished?(completion)
        }
    }

    nonisolated static func fileTransferCompletion(
        metadata: [String: Any]?,
        fileURL: URL,
        error: (any Error)?
    ) -> WatchConnectivityFileTransferCompletion {
        let identity = Self.fileTransferIdentity(from: metadata ?? [:])
        return WatchConnectivityFileTransferCompletion(
            segmentID: identity.segmentID,
            segmentIDState: identity.segmentIDState,
            generation: identity.generation,
            generationState: identity.generationState,
            attemptID: identity.attemptID,
            attemptIDState: identity.attemptIDState,
            attemptStartedAt: identity.attemptStartedAt,
            attemptStartedAtState: identity.attemptStartedAtState,
            fileURL: fileURL,
            failure: error.map { WatchConnectivityTransferFailureSnapshot(error: $0) }
        )
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
    struct FileTransferIdentity: Sendable {
        let segmentID: UUID?
        let segmentIDState: WatchRelayTransferIDState
        let generation: Int?
        let generationState: WatchRelayTransferIDState
        let attemptID: UUID?
        let attemptIDState: WatchRelayTransferIDState
        let attemptStartedAt: Date?
        let attemptStartedAtState: WatchRelayTransferIDState
    }

    nonisolated static func fileTransferIdentity(from metadata: [String: Any]) -> FileTransferIdentity {
        let segmentID = Self.segmentID(from: metadata["id"])
        let generation = Self.generation(from: metadata["generation"])
        let attemptID = Self.segmentID(from: metadata["attempt_id"])
        let attemptStartedAt = Self.attemptStartedAt(from: metadata["attempt_started_at"])
        return FileTransferIdentity(
            segmentID: segmentID.id,
            segmentIDState: segmentID.state,
            generation: generation.value,
            generationState: generation.state,
            attemptID: attemptID.id,
            attemptIDState: attemptID.state,
            attemptStartedAt: attemptStartedAt.value,
            attemptStartedAtState: attemptStartedAt.state
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
        let idParse = Self.segmentID(from: transfer.userInfo[WatchRelayACK.idKey])
        return WatchConnectivityUserInfoTransferSnapshot(
            asOf: asOf,
            recognizedType: Self.userInfoType(from: transfer.userInfo[WatchRelayACK.typeKey]),
            segmentID: idParse.id,
            idState: idParse.state,
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

    nonisolated static func generation(from rawValue: Any?) -> (value: Int?, state: WatchRelayTransferIDState) {
        guard let rawValue else {
            return (nil, .missing)
        }
        guard let generation = rawValue as? Int else {
            return (nil, .unparseable)
        }
        return (generation, .parseable)
    }

    nonisolated static func attemptStartedAt(
        from rawValue: Any?
    ) -> (value: Date?, state: WatchRelayTransferIDState) {
        guard let rawValue else {
            return (nil, .missing)
        }
        guard let string = rawValue as? String,
              let date = ISO8601DateFormatter().date(from: string)
        else {
            return (nil, .unparseable)
        }
        return (date, .parseable)
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
