// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppIntents

struct ObserverCaptureIntent: AppIntent {
    static var title: LocalizedStringResource { "solstone" }

    func perform() async throws -> some IntentResult {
        .result()
    }
}
