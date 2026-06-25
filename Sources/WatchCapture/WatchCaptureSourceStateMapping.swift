// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated func watchSourceState(
    for presentation: WatchCaptureOwnerPresentation
) -> (SourceState, SourceAttention?) {
    switch presentation.status {
    case .off:
        return (.off, nil)
    case .enrolling:
        return (.enrolling, nil)
    case .active:
        return (.active, nil)
    case .paused:
        return (.paused, nil)
    case .needsAttention(let error):
        return (.needsAttention, SourceAttention(message: error.message))
    }
}
