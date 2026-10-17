// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class I18nPilotTests: XCTestCase {
    func testLocaleCanaryAndMachineValues() throws {
        let locale = Locale.current.identifier
        print("I18N_CANARY locale=\(locale)")
        XCTAssertFalse(locale.isEmpty)
        // Typed protocol/raw values and JSON retain their exact machine meaning.
        XCTAssertEqual(try JSONEncoder().encode(SourceState.active), Data("{\"active\":{}}".utf8))
        XCTAssertEqual(SourceState.active.symbol, "checkmark.circle")
        let arguments = SourceVocabulary.finishSyncingCardBody(count: 10000).arguments
        let encoded = try JSONEncoder().encode(arguments)
        XCTAssertEqual(encoded, Data("{\"count\":10000}".utf8))
        XCTAssertEqual(try JSONDecoder().decode([String: Int].self, from: encoded), arguments)
    }

    func testPluralIdentityAndArguments() {
        for count in [0,1,2,10000] {
            let body = SourceVocabulary.finishSyncingCardBody(count: count)
            XCTAssertEqual(body.id, "ios.sourceSync.finishSyncingCardBody")
            XCTAssertEqual(body.arguments, ["count":count])
            let interrupted = SourceVocabulary.finishSyncingInterrupted(count: count)
            XCTAssertEqual(interrupted.id, "ios.sourceSync.finishSyncingInterrupted")
            XCTAssertEqual(interrupted.arguments, ["count":count])
            let subtitle = SourceVocabulary.finishSyncingSystemSubtitle(remaining: count)
            XCTAssertEqual(subtitle.id, "ios.sourceSync.finishSyncingSystemSubtitle")
            XCTAssertEqual(subtitle.arguments, ["remaining":count])
        }
        XCTAssertEqual(SourceVocabulary.standingSyncFootnote(sustaining: true).key, "ios.sourceSync.standingSyncFootnoteSustaining")
        XCTAssertEqual(SourceVocabulary.standingSyncFootnote(sustaining: false).key, "ios.sourceSync.standingSyncFootnoteLimited")
    }

    func testSubtextDecisionsUseFlagsRatherThanRenderedWords() {
        XCTAssertNil(SourceState.active.compactSubtext(activeSubtext: "translated state label", repeatsStateLabel: true))
        XCTAssertEqual(SourceState.active.compactSubtext(activeSubtext: "on", repeatsStateLabel: false), "on")
        let repeated = Source(id: "synthetic", displayName: "synthetic", kind: .screencast, state: .off,
            isJournalPaired: true, activeSubtext: "synthetic detail", subtextOverride: "translated state label",
            subtextOverrideRepeatsStateLabel: true, attention: nil, pendingStatus: .nonePending)
        XCTAssertNil(repeated.rowSubtext)
        let distinct = Source(id: "synthetic", displayName: "synthetic", kind: .screencast, state: .off,
            isJournalPaired: true, activeSubtext: "synthetic detail", subtextOverride: "off",
            subtextOverrideRepeatsStateLabel: false, attention: nil, pendingStatus: .nonePending)
        XCTAssertEqual(distinct.rowSubtext, "off")
    }

    func testEveryCompiledBundleHasPseudolocale() throws {
        let app = Bundle.main.bundleURL
        let bundles = [
            app,
            app.appendingPathComponent("PlugIns/SolstoneShareExtension.appex"),
            app.appendingPathComponent("PlugIns/SolstoneLiveActivityWidget.appex"),
            app.appendingPathComponent("Watch/SolstoneWatch.app"),
            app.appendingPathComponent("Watch/SolstoneWatch.app/PlugIns/SolstoneWatchComplication.appex"),
        ]
        for url in bundles {
            let bundle = try XCTUnwrap(Bundle(url:url), url.path)
            XCTAssertNotNil(bundle.url(forResource:"Pilot", withExtension:"strings", subdirectory:nil, localization:"en-XA"), url.path)
            let resources = PilotCopy.resources(locale:Locale(identifier:"en-XA"), bundle:.atURL(url))
            XCTAssertEqual(resources.count,64)
            for resource in resources {
                let rendered = String(localized:resource)
                XCTAssertTrue(rendered.hasPrefix("[") && rendered.hasSuffix("]"), "\(url.lastPathComponent): \(resource.key) = \(rendered)")
                XCTAssertFalse(rendered.contains("%1$lld"))
            }
            print("I18N_BUNDLE \(url.lastPathComponent) resources=\(resources.count) wrapped=\(resources.count)")
        }
    }

    func testMissingCatalogIsAnObservableEnglishFallback() {
        let withoutCatalog = Bundle(for: Self.self).bundleURL
        let resources = PilotCopy.resources(locale: Locale(identifier: "en-XA"), bundle: .atURL(withoutCatalog))
        let resource = resources.first { $0.key == "ios.sourceSync.shareSendingProgress" }!
        XCTAssertFalse(String(localized: resource).hasPrefix("["))
        XCTAssertEqual(String(localized: resource), "sending to your journal…")
    }

    func testEnglishBeforeAfter() throws {
        guard Locale.current.identifier == "en_US" else { throw XCTSkip("English byte invariant is qualified on en_US only") }
        let url = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"english-before",withExtension:"json"))
        let before = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:url))
        var after = Self.vocabularySnapshot
        for count in [0,1,2,10000] {
            after["finishSyncingCardBody.\(count)"] = SourceVocabulary.finishSyncingCardBody(count:count).rendered
            after["finishSyncingInterrupted.\(count)"] = SourceVocabulary.finishSyncingInterrupted(count:count).rendered
            after["finishSyncingSystemSubtitle.\(count)"] = SourceVocabulary.finishSyncingSystemSubtitle(remaining:count).rendered
        }
        for value in [true,false] { after["standingSyncFootnote.\(value)"] = String(localized:SourceVocabulary.standingSyncFootnote(sustaining:value)) }
        XCTAssertEqual(Set(before.keys),Set(after.keys))
        for key in before.keys { XCTAssertEqual(Data(try XCTUnwrap(before[key]).utf8),Data(try XCTUnwrap(after[key]).utf8),key) }
        print("I18N_ENGLISH compared=\(before.count)")
    }
}
