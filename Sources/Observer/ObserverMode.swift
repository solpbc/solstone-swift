// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Every capture starts as `.meeting`. `voice_memo` is never started any more; it stays
/// so sessions and chunk sidecars saved while the audio page offered it still decode.
enum ObserverMode: String, Codable, Sendable {
    case meeting
    case voiceMemo = "voice_memo"
}
