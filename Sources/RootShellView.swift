// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import os

private let mainTabLog = Logger(subsystem: "app.solstone.swift", category: "ui")

struct RootShellView: View {
    let localPort: Int
    let via: ConnectionEndpoint
    @Environment(AppConfig.self) private var appConfig
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(ConnectionSyncModel.self) private var connectionSyncModel
    @Environment(ObserverManager.self) private var observerManager
    @Environment(LocationManager.self) private var locationManager
    @Environment(ScreencastManager.self) private var screencastManager
    @Environment(PendingNotificationRouteState.self) private var pendingRoute
    @State private var showingSources = false
    @State private var showingYourSolstone = false
    @State private var showingJournal = false
    @State private var navigateToDiagnostics = false
    @State private var connectedSince = Date()
    @State private var observerSourcePauseState = ObserverSourcePauseState()

    init(
        localPort: Int,
        via: ConnectionEndpoint
    ) {
        self.localPort = localPort
        self.via = via
    }

    var body: some View {
        NavigationStack {
            DayHomeView(
                journalState: self.dayHomeJournalState,
                onOpenJournal: {
                    self.showingJournal = true
                },
                onOpenSources: {
                    self.showingSources = true
                },
                onOpenYourSolstone: {
                    self.navigateToDiagnostics = false
                    self.showingYourSolstone = true
                },
                sourcesBadgeVisible: self.sourcesBadgeVisible
            )
        }
        .environment(self.observerSourcePauseState)
        .sheet(isPresented: self.$showingJournal) {
            InAppJournalView()
        }
        .sheet(isPresented: self.$showingSources) {
            SourcesView()
                .environment(self.observerSourcePauseState)
        }
        .sheet(isPresented: self.$showingYourSolstone, onDismiss: {
            self.navigateToDiagnostics = false
        }) {
            NavigationStack {
                MoreView(
                    localPort: self.localPort,
                    via: self.via,
                    connectedSince: self.connectedSince,
                    navigateToDiagnostics: self.$navigateToDiagnostics
                )
            }
        }
        .onAppear {
            if let route = self.pendingRoute.route {
                self.apply(route)
            }
            if !self.tunnelManager.state.isConnected {
                mainTabLog.info("showing disconnected shell state")
            }
        }
        .onChange(of: self.tunnelManager.state.isConnected) { wasConnected, isConnected in
            if !wasConnected && isConnected {
                self.connectedSince = Date()
                if let route = self.pendingRoute.route {
                    self.apply(route)
                }
            } else if !isConnected {
                mainTabLog.info("showing disconnected shell state")
            }
        }
        .onChange(of: self.pendingRoute.route) { _, route in
            if let route {
                self.apply(route)
            }
        }
    }

    private var sourcesBadgeVisible: Bool {
        [
            sourceState(for: self.observerManager.state, paused: self.observerSourcePauseState.isPaused),
            self.locationManager.sourceState,
            screencastSourceState(for: self.screencastManager.state),
        ].contains(where: \.showsSourcesBadge)
    }

    // Inline switch is pinned by ConnectionSyncGrepTests /
    // IntegrationGateG4G5ConnectionSyncTests. Do not replace with
    // dayHomeJournalState(isPaired:status:).
    private var dayHomeJournalState: DayHomeJournalState {
        if !self.appConfig.isPaired {
            return .noJournal
        }
        switch self.connectionSyncModel.status {
        case .connectedIdle, .connectedWaiting, .connectedTransferring:
            return .linkedOnline
        case .offline, .connecting, .waitingForHome, .reconnecting, .unreachable:
            return .linkedOffline
        }
    }

    private func apply(_: NotificationRoute) {
        self.showingSources = false
        self.showingYourSolstone = false
        self.navigateToDiagnostics = false
        self.pendingRoute.route = nil
    }
}

private extension SourceState {
    var showsSourcesBadge: Bool {
        switch self {
        case .enrolling, .active, .needsAttention:
            true
        case .off, .readyToSetUp, .checking, .paused:
            false
        }
    }
}
