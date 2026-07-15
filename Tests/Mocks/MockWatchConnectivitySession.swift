// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import WatchConnectivity

@MainActor
final class MockWatchConnectivitySession: WatchConnectivitySession {
    enum RecordedCall {
        case transferUserInfo([String: Any])
        case sendMessage([String: Any])
    }

    private struct OutstandingRecord {
        let token: Int
        let id: UUID?
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
            OutstandingFileTransfer(id: record.id) { [weak self] in
                self?.cancelOutstanding(token: record.token)
            }
        }
    }
    var onActivationChanged: (@Sendable (Bool) -> Void)?
    var onReachabilityChanged: (@Sendable (Bool) -> Void)?
    var onWatchStateChanged: (@Sendable () -> Void)?
    var onReceiveFile: ((URL, [String: Any]) -> Void)?
    var onReceiveUserInfo: (([String: Any]) -> Void)?
    var onReceiveApplicationContext: (([String: Any]) -> Void)?
    var onFileTransferFinished: ((UUID, String?) -> Void)?
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
        self.activateCallCount += 1
        self.activationState = .activated
        self.onActivationChanged?(true)
        self.onSessionEvent?()
    }

    func transferFile(_ url: URL, metadata: [String: Any]) {
        self.transferredFiles.append((url, metadata))
        self.appendOutstandingTransfer(id: Self.segmentID(from: metadata))
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

    func seedOutstandingTransfer(id: UUID?) {
        self.appendOutstandingTransfer(id: id)
    }

    func finishTransfer(id: UUID, error: String?) {
        self.outstandingRecords.removeAll { $0.id == id }
        self.onFileTransferFinished?(id, error)
        self.onSessionEvent?()
    }

    func emitSessionEvent() {
        self.onSessionEvent?()
    }
}

private extension MockWatchConnectivitySession {
    static func segmentID(from metadata: [String: Any]) -> UUID? {
        guard let idString = metadata["id"] as? String else { return nil }
        return UUID(uuidString: idString)
    }

    func appendOutstandingTransfer(id: UUID?) {
        self.outstandingRecords.append(OutstandingRecord(token: self.nextOutstandingToken, id: id))
        self.nextOutstandingToken += 1
    }

    func cancelOutstanding(token: Int) {
        guard let index = self.outstandingRecords.firstIndex(where: { $0.token == token }) else { return }
        let record = self.outstandingRecords.remove(at: index)
        self.cancelledSegmentIDs.append(record.id)
    }
}
