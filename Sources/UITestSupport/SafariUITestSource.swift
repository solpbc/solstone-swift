// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if DEBUG
import Foundation

/// `--ui-test-safari=<mode>` shows the Safari source in one state without Safari:
/// `setUp`, `addSite`, `on`, `off`, `waiting`, `full`.
@MainActor
enum SafariUITestSource {
    static func seeded(arguments: [String] = ProcessInfo.processInfo.arguments) -> SafariSourceModel? {
        guard arguments.contains("--ui-test"),
              let mode = arguments.first(where: { $0.hasPrefix("--ui-test-safari=") })?.split(separator: "=").last
        else { return nil }
        let now = Date()
        var snapshot = SafariBrowserSnapshot(confirmed: true, heldBytes: 0, queuedBytes: 0,
            lastAccepted: now.addingTimeInterval(-90), lastContact: now, full: false)
        switch mode {
        case "setUp": snapshot.lastContact = nil; snapshot.lastAccepted = nil
        case "addSite": snapshot.lastAccepted = nil
        case "waiting": snapshot.heldBytes = 4096
        case "full": snapshot.full = true; snapshot.heldBytes = 64 * 1024 * 1024
        default: break
        }
        let box = Box(snapshot)
        let extensionOn: Bool? = mode == "off" ? false : nil
        return SafariSourceModel(load: { box.value }, readExtensionOn: { extensionOn }, openSettings: { false })
    }

    private final class Box {
        var value: SafariBrowserSnapshot
        init(_ value: SafariBrowserSnapshot) { self.value = value }
    }
}
#endif
