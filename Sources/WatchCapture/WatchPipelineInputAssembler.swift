#if os(iOS)
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SwiftUI
import UIKit

@MainActor
struct WatchPipelineAssembly {
    let input: WatchPipelineInput
    let session: WatchSessionReadiness
    let recordingStatus: WatchRecordingStatus
    let waiting: WatchWaitingBreakdown

    var installedFlowInput: WatchInstalledFlowInput {
        WatchInstalledFlowInput(
            stuck: WatchPipelineReducer.stuckState(self.input),
            recordingStatus: self.recordingStatus,
            waiting: self.waiting
        )
    }

    var lane: PhoneWatchSourceLane {
        phoneWatchSourceLane(session: self.session, flow: self.installedFlowInput)
    }
}

@propertyWrapper
@MainActor
struct WatchPipelineInputReader: DynamicProperty {
    // KILL-LIST-EXEMPT:BEGIN
    @Environment(WatchLink.self) private var watchLink
    @Environment(WatchRelayReceiver.self) private var receiver: WatchRelayReceiver?
    @Environment(WatchUploaderHolder.self) private var watchUploaderHolder
    @Environment(WatchSegmentLedger.self) private var watchSegmentLedger
    @Environment(ConnectionSyncModel.self) private var connectionSyncModel
    @Environment(WatchSourceFacts.self) private var watchSourceFacts

    var wrappedValue: WatchPipelineInputReader {
        self
    }

    func assembly(now: Date) -> WatchPipelineAssembly {
        let sessionReadiness = watchSessionReadiness(
            isSupported: self.watchLink.isSupported,
            activationState: self.watchLink.activationState,
            activationFailed: self.watchLink.activationFailed
        ) {
            watchActivatedReadiness(
                isPaired: self.watchLink.isPaired,
                isWatchAppInstalled: self.watchLink.isWatchAppInstalled,
                facts: self.watchSourceFacts.snapshot
            )
        }

        let iphoneEnvironment = WatchDiagnosticsIPhoneEnvironment.current()
        let input = WatchPipelineInput(
            now: now,
            watchStatus: self.watchLink.watchStatus,
            lifetimeReceived: self.watchSegmentLedger.lifetimeReceived,
            lifetimeHanded: self.watchSegmentLedger.lifetimeHanded,
            nonTerminalCount: self.watchSegmentLedger.nonTerminalCount,
            lastHandedAt: self.watchSegmentLedger.lastHandedAt,
            oldestNonTerminalReceivedAt: self.watchSegmentLedger.oldestNonTerminalReceivedAt,
            lastLedgerError: self.watchSegmentLedger.lastLedgerError,
            pendingCount: self.watchUploaderHolder.pendingCount,
            failedCount: self.watchUploaderHolder.failedCount,
            inFlightCount: self.watchUploaderHolder.inFlightCount,
            lastUploadAt: self.watchUploaderHolder.lastUploadAt,
            lastUploadError: self.watchUploaderHolder.lastError,
            lastReceivedAt: self.receiver?.lastReceivedAt,
            lastStagingError: self.receiver?.lastStagingError,
            isPaired: self.watchLink.isPaired,
            isWatchAppInstalled: self.watchLink.isWatchAppInstalled,
            activationState: self.watchLink.activationState,
            isReachable: self.watchLink.isReachable,
            isJournalReachable: isJournalReachable(self.connectionSyncModel.status),
            watchDiagnostics: self.watchLink.watchDiagnosticsEnvelopeResult,
            iphoneAppMarketingVersion: iphoneEnvironment.appMarketingVersion,
            iphoneAppBuild: iphoneEnvironment.appBuild,
            iOSVersion: iphoneEnvironment.iOSVersion,
            iphoneBatteryLevel: iphoneEnvironment.batteryLevel,
            iphoneBatteryState: iphoneEnvironment.batteryState,
            iphoneLowPowerModeEnabled: iphoneEnvironment.lowPowerModeEnabled,
            iphoneThermalState: iphoneEnvironment.thermalState,
            phoneLedgerSnapshot: self.watchSegmentLedger.readSnapshot(asOf: now),
            iphoneACKQueueSnapshot: self.watchLink.iPhoneACKQueueSnapshot
        )

        return WatchPipelineAssembly(
            input: input,
            session: sessionReadiness,
            recordingStatus: watchRecordingStatus(
                context: input.watchStatus,
                now: input.now,
                lastReceivedAt: input.lastReceivedAt
            ),
            waiting: WatchPipelineReducer.waitingBreakdown(input)
        )
    }
    // KILL-LIST-EXEMPT:END
}

@MainActor
private struct WatchDiagnosticsIPhoneEnvironment {
    let appMarketingVersion: DiagnosticAvailability<String>
    let appBuild: DiagnosticAvailability<String>
    let iOSVersion: DiagnosticAvailability<String>
    let batteryLevel: DiagnosticAvailability<Double>
    let batteryState: DiagnosticAvailability<String>
    let lowPowerModeEnabled: DiagnosticAvailability<Bool>
    let thermalState: DiagnosticAvailability<String>

    static func current() -> Self {
        let device = UIDevice.current
        let previousBatteryMonitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        let batteryLevel = device.batteryLevel >= 0
            ? DiagnosticAvailability<Double>.available(Double(device.batteryLevel))
            : DiagnosticAvailability<Double>.unavailable(reason: "not provided")
        let batteryState = DiagnosticAvailability<String>.available(Self.batteryStateString(device.batteryState))
        device.isBatteryMonitoringEnabled = previousBatteryMonitoring

        return Self(
            appMarketingVersion: Self.bundleString("CFBundleShortVersionString"),
            appBuild: Self.bundleString("CFBundleVersion"),
            iOSVersion: .available(device.systemVersion),
            batteryLevel: batteryLevel,
            batteryState: batteryState,
            lowPowerModeEnabled: .available(ProcessInfo.processInfo.isLowPowerModeEnabled),
            thermalState: .available(Self.thermalStateString(ProcessInfo.processInfo.thermalState))
        )
    }

    private static func bundleString(_ key: String) -> DiagnosticAvailability<String> {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty
        else {
            return .unavailable(reason: "not provided")
        }
        return .available(value)
    }

    private static func batteryStateString(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unknown:
            "unknown"
        case .unplugged:
            "unplugged"
        case .charging:
            "charging"
        case .full:
            "full"
        @unknown default:
            "unknown"
        }
    }

    private static func thermalStateString(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            "nominal"
        case .fair:
            "fair"
        case .serious:
            "serious"
        case .critical:
            "critical"
        @unknown default:
            "unknown"
        }
    }
}
#endif
