// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppIntents
import Foundation
import WidgetKit
import os

@MainActor
protocol ObserverSessionControlling: AnyObject, Sendable {
    func startCaptureSession(mode: ObserverMode) async -> Bool
    func stopCaptureSession() async -> Bool
}

let observerCaptureControlKind = "SolstoneObserverCaptureControl"
let openJournalControlKind = "SolstoneOpenJournalControl"

struct ObserverCaptureControlValue: Equatable, Sendable {
    let isOn: Bool
    let isUnavailable: Bool
    let status: ObserverCaptureControlStatus?
}

enum ObserverCaptureControlStatus: Equatable, Sendable {
    case unknownState
    case journalRequired
    case permissionUndetermined
    case permissionDenied

    var text: String {
        switch self {
        case .unknownState:
            "tbd: unknown state"
        case .journalRequired:
            "tbd: journal needed"
        case .permissionUndetermined:
            "tbd: permission needed"
        case .permissionDenied:
            "tbd: permission denied"
        }
    }
}

@MainActor
enum ObserverCaptureControlState {
    static func value(
        snapshot: AppGroupMirror.Snapshot?,
        permission: AppGroupMirror.MicrophonePermissionSnapshot
    ) -> ObserverCaptureControlValue {
        guard let snapshot else {
            return ObserverCaptureControlValue(isOn: false, isUnavailable: true, status: .unknownState)
        }

        if case .live = snapshot.session {
            return ObserverCaptureControlValue(isOn: true, isUnavailable: false, status: nil)
        }

        guard snapshot.pairing.isPaired else {
            return ObserverCaptureControlValue(isOn: false, isUnavailable: true, status: .journalRequired)
        }

        switch permission {
        case .granted:
            return ObserverCaptureControlValue(isOn: false, isUnavailable: false, status: nil)
        case .undetermined:
            return ObserverCaptureControlValue(isOn: false, isUnavailable: true, status: .permissionUndetermined)
        case .denied:
            return ObserverCaptureControlValue(isOn: false, isUnavailable: true, status: .permissionDenied)
        }
    }
}

@MainActor
protocol ObserverCaptureControlReloading {
    func reloadControls(ofKind kind: String)
}

@MainActor
struct ObserverCaptureControlCenterReloader: ObserverCaptureControlReloading {
    func reloadControls(ofKind kind: String) {
        ControlCenter.shared.reloadControls(ofKind: kind)
    }
}

@MainActor
enum ObserverCaptureControlMirrorWriter {
    static func update(
        session: AppGroupMirror.SessionState,
        mirror: AppGroupMirror,
        controls: any ObserverCaptureControlReloading = ObserverCaptureControlCenterReloader()
    ) -> Result<Void, AppGroupMirror.StorageError> {
        let snapshot = mirror.snapshot()
        let pairing = snapshot?.pairing ?? AppGroupMirror.PairingSnapshot(journalName: nil, isPaired: false)
        let microphonePermission = snapshot?.microphonePermission ?? .undetermined
        let sourceStates = snapshot?.sourceStates ?? [:]
        let backlogCount = snapshot?.backlogCount ?? 0
        let result = mirror.updateSessionAndSources(
            pairing: pairing,
            microphonePermission: microphonePermission,
            session: session,
            sourceStates: sourceStates,
            backlogCount: backlogCount
        )
        controls.reloadControls(ofKind: observerCaptureControlKind)
        return result
    }
}

private let observerCaptureIntentLog = Logger(subsystem: "app.solstone.swift", category: "app-intents")

struct ObserverCaptureIntent: AppIntent, SetValueIntent, AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "solstone" }
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "tbd", default: false)
    var value: Bool

    @Dependency private var observerManager: any ObserverSessionControlling

    init() {
        self.value = false
    }

    init(value: Bool) {
        self.value = value
    }

    func perform() async throws -> some IntentResult {
        let didChangeSession: Bool
        if self.value {
            didChangeSession = await self.observerManager.startCaptureSession(mode: .meeting)
        } else {
            didChangeSession = await self.observerManager.stopCaptureSession()
        }

        guard didChangeSession else {
            throw AppIntentError.Unrecoverable.notAllowed
        }

        await MainActor.run {
            let mirror = AppGroupMirror()
            let session: AppGroupMirror.SessionState
            if self.value {
                session = .live(mode: .meeting, startedAt: Date())
            } else {
                session = .notLive
            }

            if case .failure(let error) = ObserverCaptureControlMirrorWriter.update(session: session, mirror: mirror) {
                observerCaptureIntentLog.error("capture intent app group mirror write failed: \(String(describing: error), privacy: .public)")
            }
        }
        return .result()
    }
}
