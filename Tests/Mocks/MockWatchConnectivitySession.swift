// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import WatchConnectivity

@MainActor
final class MockWatchConnectivitySession: WatchConnectivitySession {
    enum RecordedCall {
        case activate
        case transferFile(URL, UUID?)
        case transferUserInfo([String: Any])
        case sendMessage([String: Any])
        case updateApplicationContext
        case cancel(UUID?)
    }

    private struct OutstandingRecord {
        let token: Int
        var snapshot: WatchConnectivityFileTransferSnapshot
    }

    var isSupported = true
    var isReachable = false
    var isPaired = false
    var isWatchAppInstalled = false
    var activationState: WCSessionActivationState = .notActivated
    var hasContentPending = false
    var receivedApplicationContext: [String: Any] = [:]
    var outstandingFileTransfers: [OutstandingFileTransfer] {
        self.outstandingRecords.map { record in
            OutstandingFileTransfer(id: record.snapshot.segmentID) { [weak self] in
                self?.cancelOutstanding(token: record.token)
            }
        }
    }
    var outstandingFileTransferSnapshots: [WatchConnectivityFileTransferSnapshot] {
        self.outstandingRecords.map(\.snapshot)
    }
    var outstandingUserInfoTransferSnapshots: [WatchConnectivityUserInfoTransferSnapshot] = []
    var isCompanionAppInstalledForDiagnostics: DiagnosticAvailability<Bool> = .unavailable(reason: "not configured")
    var iOSDeviceNeedsUnlockAfterRebootForDiagnostics: DiagnosticAvailability<Bool> = .unavailable(reason: "not configured")
    var onActivationChanged: (@Sendable (Bool) -> Void)?
    var onReachabilityChanged: (@Sendable (Bool) -> Void)?
    var onWatchStateChanged: (@Sendable () -> Void)?
    var onReceiveFile: ((URL, [String: Any]) -> Void)?
    var onReceiveUserInfo: (([String: Any]) -> Void)?
    var onReceiveApplicationContext: (([String: Any]) -> Void)?
    var onFileTransferFinished: ((UUID, WatchConnectivityTransferFailureSnapshot?) -> Void)?
    var onSessionEvent: (() -> Void)?

    var activateCallCount = 0
    var transferredFiles: [(URL, [String: Any])] = []
    var transferredUserInfos: [[String: Any]] = []
    var sentMessages: [[String: Any]] = []
    var updatedApplicationContexts: [[String: Any]] = []
    private(set) var callLedger: [RecordedCall] = []
    private(set) var cancelledSegmentIDs: [UUID?] = []

    private var nextOutstandingToken = 0
    private var outstandingRecords: [OutstandingRecord] = []

    func activate() {
        self.callLedger.append(.activate)
        self.activateCallCount += 1
        self.activationState = .activated
        self.onActivationChanged?(true)
        self.onSessionEvent?()
    }

    func transferFile(_ url: URL, metadata: [String: Any]) {
        let id = Self.segmentID(from: metadata)
        self.transferredFiles.append((url, metadata))
        self.callLedger.append(.transferFile(url, id))
        self.appendOutstandingTransfer(id: id)
    }

    func transferUserInfo(_ userInfo: [String: Any]) {
        self.transferredUserInfos.append(userInfo)
        self.callLedger.append(.transferUserInfo(userInfo))
    }

    func sendMessage(_ message: [String: Any]) {
        self.sentMessages.append(message)
        self.callLedger.append(.sendMessage(message))
    }

    func updateApplicationContext(_ applicationContext: [String: Any]) throws {
        self.updatedApplicationContexts.append(applicationContext)
        self.callLedger.append(.updateApplicationContext)
    }

    func emitReachability(_ isReachable: Bool) {
        self.isReachable = isReachable
        self.onReachabilityChanged?(isReachable)
    }

    func emitWatchState(
        isPaired: Bool,
        isWatchAppInstalled: Bool,
        activationState: WCSessionActivationState
    ) {
        self.isPaired = isPaired
        self.isWatchAppInstalled = isWatchAppInstalled
        self.activationState = activationState
        self.onWatchStateChanged?()
    }

