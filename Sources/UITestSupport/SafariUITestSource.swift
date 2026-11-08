// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if DEBUG
import Foundation
import Observation

/// `--ui-test-safari=<mode>` shows the Safari source in one state without Safari:
/// `setUp`, `addSite`, `on`, `off`, `waiting`, `full`. `chooseEverySite`, `chooseOneAtATime`
/// and `chooseGarbage` are `addSite` with that answer to step 2 already stored, and
/// `chooseEverySiteOpens` is `chooseEverySite` where opening Settings works.
@MainActor
enum SafariUITestSource {
    /// What the seeded source was asked to do, for the page's probes to show.
    @Observable
    final class Calls {
        var openSettings = 0
    }

    static let calls = Calls()

    static func seeded(arguments: [String] = ProcessInfo.processInfo.arguments) -> SafariSourceModel? {
        guard arguments.contains("--ui-test"),
              let mode = arguments.first(where: { $0.hasPrefix("--ui-test-safari=") })?.split(separator: "=").last
        else { return nil }
        let now = Date()
        var snapshot = SafariBrowserSnapshot(confirmed: true, heldBytes: 0, queuedBytes: 0,
            lastAccepted: now.addingTimeInterval(-90), lastContact: now, full: false)
        switch mode {
        case "setUp": snapshot.lastContact = nil; snapshot.lastAccepted = nil
        case "addSite", "chooseEverySite", "chooseOneAtATime", "chooseGarbage", "chooseEverySiteOpens":
            snapshot.lastAccepted = nil
        case "waiting": snapshot.heldBytes = 4096
        case "full": snapshot.full = true; snapshot.heldBytes = 64 * 1024 * 1024
        default: break
        }
        let choice: String? = switch mode {
        case "chooseEverySite", "chooseEverySiteOpens": SafariSetUpChoice.everySite.rawValue
        case "chooseOneAtATime": SafariSetUpChoice.oneAtATime.rawValue
        case "chooseGarbage": "garbage"
        default: nil
        }
        if let choice {
            UserDefaults.standard.set(choice, forKey: SafariSetUpChoice.storageKey)
        } else if mode == "addSite" {
            UserDefaults.standard.removeObject(forKey: SafariSetUpChoice.storageKey)
        }
        let box = Box(snapshot)
        let extensionOn: Bool? = mode == "off" ? false : nil
        let opens = mode == "chooseEverySiteOpens"
        return SafariSourceModel(load: { box.value }, readExtensionOn: { extensionOn }, openSettings: {
            Self.calls.openSettings += 1
            return opens
        })
    }

    private final class Box {
        var value: SafariBrowserSnapshot
        init(_ value: SafariBrowserSnapshot) { self.value = value }
    }
}
#endif
