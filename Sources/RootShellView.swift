// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import os

private let mainTabLog = Logger(subsystem: "app.solstone.swift", category: "ui")
private let routerLog = Logger(subsystem: "app.solstone.swift", category: "router")

struct RootShellView: View {
    let localPort: Int
    let via: ConnectionEndpoint
    let presentSourcesOnFirstAppear: Bool
    @Environment(AppConfig.self) private var appConfig
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(VoiceManager.self) private var voiceManager
    @Environment(ObserverManager.self) private var observerManager
    @Environment(LocationManager.self) private var locationManager
    @Environment(PendingNotificationRouteState.self) private var pendingRoute
    @Environment(PendingFoldState.self) private var pendingFold
    @Environment(\.openURL) private var openURL
    @State private var showingSources = false
    @State private var showingYourSolstone = false
    @State private var showingChat = false
    @State private var navigateToDiagnostics = false
    @State private var didPresentFirstSources = false
    @State private var connectedSince = Date()
    @State private var observerSourcePauseState = ObserverSourcePauseState()

    init(
        localPort: Int,
        via: ConnectionEndpoint,
        presentSourcesOnFirstAppear: Bool
    ) {
        self.localPort = localPort
        self.via = via
        self.presentSourcesOnFirstAppear = presentSourcesOnFirstAppear
    }

    var body: some View {
        NavigationStack {
            DayHomeView(
                journalState: self.dayHomeJournalState,
                onTurnOnSource: {
                    self.showingSources = true
                },
                onOpenJournal: {
                    self.openInJournal()
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
            if self.presentSourcesOnFirstAppear && !self.didPresentFirstSources {
                self.didPresentFirstSources = true
                self.showingSources = true
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
            self.locationManager.sourceState
        ].contains(where: \.showsSourcesBadge)
    }

    private var foldBadgeVisible: Bool {
        self.pendingFold.useID != nil
    }

    private var dayHomeJournalState: DayHomeJournalState {
        if !self.appConfig.isPaired {
            return .noJournal
        }
        if self.tunnelManager.state.isConnected {
            return .linkedOnline
        }
        return .linkedOffline
    }

    private func apply(_ route: NotificationRoute) {
        switch route {
        case .today:
            self.showingSources = false
            self.showingYourSolstone = false
            self.navigateToDiagnostics = false
            self.pendingRoute.route = nil
        case .solChatRequest:
            self.showingSources = false
            self.showingYourSolstone = false
            self.navigateToDiagnostics = false
            if self.dayHomeJournalState == .linkedOnline {
                self.presentChat()
                self.pendingRoute.route = nil
            }
        case .solChatFold(let useID):
            self.pendingFold.markPending(useID)
            self.showingSources = false
            self.showingYourSolstone = false
            self.navigateToDiagnostics = false
            if self.dayHomeJournalState == .linkedOnline {
                self.presentChat()
                self.pendingRoute.route = nil
            }
        }
    }

    private func presentChat() {
        routerLog.info("chat presented")
        self.showingChat = true
    }

    private func openInJournal() {
        if let url = ConveyURL.rootURL(activeLocalPort: self.localPort) {
            self.openURL(url)
        }
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
