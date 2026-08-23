// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import os

private let mainTabLog = Logger(subsystem: "app.solstone.swift", category: "ui")

struct RootShellView: View {
    let via: ConnectionEndpoint
    @Environment(AppConfig.self) private var appConfig
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(ConnectionSyncModel.self) private var connectionSyncModel
    @Environment(ObserverManager.self) private var observerManager
    @Environment(ObserverRegistration.self) private var observerRegistration
    @Environment(LocationManager.self) private var locationManager
    @Environment(ScreencastManager.self) private var screencastManager
    @Environment(PendingNotificationRouteState.self) private var pendingRoute
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var homeChrome
    @State private var path = NavigationPath()
    @State private var presentedPane: PresentedShellPane?
    @State private var journalMark: JournalMark?
    @State private var statusPath = NavigationPath()
    @State private var statusDetent: PresentationDetent = .medium
    @State private var showingSources = false
    @State private var connectedSince = Date()
    @State private var observerSourcePauseState = ObserverSourcePauseState()
    @State private var crossFadePreference = AccessibilityCrossFadePreference()

    private var prefersCrossFade: Bool { self.crossFadePreference.prefersCrossFadeTransitions }

    init(
        via: ConnectionEndpoint
    ) {
        self.via = via
    }

    var body: some View {
        ZStack {
            if self.presentedPane == .shelf {
                self.homeStack
                    .accessibilityHidden(true)
                    .accessibilityChildren { EmptyView() }
            } else {
                self.homeStack
            }

            if self.presentedPane == .shelf {
                ShelfPane(presentedPane: self.$presentedPane)
                    .transition(self.prefersCrossFade ? .opacity : .move(edge: .leading))
            }
        }
        .animation(self.prefersCrossFade ? .easeInOut : .default, value: self.presentedPane)
        .containerShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .environment(self.observerSourcePauseState)
        .environment(self.crossFadePreference)
        .task {
            await self.crossFadePreference.observe()
        }
        .sheet(isPresented: self.isJournalPresented) {
            InAppJournalView(mark: self.journalMark)
                // 0.75 keeps the first deck tile row in the band above the pane on iPhone 17 Pro.
                .presentationDetents([.fraction(0.75)])
                .presentationDragIndicator(.visible)
                .containerShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .transition(self.prefersCrossFade ? .opacity : .move(edge: .bottom))
        }
        .sheet(isPresented: self.$showingSources) {
            SourcesView()
                .environment(self.observerSourcePauseState)
        }
        .sheet(isPresented: self.isStatusPresented) {
            self.statusSheet
        }
        .task(id: self.observerRegistration.activeLocalPort) {
            await self.fetchJournalMark()
        }
        .onAppear {
            if let route = self.pendingRoute.route {
                self.apply(route)
            }
            if !self.tunnelManager.state.isConnected {
                mainTabLog.info("showing disconnected shell state")
            }
            self.applyDebugSeeds()
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
        .onChange(of: self.statusPath.count) { _, count in
            self.statusDetent = count > 0 ? .large : .medium
        }
        .onChange(of: self.presentedPane) { _, pane in
            if pane != .status {
                self.statusPath = NavigationPath()
                self.statusDetent = .medium
            }
        }
    }

    private var homeStack: some View {
        NavigationStack(path: self.$path) {
            DayHomeView(
                journalState: self.dayHomeJournalState,
                journalMark: self.journalMark,
                homeChrome: self.homeChrome,
                onOpenJournal: {
                    self.presentedPane = .journal
                },
                onOpenSources: {
                    self.showingSources = true
                },
                onOpenYourSolstone: {
                    self.presentedPane = .shelf
                },
                onOpenStatus: {
                    self.presentedPane = .status
                },
                sourcesBadgeVisible: self.sourcesBadgeVisible
            )
            .navigationDestination(for: ShellDestination.self) { destination in
                ShellDestinationView(destination: destination)
            }
            .overlay(alignment: .leading) {
                if self.path.isEmpty {
                    ShelfHitStrip(onOpen: {
                        self.presentedPane = .shelf
                    })
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isJournalPresented: Binding<Bool> {
        Binding(
            get: { self.presentedPane == .journal },
            set: { if !$0, self.presentedPane == .journal { self.presentedPane = nil } }
        )
    }

    private var isStatusPresented: Binding<Bool> {
        Binding(
            get: { self.presentedPane == .status },
            set: { if !$0, self.presentedPane == .status { self.presentedPane = nil } }
        )
    }

    @ViewBuilder
    private var statusSheet: some View {
        NavigationStack(path: self.$statusPath) {
            Group {
                if self.reduceMotion || self.prefersCrossFade {
                    StatusPane(via: self.via, connectedSince: self.connectedSince)
                } else {
                    StatusPane(via: self.via, connectedSince: self.connectedSince)
                        .navigationTransition(.zoom(sourceID: HomeChromeID.status, in: self.homeChrome))
                }
            }
            .navigationDestination(for: StatusPush.self) { push in
                switch push {
                case .diagnostics:
                    DiagnosticsView()
                case .problemReports:
                    ProblemReportsView()
                }
            }
        }
        .presentationDetents([.medium, .large], selection: self.$statusDetent)
        .presentationDragIndicator(.visible)
        .containerShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .transition(self.prefersCrossFade ? .opacity : .identity)
    }

    private func fetchJournalMark() async {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-journal-mark"),
           !ProcessInfo.processInfo.arguments.contains("--ui-test-no-journal")
        {
            return
        }
#endif
        guard let port = self.observerRegistration.activeLocalPort else {
            self.journalMark = nil
            return
        }
        self.journalMark = await JournalIdentityFetcher().fetch(localPort: port)
    }

    private func applyDebugSeeds() {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-test") else { return }
        if arguments.contains("--ui-test-journal-mark"),
           !arguments.contains("--ui-test-no-journal")
        {
            self.journalMark = .uiTestSample
        }
        if let raw = arguments.first(where: { $0.hasPrefix("--ui-test-open-pane=") }) {
            let pane = String(raw.dropFirst("--ui-test-open-pane=".count))
            switch pane {
            case "status":
                self.presentedPane = .status
            case "journal":
                self.presentedPane = .journal
            case "shelf":
                self.presentedPane = .shelf
            default:
                break
            }
        }
#endif
    }

    private var sourcesBadgeVisible: Bool {
        [
            sourceState(for: self.observerManager.state, paused: self.observerSourcePauseState.isPaused),
            self.locationManager.sourceState,
            screencastSourceState(for: self.screencastManager.state),
        ].contains(where: \.showsSourcesBadge)
    }

    // Inline switch is pinned by ConnectionSyncGrepTests:9-14 and
    // IntegrationGateG4G5ConnectionSyncTests:176-186. Do not replace with
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
        self.presentedPane = nil
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

private struct ShelfHitStrip: View {
    let onOpen: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 20)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        if value.translation.width > 40 {
                            self.onOpen()
                        }
                    }
            )
            .accessibilityHidden(true)
            .accessibilityIdentifier("shell.hitStrip")
    }
}

@Observable
final class AccessibilityCrossFadePreference {
    private(set) var prefersCrossFadeTransitions = UIAccessibility.prefersCrossFadeTransitions

    func observe() async {
        self.prefersCrossFadeTransitions = UIAccessibility.prefersCrossFadeTransitions
        let notifications = NotificationCenter.default.notifications(
            named: UIAccessibility.prefersCrossFadeTransitionsStatusDidChange
        )
        for await _ in notifications {
            self.prefersCrossFadeTransitions = UIAccessibility.prefersCrossFadeTransitions
        }
    }
}
