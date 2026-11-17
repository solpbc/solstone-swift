// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppIntents
import Foundation

struct OpenJournalIntent: AppIntent {
    static var title: LocalizedStringResource { LocalizedStringResource("m696f732e6c69766561637469766974792e7469746c65", table: "Localizable") }

    func perform() async throws -> some IntentResult {
        .result(opensIntent: OpenURLIntent(URL(string: "solstone://journal")!))
    }
}
