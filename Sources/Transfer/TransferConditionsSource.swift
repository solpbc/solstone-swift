// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

nonisolated private final class TransferConditionsBox: @unchecked Sendable {
    private struct State: Sendable {
        var pathStatus: NetworkPathStatus?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func setPathStatus(_ status: NetworkPathStatus) {
        self.state.withLock { $0.pathStatus = status }
    }

    func pathStatus() -> NetworkPathStatus? {
        self.state.withLock { $0.pathStatus }
    }
}

nonisolated private struct LiveTransferConditionsProvider: TransferConditionsProviding {
    private let box: TransferConditionsBox

    init(box: TransferConditionsBox) {
        self.box = box
    }

    func current() -> TransferDispatchConditions {
        let processInfo = ProcessInfo.processInfo
        let pathStatus = self.box.pathStatus()
        return TransferDispatchConditions(
            thermalState: processInfo.thermalState,
            lowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            isExpensive: pathStatus?.isExpensive ?? false,
            isConstrained: pathStatus?.isConstrained ?? false
        )
    }
}

@MainActor
final class TransferConditionsSource {
    private let box = TransferConditionsBox()
    private let pathMonitor: PathMonitor
    private var thermalObserver: NSObjectProtocol?
    private var powerObserver: NSObjectProtocol?
    private var started = false

    init(pathMonitor: PathMonitor = PathMonitor()) {
        self.pathMonitor = pathMonitor
    }

    var provider: any TransferConditionsProviding {
        LiveTransferConditionsProvider(box: self.box)
    }

    func start(onChange: @escaping @MainActor @Sendable () -> Void) {
        self.stop()
        self.started = true
        _ = ProcessInfo.processInfo.thermalState

        self.pathMonitor.start { [weak self, box] status in
            box.setPathStatus(status)
            Task { @MainActor in
                guard let self, self.started else { return }
                onChange()
            }
        }

        self.thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: ProcessInfo.processInfo,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.started else { return }
                onChange()
            }
        }

        self.powerObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: ProcessInfo.processInfo,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.started else { return }
                onChange()
            }
        }
    }

    func stop() {
        self.started = false
        self.pathMonitor.stop()
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
            self.thermalObserver = nil
        }
        if let powerObserver {
            NotificationCenter.default.removeObserver(powerObserver)
            self.powerObserver = nil
        }
    }
}
