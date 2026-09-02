// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppIntents

struct SolstoneAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .orange }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ObserverCaptureIntent(value: true),
            phrases: [
                "turn on audio in \(.applicationName)",
                "start audio in \(.applicationName)",
                "\(.applicationName) audio on"
            ],
            shortTitle: "turn on audio",
            systemImageName: "waveform"
        )
    }
}
