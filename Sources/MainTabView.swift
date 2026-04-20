// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UIKit
import os

private let log = Logger(subsystem: "org.solpbc.solstone-swift", category: "ui")

struct MainTabView: View {
    let localPort: Int
    let via: ConnectionEndpoint
    let isPlaceholderMode: Bool
    let onOpenSettings: () -> Void
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(BannerPresenter.self) private var bannerPresenter
    @Environment(PortalPage.self) private var portalPage
    @State private var selectedTab = AppTab.today
    @State private var lastPortalTab = AppTab.today
    @State private var debugVoiceState: VoiceState?
    @State private var debugBrainStatus: BrainStatus?
    @State private var debugCycleCount = 0
    @State private var navigateToDiagnostics = false
    @State private var connectedSince = Date()

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
            case .sense: "ear"
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
    private var reconnectOverlay: some View {
        if !self.tunnelManager.state.isConnected {
            ZStack {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                ConnectingView(
                    state: self.tunnelManager.state,
                    hasHostKeyMismatch: self.tunnelManager.hasHostKeyMismatch,
                    onAcceptKey: {
                        Task {
                            await self.tunnelManager.acceptNewHostKey()
                        }
                    },
                    onOpenSettings: self.onOpenSettings,
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
            self.portalTab
                .tag(AppTab.today)
                .tabItem {
                    Label(AppTab.today.label, systemImage: AppTab.today.iconName)
                }
                .keyboardShortcut(KeyEquivalent(AppTab.today.shortcutKey), modifiers: .command)

            self.portalTab
                .tag(AppTab.ask)
                .tabItem {
                    Label(AppTab.ask.label, systemImage: AppTab.ask.iconName)
                }
                .keyboardShortcut(KeyEquivalent(AppTab.ask.shortcutKey), modifiers: .command)

            NavigationStack {
                SenseView()
            }
            .tag(AppTab.sense)
            .tabItem {
                Label(AppTab.sense.label, systemImage: AppTab.sense.iconName)
            }
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
        .overlay(alignment: .bottomTrailing) {
            VoiceButton(
                stateOverride: self.debugVoiceState,
                brainStatusOverride: self.debugBrainStatus,
                onTap: self.handleWave1VoiceTap,
                onDebugLongPress: self.cycleDebugVoiceState
            )
                .padding(.trailing, 20)
                .padding(.bottom, 20)
        }
        .onAppear {
            if !self.isPlaceholderMode {
                self.portalPage.load(port: self.localPort)
                self.handleTabSelection(self.selectedTab)
            }
        }
        .onChange(of: self.localPort) { _, port in
            if !self.isPlaceholderMode {
                self.portalPage.load(port: port)
            }
        }
        .onChange(of: self.selectedTab) { _, tab in
            self.handleTabSelection(tab)
        }
        .onChange(of: self.tunnelManager.state.isConnected) { wasConnected, isConnected in
            if !wasConnected && isConnected {
                self.connectedSince = Date()
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
            if !self.isPlaceholderMode {
                self.handlePortalRoute(route)
            }
        }
    }

    @ViewBuilder
    private var portalTab: some View {
        ZStack {
            if self.isPlaceholderMode {
                Color(.systemBackground)
                    .ignoresSafeArea(edges: .top)
            } else {
                PortalWebView(portalPage: self.portalPage)
                    .ignoresSafeArea(edges: .top)
            }

            if !self.isPlaceholderMode && !self.tunnelManager.state.isConnected {
                self.reconnectOverlay
            }

            if !self.isPlaceholderMode && self.tunnelManager.state.isConnected && !self.portalPage.isReady {
                self.loadingOverlay
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

    private func tabForRoute(_ route: String, currentPortalTab: AppTab) -> AppTab {
        if route.hasPrefix("today") { return .today }
        if route.hasPrefix("ask") { return .ask }
        if route.hasPrefix("entity/") { return currentPortalTab }
        return .today
    }

    private func handleTabSelection(_ tab: AppTab) {
        if self.isPlaceholderMode {
            if tab == .today || tab == .ask {
                self.lastPortalTab = tab
            }
            return
        }
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

    private func handleWave1VoiceTap() {
        log.info("voice: tap (Wave 2)")
    }

    private func cycleDebugVoiceState() {
        let states: [VoiceState] = [
            .idle,
            .connecting,
            .listening,
            .speaking,
            .error(.connectionFailed("debug"))
        ]
        let nextIndex: Int
        if let debugVoiceState,
           let currentIndex = states.firstIndex(of: debugVoiceState)
        {
            nextIndex = (currentIndex + 1) % states.count
        } else {
            nextIndex = 0
        }
        self.debugVoiceState = states[nextIndex]
        self.debugCycleCount += 1
        self.debugBrainStatus = self.debugCycleCount.isMultiple(of: 2) ? .refreshing : nil
    }
}
