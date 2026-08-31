// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import WatchConnectivity
import XCTest

private struct WatchModelTestStorage {
    let paths: WatchCaptureStoragePaths
    let fileWriter: any WatchFileWriting

    init(rootURL: URL, fileWriter: any WatchFileWriting = FoundationWatchFileWriter()) throws {
        self.paths = try WatchCaptureStoragePaths(rootURL: rootURL)
        self.fileWriter = fileWriter
    }

    var rootURL: URL { self.paths.rootURL }

    func dayString(for date: Date) -> String {
        self.paths.dayString(for: date)
    }

    func segmentString(for date: Date, durationSeconds: Double) -> String {
        self.paths.segmentString(for: date, durationSeconds: durationSeconds)
    }

    func manifestURL(directory: URL) -> URL {
        self.paths.manifestURL(directory: directory)
    }
}

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

    func testModelInitializationPublishesBalancedComplicationSnapshotInterval() async throws {
        let signpostSink = WatchModelSignpostSink()
        let signposter = WatchSignposter(sink: signpostSink)
        let storage = try WatchModelTestStorage(rootURL: self.temporaryDirectory.appendingPathComponent("storage"))
        let storageActor = self.storageActor(for: storage)
        let session = WatchModelConnectivitySession()
        let relaySender = WatchRelaySender(
            paths: storage.paths,
            storageActor: storageActor,
            session: session,
            signposter: signposter
        )
        let collector = WatchRelayDiagnosticsCollector(
            paths: storage.paths,
            storageActor: storageActor,
            session: session,
            environmentProvider: WatchModelEnvironmentProvider(),
            signposter: signposter
        )
        let complicationRoot = self.temporaryDirectory.appendingPathComponent("complication", isDirectory: true)
        try FileManager.default.createDirectory(at: complicationRoot, withIntermediateDirectories: true)
        var reloadCount = 0

        let model = WatchCaptureModel(
            paths: storage.paths,
            storageActor: storageActor,
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
        let snapshotURL = complicationRoot.appendingPathComponent(WatchComplicationSnapshot.fileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
        let didWriteSnapshot = await self.waitForFile(at: snapshotURL)
        XCTAssertTrue(didWriteSnapshot)
        let didReloadComplication = await self.waitUntil { reloadCount == 1 }
        XCTAssertTrue(didReloadComplication)
        let complicationEvents = signpostSink.events.filter { $0.boundary == .complicationSnapshot }
        XCTAssertEqual(complicationEvents.map(\.kind), [.begin, .end])
    }

    func testComplicationSnapshotPublicationIsDeferredAndFIFO() async throws {
        let storage = try WatchModelTestStorage(rootURL: self.temporaryDirectory.appendingPathComponent("fifo-storage"))
        let writer = BlockingComplicationSnapshotWriter()
        let storageActor = WatchCaptureStorageActor(
            paths: storage.paths,
            fileWriter: writer
        )
        try await storageActor.prepareRoot()
        let complicationRoot = self.temporaryDirectory.appendingPathComponent("fifo-complication", isDirectory: true)
        try FileManager.default.createDirectory(at: complicationRoot, withIntermediateDirectories: true)
        let snapshotURL = complicationRoot.appendingPathComponent(WatchComplicationSnapshot.fileName)
        let session = WatchModelConnectivitySession()
        let relaySender = WatchRelaySender(paths: storage.paths, storageActor: storageActor, session: session)
        let collector = WatchRelayDiagnosticsCollector(
            paths: storage.paths,
            storageActor: storageActor,
            session: session,
            environmentProvider: WatchModelEnvironmentProvider()
        )

        let model = WatchCaptureModel(
            paths: storage.paths,
            storageActor: storageActor,
            relaySender: relaySender,
            session: session,
            diagnosticsCollector: collector,
            notificationScheduler: WatchModelNotificationScheduler(),
            environmentProvider: WatchModelEnvironmentProvider(),
            complicationRootURL: { complicationRoot },
            reloadComplicationTimelines: {}
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
        await writer.waitUntilWriteEntered()
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))

        let newerPresentation = WatchCaptureOwnerPresentation(status: .off, queuedCount: 7)
        model.presentation = newerPresentation
        let writesBeforeRelease = await writer.writeCount()
        XCTAssertEqual(writesBeforeRelease, 1)

        await writer.release()
        let didWriteBothSnapshots = await self.waitForWriteCount(2, writer: writer)
        XCTAssertTrue(didWriteBothSnapshots)
        let didWriteSnapshot = await self.waitForFile(at: snapshotURL)
        XCTAssertTrue(didWriteSnapshot)

        let snapshot = try JSONDecoder().decode(WatchComplicationSnapshot.self, from: Data(contentsOf: snapshotURL))
        XCTAssertEqual(snapshot, WatchComplicationSnapshot(presentation: newerPresentation, isReachable: true))
    }

    func testRelayStateRefreshTailPublishesNewerCountsAfterHeldEarlierRefresh() async throws {
        let writer = BlockingRelayStateRefreshWriter()
        let storage = try WatchModelTestStorage(
            rootURL: self.temporaryDirectory.appendingPathComponent("relay-state-storage"),
            fileWriter: writer
        )
        let storageActor = WatchCaptureStorageActor(
            paths: storage.paths,
            fileWriter: writer
        )
        try await storageActor.prepareRoot()
        let externalActor = WatchCaptureStorageActor(
            paths: storage.paths,
            fileWriter: FoundationWatchFileWriter()
        )
        try await externalActor.writeManifest(self.queuedManifest(storage: storage, id: UUID(), index: 0), transactionClass: .captureSafety)
        let initialCatalog = await externalActor.scanCatalog(transactionClass: .maintenance)
        XCTAssertEqual(initialCatalog.entries.count, 1)
        await writer.armNextRead()
        let complicationRoot = self.temporaryDirectory.appendingPathComponent("relay-state-complication", isDirectory: true)
        try FileManager.default.createDirectory(at: complicationRoot, withIntermediateDirectories: true)
        let session = WatchModelConnectivitySession()
        let relaySender = WatchRelaySender(paths: storage.paths, storageActor: storageActor, session: session)
        let collector = WatchRelayDiagnosticsCollector(
            paths: storage.paths,
            storageActor: storageActor,
            session: session,
            environmentProvider: WatchModelEnvironmentProvider()
        )
        let model = WatchCaptureModel(
            paths: storage.paths,
            storageActor: storageActor,
            relaySender: relaySender,
            session: session,
            diagnosticsCollector: collector,
            notificationScheduler: WatchModelNotificationScheduler(),
            environmentProvider: WatchModelEnvironmentProvider(),
            complicationRootURL: { complicationRoot },
            reloadComplicationTimelines: {}
        )
        await writer.waitUntilReadEntered()
        await writer.releaseRead()
        let snapshotURL = complicationRoot.appendingPathComponent(WatchComplicationSnapshot.fileName)
        let didWriteInitialSnapshot = await self.waitForFile(at: snapshotURL)
        XCTAssertTrue(didWriteInitialSnapshot)
        let didPublishInitialCounts = await self.waitForRelayCount(1, model: model)
        XCTAssertTrue(didPublishInitialCounts)
        await model.requestDiagnosticsRefresh()
        await self.waitUntilReadsIdle(writer: writer)

        await writer.armNextRead()
        relaySender.onStateChanged?()
        await writer.waitUntilReadEntered()

        try await externalActor.writeManifest(self.queuedManifest(storage: storage, id: UUID(), index: 1), transactionClass: .captureSafety)
        let expandedCatalog = await externalActor.scanCatalog(transactionClass: .maintenance)
        XCTAssertEqual(expandedCatalog.entries.count, 2)
        relaySender.onStateChanged?()

        await writer.releaseRead()
        let didPublishNewerCounts = await self.waitForRelayCount(2, model: model)
        let relayReadCount = await writer.readCount()
        XCTAssertTrue(
            didPublishNewerCounts,
            "relay refresh did not publish the newer catalog; reads after arm: \(relayReadCount)"
        )
        XCTAssertEqual(model.presentation.queuedCount, 2)
    }

    func testRelayStateRefreshDoesNotFanOutOneScanPerStateChanged() async throws {
        let sink = WatchModelSignpostSink()
        let signposter = WatchSignposter(sink: sink)
        let writer = BlockingRelayStateRefreshWriter()
        let storage = try WatchModelTestStorage(
            rootURL: self.temporaryDirectory.appendingPathComponent("relay-fanout-storage"),
            fileWriter: writer
        )
        let storageActor = WatchCaptureStorageActor(
            paths: storage.paths,
            fileWriter: writer
        )
        try await storageActor.prepareRoot()
        let externalActor = WatchCaptureStorageActor(
            paths: storage.paths,
            fileWriter: FoundationWatchFileWriter()
        )
        try await externalActor.writeManifest(self.queuedManifest(storage: storage, id: UUID(), index: 0), transactionClass: .captureSafety)
        await writer.armNextRead()
        let complicationRoot = self.temporaryDirectory.appendingPathComponent("relay-fanout-complication", isDirectory: true)
        try FileManager.default.createDirectory(at: complicationRoot, withIntermediateDirectories: true)
        let session = WatchModelConnectivitySession()
        let relaySender = WatchRelaySender(paths: storage.paths, storageActor: storageActor, session: session)
        let collector = WatchRelayDiagnosticsCollector(
            paths: storage.paths,
            storageActor: storageActor,
            session: session,
            environmentProvider: WatchModelEnvironmentProvider()
        )
        let model = WatchCaptureModel(
            paths: storage.paths,
            storageActor: storageActor,
            relaySender: relaySender,
            session: session,
            diagnosticsCollector: collector,
            notificationScheduler: WatchModelNotificationScheduler(),
            environmentProvider: WatchModelEnvironmentProvider(),
            signposter: signposter,
            complicationRootURL: { complicationRoot },
            reloadComplicationTimelines: {}
        )
        await writer.waitUntilReadEntered()
        await writer.releaseRead()
        let didPublishInitialCounts = await self.waitForRelayCount(1, model: model)
        XCTAssertTrue(didPublishInitialCounts)
        await model.requestDiagnosticsRefresh()
        await self.waitUntilReadsIdle(writer: writer)
        sink.reset()

        await writer.armNextRead()
        relaySender.onStateChanged?()
        await writer.waitUntilReadEntered()
        try await externalActor.writeManifest(self.queuedManifest(storage: storage, id: UUID(), index: 1), transactionClass: .captureSafety)
        relaySender.onStateChanged?()
        relaySender.onStateChanged?()
        relaySender.onStateChanged?()
        await writer.releaseRead()
        let didPublishNewerCounts = await self.waitForRelayCount(2, model: model)
        let relayReadCount = await writer.readCount()
        XCTAssertTrue(
            didPublishNewerCounts,
            "coalesced relay refresh did not publish the newer catalog; reads after arm: \(relayReadCount)"
        )

        let requestEnds = sink.events.filter {
            $0.kind == .end && $0.boundary == .relayStateRefreshRequest
        }
        XCTAssertEqual(requestEnds.filter { $0.fields.result == .becameOwner }.count, 1)
        XCTAssertEqual(requestEnds.filter { $0.fields.result == .scheduledFollowUp }.count, 1)
        XCTAssertEqual(requestEnds.filter { $0.fields.result == .mergedFollowUp }.count, 2)
        _ = model
    }

    func testIdenticalComplicationSnapshotDoesNotWriteOrReloadAfterRecovery() async throws {
        let writer = BlockingComplicationSnapshotWriter()
        let storage = try WatchModelTestStorage(
            rootURL: self.temporaryDirectory.appendingPathComponent("identical-snapshot-storage")
        )
        let storageActor = WatchCaptureStorageActor(
            paths: storage.paths,
            fileWriter: writer
        )
        try await storageActor.prepareRoot()
        let complicationRoot = self.temporaryDirectory.appendingPathComponent("identical-snapshot-complication", isDirectory: true)
        try FileManager.default.createDirectory(at: complicationRoot, withIntermediateDirectories: true)
        var reloadCount = 0
        let session = WatchModelConnectivitySession()
        let relaySender = WatchRelaySender(paths: storage.paths, storageActor: storageActor, session: session)
        let collector = WatchRelayDiagnosticsCollector(
            paths: storage.paths,
            storageActor: storageActor,
            session: session,
            environmentProvider: WatchModelEnvironmentProvider()
        )
        let model = WatchCaptureModel(
            paths: storage.paths,
            storageActor: storageActor,
            relaySender: relaySender,
            session: session,
            diagnosticsCollector: collector,
            notificationScheduler: WatchModelNotificationScheduler(),
            environmentProvider: WatchModelEnvironmentProvider(),
            complicationRootURL: { complicationRoot },
            reloadComplicationTimelines: { reloadCount += 1 }
        )
        await writer.waitUntilWriteEntered()
        await writer.release()
        let snapshotURL = complicationRoot.appendingPathComponent(WatchComplicationSnapshot.fileName)
        let didWriteSnapshot = await self.waitForFile(at: snapshotURL)
        XCTAssertTrue(didWriteSnapshot)
        let didReloadOnce = await self.waitUntil { reloadCount == 1 }
        XCTAssertTrue(didReloadOnce)
        await self.waitUntilWritesIdle(writer: writer)
        let writesAfterRecovery = await writer.writeCount()
        let reloadsAfterRecovery = reloadCount

        model.presentation = WatchCaptureOwnerPresentation(status: .off, queuedCount: 0, confirmingCount: 4)
        await self.waitUntilWritesIdle(writer: writer)
        let writesAfterIdentical = await writer.writeCount()
        XCTAssertEqual(writesAfterIdentical, writesAfterRecovery)
        XCTAssertEqual(reloadCount, reloadsAfterRecovery)
        _ = model
    }

    func testFirstUnchangedComplicationStillReloadsOnce() async throws {
        let storage = try WatchModelTestStorage(
            rootURL: self.temporaryDirectory.appendingPathComponent("recovery-reload-storage")
        )
        let storageActor = self.storageActor(for: storage)
        try await storageActor.prepareRoot()
        let complicationRoot = self.temporaryDirectory.appendingPathComponent("recovery-reload-complication", isDirectory: true)
        try FileManager.default.createDirectory(at: complicationRoot, withIntermediateDirectories: true)
        let snapshotURL = complicationRoot.appendingPathComponent(WatchComplicationSnapshot.fileName)
        let initialPresentation = WatchCaptureOwnerPresentation(status: .off, queuedCount: 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(WatchComplicationSnapshot(presentation: initialPresentation, isReachable: true))
            .write(to: snapshotURL, options: .atomic)
        var reloadCount = 0
        let session = WatchModelConnectivitySession()
        let relaySender = WatchRelaySender(paths: storage.paths, storageActor: storageActor, session: session)
        let collector = WatchRelayDiagnosticsCollector(
            paths: storage.paths,
            storageActor: storageActor,
            session: session,
            environmentProvider: WatchModelEnvironmentProvider()
        )
        let sink = WatchModelSignpostSink()
        let model = WatchCaptureModel(
            paths: storage.paths,
            storageActor: storageActor,
            relaySender: relaySender,
            session: session,
            diagnosticsCollector: collector,
            notificationScheduler: WatchModelNotificationScheduler(),
            environmentProvider: WatchModelEnvironmentProvider(),
            signposter: WatchSignposter(sink: sink),
            complicationRootURL: { complicationRoot },
            reloadComplicationTimelines: { reloadCount += 1 }
        )
        let didRecoveryReload = await self.waitUntil { reloadCount == 1 }
        XCTAssertTrue(didRecoveryReload)
        XCTAssertTrue(sink.events.contains {
            $0.kind == .end && $0.boundary == .complicationSnapshot && $0.fields.result == .recoveryReloaded
        })

        model.presentation = WatchCaptureOwnerPresentation(status: .off, queuedCount: 0, confirmingCount: 2)
        let didCacheIdenticalSnapshot = await self.waitUntil {
            sink.events.contains {
                $0.kind == .end && $0.boundary == .complicationSnapshot && $0.fields.result == .cached
            }
        }
        XCTAssertTrue(didCacheIdenticalSnapshot)
        XCTAssertEqual(reloadCount, 1)
        _ = model
    }

    func testFailedComplicationRewriteForcesNextEqualSnapshotWrite() async throws {
        let writer = BlockingComplicationSnapshotWriter()
        let storage = try WatchModelTestStorage(
            rootURL: self.temporaryDirectory.appendingPathComponent("rewrite-debt-storage")
        )
        let storageActor = WatchCaptureStorageActor(paths: storage.paths, fileWriter: writer)
        try await storageActor.prepareRoot()
        let complicationRoot = self.temporaryDirectory.appendingPathComponent("rewrite-debt-complication", isDirectory: true)
        try FileManager.default.createDirectory(at: complicationRoot, withIntermediateDirectories: true)
        let session = WatchModelConnectivitySession()
        let relaySender = WatchRelaySender(paths: storage.paths, storageActor: storageActor, session: session)
        let collector = WatchRelayDiagnosticsCollector(
            paths: storage.paths,
            storageActor: storageActor,
            session: session,
            environmentProvider: WatchModelEnvironmentProvider()
        )
        let sink = WatchModelSignpostSink()
        var reloadCount = 0
        let model = WatchCaptureModel(
            paths: storage.paths,
            storageActor: storageActor,
            relaySender: relaySender,
            session: session,
            diagnosticsCollector: collector,
            notificationScheduler: WatchModelNotificationScheduler(),
            environmentProvider: WatchModelEnvironmentProvider(),
            signposter: WatchSignposter(sink: sink),
            complicationRootURL: { complicationRoot },
            reloadComplicationTimelines: { reloadCount += 1 }
        )

        await writer.waitUntilWriteEntered()
        await writer.release()
        let didPublishInitialSnapshot = await self.waitUntilSettled { reloadCount == 1 }
        XCTAssertTrue(didPublishInitialSnapshot)
        await self.waitUntilWritesIdle(writer: writer)
        let initialWriteCount = await writer.writeCount()

        await writer.failNextWrite()
        sink.reset()
        model.presentation = WatchCaptureOwnerPresentation(status: .off, queuedCount: 1)
        let didFailRewrite = await self.waitUntilSettled {
            sink.events.contains {
                $0.kind == .end && $0.boundary == .complicationSnapshot && $0.fields.result == .failed
            }
        }
        XCTAssertTrue(didFailRewrite)
        let writeCountAfterFailure = await writer.writeCount()
        XCTAssertEqual(writeCountAfterFailure, initialWriteCount + 1)
        XCTAssertEqual(reloadCount, 1)

        // This is byte-identical to the snapshot still on disk. Rewrite debt must
        // bypass the equality fast path and durably rewrite it before reloading.
        model.presentation = WatchCaptureOwnerPresentation(status: .off, queuedCount: 0)
        let didForceEqualRewrite = await self.waitUntilSettled { reloadCount == 2 }
        XCTAssertTrue(didForceEqualRewrite)
        let writeCountAfterRecovery = await writer.writeCount()
        XCTAssertEqual(writeCountAfterRecovery, initialWriteCount + 2)
    }

    func testStatusPublicationReportsPrimaryAndFallbackOutcomes() async throws {
        let signpostSink = WatchModelSignpostSink()
        let signposter = WatchSignposter(sink: signpostSink)
        let storage = try WatchModelTestStorage(rootURL: self.temporaryDirectory.appendingPathComponent("status-storage"))
        let storageActor = self.storageActor(for: storage)
        let session = WatchModelConnectivitySession()
        let relaySender = WatchRelaySender(
            paths: storage.paths,
            storageActor: storageActor,
            session: session,
            signposter: signposter
        )
        let collector = WatchRelayDiagnosticsCollector(
            paths: storage.paths,
            storageActor: storageActor,
            session: session,
            environmentProvider: WatchModelEnvironmentProvider(),
            signposter: signposter
        )
        let complicationRoot = self.temporaryDirectory.appendingPathComponent("status-complication", isDirectory: true)
        try FileManager.default.createDirectory(at: complicationRoot, withIntermediateDirectories: true)
        let model = WatchCaptureModel(
            paths: storage.paths,
            storageActor: storageActor,
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
        let didPublishFallback = await self.waitUntil {
            signpostSink.events.contains {
                $0.kind == .end && $0.boundary == .statusPublication && $0.fields.result == .partial
            }
        }
        XCTAssertTrue(didPublishFallback)

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
    }

    func testStatusPublicationAllSuccessEmitsNoFallbackInterval() async throws {
        let (model, sink) = try self.makeStatusPublicationFixture(name: "status-success")
        await Task.yield()
        await Task.yield()
        sink.reset()

        model.republishStatusOnReconnect()
        let didPublish = await self.waitUntil {
            sink.events.contains {
                $0.kind == .end && $0.boundary == .statusPublication && $0.fields.result == .completed
            }
        }
        XCTAssertTrue(didPublish)

        XCTAssertTrue(sink.events.contains {
            $0.kind == .end && $0.boundary == .applicationContextPrimary && $0.fields.result == .completed
        })
        XCTAssertFalse(sink.events.contains { $0.boundary == .applicationContextFallback })
        XCTAssertTrue(sink.events.contains {
            $0.kind == .end && $0.boundary == .statusPublication && $0.fields.result == .completed
        })
    }

    func testReconnectPublishesCachedStatusBeforeDiagnosticsRefreshCompletes() async throws {
        let writer = BlockingRelayStateRefreshWriter()
        let storage = try WatchModelTestStorage(
            rootURL: self.temporaryDirectory.appendingPathComponent("reconnect-cached-first-storage"),
            fileWriter: writer
        )
        let storageActor = WatchCaptureStorageActor(paths: storage.paths, fileWriter: writer)
        try await storageActor.prepareRoot()
        try await storageActor.writeManifest(
            self.queuedManifest(storage: storage, id: UUID(), index: 0),
            transactionClass: .captureSafety
        )
        let complicationRoot = self.temporaryDirectory.appendingPathComponent(
            "reconnect-cached-first-complication",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: complicationRoot, withIntermediateDirectories: true)
        let session = WatchModelConnectivitySession()
        let relaySender = WatchRelaySender(paths: storage.paths, storageActor: storageActor, session: session)
        let collector = WatchRelayDiagnosticsCollector(
            paths: storage.paths,
            storageActor: storageActor,
            session: session,
            environmentProvider: WatchModelEnvironmentProvider()
        )
        let model = WatchCaptureModel(
            paths: storage.paths,
            storageActor: storageActor,
            relaySender: relaySender,
            session: session,
            diagnosticsCollector: collector,
            notificationScheduler: WatchModelNotificationScheduler(),
            environmentProvider: WatchModelEnvironmentProvider(),
            complicationRootURL: { complicationRoot },
            reloadComplicationTimelines: {}
        )
        let didSettleLaunch = await self.waitUntilSettled {
            model.presentation.queuedCount == 1 && session.applicationContextUpdateCount >= 2
        }
        XCTAssertTrue(didSettleLaunch)
        await model.requestDiagnosticsRefresh()
        await self.waitUntilReadsIdle(writer: writer)

        let updatesBeforeReconnect = session.applicationContextUpdateCount
        let cachedEnvelope = WatchStatusContext(
            applicationContext: session.receivedApplicationContext
        )?.diagnosticsEnvelope
        await writer.armNextRead()
        model.republishStatusOnReconnect()
        await writer.waitUntilReadEntered()

        XCTAssertEqual(session.applicationContextUpdateCount, updatesBeforeReconnect + 1)
        XCTAssertEqual(
            WatchStatusContext(applicationContext: session.receivedApplicationContext)?.diagnosticsEnvelope,
            cachedEnvelope
        )

        await writer.releaseRead()
        let didPublishFreshDiagnostics = await self.waitUntilSettled {
            session.applicationContextUpdateCount == updatesBeforeReconnect + 2
        }
        XCTAssertTrue(didPublishFreshDiagnostics)
    }

    func testStatusPublicationBothFailuresReportsFailedParent() async throws {
        let (model, sink, session) = try self.makeStatusPublicationFixtureIncludingSession(name: "status-both-fail")
        await Task.yield()
        await Task.yield()
        sink.reset()
        session.remainingPublicationFailures = 2

        model.republishStatusOnReconnect()
        let didFailPublication = await self.waitUntil {
            sink.events.contains {
                $0.kind == .end && $0.boundary == .statusPublication && $0.fields.result == .failed
            }
        }
        XCTAssertTrue(didFailPublication)

        XCTAssertTrue(sink.events.contains {
            $0.kind == .end && $0.boundary == .applicationContextPrimary && $0.fields.result == .failed
        })
        XCTAssertTrue(sink.events.contains {
            $0.kind == .end && $0.boundary == .applicationContextFallback && $0.fields.result == .failed
        })
        XCTAssertTrue(sink.events.contains {
            $0.kind == .end && $0.boundary == .statusPublication && $0.fields.result == .failed
        })
    }

    func testDiagnosticsEnvelopeStaysOwedUntilPrimaryApplicationContextAcceptsIt() async throws {
        let (model, sink, session) = try self.makeStatusPublicationFixtureIncludingSession(
            name: "owed-until-accepted"
        )
        let didLaunchAcceptPrimary = await self.waitUntilSettled {
            sink.events.contains {
                $0.kind == .end && $0.boundary == .statusPublication && $0.fields.result == .completed
            }
        }
        XCTAssertTrue(didLaunchAcceptPrimary)
        XCTAssertFalse(model.diagnosticsEnvelopeOwedUntilAccepted)

        sink.reset()
        session.remainingPublicationFailures = 1
        await model.requestDiagnosticsRefresh()
        XCTAssertTrue(model.diagnosticsEnvelopeOwedUntilAccepted)
        XCTAssertTrue(sink.events.contains {
            $0.kind == .end && $0.boundary == .applicationContextPrimary && $0.fields.result == .failed
        })
        XCTAssertTrue(sink.events.contains {
            $0.kind == .end && $0.boundary == .applicationContextFallback && $0.fields.result == .completed
        })
        XCTAssertTrue(sink.events.contains {
            $0.kind == .end && $0.boundary == .statusPublication && $0.fields.result == .partial
        })

        sink.reset()
        session.remainingPublicationFailures = 0
        await model.requestDiagnosticsRefresh()
        XCTAssertFalse(model.diagnosticsEnvelopeOwedUntilAccepted)
        XCTAssertTrue(sink.events.contains {
            $0.kind == .end && $0.boundary == .applicationContextPrimary && $0.fields.result == .completed
        })
        XCTAssertFalse(sink.events.contains { $0.boundary == .applicationContextFallback })
    }

    func testDiagnosticsAcceptanceRequiresCurrentGenerationEvenWhenBytesMatch() {
        let envelope = Data("same-envelope".utf8)
        var cache = WatchDiagnosticsPublicationCache(envelopeData: envelope)
        let first = cache.publication
        cache.replaceEnvelope(envelope)

        cache.markAccepted(envelopeData: first.envelopeData, generation: first.generation)
        XCTAssertTrue(cache.owedUntilAccepted)

        let current = cache.publication
        cache.markAccepted(envelopeData: current.envelopeData, generation: current.generation)
        XCTAssertFalse(cache.owedUntilAccepted)
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
        let storage = try WatchModelTestStorage(rootURL: self.temporaryDirectory.appendingPathComponent("session-trigger-storage"))
        let session = WatchModelConnectivitySession()
        let sender = WatchRelaySender(paths: storage.paths, storageActor: self.storageActor(for: storage), session: session, signposter: signposter)
        let model = WatchSessionModel(session: session, relaySender: sender)

        session.activationState = .activated
        session.emitActivationChanged(true)
        let didDrainActivation = await self.waitUntil {
            sink.events.contains {
                $0.kind == .end && $0.boundary == .relayDrain && $0.fields.trigger == .connectivityActivation
            }
        }
        XCTAssertTrue(didDrainActivation)
        XCTAssertTrue(sink.events.contains {
            $0.kind == .end && $0.boundary == .relayDrain && $0.fields.trigger == .connectivityActivation
        })

        sink.reset()
        session.emitReachability(true)
        let didDrainReachability = await self.waitUntil {
            sink.events.contains {
                $0.kind == .end && $0.boundary == .relayDrain && $0.fields.trigger == .connectivityReachability
            }
        }
        XCTAssertTrue(didDrainReachability)
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
        let storage = try WatchModelTestStorage(rootURL: self.temporaryDirectory.appendingPathComponent(name))
        let storageActor = self.storageActor(for: storage)
        let session = WatchModelConnectivitySession()
        let relaySender = WatchRelaySender(
            paths: storage.paths,
            storageActor: storageActor,
            session: session,
            signposter: signposter
        )
        let collector = WatchRelayDiagnosticsCollector(
            paths: storage.paths,
            storageActor: storageActor,
            session: session,
            environmentProvider: WatchModelEnvironmentProvider(),
            signposter: signposter
        )
        let complicationRoot = self.temporaryDirectory.appendingPathComponent("\(name)-complication", isDirectory: true)
        try FileManager.default.createDirectory(at: complicationRoot, withIntermediateDirectories: true)
        let model = WatchCaptureModel(
            paths: storage.paths,
            storageActor: storageActor,
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
        let storage = try WatchModelTestStorage(rootURL: self.temporaryDirectory.appendingPathComponent(name))
        let storageActor = self.storageActor(for: storage)
        let day = storage.dayString(for: now)
        let segment = storage.segmentString(for: now, durationSeconds: 60)
        let directory = try await storageActor.prepareSegmentDirectory(day: day, segment: segment)
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
        try await storageActor.writeManifest(manifest, transactionClass: .captureSafety)
        let session = WatchModelConnectivitySession()
        let relaySender = WatchRelaySender(
            paths: storage.paths,
            storageActor: storageActor,
            session: session,
            clock: { now },
            signposter: signposter
        )
        session.activationState = .activated
        await relaySender.requestDrain(trigger: .testDirect)
        let attemptData = try await storage.fileWriter.readData(
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
        let snapshotStorage = try WatchModelTestStorage(
            rootURL: self.temporaryDirectory.appendingPathComponent("\(name)-snapshot-storage")
        )
        let snapshotStorageActor = self.storageActor(for: snapshotStorage)
        let snapshotSession = WatchModelConnectivitySession()
        let snapshotSender = WatchRelaySender(
            paths: snapshotStorage.paths,
            storageActor: snapshotStorageActor,
            session: snapshotSession,
            clock: { now },
            signposter: signposter
        )
        let snapshotCollector = WatchRelayDiagnosticsCollector(
            paths: snapshotStorage.paths,
            storageActor: snapshotStorageActor,
            session: snapshotSession,
            environmentProvider: WatchModelEnvironmentProvider(),
            signposter: signposter
        )
        let complicationRoot = self.temporaryDirectory.appendingPathComponent("\(name)-complication", isDirectory: true)
        try FileManager.default.createDirectory(at: complicationRoot, withIntermediateDirectories: true)
        let snapshotModel = WatchCaptureModel(
            paths: snapshotStorage.paths,
            storageActor: snapshotStorageActor,
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
        let snapshotURL = complicationRoot.appendingPathComponent(WatchComplicationSnapshot.fileName)
        let didWriteSnapshot = await self.waitForFile(at: snapshotURL)
        XCTAssertTrue(didWriteSnapshot)
        let envelopeData = await snapshotCollector.makeEnvelopeData(asOf: now)
        let diagnosticsEnvelope = try XCTUnwrap(envelopeData)
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
            manifest: try await storage.fileWriter.readData(from: storage.manifestURL(directory: directory)),
            relayBundle: try await storage.fileWriter.readData(from: relaySender.bundleURL(for: id)),
            normalizedAttemptRecord: try WatchRelayAttemptRecord.makeEncoder().encode(normalizedAttempt),
            complicationSnapshot: try Data(contentsOf: snapshotURL)
        )
    }

    private func storageActor(for storage: WatchModelTestStorage) -> WatchCaptureStorageActor {
        WatchCaptureStorageActor(
            paths: storage.paths,
            fileWriter: storage.fileWriter
        )
    }

    private func queuedManifest(
        storage: WatchModelTestStorage,
        id: UUID,
        index: Int
    ) -> WatchSegmentManifest {
        let startedAt = Date(timeIntervalSince1970: 1_735_689_600 + Double(index * 60))
        return WatchSegmentManifest(
            id: id,
            day: storage.dayString(for: startedAt),
            segment: storage.segmentString(for: startedAt, durationSeconds: 60),
            startedAt: startedAt,
            duration: 60,
            sensors: [],
            partial: false,
            lost: false,
            gap: false,
            fixCount: 0,
            state: .queued,
            failureReason: nil
        )
    }

    private func waitForFile(at url: URL) async -> Bool {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func waitForWriteCount(
        _ count: Int,
        writer: BlockingComplicationSnapshotWriter
    ) async -> Bool {
        for _ in 0..<100 {
            if await writer.writeCount() >= count {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if predicate() {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func waitUntilSettled(_ predicate: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if predicate() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private func waitForReadCount(
        _ count: Int,
        writer: BlockingRelayStateRefreshWriter
    ) async -> Bool {
        for _ in 0..<100 {
            if await writer.readCount() >= count {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func waitForRelayCount(_ count: Int, model: WatchCaptureModel) async -> Bool {
        for _ in 0..<400 {
            if model.presentation.queuedCount == count {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private func waitUntilReadsIdle(writer: BlockingRelayStateRefreshWriter) async {
        var last = await writer.readCount()
        var stable = 0
        for _ in 0..<200 {
            try? await Task.sleep(for: .milliseconds(10))
            let current = await writer.readCount()
            if current == last {
                stable += 1
                if stable >= 8 { return }
            } else {
                stable = 0
                last = current
            }
        }
    }

    private func waitUntilWritesIdle(writer: BlockingComplicationSnapshotWriter) async {
        var last = await writer.writeCount()
        var stable = 0
        for _ in 0..<200 {
            try? await Task.sleep(for: .milliseconds(10))
            let current = await writer.writeCount()
            if current == last {
                stable += 1
                if stable >= 8 { return }
            } else {
                stable = 0
                last = current
            }
        }
    }
}

private actor BlockingComplicationSnapshotWriter: WatchFileWriting {
    private let base = FoundationWatchFileWriter()
    private var writeEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var writeReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var didEnterWrite = false
    private var shouldBlock = true
    private var writes = 0
    private var writeFailuresRemaining = 0

    func createDirectory(at url: URL) async throws {
        try await self.base.createDirectory(at: url)
    }

    func createFileIfNeeded(at url: URL) async throws {
        try await self.base.createFileIfNeeded(at: url)
    }

    func fileExists(at url: URL) async -> Bool {
        await self.base.fileExists(at: url)
    }

    func itemKind(at url: URL) async throws -> WatchCaptureStorageItemKind {
        try await self.base.itemKind(at: url)
    }

    func fileSize(at url: URL) async throws -> Int64 {
        try await self.base.fileSize(at: url)
    }

    func fileFingerprint(at url: URL) async throws -> WatchCaptureStorageFileFingerprint? {
        try await self.base.fileFingerprint(at: url)
    }

    func readData(from url: URL) async throws -> Data {
        try await self.base.readData(from: url)
    }

    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) async throws {
        self.writes += 1
        if !self.didEnterWrite {
            self.didEnterWrite = true
            let waiters = self.writeEntryWaiters
            self.writeEntryWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
        if self.shouldBlock {
            await withCheckedContinuation { continuation in
                self.writeReleaseWaiters.append(continuation)
            }
            self.shouldBlock = false
        }
        if self.writeFailuresRemaining > 0 {
            self.writeFailuresRemaining -= 1
            throw WatchModelTestError.complicationWriteFailed
        }
        try await self.base.writeData(data, to: url, options: options)
    }

    func appendLine(_ line: Data, to url: URL) async throws {
        try await self.base.appendLine(line, to: url)
    }

    func atomicReplaceFile(at url: URL, with data: Data) async throws {
        try await self.base.atomicReplaceFile(at: url, with: data)
    }

    func removeItem(at url: URL) async throws {
        try await self.base.removeItem(at: url)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) async throws {
        try await self.base.moveItem(at: sourceURL, to: destinationURL)
    }

    func contentsOfDirectory(at url: URL) async throws -> [URL] {
        try await self.base.contentsOfDirectory(at: url)
    }

    func waitUntilWriteEntered() async {
        guard !self.didEnterWrite else { return }
        await withCheckedContinuation { continuation in
            self.writeEntryWaiters.append(continuation)
        }
    }

    func release() {
        let waiters = self.writeReleaseWaiters
        self.writeReleaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func writeCount() -> Int {
        self.writes
    }

    func failNextWrite() {
        self.writeFailuresRemaining += 1
    }
}

private actor BlockingRelayStateRefreshWriter: WatchFileWriting {
    private let base = FoundationWatchFileWriter()
    private var shouldBlockNextRead = false
    private var reads = 0
    private var readEntered = false
    private var readEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var readReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    func createDirectory(at url: URL) async throws { try await self.base.createDirectory(at: url) }
    func createFileIfNeeded(at url: URL) async throws { try await self.base.createFileIfNeeded(at: url) }
    func fileExists(at url: URL) async -> Bool { await self.base.fileExists(at: url) }
    func itemKind(at url: URL) async throws -> WatchCaptureStorageItemKind {
        try await self.base.itemKind(at: url)
    }
    func fileSize(at url: URL) async throws -> Int64 { try await self.base.fileSize(at: url) }
    func fileFingerprint(at url: URL) async throws -> WatchCaptureStorageFileFingerprint? {
        try await self.base.fileFingerprint(at: url)
    }

    func readData(from url: URL) async throws -> Data {
        self.reads += 1
        if self.shouldBlockNextRead {
            self.shouldBlockNextRead = false
            self.readEntered = true
            let waiters = self.readEntryWaiters
            self.readEntryWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                self.readReleaseWaiters.append(continuation)
            }
        }
        return try await self.base.readData(from: url)
    }

    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) async throws {
        try await self.base.writeData(data, to: url, options: options)
    }
    func appendLine(_ line: Data, to url: URL) async throws { try await self.base.appendLine(line, to: url) }
    func atomicReplaceFile(at url: URL, with data: Data) async throws {
        try await self.base.atomicReplaceFile(at: url, with: data)
    }
    func removeItem(at url: URL) async throws { try await self.base.removeItem(at: url) }
    func moveItem(at sourceURL: URL, to destinationURL: URL) async throws {
        try await self.base.moveItem(at: sourceURL, to: destinationURL)
    }
    func contentsOfDirectory(at url: URL) async throws -> [URL] {
        try await self.base.contentsOfDirectory(at: url)
    }

    func armNextRead() {
        self.shouldBlockNextRead = true
        self.readEntered = false
        self.reads = 0
    }

    func waitUntilReadEntered() async {
        guard !self.readEntered else { return }
        await withCheckedContinuation { continuation in
            self.readEntryWaiters.append(continuation)
        }
    }

    func releaseRead() {
        let waiters = self.readReleaseWaiters
        self.readReleaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func readCount() -> Int {
        self.reads
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
    private(set) var applicationContextUpdateCount = 0

    func activate() {}
    private(set) var transferredFiles: [(URL, [String: Any])] = []

    func transferFile(_ url: URL, metadata: [String: Any]) {
        self.transferredFiles.append((url, metadata))
    }
    func transferUserInfo(_ userInfo: [String: Any]) {}
    func sendMessage(_ message: [String: Any]) {}
    func updateApplicationContext(_ applicationContext: [String: Any]) throws {
        self.applicationContextUpdateCount += 1
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
    case complicationWriteFailed
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
