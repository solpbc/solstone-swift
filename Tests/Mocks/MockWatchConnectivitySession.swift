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
        let snapshot: WatchConnectivityFileTransferSnapshot
        let metadata: [String: Any]
        let fileURL: URL
    }

    var isSupported = true
    var isReachable = false
    var isPaired = false
    var isWatchAppInstalled = false
    var activationState: WCSessionActivationState = .notActivated
    var hasContentPending = false
    var receivedApplicationContext: [String: Any] = [:]
    var outstandingFileTransfers: [WatchConnectivityFileTransferObservation] {
        self.outstandingRecords.enumerated().map { index, record in
            let completion = LiveWatchConnectivitySession.fileTransferCompletion(
                metadata: record.metadata,
                fileURL: record.fileURL,
                error: nil
            )
            return WatchConnectivityFileTransferObservation(
                runtimeToken: WatchConnectivityFileTransferRuntimeToken(value: index),
                snapshot: record.snapshot,
                generation: completion.generation,
                generationState: completion.generationState,
                attemptID: completion.attemptID,
                attemptIDState: completion.attemptIDState,
                attemptStartedAt: completion.attemptStartedAt,
                attemptStartedAtState: completion.attemptStartedAtState
            ) { [weak self] in
                self?.cancelOutstanding(token: record.token)
            }
        }
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
    var onFileTransferFinished: ((WatchConnectivityFileTransferCompletion) -> Void)?
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
        let completion = LiveWatchConnectivitySession.fileTransferCompletion(
            metadata: metadata,
            fileURL: url,
            error: nil
        )
        let id = completion.segmentID
        self.transferredFiles.append((url, metadata))
        self.callLedger.append(.transferFile(url, id))
        self.appendOutstandingTransfer(
            snapshot: WatchConnectivityFileTransferSnapshot(
                asOf: Date(timeIntervalSince1970: 0),
                segmentID: id,
                idState: completion.segmentIDState,
                isTransferring: true,
                progress: Self.defaultProgress()
            ),
            metadata: metadata,
            fileURL: url
        )
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

    func emitActivationChanged(_ didActivate: Bool) {
        self.onActivationChanged?(didActivate)
        self.onSessionEvent?()
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
        progress: WatchConnectivityProgressSnapshot? = nil,
        generation: Int? = nil,
        attemptID: UUID? = nil,
        attemptStartedAt: Date? = nil
    ) {
        let state = idState ?? (id == nil ? .missing : .parseable)
        let metadata = Self.metadata(
            id: id,
            idState: state,
            generation: generation,
            attemptID: attemptID,
            attemptStartedAt: attemptStartedAt
        )
        self.appendOutstandingTransfer(
            snapshot: WatchConnectivityFileTransferSnapshot(
                asOf: Date(timeIntervalSince1970: 0),
                segmentID: id,
                idState: state,
                isTransferring: isTransferring,
                progress: progress ?? Self.defaultProgress()
            ),
            metadata: metadata,
            fileURL: URL(fileURLWithPath: "/mock/\(UUID().uuidString).watchrelay")
        )
    }

    func seedOutstandingUserInfoTransfer(
        recognizedType: WatchConnectivityUserInfoTransferType?,
        segmentID: UUID? = nil,
        idState: WatchRelayTransferIDState? = nil,
        isTransferring: Bool = true
    ) {
        self.outstandingUserInfoTransferSnapshots.append(WatchConnectivityUserInfoTransferSnapshot(
            asOf: Date(timeIntervalSince1970: 0),
            recognizedType: recognizedType,
            segmentID: segmentID,
            idState: idState ?? (segmentID == nil ? .missing : .parseable),
            isTransferring: isTransferring
        ))
    }

    func finishTransfer(id: UUID, failure: WatchConnectivityTransferFailureSnapshot?) {
        let record = self.outstandingRecords.first { $0.snapshot.segmentID == id }
        self.outstandingRecords.removeAll { $0.snapshot.segmentID == id }
        if let record {
            self.finish(record: record, failure: failure)
        } else {
            self.finish(
                completion: LiveWatchConnectivitySession.fileTransferCompletion(
                    metadata: ["id": id.uuidString],
                    fileURL: URL(fileURLWithPath: "/mock/finished.watchrelay"),
                    error: nil
                ),
                failure: failure
            )
        }
        self.onSessionEvent?()
    }

    func finishTransfer(attemptID: UUID, failure: WatchConnectivityTransferFailureSnapshot?) {
        guard let index = self.outstandingRecords.firstIndex(where: { record in
            LiveWatchConnectivitySession.fileTransferCompletion(
                metadata: record.metadata,
                fileURL: record.fileURL,
                error: nil
            ).attemptID == attemptID
        }) else {
            return
        }
        let record = self.outstandingRecords.remove(at: index)
        self.finish(record: record, failure: failure)
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
    static func metadata(
        id: UUID?,
        idState: WatchRelayTransferIDState,
        generation: Int?,
        attemptID: UUID?,
        attemptStartedAt: Date?
    ) -> [String: Any] {
        var metadata: [String: Any] = [:]
        switch idState {
        case .parseable:
            metadata["id"] = id?.uuidString
        case .missing:
            break
        case .unparseable:
            metadata["id"] = "not-a-uuid"
        }
        if let generation {
            metadata["generation"] = generation
        }
        if let attemptID {
            metadata["attempt_id"] = attemptID.uuidString
        }
        if let attemptStartedAt {
            metadata["attempt_started_at"] = ISO8601DateFormatter().string(from: attemptStartedAt)
        }
        return metadata
    }

    func appendOutstandingTransfer(
        snapshot: WatchConnectivityFileTransferSnapshot,
        metadata: [String: Any],
        fileURL: URL
    ) {
        self.outstandingRecords.append(OutstandingRecord(
            token: self.nextOutstandingToken,
            snapshot: snapshot,
            metadata: metadata,
            fileURL: fileURL
        ))
        self.nextOutstandingToken += 1
    }

    private func finish(record: OutstandingRecord, failure: WatchConnectivityTransferFailureSnapshot?) {
        let completion = LiveWatchConnectivitySession.fileTransferCompletion(
            metadata: record.metadata,
            fileURL: record.fileURL,
            error: nil
        )
        self.finish(completion: completion, failure: failure)
    }

    private func finish(
        completion: WatchConnectivityFileTransferCompletion,
        failure: WatchConnectivityTransferFailureSnapshot?
    ) {
        self.onFileTransferFinished?(WatchConnectivityFileTransferCompletion(
            segmentID: completion.segmentID,
            segmentIDState: completion.segmentIDState,
            generation: completion.generation,
            generationState: completion.generationState,
            attemptID: completion.attemptID,
            attemptIDState: completion.attemptIDState,
            attemptStartedAt: completion.attemptStartedAt,
            attemptStartedAtState: completion.attemptStartedAtState,
            fileURL: completion.fileURL,
            failure: failure
        ))
    }

    func cancelOutstanding(token: Int) {
        guard let index = self.outstandingRecords.firstIndex(where: { $0.token == token }) else { return }
        let record = self.outstandingRecords.remove(at: index)
        self.cancelledSegmentIDs.append(record.snapshot.segmentID)
        self.callLedger.append(.cancel(record.snapshot.segmentID))
    }
}