    func deliverFile(_ url: URL, metadata: [String: Any]) {
        self.onReceiveFile?(url, metadata)
        self.onSessionEvent?()
    }

    func deliverUserInfo(_ userInfo: [String: Any]) {
        self.onReceiveUserInfo?(userInfo)
        self.onSessionEvent?()
    }

    func deliverApplicationContext(_ applicationContext: [String: Any]) {
        self.receivedApplicationContext = applicationContext
        self.onReceiveApplicationContext?(applicationContext)
        self.onSessionEvent?()
    }

    func seedOutstandingTransfer(
        id: UUID?,
        idState: WatchRelayTransferIDState? = nil,
        isTransferring: Bool = true,
        progress: WatchConnectivityProgressSnapshot? = nil
    ) {
        self.appendOutstandingTransfer(
            snapshot: WatchConnectivityFileTransferSnapshot(
                asOf: Date(timeIntervalSince1970: 0),
                segmentID: id,
                idState: idState ?? (id == nil ? .missing : .parseable),
                isTransferring: isTransferring,
                progress: progress ?? Self.defaultProgress()
            )
        )
    }

    func seedOutstandingUserInfoTransfer(
        recognizedType: WatchConnectivityUserInfoTransferType?,
        isTransferring: Bool = true
    ) {
        self.outstandingUserInfoTransferSnapshots.append(WatchConnectivityUserInfoTransferSnapshot(
            asOf: Date(timeIntervalSince1970: 0),
            recognizedType: recognizedType,
            isTransferring: isTransferring
        ))
    }

    func finishTransfer(id: UUID, failure: WatchConnectivityTransferFailureSnapshot?) {
        self.outstandingRecords.removeAll { $0.snapshot.segmentID == id }
        self.onFileTransferFinished?(id, failure)
        self.onSessionEvent?()
    }

    func emitSessionEvent() {
        self.onSessionEvent?()
    }

    nonisolated static func defaultProgress(
        isIndeterminate: Bool = false,
        completedUnitCount: Int64 = 0,
        totalUnitCount: Int64 = 1,
        fractionCompleted: Double? = 0
    ) -> WatchConnectivityProgressSnapshot {
        WatchConnectivityProgressSnapshot(
            isIndeterminate: isIndeterminate,
            isFinished: false,
            isCancelled: false,
            completedUnitCount: completedUnitCount,
            totalUnitCount: totalUnitCount,
            fractionCompleted: isIndeterminate ? nil : fractionCompleted,
            throughputBytesPerSecond: nil,
            estimatedTimeRemainingSeconds: nil,
            kind: nil,
            fileTotalCount: nil,
            fileCompletedCount: nil
        )
    }
}

private extension MockWatchConnectivitySession {
    static func segmentID(from metadata: [String: Any]) -> UUID? {
        guard let idString = metadata["id"] as? String else { return nil }
        return UUID(uuidString: idString)
    }

    func appendOutstandingTransfer(id: UUID?) {
        self.appendOutstandingTransfer(snapshot: WatchConnectivityFileTransferSnapshot(
            asOf: Date(timeIntervalSince1970: 0),
            segmentID: id,
            idState: id == nil ? .missing : .parseable,
            isTransferring: true,
            progress: Self.defaultProgress()
        ))
    }

    func appendOutstandingTransfer(snapshot: WatchConnectivityFileTransferSnapshot) {
        self.outstandingRecords.append(OutstandingRecord(token: self.nextOutstandingToken, snapshot: snapshot))
        self.nextOutstandingToken += 1
    }

    func cancelOutstanding(token: Int) {
        guard let index = self.outstandingRecords.firstIndex(where: { $0.token == token }) else { return }
        let record = self.outstandingRecords.remove(at: index)
        self.cancelledSegmentIDs.append(record.snapshot.segmentID)
        self.callLedger.append(.cancel(record.snapshot.segmentID))
    }
}
