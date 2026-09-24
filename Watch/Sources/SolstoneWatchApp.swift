// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

@main
struct SolstoneWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @State private var sessionModel: WatchSessionModel
    @State private var captureModel: WatchCaptureModel
    @State private var backgroundTaskCoordinator: WatchBackgroundTaskCoordinator

#if DEBUG && targetEnvironment(simulator)
    private static var sunArcDebugOverride: SunArcBackgroundDebugOverride? {
        SunArcBackgroundDebugScene.sceneOverride(for: ProcessInfo.processInfo.arguments)
    }

    static var facePinOverride: (presentation: WatchCaptureOwnerPresentation, isReachable: Bool)? {
        WatchFaceDebugScene.pin(from: ProcessInfo.processInfo.arguments)
    }

    private static var usesSimulatorPresentationSeed: Bool {
        ProcessInfo.processInfo.arguments.contains("--app-store-screenshots")
            || Self.sunArcDebugOverride != nil
    }

    static var usesSimulatorSyntheticSession: Bool {
        Self.facePinOverride != nil || Self.usesSimulatorPresentationSeed
    }
#endif

    init() {
        let bootstrap = WatchSignpost.begin(.bootstrap)
        defer {
            WatchSignpost.end(bootstrap, fields: WatchSignpostFields(result: .completed))
        }
#if DEBUG && targetEnvironment(simulator)
        if Self.usesSimulatorSyntheticSession {
            let session = LiveWatchConnectivitySession(messageSend: { _, _ in })
            let model = WatchSessionModel(session: session, relaySender: nil)
            let pin = Self.facePinOverride
            let isReachable: Bool
            let presentation: WatchCaptureOwnerPresentation

            if let pin {
                isReachable = pin.isReachable
                presentation = pin.presentation
            } else {
                let saved = ProcessInfo.processInfo.arguments.contains("--screenshot-saved")
                isReachable = !saved
                presentation = WatchCaptureOwnerPresentation(
                    status: saved ? .off : .active,
                    queuedCount: saved ? 3 : 0,
                    handedOffCount: saved ? 0 : 2,
                    isSessionRunning: !saved,
                    sessionStartedAt: saved ? nil : Date().addingTimeInterval(-135),
                    lastVerifiedAudioAt: saved ? nil : Date()
                )
            }

            model.isReachable = isReachable
            let nonce = model.journalVersion.beginReachableSession()
            let version = WatchJournalVersionPayload(
                revision: 1, identity: "sample-journal", version: "2.0.0", current: isReachable, nonce: nonce
            )
            if let data = try? JSONEncoder().encode(version) {
                model.journalVersion.receive(data, live: isReachable)
            }
            self._sessionModel = State(initialValue: model)
            self._captureModel = State(initialValue: WatchCaptureModel(screenshotPresentation: presentation))
            self._backgroundTaskCoordinator = State(initialValue:
                WatchBackgroundTaskCoordinator(session: session, storageActor: nil)
            )
            return
        }
#endif
        let session = LiveWatchConnectivitySession()
        let storageActor: WatchCaptureStorageActor?
        do {
            let paths = try WatchCaptureStoragePaths()
            let fileWriter = FoundationWatchFileWriter()
            let actor = WatchCaptureStorageActor(
                paths: paths,
                fileWriter: fileWriter
            )
            storageActor = actor
            let relaySender = WatchRelaySender(
                paths: paths,
                storageActor: actor,
                session: session
            )
            let environmentProvider = LiveWatchRelayDiagnosticsEnvironmentProvider()
            let diagnosticsCollector = WatchRelayDiagnosticsCollector(
                paths: paths,
                storageActor: actor,
                session: session,
                environmentProvider: environmentProvider
            )
            let sessionModel = WatchSessionModel(session: session, relaySender: relaySender)
            let captureModel = WatchCaptureModel(
                paths: paths,
                storageActor: actor,
                relaySender: relaySender,
                session: session,
                diagnosticsCollector: diagnosticsCollector,
                environmentProvider: environmentProvider
            )
            sessionModel.onActivationRepublish = { [weak captureModel] in captureModel?.republishStatusOnActivation() }
            self._sessionModel = State(initialValue: sessionModel)
            self._captureModel = State(initialValue: captureModel)
        } catch {
            storageActor = nil
            self._sessionModel = State(initialValue: WatchSessionModel(
                session: session,
                relaySender: nil
            ))
            self._captureModel = State(initialValue: WatchCaptureModel(initializationError: error))
        }
        let coordinator = WatchBackgroundTaskCoordinator(session: session, storageActor: storageActor)
        self._backgroundTaskCoordinator = State(initialValue: coordinator)
        self.appDelegate.session = session
        self.appDelegate.backgroundTaskCoordinator = coordinator
    }

    var body: some Scene {
        WindowGroup {
            WatchSunArcRoot(sessionModel: self.sessionModel, captureModel: self.captureModel)
        }
    }
}

