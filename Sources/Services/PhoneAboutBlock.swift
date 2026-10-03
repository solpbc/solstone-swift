// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import UIKit

nonisolated struct WatchAboutFacts: Sendable {
    let marketingVersion: String?
    let build: String?
    let osVersion: String?
}

enum PhoneAboutBlock {
    static func block(
        journalVersion: JournalVersionMetadata,
        watchFacts: WatchAboutFacts?,
        now: Date = Date()
    ) -> String {
        var lines = [self.iosAppLine()]
        if let watchFacts {
            lines.append(self.watchLine(facts: watchFacts))
        }
        lines.append(self.journalLine(metadata: journalVersion, now: now))
        return AboutBlock.block(lines)
    }

    static func iosAppLine() -> String {
        let idiom = DeviceDescriptionSnapshot.mapUserInterfaceIdiom(UIDevice.current.userInterfaceIdiom)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = version.patchVersion == 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        // The running binary's architecture, never the CPU subtype: NXGetLocalArchInfo names
        // A12-and-later iPhones "arm64e", which the line grammar does not allow. Every device
        // build is arm64; a simulator prints its slice (arm64, or x86_64 for an Intel slice).
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = ""
        #endif
        return AboutBlock.line(
            name: "ios app",
            version: AppVersion.shortVersion,
            build: AppVersion.build,
            os: idiom.platform,
            osVersion: osVersion,
            arch: arch
        )
    }

    static func watchLine(facts: WatchAboutFacts) -> String {
        AboutBlock.line(
            name: "watch app",
            version: facts.marketingVersion ?? "",
            build: facts.build ?? "",
            os: "watchos",
            osVersion: facts.osVersion ?? ""
        )
    }

    static func journalLine(metadata: JournalVersionMetadata, now: Date = Date()) -> String {
        let hasHostFacts = metadata.hostFactsAcceptedAt != nil
        return AboutBlock.line(
            name: "journal",
            version: metadata.version ?? "",
            build: hasHostFacts ? metadata.journalBuild ?? "" : "",
            os: hasHostFacts ? metadata.journalOS ?? "" : "",
            osVersion: hasHostFacts ? metadata.journalOSVersion ?? "" : "",
            arch: hasHostFacts ? metadata.journalArch ?? "" : "",
            isCurrent: metadata.isCurrent,
            observedAt: metadata.versionObservedAt,
            now: now
        )
    }
}
