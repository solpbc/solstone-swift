// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

enum ObserverMode: String, CaseIterable, Codable, Sendable {
    case meeting
    case voiceMemo = "voice_memo"

    var label: String {
        switch self {
        case .meeting:
            "Meeting"
        case .voiceMemo:
            "Voice memo"
        }
    }
}