/// The bi-modal watch face (founder, 2026-09-23). Wrist up: the hero, the details and the
/// control on brand ink, with no sun arc. Wrist down (`isLuminanceReduced`): only the sun arc's
/// dark row over black, and nothing else. `WatchHomeView` holds one unconditional position, so
/// its `.task`, its `scenePhase` raise handler and its elapsed timeline keep their identity
/// across the switch; only the layer beneath it changes.
private struct WatchSunArcRoot: View {
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let sessionModel: WatchSessionModel
    let captureModel: WatchCaptureModel

#if DEBUG && targetEnvironment(simulator)
    private var isWristDown: Bool {
        WatchFaceDebugScene.isWristDown(from: ProcessInfo.processInfo.arguments)
    }

    private var effectiveLuminanceReduced: Bool {
        self.isLuminanceReduced || self.isWristDown
    }

    private static var sunArcDebugOverride: SunArcBackgroundDebugOverride? {
        SunArcBackgroundDebugScene.sceneOverride(for: ProcessInfo.processInfo.arguments)
    }
#else
    private var effectiveLuminanceReduced: Bool {
        self.isLuminanceReduced
    }
#endif

    var body: some View {
        let mode = WatchFaceMode(luminanceReduced: self.effectiveLuminanceReduced)
        let face = ZStack {
            if mode.showsSunArc {
                self.sunArc
            } else {
                Color(watchFaceHex: mode.groundHex).ignoresSafeArea()
            }
            WatchHomeView(model: self.sessionModel, captureModel: self.captureModel)
                .opacity(mode.showsContent ? 1 : 0)
                .accessibilityHidden(!mode.showsContent)
                .allowsHitTesting(mode.showsContent)
                .task {
#if DEBUG && targetEnvironment(simulator)
                    if SolstoneWatchApp.usesSimulatorSyntheticSession { return }
#endif
                    self.sessionModel.activate()
                }
        }
#if DEBUG && targetEnvironment(simulator)
        if self.isWristDown {
            face.environment(\.isLuminanceReduced, true)
        } else {
            face
        }
#else
        face
#endif
    }

    /// The wrist-down face: the sun arc's dark row over black, with nothing on top of it.
    private var sunArc: some View {
#if DEBUG && targetEnvironment(simulator)
        SunArcBackgroundHost(
            palette: SunArcGroundPalette(),
            presentationCoordinate: self.captureModel.sunArcPresentationCoordinate,
            debugOverride: Self.sunArcDebugOverride,
            fixedAppearance: .dark,
            blackGround: true
        ) {
            EmptyView()
        }
#else
        SunArcBackgroundHost(
            palette: SunArcGroundPalette(),
            presentationCoordinate: self.captureModel.sunArcPresentationCoordinate,
            fixedAppearance: .dark,
            blackGround: true
        ) {
            EmptyView()
        }
#endif
    }
}

private extension Color {
    init(watchFaceHex hex: String) {
        let rgb = SunArcOKLab.rgb(fromHex: hex)
        self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }
}
