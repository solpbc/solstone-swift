// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import os

private let mainTabLog = Logger(subsystem: "app.solstone.swift", category: "ui")
private let routerLog = Logger(subsystem: "app.solstone.swift", category: "router")

struct RootShellView: View {
    let localPort: Int
    let via: ConnectionEndpoint
    @Environment(AppConfig.self) private var appConfig
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(ConnectionSyncModel.self) private var connectionSyncModel
    @Environment(VoiceManager.self) private var voiceManager
    @Environment(ObserverManager.self) private var observerManager
    @Environment(LocationManager.self) private var locationManager
    @Environment(ScreencastManager.self) private var screencastManager
    @Environment(PendingNotificationRouteState.self) private var pendingRoute
    @Environment(PendingFoldState.self) private var pendingFold
    @State private var showingSources = false
    @State private var showingYourSolstone = false
    @State private var showingChat = false
    @State private var showingJournal = false
    @State private var navigateToDiagnostics = false
    @State private var connectedSince = Date()
    @State private var observerSourcePauseState = ObserverSourcePauseState()
    @State private var appliedOfflineRoute: NotificationRoute?

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
                onTurnOnSource: {
                    self.showingSources = true
                },
                onOpenJournal: {
                    self.showingJournal = true
                },
                onPresentChat: {
                    self.presentChat()
                },
                onOpenSources: {
                    self.showingSources = true
                },
                onOpenYourSolstone: {
                    self.navigateToDiagnostics = false
                    self.showingYourSolstone = true
                },
                sourcesBadgeVisible: self.sourcesBadgeVisible,
                foldBadgeVisible: self.foldBadgeVisible
            )
        }
        .overlay(alignment: .top) {
            VoiceHUDOverlay(voiceManager: self.voiceManager)
                .allowsHitTesting(true)
        }
        .sheet(isPresented: self.$showingChat) {
            ChatView()
        }
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
        .onChange(of: self.pendingRoute.route) { oldRoute, route in
            if oldRoute != route {
                self.appliedOfflineRoute = nil
            }
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

    private var foldBadgeVisible: Bool {
        self.pendingFold.useID != nil
    }

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

    private func apply(_ route: NotificationRoute) {
        let action = NotificationRoute.decidePendingRoute(
            route,
            online: self.dayHomeJournalState == .linkedOnline,
            alreadyAppliedOffline: self.appliedOfflineRoute == route
        )

        switch action {
        case .present:
            if case .solChatFold(let useID) = route {
                self.pendingFold.markPending(useID)
            }
            self.showingSources = false
            self.showingYourSolstone = false
            self.navigateToDiagnostics = false
            self.presentChat()
            self.pendingRoute.route = nil
            self.appliedOfflineRoute = nil
        case .dismissOnly:
            if case .solChatFold(let useID) = route {
                self.pendingFold.markPending(useID)
            }
            self.showingSources = false
            self.showingYourSolstone = false
            self.navigateToDiagnostics = false
            self.appliedOfflineRoute = route
        case .ignore:
            break
        case .clear:
            self.showingSources = false
            self.showingYourSolstone = false
            self.navigateToDiagnostics = false
            self.pendingRoute.route = nil
            self.appliedOfflineRoute = nil
        }
    }

    private func presentChat() {
        routerLog.info("chat presented")
        self.showingChat = true
    }
}

private extension SourceState {
    var showsSourcesBadge: Bool {
        switch self {
        case .enrolling, .active, .needsAttention:
            true
        case .off, .paused:
            false
        }
    }
}
