// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import os

private let mainTabLog = Logger(subsystem: "app.solstone.swift", category: "ui")
private let routerLog = Logger(subsystem: "app.solstone.swift", category: "router")

struct MainTabView: View {
    let localPort: Int
    let via: ConnectionEndpoint
    let onOpenSettings: () -> Void
    @Environment(AppConfig.self) private var appConfig
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(BannerPresenter.self) private var bannerPresenter
    @Environment(VoiceManager.self) private var voiceManager
    @Environment(ObserverManager.self) private var observerManager
    @Environment(LocationManager.self) private var locationManager
    @Environment(PendingNotificationRouteState.self) private var pendingRoute
    @Environment(\.openURL) private var openURL
    @State private var selectedTab: AppTab
    @State private var showingChatStub = false
    @State private var navigateToDiagnostics = false
    @State private var connectedSince = Date()
    @State private var observerSourcePauseState = ObserverSourcePauseState()

    init(
        localPort: Int,
        via: ConnectionEndpoint,
        onOpenSettings: @escaping () -> Void,
        initialTab: AppTab = .today
    ) {
        self.localPort = localPort
        self.via = via
        self.onOpenSettings = onOpenSettings
        self._selectedTab = State(initialValue: initialTab)
    }

    enum AppTab: Hashable {
        case today, sense, more

        var iconName: String {
            switch self {
            case .today: "sun.max"
            case .sense: "square.stack.3d.up"
            case .more: "ellipsis.circle"
            }
        }

        var label: String {
            switch self {
            case .today: "today"
            case .sense: "sense"
            case .more: "more"
            }
        }

        var shortcutKey: Character {
            switch self {
            case .today: "1"
            case .sense: "2"
            case .more: "3"
            }
        }
    }

    @ViewBuilder
    private var healthDot: some View {
        let health = self.tunnelManager.connectionHealth
        if health == .healthy || health == .degraded {
            Circle()
                .fill(health == .healthy ? Color.green : Color.yellow)
                .frame(width: 8, height: 8)
                .padding(.leading, 32)
                .padding(.bottom, 18)
                .accessibilityLabel("connection \(health == .healthy ? "healthy" : "degraded")")
        }
    }

    var body: some View {
        TabView(selection: self.$selectedTab) {
            NavigationStack {
                DayHomeView(
                    journalState: self.dayHomeJournalState,
                    onTurnOnSource: {
                        self.selectedTab = .sense
                    },
                    onOpenJournal: {
                        if self.dayHomeJournalState == .linkedOnline {
                            self.openInJournal()
                        }
                    },
                    onPresentChat: {
                        self.presentChatStub()
                    }
                )
            }
            .tag(AppTab.today)
            .tabItem {
                Label(AppTab.today.label, systemImage: AppTab.today.iconName)
            }
            .keyboardShortcut(KeyEquivalent(AppTab.today.shortcutKey), modifiers: .command)

            SourcesView()
                .environment(self.observerSourcePauseState)
            .tag(AppTab.sense)
            .tabItem {
                Label(AppTab.sense.label, systemImage: AppTab.sense.iconName)
            }
            .badge(self.sourcesBadgeVisible ? " " : nil)
            .keyboardShortcut(KeyEquivalent(AppTab.sense.shortcutKey), modifiers: .command)

            NavigationStack {
                MoreView(
                    localPort: self.localPort,
                    via: self.via,
                    connectedSince: self.connectedSince,
                    navigateToDiagnostics: self.$navigateToDiagnostics
                )
            }
            .tag(AppTab.more)
            .tabItem {
                Label(AppTab.more.label, systemImage: AppTab.more.iconName)
            }
            .keyboardShortcut(KeyEquivalent(AppTab.more.shortcutKey), modifiers: .command)
        }
        .tabViewStyle(.sidebarAdaptable)
        .overlay(alignment: .bottomLeading) {
            self.healthDot
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            if self.selectedTab == .today && self.dayHomeJournalState == .linkedOnline {
                DayZeroOverlayView(
                    localPort: self.localPort,
                    onBrowseJournal: {
                        self.openInJournal()
                    }
                )
            }
        }
        .overlay(alignment: .top) {
            VoiceHUDOverlay(voiceManager: self.voiceManager)
                .allowsHitTesting(true)
        }
        .sheet(isPresented: self.$showingChatStub) {
            ChatStubView()
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
        .onChange(of: self.bannerPresenter.showDiagnostics) { _, show in
            if show {
                self.selectedTab = .more
                self.navigateToDiagnostics = true
                self.bannerPresenter.showDiagnostics = false
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
            self.selectedTab = .today
        case .solChatRequest:
            self.selectedTab = .today
            if self.dayHomeJournalState == .linkedOnline {
                self.presentChatStub()
            }
        }
        self.pendingRoute.route = nil
    }

    private func presentChatStub() {
        routerLog.info("chat stub presented")
        self.showingChatStub = true
    }

    private func openInJournal() {
        guard let url = URL(string: "http://127.0.0.1:\(self.localPort)/") else { return }
        self.openURL(url)
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
