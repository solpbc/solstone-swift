// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated func makeAudioSource(
    state: SourceState,
    attention: SourceAttention?,
    isJournalPaired: Bool
) -> Source {
    Source(
        id: "audio",
        displayName: "audio",
        kind: .observer,
        state: state,
        isJournalPaired: isJournalPaired,
        activeSubtext: SourceVocabulary.observerActiveSubtext,
        attention: attention,
        pendingStatus: .nonePending
    )
}

nonisolated func makeLocationSource(
    state: SourceState,
    attention: SourceAttention?,
    isJournalPaired: Bool
) -> Source {
    Source(
        id: "location",
        displayName: LocationVocabulary.sourceDisplayName,
        kind: .location,
        state: state,
        isJournalPaired: isJournalPaired,
        activeSubtext: LocationVocabulary.activeSubtext(isJournalPaired: isJournalPaired),
        attention: attention,
        pendingStatus: .nonePending
    )
}

nonisolated func makeScreencastSource(
    managerState: ScreencastManager.State,
    isJournalPaired: Bool
) -> Source {
    screencastSourcePresentation(
        managerState: managerState,
        isJournalPaired: isJournalPaired
    )
}

nonisolated func makeOmiSource(
    now: Date,
    effectiveConnectionState: OmiSourceState,
    enabled: Bool,
    liveBattery: OmiReadState<Int>,
    lastKnownBattery: TimedReading<Int>?,
    liveRSSI: Int?,
    lastKnownSignal: TimedReading<Int>?,
    isJournalPaired: Bool
) -> Source {
    let mapped = omiSourceState(for: effectiveConnectionState, enabled: enabled)
    let battery = OmiSourceLogic.surfacedBattery(live: liveBattery, lastKnown: lastKnownBattery)
    let signal = OmiSourceLogic.surfacedSignal(live: liveRSSI, lastKnown: lastKnownSignal)
    return Source(
        id: "omi",
        displayName: "omi pendant",
        kind: .omi,
        state: mapped.0,
        isJournalPaired: isJournalPaired,
        activeSubtext: SourceVocabulary.observerActiveSubtext,
        attention: mapped.1,
        pendingStatus: .nonePending,
        detailSubtext: OmiSourceLogic.sourceReadingSubtext(
            battery: battery,
            signal: signal,
            now: now
        )
    )
}

// Moved from Sources/SourcesView.swift. Signature unchanged so
// SourcesViewRowBuilderTests / WatchActivationRepublishGrepTests keep
// calling watchSourceModel(from:isJournalPaired:).
nonisolated func watchSourceModel(from lane: PhoneWatchSourceLane, isJournalPaired: Bool) -> Source? {
    guard lane != .unsupported else {
        return nil
    }
    let presentation = phoneWatchSourcePresentation(lane: lane)
    return Source(
        id: "watch",
        displayName: SourceVocabulary.watchSourceDisplayName,
        kind: .watch,
        state: presentation.state,
        isJournalPaired: isJournalPaired,
        activeSubtext: SourceVocabulary.watchListeningSubtext,
        subtextOverride: presentation.subtext,
        attention: presentation.attention,
        pendingStatus: .nonePending,
        showsSubtext: presentation.subtext != nil
    )
}
// watchSourceModel-end

nonisolated struct HomeSourceBundle: Equatable, Sendable {
    var audio: Source
    var location: Source
    var screencast: Source
    var omi: Source
    var watch: Source?
}

@MainActor
func makeHomeSourceBundle(
    now: Date,
    isJournalPaired: Bool,
    observerManager: ObserverManager,
    observerSourcePauseState: ObserverSourcePauseState,
    locationManager: LocationManager,
    screencastManager: ScreencastManager,
    omiSourceManager: OmiSourceManager,
    watchLane: PhoneWatchSourceLane
) -> HomeSourceBundle {
    let audioState = sourceState(for: observerManager.state, paused: observerSourcePauseState.isPaused)
    let audioAttention: SourceAttention? = {
        if case .error(let error) = observerManager.state {
            return SourceAttention(message: error.message)
        }
        return nil
    }()
    return HomeSourceBundle(
        audio: makeAudioSource(state: audioState, attention: audioAttention, isJournalPaired: isJournalPaired),
        location: makeLocationSource(
            state: locationManager.sourceState,
            attention: locationManager.sourceAttention,
            isJournalPaired: isJournalPaired
        ),
        screencast: makeScreencastSource(
            managerState: screencastManager.state,
            isJournalPaired: isJournalPaired
        ),
        omi: makeOmiSource(
            now: now,
            effectiveConnectionState: omiSourceManager.effectiveConnectionState(now: now),
            enabled: omiSourceManager.enabled,
            liveBattery: omiSourceManager.battery,
            lastKnownBattery: omiSourceManager.lastKnownBattery,
            liveRSSI: omiSourceManager.connectedRSSI,
            lastKnownSignal: omiSourceManager.lastKnownSignal,
            isJournalPaired: isJournalPaired
        ),
        watch: watchSourceModel(from: watchLane, isJournalPaired: isJournalPaired)
    )
}
