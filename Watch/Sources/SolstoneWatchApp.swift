// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

@main
struct SolstoneWatchApp: App {
    @State private var sessionModel: WatchSessionModel
    @State private var captureModel: WatchCaptureModel

    init() {
        let session = LiveWatchConnectivitySession()
        do {
            let storage = try WatchCaptureStorage()
            let relaySender = WatchRelaySender(storage: storage, session: session)
            let sessionModel = WatchSessionModel(session: session, relaySender: relaySender)
            let captureModel = WatchCaptureModel(storage: storage, relaySender: relaySender, session: session)
            sessionModel.onReachableRepublish = { [weak captureModel] in captureModel?.republishStatusOnReconnect() }
            self._sessionModel = State(initialValue: sessionModel)
            self._captureModel = State(initialValue: captureModel)
        } catch {
            self._sessionModel = State(initialValue: WatchSessionModel(
                session: session,
                relaySender: nil
            ))
            self._captureModel = State(initialValue: WatchCaptureModel(initializationError: error))
        }
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
