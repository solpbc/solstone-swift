// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

nonisolated enum WatchFaceMark: Equatable, Sendable {
    case active
    case activeDimmed
    case alert
}

nonisolated enum WatchFaceColorRole: Equatable, Sendable, CaseIterable, Codable {
    case live
    case flight
    case calm
    case alert
}

nonisolated struct WatchFaceHandoff: Equatable, Sendable {
    let line: String
    let subtext: String?
    let role: WatchFaceColorRole
}

nonisolated struct WatchFaceDetailRow: Equatable, Sendable {
    let label: String
    let value: Int
}

nonisolated struct WatchFaceModel: Equatable, Sendable {
    let markVariant: WatchFaceMark
    let stateWord: String
    let stateColorRole: WatchFaceColorRole
    let showsElapsed: Bool
    let compactHandoff: WatchFaceHandoff?
    let detailRows: [WatchFaceDetailRow]
    let trustLine: String?
    let linkLine: String
    let linkInRange: Bool
}

nonisolated func watchFaceModel(
    for presentation: WatchCaptureOwnerPresentation,
    isReachable: Bool
) -> WatchFaceModel {
    let state: (word: String, mark: WatchFaceMark, role: WatchFaceColorRole, showsElapsed: Bool)
    switch presentation.status {
    case .active:
        state = (
            SourceVocabulary.watchHeadlineListening,
            .active,
            .live,
            true
        )
    case .enrolling:
        state = (
            SourceVocabulary.watchHeadlineEnrolling,
            .active,
            .live,
            false
        )
    case .needsAttention(let error):
        state = (
            error.message,
            .alert,
            .alert,
            false
        )
    case .off:
        state = (
            SourceVocabulary.watchHeadlineOff,
            .activeDimmed,
            .calm,
            false
        )
    }

    let handoff: WatchFaceHandoff?
    if presentation.transferringCount > 0 {
        handoff = WatchFaceHandoff(
            line: SourceVocabulary.watchSendingCount(presentation.transferringCount),
            subtext: nil,
            role: .flight
        )
    } else if presentation.queuedCount > 0 {
        handoff = WatchFaceHandoff(
            line: SourceVocabulary.watchSavedOnWatchCount(presentation.queuedCount),
            subtext: SourceVocabulary.watchWaitingForPhone,
            role: .calm
        )
    } else {
        handoff = nil
    }

    var detailRows: [WatchFaceDetailRow] = []
    if presentation.queuedCount > 0 {
        detailRows.append(WatchFaceDetailRow(label: SourceVocabulary.watchPipelineSaved, value: presentation.queuedCount))
    }
    if presentation.transferringCount > 0 {
        detailRows.append(WatchFaceDetailRow(label: SourceVocabulary.watchPipelineSending, value: presentation.transferringCount))
    }
    if presentation.confirmingCount > 0 {
        detailRows.append(WatchFaceDetailRow(label: SourceVocabulary.watchPipelineConfirming, value: presentation.confirmingCount))
    }
    if presentation.handedOffCount > 0 {
        detailRows.append(WatchFaceDetailRow(label: SourceVocabulary.watchPipelineHandedOff, value: presentation.handedOffCount))
    }

    return WatchFaceModel(
        markVariant: state.mark,
        stateWord: state.word,
        stateColorRole: state.role,
        showsElapsed: state.showsElapsed,
        compactHandoff: handoff,
        detailRows: detailRows,
        trustLine: SourceVocabulary.trustLineConfigured,
        linkLine: watchLinkLine(isReachable: isReachable),
        linkInRange: isReachable
    )
}

nonisolated func watchLinkLine(isReachable: Bool) -> String {
    isReachable ? SourceVocabulary.watchLinkConnected : SourceVocabulary.watchLinkNotConnected
}
