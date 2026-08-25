// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppIntents
import Foundation

struct OpenJournalIntent: AppIntent {
    static var title: LocalizedStringResource { "tbd" }

    func perform() async throws -> some IntentResult {
        .result(opensIntent: OpenURLIntent(URL(string: "solstone://journal")!))
    }
}
