// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import WatchConnectivity
import XCTest

@MainActor
final class WatchCaptureModelSignpostTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        self.temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchCaptureModelSignpostTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.temporaryDirectory)
        self.temporaryDirectory = nil
    }

    func testModelInitializationPublishesBalancedComplicationSnapshotInterval() throws {
        let signpostSink = WatchModelSignpostSink()
        let signposter = WatchSignposter(sink: signpostSink)
        let storage = try WatchCaptureStorage(rootURL: self.temporaryDirectory.appendingPathComponent("storage"))
        let session = WatchModelConnectivitySession()
        let diagnosticsStore = WatchRelayDiagnosticsStore(storage: storage)
        let relaySender = WatchRelaySender(storage: storage, session: session, diagnosticsStore: diagnosticsStore, signposter: signposter)
        let collector = WatchRelayDiagnosticsCollector(
            storage: storage,
            diagnosticsStore: diagnosticsStore,
            session: session,
            environmentProvider: WatchModelEnvironmentProvider(),
            signposter: signposter
        )
        let complicationRoot = self.temporaryDirectory.appendingPathComponent("complication", isDirectory: true)
        try FileManager.default.createDirectory(at: complicationRoot, withIntermediateDirectories: true)
        var reloadCount = 0

        let model = WatchCaptureModel(
            storage: storage,
            relaySender: relaySender,
            session: session,
            diagnosticsCollector: collector,
            notificationScheduler: WatchModelNotificationScheduler(),
            environmentProvider: WatchModelEnvironmentProvider(),
            signposter: signposter,
            complicationRootURL: { complicationRoot },
            reloadComplicationTimelines: { reloadCount += 1 }
        )

        XCTAssertNotNil(model.presentation)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: complicationRoot.appendingPathComponent(WatchComplicationSnapshot.fileName).path
        ))
        XCTAssertEqual(reloadCount, 1)
        XCTAssertEqual(signpostSink.events.map(\.boundary), [.complicationSnapshot, .complicationSnapshot])
        XCTAssertEqual(signpostSink.events.map(\.kind), [.begin, .end])
        XCTAssertEqual(signpostSink.openIntervalCount, 0)
    }

    func testStatusPublicationReportsPrimaryAndFallbackOutcomes() async throws {
        let signpostSink = WatchModelSignpostSink()
        let signposter = WatchSignposter(sink: signpostSink)
        let storage = try WatchCaptureStorage(rootURL: self.temporaryDirectory.appendingPathComponent("status-storage"))
        let session = WatchModelConnectivitySession()
        let diagnosticsStore = WatchRelayDiagnosticsStore(storage: storage)
        let relaySender = WatchRelaySender(storage: storage, session: session, diagnosticsStore: diagnosticsStore, signposter: signposter)
        let collector = WatchRelayDiagnosticsCollector(
            storage: storage,
            diagnosticsStore: diagnosticsStore,
            session: session,
            environmentProvider: WatchModelEnvironmentProvider(),
            signposter: signposter
        )
        let complicationRoot = self.temporaryDirectory.appendingPathComponent("status-complication", isDirectory: true)
        try FileManager.default.createDirectory(at: complicationRoot, withIntermediateDirectories: true)
        let model = WatchCaptureModel(
            storage: storage,
            relaySender: relaySender,
            session: session,
            diagnosticsCollector: collector,
            notificationScheduler: WatchModelNotificationScheduler(),
            environmentProvider: WatchModelEnvironmentProvider(),
            signposter: signposter,
            complicationRootURL: { complicationRoot },
            reloadComplicationTimelines: {}
        )
        await Task.yield()
        await Task.yield()
        signpostSink.reset()

        session.remainingPublicationFailures = 1
        model.republishStatusOnReconnect()

        XCTAssertEqual(
            signpostSink.events.filter { event in
                event.boundary == .statusPublication
                    || event.boundary == .applicationContextPrimary
                    || event.boundary == .applicationContextFallback
            },
            [
                .init(kind: .begin, boundary: .statusPublication, fields: WatchSignpostFields()),
                .init(kind: .begin, boundary: .applicationContextPrimary, fields: WatchSignpostFields()),
                .init(kind: .end, boundary: .applicationContextPrimary, fields: WatchSignpostFields(result: .failed)),
                .init(kind: .begin, boundary: .applicationContextFallback, fields: WatchSignpostFields()),
                .init(kind: .end, boundary: .applicationContextFallback, fields: WatchSignpostFields(result: .completed)),
                .init(kind: .end, boundary: .statusPublication, fields: WatchSignpostFields(result: .partial)),
            ]
        )
        XCTAssertEqual(signpostSink.openIntervalCount, 0)
    }

    func testStatusPublicationAllSuccessEmitsNoFallbackInterval() async throws {
        let (model, sink) = try self.makeStatusPublicationFixture(name: "status-success")
        await Task.yield()
        await Task.yield()
        sink.reset()

        model.republishStatusOnReconnect()

        XCTAssertTrue(sink.events.contains {
            $0.kind == .end && $0.boundary == .applicationContextPrimary && $0.fields.result == .completed
        })
        XCTAssertFalse(sink.events.contains { $0.boundary == .applicationContextFallback })
        XCTAssertTrue(sink.events.contains {
            $0.kind == .end && $0.boundary == .statusPublication && $0.fields.result == .completed
        })
    }

    func testStatusPublicationBothFailuresReportsFailedParent() async throws {
        let (model, sink, session) = try self.makeStatusPublicationFixtureIncludingSession(name: "status-both-fail")
        await Task.yield()
        await Task.yield()
        sink.reset()
        session.remainingPublicationFailures = 2

        model.republishStatusOnReconnect()

        XCTAssertTrue(sink.events.contains {
            $0.kind == .end && $0.boundary == .applicationContextPrimary && $0.fields.result == .failed
        })
        XCTAssertTrue(sink.events.contains {
            $0.kind == .end && $0.boundary == .applicationContextFallback && $0.fields.result == .failed
        })
        XCTAssertTrue(sink.events.contains {
            $0.kind == .end && $0.boundary == .statusPublication && $0.fields.result == .failed
        })
        XCTAssertEqual(sink.openIntervalCount, 0)
    }

    func testNoOpAndRecordingSignpostsPreservePublishedArtifactBytes() async throws {
        let noOp = try await self.signpostArtifacts(
            name: "noop-artifacts",
            signposter: WatchSignposter(sink: NoOpWatchSignpostIntervalSink())
        )
        let sink = WatchModelSignpostSink()
        let recorded = try await self.signpostArtifacts(
            name: "recorded-artifacts",
            signposter: WatchSignposter(sink: sink)
        )

        XCTAssertFalse(sink.events.isEmpty)
        XCTAssertEqual(recorded.statusPayload, noOp.statusPayload)
        XCTAssertEqual(recorded.diagnosticsEnvelope, noOp.diagnosticsEnvelope)
        XCTAssertEqual(recorded.manifest, noOp.manifest)
        XCTAssertEqual(recorded.relayBundle, noOp.relayBundle)
        XCTAssertEqual(recorded.normalizedAttemptRecord, noOp.normalizedAttemptRecord)
        XCTAssertEqual(recorded.complicationSnapshot, noOp.complicationSnapshot)
    }

    func testConnectivityActivationAndReachabilityReachRelayDrainWithTheirTriggers() async throws {
        let sink = WatchModelSignpostSink()
        let signposter = WatchSignposter(sink: sink)
        let storage = try WatchCaptureStorage(rootURL: self.temporaryDirectory.appendingPathComponent("session-trigger-storage"))
        let session = WatchModelConnectivitySession()
        let sender = WatchRelaySender(storage: storage, session: session, signposter: signposter)
        let model = WatchSessionModel(session: session, relaySender: sender)

        session.activationState = .activated
        session.emitActivationChanged(true)
        await Task.yield()
        XCTAssertTrue(sink.events.contains {
            $0.kind == .end && $0.boundary == .relayDrain && $0.fields.trigger == .connectivityActivation
        })

        sink.reset()
        session.emitReachability(true)
        await Task.yield()
        XCTAssertTrue(sink.events.contains {
            $0.kind == .end && $0.boundary == .relayDrain && $0.fields.trigger == .connectivityReachability
        })
        _ = model
    }

    private func makeStatusPublicationFixture(
        name: String
    ) throws -> (WatchCaptureModel, WatchModelSignpostSink) {
        let (model, sink, _) = try self.makeStatusPublicationFixtureIncludingSession(name: name)
        return (model, sink)
    }

    private func makeStatusPublicationFixtureIncludingSession(
        name: String
    ) throws -> (WatchCaptureModel, WatchModelSignpostSink, WatchModelConnectivitySession) {
        let sink = WatchModelSignpostSink()
        let signposter = WatchSignposter(sink: sink)
        let storage = try WatchCaptureStorage(rootURL: self.temporaryDirectory.appendingPathComponent(name))
        let session = WatchModelConnectivitySession()
        let diagnosticsStore = WatchRelayDiagnosticsStore(storage: storage)
        let relaySender = WatchRelaySender(storage: storage, session: session, diagnosticsStore: diagnosticsStore, signposter: signposter)
        let collector = WatchRelayDiagnosticsCollector(
            storage: storage,
            diagnosticsStore: diagnosticsStore,
            session: session,
            environmentProvider: WatchModelEnvironmentProvider(),
            signposter: signposter
        )
        let complicationRoot = self.temporaryDirectory.appendingPathComponent("\(name)-complication", isDirectory: true)
        try FileManager.default.createDirectory(at: complicationRoot, withIntermediateDirectories: true)
        let model = WatchCaptureModel(
            storage: storage,
            relaySender: relaySender,
            session: session,
            diagnosticsCollector: collector,
            notificationScheduler: WatchModelNotificationScheduler(),
            environmentProvider: WatchModelEnvironmentProvider(),
            signposter: signposter,
            complicationRootURL: { complicationRoot },
            reloadComplicationTimelines: {}
        )
        return (model, sink, session)
    }

    private struct SignpostArtifacts {
        let statusPayload: Data
        let diagnosticsEnvelope: Data
        let manifest: Data
        let relayBundle: Data
        let normalizedAttemptRecord: Data
        let complicationSnapshot: Data
    }

    private func signpostArtifacts(
        name: String,
        signposter: any WatchSignposting
    ) async throws -> SignpostArtifacts {
        let now = Date(timeIntervalSince1970: 1_713_624_000)
        let storage = try WatchCaptureStorage(rootURL: self.temporaryDirectory.appendingPathComponent(name))
        let day = storage.dayString(for: now)
        let segment = storage.segmentString(for: now, durationSeconds: 60)
        let directory = try storage.ensureSegmentDirectory(day: day, segment: segment)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let manifest = WatchSegmentManifest(
            id: id,
            day: day,
            segment: segment,
            startedAt: now,
            duration: 60,
            sensors: [],
            partial: false,
            lost: false,
            gap: false,
            fixCount: 0,
            state: .queued,
            failureReason: nil
        )
        try storage.writeManifest(manifest, in: directory)
        let session = WatchModelConnectivitySession()
        let diagnosticsStore = WatchRelayDiagnosticsStore(storage: storage)
        let relaySender = WatchRelaySender(
            storage: storage,
            session: session,
            diagnosticsStore: diagnosticsStore,
            clock: { now },
            signposter: signposter
        )
        session.activationState = .activated
        relaySender.drain(trigger: .testDirect)
        let attemptData = try storage.fileWriter.readData(
            from: directory.appendingPathComponent(WatchRelayAttemptRecord.filename, isDirectory: false)
        )
        let attemptDecoder = JSONDecoder()
        attemptDecoder.dateDecodingStrategy = .iso8601
        let attempt = try attemptDecoder.decode(WatchRelayAttemptRecord.self, from: attemptData)
        let normalizedAttempt = WatchRelayAttemptRecord(
            version: attempt.version,
            segmentID: attempt.segmentID,
            generation: attempt.generation,
            attemptID: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            attemptStartedAt: attempt.attemptStartedAt
        )
        let snapshotStorage = try WatchCaptureStorage(
            rootURL: self.temporaryDirectory.appendingPathComponent("\(name)-snapshot-storage")
        )
        let snapshotSession = WatchModelConnectivitySession()
        let snapshotDiagnosticsStore = WatchRelayDiagnosticsStore(storage: snapshotStorage)
        let snapshotSender = WatchRelaySender(
            storage: snapshotStorage,
            session: snapshotSession,
            diagnosticsStore: snapshotDiagnosticsStore,
            clock: { now },
            signposter: signposter
        )
        let snapshotCollector = WatchRelayDiagnosticsCollector(
            storage: snapshotStorage,
            diagnosticsStore: snapshotDiagnosticsStore,
            session: snapshotSession,
            environmentProvider: WatchModelEnvironmentProvider(),
            signposter: signposter
        )
        let complicationRoot = self.temporaryDirectory.appendingPathComponent("\(name)-complication", isDirectory: true)
        try FileManager.default.createDirectory(at: complicationRoot, withIntermediateDirectories: true)
        let snapshotModel = WatchCaptureModel(
            storage: snapshotStorage,
            relaySender: snapshotSender,
            session: snapshotSession,
            diagnosticsCollector: snapshotCollector,
            notificationScheduler: WatchModelNotificationScheduler(),
            environmentProvider: WatchModelEnvironmentProvider(),
            clock: WatchModelFixedClock(date: now),
            signposter: signposter,
            complicationRootURL: { complicationRoot },
            reloadComplicationTimelines: {}
        )
        snapshotModel.presentation = WatchCaptureOwnerPresentation(status: .off, queuedCount: 1)
        let diagnosticsEnvelope = try XCTUnwrap(snapshotCollector.makeEnvelopeData(asOf: now))
        let statusPayload = try XCTUnwrap(WatchStatusContext(
            phase: .idle,
            sessionID: nil,
            startedAt: nil,
            asOf: now,
            seq: 1,
            queuedCount: 0,
            transferringCount: 0,
            diagnosticsEnvelope: diagnosticsEnvelope
        ).applicationContext()[WatchStatusContext.applicationContextKey] as? Data)
        _ = snapshotModel
        return SignpostArtifacts(
            statusPayload: statusPayload,
            diagnosticsEnvelope: diagnosticsEnvelope,
            manifest: try storage.fileWriter.readData(from: storage.manifestURL(directory: directory)),
            relayBundle: try storage.fileWriter.readData(from: relaySender.bundleURL(for: id)),
            normalizedAttemptRecord: try WatchRelayAttemptRecord.makeEncoder().encode(normalizedAttempt),
            complicationSnapshot: try Data(contentsOf: complicationRoot.appendingPathComponent(WatchComplicationSnapshot.fileName))
        )
    }
}

