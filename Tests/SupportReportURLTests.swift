// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
import UIKit
@testable import solstone_swift

struct SupportReportURLTests {
    @Test @MainActor func reportUsesFixedFragmentContract() throws {
        let suiteName = "SupportReportURLTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let journalVersion = JournalVersionMetadata(defaults: defaults) { _ in nil }
        journalVersion.setIdentity("identity")
        journalVersion.noteConnected(localPort: 7071)
        #expect(journalVersion.applyValidated(
            name: "private-journal-name",
            version: "1.2.3",
            pairingIdentity: "identity"
        ))
        journalVersion.acceptHostFacts(
            os: "ubuntu",
            osVersion: "24.04",
            arch: "x86_64",
            build: nil,
            identity: "identity",
            activePort: 7071,
            version: "1.2.3"
        )
        let about = PhoneAboutBlock.block(journalVersion: journalVersion, watchFacts: nil)
        let aboutLines = about.components(separatedBy: "\n")
        let expectedJournalLine = AboutBlock.line(
            name: "journal",
            version: "1.2.3",
            os: "ubuntu",
            osVersion: "24.04",
            arch: "x86_64"
        )
        let deviceName = UIDevice.current.name
        let osVersion = UIDevice.current.systemVersion
        let url = SupportReportURL.make(
            version: AppVersion.shortVersion,
            build: AppVersion.build,
            osVersion: osVersion,
            state: "no recent problem report",
            about: about
        )
        let absolute = url.absoluteString

        #expect(absolute.hasPrefix("https://support.solstone.app/#report=v1&app=solstone+for+ios"))
        #expect(absolute.contains("&state=no+recent+problem+report"))
        #expect(!absolute.contains("?"))
        #expect(absolute.contains("&os=ios"))

        let fragment = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedFragment)
        let fields = Dictionary(uniqueKeysWithValues: fragment.split(separator: "&").compactMap { pair -> (String, String)? in
            let pieces = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard pieces.count == 2,
                  let key = pieces[0].replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  let value = pieces[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding else { return nil }
            return (key, value)
        })
        let decodedFragment = try #require(fragment
            .replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding)

        #expect(fields["report"] == "v1")
        #expect(fields["app"] == "solstone for ios")
        #expect(fields["version"] == AppVersion.shortVersion)
        #expect(fields["build"] == AppVersion.build)
        #expect(fields["os"] == "ios")
        #expect(fields["os_version"] == osVersion)
        #expect(fields["about"] == about)
        #expect(aboutLines.count == 2)
        #expect(aboutLines.last == expectedJournalLine)
        #expect(fields["about"]?.contains("\n") == true)
        #expect(fields["about"]?.contains("·") == true)
        #expect(!decodedFragment.contains("private-journal-name"))
        if !AppVersion.sourceCommit.isEmpty {
            #expect(!decodedFragment.contains(AppVersion.sourceCommit))
        }
        if !deviceName.isEmpty,
           !AppVersion.shortVersion.contains(deviceName),
           !AppVersion.build.contains(deviceName),
           !osVersion.contains(deviceName) {
            #expect(!decodedFragment.contains(deviceName))
        }
    }

    @Test func optionalFieldsAreOmittedAndStateIsBounded() {
        let url = SupportReportURL.make(
            version: "1",
            build: "2",
            osVersion: "",
            state: String(repeating: "é", count: 501),
            about: ""
        ).absoluteString

        #expect(!url.contains("os_version="))
        #expect(url.components(separatedBy: "%C3%A9").count - 1 == 500)
        #expect(!SupportReportURL.make(version: "1", build: "2", osVersion: "", state: "", about: "")
            .absoluteString.contains("state="))
        #expect(url.contains("&about="))
    }
}
