// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import UIKit

@MainActor
final class ObserverBackgroundTunnelCoordinator {
    private let tunnelManager: TunnelManager
    private let transferEndpointResolver: LoopbackTransferEndpointResolver
    private let transferEngine: TransferEngine
    private let bootstrapTransferAction: () async -> Void
    private let onTunnelConnected: (Int) async -> Void
    private let onTunnelRevoked: () -> Void
    private let onTunnelClearPairingRefused: () -> Void
    private let isPaired: () -> Bool
    private let allowsActivity: () -> Bool
    private let isObserverSustaining: () -> Bool
    private let isAnyBackgroundSustaining: () -> Bool
    private let totals: () -> (failed: Int, pending: Int)
    private let inFlight: () -> Int
    private let backoff: () -> TransferBackoffStatus
    private let driveDrain: () async -> Void
    private let fallbackScenePhase: @MainActor () -> TunnelScenePhase
    private let makeAsserter: @MainActor () -> any BackgroundTaskAsserting
    private let clock: any ObserverClock
    private let settleInterval: Duration
    private let isIntegrationMode: Bool
    private let isUITest: Bool

    private var bootstrapTask: Task<Void, Never>?
    private var didCompleteBootstrap = false
    private(set) var backgroundDrainTask: Task<Void, Never>?
    private(set) var sustainStartTask: Task<Void, Never>?
    private var tunnelStateSyncTask: Task<Void, Never>?

    init(
        tunnelManager: TunnelManager,
        transferEndpointResolver: LoopbackTransferEndpointResolver,
        transferEngine: TransferEngine,
        bootstrapTransferAction: @escaping () async -> Void,
        onTunnelConnected: @escaping (Int) async -> Void = { _ in },
        onTunnelRevoked: @escaping () -> Void = {},
        onTunnelClearPairingRefused: @escaping () -> Void = {},
        isPaired: @escaping () -> Bool,
        allowsActivity: @escaping () -> Bool = { true },
        isObserverSustaining: @escaping () -> Bool,
        isAnyBackgroundSustaining: @escaping () -> Bool,
        totals: @escaping () -> (failed: Int, pending: Int),
        inFlight: @escaping () -> Int,
        backoff: @escaping () -> TransferBackoffStatus,
        driveDrain: @escaping () async -> Void,
        fallbackScenePhase: @escaping @MainActor () -> TunnelScenePhase = { ObserverBackgroundTunnelCoordinator.applicationScenePhase() },
        makeAsserter: @escaping @MainActor () -> any BackgroundTaskAsserting = { UIBackgroundTaskAsserter() },
        clock: any ObserverClock = SystemObserverClock(),
        settleInterval: Duration = .seconds(2),
        isIntegrationMode: Bool = false,
        isUITest: Bool = false
    ) {
        self.tunnelManager = tunnelManager
        self.transferEndpointResolver = transferEndpointResolver
        self.transferEngine = transferEngine
        self.bootstrapTransferAction = bootstrapTransferAction
        self.onTunnelConnected = onTunnelConnected
        self.onTunnelRevoked = onTunnelRevoked
        self.onTunnelClearPairingRefused = onTunnelClearPairingRefused
        self.isPaired = isPaired
        self.allowsActivity = allowsActivity
        self.isObserverSustaining = isObserverSustaining
        self.isAnyBackgroundSustaining = isAnyBackgroundSustaining
        self.totals = totals
        self.inFlight = inFlight
        self.backoff = backoff
        self.driveDrain = driveDrain
        self.fallbackScenePhase = fallbackScenePhase
        self.makeAsserter = makeAsserter
        self.clock = clock
        self.settleInterval = settleInterval
        self.isIntegrationMode = isIntegrationMode
        self.isUITest = isUITest
    }

    static func applicationScenePhase() -> TunnelScenePhase {
        switch UIApplication.shared.applicationState {
        case .active:
            return .active
        case .inactive:
            return .inactive
        case .background:
            return .background
        @unknown default:
            return .inactive
        }
    }

    func install(on observerManager: ObserverManager) {
        self.tunnelManager.isBackgroundSustained = { [weak self] in
            self?.isAnyBackgroundSustaining() ?? false
        }
        self.tunnelManager.onStateChanged = { [weak self] newState in
            self?.handleTunnelStateChanged(newState)
        }
        observerManager.onSustainingBackgroundChanged = { [weak self] isSustaining in
            self?.handleObserverSustainingChanged(isSustaining)
        }
    }

    func bootstrapTransferIfNeeded() async {
        if self.didCompleteBootstrap {
            return
        }
        if let existing = self.bootstrapTask {
            await existing.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.bootstrapTransferAction()
            self.didCompleteBootstrap = true
        }
        self.bootstrapTask = task
        await task.value
    }

    func cancelBackgroundDrain() {
        self.backgroundDrainTask?.cancel()
        self.backgroundDrainTask = nil
    }

