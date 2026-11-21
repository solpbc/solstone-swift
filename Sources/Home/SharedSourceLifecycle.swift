// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

/// Observes source configuration across all destinations, including hidden home tiles.
struct SharedSourceLifecycle: ViewModifier {
    @Environment(AppConfig.self) private var config
    @Environment(TunnelManager.self) private var tunnel
    @Environment(ObserverManager.self) private var audio
    @Environment(ObserverSourcePauseState.self) private var pause
    @Environment(LocationManager.self) private var location
    @Environment(ScreencastManager.self) private var screen
    @Environment(CalendarSourceHandle.self) private var calendar
    @Environment(ObsidianSourceHandle.self) private var obsidian
    @Environment(ObsidianTransferHolder.self) private var transfer
    @Environment(ScreenshotsSourceHandle.self) private var screenshots
    @Environment(SafariSourceModel.self) private var safari: SafariSourceModel?
    @Environment(WatchLink.self) private var watchLink
    @WatchPipelineInputReader private var watch
    @Environment(\.scenePhase) private var phase

    private struct Inputs: Equatable {
        var identity: SharedSources.Identity?
        var link: SharedSources.Connection?
        var declarations: [SourceDeclaration] = []
    }

    private var inputs: Inputs {
        guard config.isPaired, config.journalSendConfirmed,
              let identity = config.sharedSources.currentIdentity else { return Inputs() }
        let connection = tunnel.activeConnection.map {
            SharedSources.Connection(identity: identity, port: $0.port, epoch: $0.epoch)
        }
        guard connection != nil else { return Inputs(identity: identity) }
        let bundle = makeHomeSourceBundle(isJournalPaired: true, observerManager: audio,
            observerSourcePauseState: pause, locationManager: location, screencastManager: screen,
            watchLane: watchLink.isPaired ? watch.assembly(now: Date()).lane : .noWatchPaired)
        var sources = [makeCalendarSource(calendar.source, isJournalPaired: true), makeScreenshotsSource(screenshots.source)]
        if audio.isEnrolled || bundle.audio.state == .active { sources.append(bundle.audio) }
        if location.isEnabled || bundle.location.state == .active { sources.append(bundle.location) }
        if screen.isEnrolled || bundle.screencast.state == .active { sources.append(bundle.screencast) }
        if let watch = bundle.watch { sources.append(watch) }
        if let safari, let snapshot = safari.snapshot {
            sources.append(safariSourceModel(snapshot: snapshot, extensionOn: safari.extensionOn, isJournalPaired: true))
        }
        var declarations = sources.compactMap { SourceDeclaration($0) }
        let vault = obsidian.source.status
        if vault.isEnabled, vault.selectedVaultID != nil, !vault.isEnrolling, !vault.isScanning,
           !transfer.choosingVault,
           let entry = SourceDeclaration(makeObsidianSource(obsidian.source, isJournalPaired: true), detail: vault.vaultName) {
            declarations.append(entry)
        }
        return Inputs(identity: identity, link: connection, declarations: declarations)
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: inputs, initial: true) { _, inputs in
                config.sharedSources.update(identity: inputs.identity, connection: inputs.link, declarations: inputs.declarations)
            }
            .onChange(of: phase) { _, phase in
                if phase == .active { config.sharedSources.refresh(detail: false) }
            }
    }
}