@MainActor
private final class WatchModelSignpostSink: WatchSignpostIntervalSink {
    enum Kind: Equatable {
        case begin
        case end
    }

    struct Event: Equatable {
        let kind: Kind
        let boundary: WatchSignpostBoundary
        let fields: WatchSignpostFields
    }

    let isEnabled = true
    private(set) var events: [Event] = []
    private var openIntervals: Set<ObjectIdentifier> = []

    var openIntervalCount: Int { self.openIntervals.count }

    func reset() {
        self.events.removeAll()
        self.openIntervals.removeAll()
    }

    func begin(_ boundary: WatchSignpostBoundary, fields: WatchSignpostFields) -> WatchSignpostInvocation {
        let invocation = WatchSignpostInvocation(boundary: boundary)
        self.openIntervals.insert(ObjectIdentifier(invocation))
        self.events.append(Event(kind: .begin, boundary: boundary, fields: fields))
        return invocation
    }

    func end(_ invocation: WatchSignpostInvocation, fields: WatchSignpostFields) {
        self.openIntervals.remove(ObjectIdentifier(invocation))
        self.events.append(Event(kind: .end, boundary: invocation.boundary, fields: fields))
    }
}

@MainActor
private final class WatchModelConnectivitySession: WatchConnectivitySession {
    var isSupported = true
    var isReachable = false
    var isPaired = false
    var isWatchAppInstalled = false
    var activationState: WCSessionActivationState = .notActivated
    var hasContentPending = false
    var receivedApplicationContext: [String: Any] = [:]
    var outstandingFileTransfers: [WatchConnectivityFileTransferObservation] = []
    var outstandingUserInfoTransferSnapshots: [WatchConnectivityUserInfoTransferSnapshot] = []
    var isCompanionAppInstalledForDiagnostics: DiagnosticAvailability<Bool> = .unavailable(reason: "test")
    var iOSDeviceNeedsUnlockAfterRebootForDiagnostics: DiagnosticAvailability<Bool> = .unavailable(reason: "test")
    var onActivationChanged: (@Sendable (Bool) -> Void)?
    var onReachabilityChanged: (@Sendable (Bool) -> Void)?
    var onWatchStateChanged: (@Sendable () -> Void)?
    var onReceiveFile: ((URL, [String: Any]) -> Void)?
    var onReceiveUserInfo: (([String: Any]) -> Void)?
    var onReceiveApplicationContext: (([String: Any]) -> Void)?
    var onFileTransferFinished: ((WatchConnectivityFileTransferCompletion) -> Void)?
    var onSessionEvent: (() -> Void)?
    var remainingPublicationFailures = 0