    func startBackgroundDrain() {
        guard !self.isIntegrationMode, !self.isUITest else { return }
        self.backgroundDrainTask?.cancel()
        let coordinator = BackgroundDrainCoordinator(
            totals: self.totals,
            inFlight: self.inFlight,
            backoff: self.backoff,
            isSustaining: self.isAnyBackgroundSustaining,
            isConnected: { [weak self] in
                self?.tunnelManager.state.isConnected ?? false
            },
            drive: { [weak self] in
                guard let self else { return }
                await self.bootstrapTransferIfNeeded()
                await self.driveDrain()
            },
            disconnect: { [weak self] in
                await self?.disconnectTunnelNow()
            },
            asserter: self.makeAsserter(),
            clock: self.clock,
            settleInterval: self.settleInterval
        )
        self.backgroundDrainTask = Task { @MainActor in
            await coordinator.run()
        }
    }

    func handleTunnelStateChanged(_ newState: TunnelState) {
        if case .error(.revoked) = newState {
            self.onTunnelRevoked()
        }
        let previous = self.tunnelStateSyncTask
        switch newState {
        case .connected(let port, _):
            let connection = self.tunnelManager.activeConnection
            let effectivePort = connection?.port ?? port
            let effectiveEpoch = connection?.epoch ?? self.tunnelManager.connectionEpoch
            let pairingIdentity = self.tunnelManager.dialedPairingIdentity
            self.onTunnelClearPairingRefused()
            self.tunnelStateSyncTask = Task { @MainActor [weak self] in
                await previous?.value
                guard let self, self.tunnelManager.state.isConnected else { return }
                await self.transferEndpointResolver.update(
                    activeLocalPort: effectivePort,
                    connectionEpoch: effectiveEpoch
                )
                await self.transferEngine.noteNewConnectionEstablished(pairingIdentity: pairingIdentity)
                await self.transferEngine.endpointAvailabilityChanged()
                await self.onTunnelConnected(effectivePort)
            }
        case .connecting, .waitingForHome, .disconnected, .error:
            self.tunnelStateSyncTask = Task { @MainActor [weak self] in
                await previous?.value
                guard let self, !self.tunnelManager.state.isConnected else { return }
                await self.transferEndpointResolver.update(activeLocalPort: nil, connectionEpoch: nil)
                await self.transferEngine.endpointAvailabilityChanged()
            }
        }
    }

    func handleObserverSustainingChanged(_ isSustaining: Bool) {
        if isSustaining {
            self.cancelBackgroundDrain()
            guard !self.isIntegrationMode, !self.isUITest else { return }
            let phase = self.effectiveScenePhase()
            guard phase != .active else { return }
            guard self.allowsActivity(), self.isPaired() else { return }

            self.sustainStartTask?.cancel()
            self.sustainStartTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.bootstrapTransferIfNeeded()
                guard !Task.isCancelled,
                      self.isObserverSustaining(),
                      !self.isIntegrationMode,
                      !self.isUITest,
                      self.effectiveScenePhase() != .active,
                      self.allowsActivity(),
                      self.isPaired()
                else { return }

                if let connection = self.tunnelManager.activeConnection {
                    let pairingIdentity = self.tunnelManager.dialedPairingIdentity
                    await self.transferEndpointResolver.update(
                        activeLocalPort: connection.port,
                        connectionEpoch: connection.epoch
                    )
                    await self.transferEngine.noteNewConnectionEstablished(pairingIdentity: pairingIdentity)
                    await self.transferEngine.endpointAvailabilityChanged()
                }

                switch self.tunnelManager.state {
                case .disconnected:
                    self.startNetworkMonitoringIfNeeded()
                    await self.tunnelManager.retryNow()
                case .error(let error):
                    guard error.isRetryable else { return }
                    self.startNetworkMonitoringIfNeeded()
                    await self.tunnelManager.retryNow()
                case .waitingForHome:
                    self.startNetworkMonitoringIfNeeded()
                    await self.tunnelManager.retryNow()
                case .connecting:
                    self.startNetworkMonitoringIfNeeded()
                case .connected(let port, _):
                    self.startNetworkMonitoringIfNeeded()
                    await self.onTunnelConnected(self.tunnelManager.activeConnection?.port ?? port)
                }
            }
        } else {
            self.sustainStartTask?.cancel()
            self.sustainStartTask = nil
            guard !self.isIntegrationMode, !self.isUITest else { return }
            guard self.effectiveScenePhase() == .background else { return }
            self.startBackgroundDrain()
        }
    }

    private func effectiveScenePhase() -> TunnelScenePhase {
        if self.tunnelManager.hasReceivedScenePhase {
            return self.tunnelManager.scenePhase
        }
        let fallback = self.fallbackScenePhase()
        if fallback == .background {
            self.tunnelManager.receiveScenePhase(.background)
        }
        return fallback
    }

    private func startNetworkMonitoringIfNeeded() {
        if !self.tunnelManager.isNetworkMonitoring {
            self.tunnelManager.startNetworkMonitoring()
        }
    }

    private func disconnectTunnelNow() async {
        self.tunnelManager.cancelConnect()
        self.tunnelManager.cancelReconnect()
        self.tunnelManager.stopNetworkMonitoring()
        await self.tunnelManager.disconnect()
    }
}
