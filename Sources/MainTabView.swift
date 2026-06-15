// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UIKit
import os

private let mainTabLog = Logger(subsystem: "app.solstone.swift", category: "ui")

struct MainTabView: View {
    let localPort: Int
    let via: ConnectionEndpoint
    let onOpenSettings: () -> Void
    @Environment(AppConfig.self) private var appConfig
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(BannerPresenter.self) private var bannerPresenter
    @Environment(PortalPage.self) private var portalPage
    @Environment(VoiceManager.self) private var voiceManager
    @Environment(ObserverManager.self) private var observerManager
    @Environment(LocationManager.self) private var locationManager
    @Environment(PendingNotificationRouteState.self) private var pendingRoute
    @State private var selectedTab: AppTab
    @State private var lastPortalTab = AppTab.today
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
        case today, ask, sense, more

        var route: String {
            switch self {
            case .today: "today"
            case .ask: "ask"
            case .sense, .more: ""
            }
        }

        var iconName: String {
            switch self {
            case .today: "sun.max"
            case .ask: "bubble.left.and.questionmark"
            case .sense: "square.stack.3d.up"
            case .more: "ellipsis.circle"
            }
        }

        var label: String {
            switch self {
            case .today: "today"
            case .ask: "ask"
            case .sense: "sense"
            case .more: "more"
            }
        }

        var shortcutKey: Character {
            switch self {
            case .today: "1"
            case .ask: "2"
            case .sense: "3"
            case .more: "4"
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
            self.portalTab(for: .today)
                .tag(AppTab.today)
                .tabItem {
                    Label(AppTab.today.label, systemImage: AppTab.today.iconName)
                }
                .keyboardShortcut(KeyEquivalent(AppTab.today.shortcutKey), modifiers: .command)

            self.portalTab(for: .ask)
                .tag(AppTab.ask)
                .tabItem {
                    Label(AppTab.ask.label, systemImage: AppTab.ask.iconName)
                }
                .keyboardShortcut(KeyEquivalent(AppTab.ask.shortcutKey), modifiers: .command)

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
            if self.selectedTab == .today && self.tunnelManager.state.isConnected {
                DayZeroOverlayView(
                    localPort: self.localPort,
                    onBrowseJournal: {
                        self.selectedTab = .today
                        self.portalPage.navigate(to: AppTab.today.route)
                    }
                )
            }
        }
        .overlay(alignment: .top) {
            VoiceHUDOverlay(voiceManager: self.voiceManager)
                .allowsHitTesting(true)
        }
        .onAppear {
            self.loadPortalIfReady()
            self.handleTabSelection(self.selectedTab)
            if let route = self.pendingRoute.route {
                self.apply(route)
            }
            if !self.tunnelManager.state.isConnected {
                mainTabLog.info("showing disconnected shell state")
            }
        }
        .onChange(of: self.localPort) { _, port in
            self.loadPortalIfReady(port: port)
        }
        .onChange(of: self.selectedTab) { _, tab in
            self.handleTabSelection(tab)
        }
        .onChange(of: self.tunnelManager.state.isConnected) { wasConnected, isConnected in
            if !wasConnected && isConnected {
                self.connectedSince = Date()
                self.loadPortalIfReady()
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
        .onChange(of: self.portalPage.currentRoute) { _, route in
            self.handlePortalRoute(route)
        }
        .onChange(of: self.pendingRoute.route) { _, route in
            if let route {
                self.apply(route)
            }
        }
    }

    @ViewBuilder
    private func portalTab(for tab: AppTab) -> some View {
        if !self.appConfig.isPaired {
            if tab == .ask {
                AskNoJournalPlaceholderContainer()
            } else {
                NavigationStack {
                    OnThisPhoneView(onTurnOnSource: { self.selectedTab = .sense })
                }
            }
        } else if !self.tunnelManager.state.isConnected {
            PortalWarmCardView()
        } else {
            ZStack {
                PortalWebView(portalPage: self.portalPage)
                    .ignoresSafeArea(edges: .top)

                if !self.portalPage.isReady {
                    self.loadingOverlay
                }
            }
        }
    }

    @ViewBuilder
    private var loadingOverlay: some View {
        ZStack {
            Image("SolRing")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 40, height: 40)
                .opacity(0.3)
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .accessibilityLabel("loading portal")
    }

    private var sourcesBadgeVisible: Bool {
        [
            sourceState(for: self.observerManager.state, paused: self.observerSourcePauseState.isPaused),
            self.locationManager.sourceState
        ].contains(where: \.showsSourcesBadge)
    }

    private func tabForRoute(_ route: String, currentPortalTab: AppTab) -> AppTab {
        if route.hasPrefix("today") { return .today }
        if route.hasPrefix("ask") { return .ask }
        if route.hasPrefix("entity/") { return currentPortalTab }
        return .today
    }

    private func handleTabSelection(_ tab: AppTab) {
        guard self.appConfig.isPaired, self.tunnelManager.state.isConnected else { return }
        switch tab {
        case .today, .ask:
            self.lastPortalTab = tab
            if !self.portalPage.currentRoute.hasPrefix(tab.route) {
                self.portalPage.navigate(to: tab.route)
            }
        case .sense, .more:
            break
        }
    }

    private func handlePortalRoute(_ route: String) {
        let matchedTab = self.tabForRoute(route, currentPortalTab: self.lastPortalTab)
        if matchedTab == .today || matchedTab == .ask {
            self.lastPortalTab = matchedTab
        }
        switch self.selectedTab {
        case .today, .ask:
            if matchedTab != self.selectedTab {
                self.selectedTab = matchedTab
            }
        case .sense, .more:
            break
        }
    }

    private func apply(_ route: NotificationRoute) {
        guard self.appConfig.isPaired, self.tunnelManager.state.isConnected else { return }
        self.selectedTab = .today
        self.lastPortalTab = .today
        self.portalPage.navigate(to: route.portalHash)
        self.pendingRoute.route = nil
    }

    private func loadPortalIfReady(port: Int? = nil) {
        guard self.appConfig.isPaired, self.tunnelManager.state.isConnected else { return }
        self.portalPage.load(port: port ?? self.localPort)
    }
}

private struct PortalWarmCardView: View {
    @Environment(TunnelManager.self) private var tunnelManager
    @State private var showingDetails = false

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text("your journal's connected — waiting for a network")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("portal.warmCard")
                Text("safe on this phone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button {
                self.showingDetails = true
            } label: {
                HStack(spacing: 4) {
                    Text("details")
                        .font(.footnote)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("connection details")
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .sheet(isPresented: self.$showingDetails) {
            NavigationStack {
                ConnectingView(
                    state: self.tunnelManager.state,
                    onRetry: {
                        Task {
                            await self.tunnelManager.retryNow()
                        }
                    },
                    reconnectCountdown: self.tunnelManager.reconnectCountdown,
                    consecutiveWiFiFailures: self.tunnelManager.consecutiveWiFiFailures,
                    currentInterfaceIsWiFi: self.tunnelManager.currentInterfaceIsWiFi ?? false,
                    connectionStages: self.tunnelManager.connectionStages
                )
                .navigationTitle("details")
                .navigationBarTitleDisplayMode(.inline)
            }
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
