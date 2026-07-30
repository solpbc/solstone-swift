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

    init() {
        let session = LiveWatchConnectivitySession()
        let notificationScheduler = LiveWatchNotificationScheduler()
        UNUserNotificationCenter.current().delegate = notificationScheduler
        let diagnosticsStore: WatchRelayDiagnosticsStore?
        do {
            let storage = try WatchCaptureStorage()
            let store = WatchRelayDiagnosticsStore(storage: storage)
            diagnosticsStore = store
            let relaySender = WatchRelaySender(storage: storage, session: session, diagnosticsStore: store)
            let diagnosticsCollector = WatchRelayDiagnosticsCollector(
                storage: storage,
                diagnosticsStore: store,
                session: session
            )
            let sessionModel = WatchSessionModel(session: session, relaySender: relaySender)
            let captureModel = WatchCaptureModel(
                storage: storage,
                relaySender: relaySender,
                session: session,
                diagnosticsCollector: diagnosticsCollector,
                notificationScheduler: notificationScheduler
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
