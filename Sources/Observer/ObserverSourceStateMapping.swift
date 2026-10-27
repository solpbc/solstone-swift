// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// `enrolled` is the owner's own record that they set audio up at least once.
///
/// Without it an idle manager is indistinguishable from one the owner switched off,
/// and `off` is the owner's *intent* — so a fresh install would claim a decision
/// nobody made. ⛔ `enrolled` is never inferred from the manager's state; it is read
/// from what the owner actually did.
nonisolated func sourceState(
    for observerState: ObserverState,
    paused: Bool,
    enrolled: Bool,
    microphoneTaken: MicrophoneTakenPause?
) -> SourceState {
    if microphoneTaken != nil {
        return enrolled ? .paused : .readyToSetUp
    }
    return switch observerState {
    case .microphoneTaken:
        enrolled ? .paused : .readyToSetUp
    case .error(.permissionDenied) where !enrolled:
        // ⛔ Not a fault. The owner was asked for the microphone and said no, so nothing
        // they set up has stopped working — there is no evidence the permission was ever
        // held. `needs attention` here would be a diagnosis of a thing that never started.
        // The recovery route survives the word: the detail screen offers ios settings off
        // the manager's own error state, not off this one.
        .readyToSetUp
    case .error:
        .needsAttention
    case .starting:
        .enrolling
    case .active, .stopping:
        .active
    case .idle:
        if paused {
            .paused
        } else {
            enrolled ? .off : .readyToSetUp
        }
    }
}

nonisolated struct AudioOwnerPresentation: Equatable, Sendable {
    var sourceState: SourceState
    var tileLine: String?       // short key, or nil
    var detailLine: String?     // short key while holding, long key when stopped and enrolled
    var firstUseLine: String?   // short key when !enrolled
    var pauseEnabled: Bool
    var pauseReadsResume: Bool
    var showsLiveElapsed: Bool
    var switchEnabled: Bool
}

nonisolated func audioOwnerPresentation(
    observerState: ObserverState,
    ownerPaused: Bool,
    enrolled: Bool,
    microphoneTaken: MicrophoneTakenPause?
) -> AudioOwnerPresentation {
    let state = sourceState(
        for: observerState,
        paused: ownerPaused,
        enrolled: enrolled,
        microphoneTaken: microphoneTaken
    )

    switch microphoneTaken {
    case .holdingSession:
        return AudioOwnerPresentation(
            sourceState: state,
            tileLine: SourceVocabulary.microphoneTakenSubtextCompact,
            detailLine: SourceVocabulary.microphoneTakenSubtextCompact,
            firstUseLine: nil,
            pauseEnabled: false,
            pauseReadsResume: false,
            showsLiveElapsed: false,
            switchEnabled: false
        )
    case .stopped:
        if state == .paused {
            return AudioOwnerPresentation(
                sourceState: state,
                tileLine: SourceVocabulary.microphoneTakenSubtextCompact,
                detailLine: SourceVocabulary.microphoneTakenSubtext,
                firstUseLine: nil,
                pauseEnabled: true,
                pauseReadsResume: true,
                showsLiveElapsed: false,
                switchEnabled: true
            )
        } else {
            return AudioOwnerPresentation(
                sourceState: state,
                tileLine: nil,
                detailLine: nil,
                firstUseLine: SourceVocabulary.microphoneTakenSubtextCompact,
                pauseEnabled: false,
                pauseReadsResume: false,
                showsLiveElapsed: false,
                switchEnabled: true
            )
        }
    case nil:
        let isLive: Bool
        if case .active = observerState {
            isLive = true
        } else {
            isLive = false
        }
        let pauseEnabled: Bool
        let pauseReadsResume: Bool
        switch state {
        case .active:
            pauseEnabled = true
            pauseReadsResume = false
        case .paused:
            pauseEnabled = true
            pauseReadsResume = true
        case .off, .enrolling, .readyToSetUp, .checking, .needsAttention:
            pauseEnabled = false
            pauseReadsResume = false
        }
        let tileLine: String?
        if state == .needsAttention, case .error(let error) = observerState {
            tileLine = audioAttentionLine(error)
        } else {
            tileLine = nil
        }
        return AudioOwnerPresentation(
            sourceState: state,
            tileLine: tileLine,
            detailLine: nil,
            firstUseLine: nil,
            pauseEnabled: pauseEnabled,
            pauseReadsResume: pauseReadsResume,
            showsLiveElapsed: isLive,
            switchEnabled: true
        )
    }
}

nonisolated func audioAttentionLine(_ error: ObserverError) -> String {
    switch error {
    case .permissionDenied:
        SourceVocabulary.audioAttentionMicrophoneOff
    case .audioSessionConflict, .uploadFailed, .unavailable:
        SourceVocabulary.audioAttentionNotRunning
    case .diskFull:
        SourceVocabulary.audioAttentionStorageFull
    }
}

nonisolated enum AudioListenButtonKind: Equatable, Sendable {
    case start
    case stop
    case retry
}

nonisolated func audioListenButtonKind(_ state: ObserverState) -> AudioListenButtonKind {
    switch state {
    case .idle, .starting, .stopping, .microphoneTaken:
        .start
    case .active:
        .stop
    case .error(let error):
        switch error {
        case .diskFull, .permissionDenied:
            .start
        case .audioSessionConflict, .unavailable, .uploadFailed:
            .retry
        }
    }
}

nonisolated enum AudioTileSwitchCommand: Equatable, Sendable {
    case start
    case stop
    case ignore
}

nonisolated func audioTileSwitchCommand(
    requestedOn: Bool,
    microphoneTaken: MicrophoneTakenPause?
) -> AudioTileSwitchCommand {
    if microphoneTaken == .holdingSession {
        return .ignore
    }
    return requestedOn ? .start : .stop
}