    func activate() {}
    private(set) var transferredFiles: [(URL, [String: Any])] = []

    func transferFile(_ url: URL, metadata: [String: Any]) {
        self.transferredFiles.append((url, metadata))
    }
    func transferUserInfo(_ userInfo: [String: Any]) {}
    func sendMessage(_ message: [String: Any]) {}
    func updateApplicationContext(_ applicationContext: [String: Any]) throws {
        if self.remainingPublicationFailures > 0 {
            self.remainingPublicationFailures -= 1
            throw WatchModelTestError.publicationFailed
        }
        self.receivedApplicationContext = applicationContext
    }

    func emitActivationChanged(_ didActivate: Bool) {
        self.onActivationChanged?(didActivate)
    }

    func emitReachability(_ isReachable: Bool) {
        self.isReachable = isReachable
        self.onReachabilityChanged?(isReachable)
    }
}

private enum WatchModelTestError: Error {
    case publicationFailed
}

nonisolated private struct WatchModelFixedClock: ObserverClock {
    let date: Date

    func now() -> Date { self.date }

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

@MainActor
private final class WatchModelNotificationScheduler: WatchNotificationScheduling {
    func authorizationStatus() async -> WatchNotificationAuthorizationStatus { .authorized }
    func alertSetting() async -> WatchNotificationAlertSetting { .enabled }
    func requestAuthorization() async throws -> WatchNotificationAuthorizationStatus { .authorized }
    func add(identifier: String, title: String, body: String, triggerDate: Date?) async throws {}
    func removePending(identifier: String) {}
}

@MainActor
private final class WatchModelEnvironmentProvider: WatchRelayDiagnosticsEnvironmentProviding {
    func snapshot() -> WatchRelayDiagnosticsEnvironmentSnapshot {
        WatchRelayDiagnosticsEnvironmentSnapshot(
            watchAppMarketingVersion: .unavailable(reason: "test"),
            watchAppBuild: .unavailable(reason: "test"),
            watchOSVersion: .unavailable(reason: "test"),
            watchBatteryLevel: .unavailable(reason: "test"),
            watchBatteryState: .unavailable(reason: "test"),
            watchLowPowerModeEnabled: .unavailable(reason: "test"),
            watchThermalState: .unavailable(reason: "test")
        )
    }
}
