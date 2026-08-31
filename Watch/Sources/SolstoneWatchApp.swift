// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UserNotifications

@main
struct SolstoneWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @State private var sessionModel: WatchSessionModel
    @State private var captureModel: WatchCaptureModel
    @State private var backgroundTaskCoordinator: WatchBackgroundTaskCoordinator
    private let notificationScheduler: LiveWatchNotificationScheduler

    init() {
        let bootstrap = WatchSignpost.begin(.bootstrap)
        defer {
            WatchSignpost.end(bootstrap, fields: WatchSignpostFields(result: .completed))
        }
        let session = LiveWatchConnectivitySession()
        self.notificationScheduler = LiveWatchNotificationScheduler()
        UNUserNotificationCenter.current().delegate = self.notificationScheduler
            let diagnosticsStore: WatchRelayDiagnosticsStore?
        do {
            let storage = try WatchCaptureStorage()
            let store = WatchRelayDiagnosticsStore(storage: storage)
            diagnosticsStore = store
            let relaySender = WatchRelaySender(storage: storage, session: session, diagnosticsStore: store)
            let environmentProvider = LiveWatchRelayDiagnosticsEnvironmentProvider()
            let diagnosticsCollector = WatchRelayDiagnosticsCollector(
                storage: storage,
                diagnosticsStore: store,
                session: session,
                environmentProvider: environmentProvider
            )
            let sessionModel = WatchSessionModel(session: session, relaySender: relaySender)
            let captureModel = WatchCaptureModel(
                storage: storage,
                relaySender: relaySender,
                session: session,
                diagnosticsCollector: diagnosticsCollector,
                notificationScheduler: self.notificationScheduler,
                environmentProvider: environmentProvider
            )
            sessionModel.onReachableRepublish = { [weak captureModel] in captureModel?.republishStatusOnReconnect() }
            self._sessionModel = State(initialValue: sessionModel)
            self._captureModel = State(initialValue: captureModel)
        } catch {
            diagnosticsStore = nil
            self._sessionModel = State(initialValue: WatchSessionModel(
                session: session,
                relaySender: nil
            ))
            self._captureModel = State(initialValue: WatchCaptureModel(initializationError: error))
        }
        let coordinator = WatchBackgroundTaskCoordinator(session: session, diagnosticsStore: diagnosticsStore)
        self._backgroundTaskCoordinator = State(initialValue: coordinator)
        self.appDelegate.session = session
        self.appDelegate.backgroundTaskCoordinator = coordinator
    }

    var body: some Scene {
        WindowGroup {
            WatchHomeView(model: self.sessionModel, captureModel: self.captureModel)
                .task {
                    self.sessionModel.activate()
                }
        }
    }
}
