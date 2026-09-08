// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class WatchComplicationBundleCompositionTests: XCTestCase {
    /// 🔒 The bundle ships **one** widget, and it carries every family we support.
    ///
    /// This test used to assert the opposite — that a second, Smart-Stack-only widget was
    /// registered. That widget was removed: `.accessoryRectangular` already *is* the Smart Stack
    /// presentation, so the second one only ever produced a duplicate, indistinguishable row in
    /// the owner's widget picker.
    func testBundleRegistersExactlyOneWidgetCoveringEveryFamily() throws {
        let source = try Self.complicationSource()

        let bundleBody = try Self.section(
            of: source,
            from: "struct SolstoneWatchComplicationBundle: WidgetBundle {",
            to: "struct SolstoneWatchComplication: Widget {"
        )

        // One widget in the bundle, and it is the status complication.
        XCTAssertTrue(bundleBody.contains("SolstoneWatchComplication()"))
        XCTAssertEqual(
            bundleBody.components(separatedBy: "()").count - 1,
            1,
            "the watch widget bundle must register exactly one widget"
        )

        XCTAssertTrue(source.contains("kind: WatchComplicationSnapshot.widgetKind"))
        XCTAssertTrue(source.contains("SolstoneWatchComplicationView(entry: entry)"))
        XCTAssertTrue(
            source.contains(".supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])")
        )

        // ⛔ The removed widget must not come back under its old name.
        XCTAssertFalse(source.contains("SolstoneWatchStatusSmartStackWidget()"))
        XCTAssertFalse(source.contains("struct SolstoneWatchStatusSmartStackProvider"))
    }

    /// 🔒 **No widget kind may be a prefix of another kind.**
    ///
    /// WidgetKit persists per-widget timeline and placeholder state in a path keyed by `kind`.
    /// The bundle previously shipped `"SolstoneWatchStatus"` alongside
    /// `"SolstoneWatchStatusSmartStack"` — a strict prefix — which is the leading explanation for
    /// the widget rendering correctly in the gallery yet refusing to persist into the Smart Stack
    /// when the owner added it. Distinct-but-prefixed is not distinct enough.
    ///
    /// ⚠ This passes trivially while there is one kind. It exists for the next person who adds a
    /// second one, which is precisely when the trap fires and precisely when nobody is looking.
    func testWidgetKindsAreNotPrefixesOfEachOther() throws {
        let kinds = try Self.declaredWidgetKinds()

        XCTAssertFalse(kinds.isEmpty, "found no widgetKind declarations — the scan is broken, not the code")
        XCTAssertEqual(Set(kinds).count, kinds.count, "widget kinds must be unique: \(kinds)")

        for outer in kinds {
            for inner in kinds where inner != outer {
                XCTAssertFalse(
                    inner.hasPrefix(outer),
                    "widget kind \"\(inner)\" has \"\(outer)\" as a prefix; kinds must be prefix-free"
                )
            }
        }
    }

    /// 🔒 **Every widget reload must republish relevance in the same breath.**
    ///
    /// The card's Smart Stack relevance is a rolling date window derived from live capture state.
    /// A reload that does not invalidate relevance leaves the system ranking the card against a
    /// window that has already moved, so the boost decays even while capture continues. Nothing
    /// in the type system pairs these two calls, so this counts them.
    func testEveryComplicationReloadAlsoInvalidatesRelevance() throws {
        let source = try String(
            contentsOf: Self.worktreeRoot().appendingPathComponent("Watch/Sources/WatchCaptureModel.swift"),
            encoding: .utf8
        )

        let reloads = source.components(
            separatedBy: "reloadTimelines(ofKind: WatchComplicationSnapshot.widgetKind)"
        ).count - 1
        let invalidations = source.components(
            separatedBy: "invalidateRelevance(ofKind: WatchComplicationSnapshot.widgetKind)"
        ).count - 1

        XCTAssertGreaterThan(reloads, 0, "found no complication reloads — the scan is broken, not the code")
        XCTAssertEqual(
            invalidations,
            reloads,
            "every complication reload must be paired with a relevance invalidation"
        )
    }

    /// 🔒 The provider must override `relevance()`, and must stay silent when capture is off.
    ///
    /// ⛔ `TimelineProvider` ships a **default** `relevance()` that returns nothing, so dropping
    /// the override is a silent regression: the widget keeps working and simply stops ever
    /// surfacing itself, which is the exact defect this override was added to fix.
    func testProviderPublishesRelevanceOnlyWhileCapturing() throws {
        let source = try Self.complicationSource()

        XCTAssertTrue(source.contains("func relevance() async -> WidgetRelevance<Void>"))
        // The window is computed by the pure helper (tested for staleness in
        // WatchComplicationSnapshotTests), and published through it — never opened from `Date()`
        // directly, which is the stale-snapshot regression the helper closes.
        XCTAssertTrue(source.contains("watchComplicationRelevanceWindow("))
        XCTAssertTrue(source.contains("WidgetRelevanceAttribute(context: .date(range: window, kind: .default))"))
        // The off path returns an empty relevance rather than a window.
        XCTAssertTrue(source.contains("return WidgetRelevance([])"))
    }

    // MARK: - helpers

    /// Every widget `kind` literal declared anywhere in the app, across **both** widget bundles.
    ///
    /// ⚠ Scans directories rather than a fixed file list on purpose: a fixed list silently stops
    /// covering the next widget someone adds, which is exactly the case this guard is for.
    private static func declaredWidgetKinds() throws -> [String] {
        let roots = ["SolstoneWatchComplication", "SolstoneLiveActivityWidget"]
        var files: [URL] = [
            self.worktreeRoot().appendingPathComponent("Sources/WatchCapture/WatchComplicationSnapshot.swift"),
        ]

        for root in roots {
            let directory = self.worktreeRoot().appendingPathComponent(root)
            let contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            files.append(contentsOf: contents.filter { $0.pathExtension == "swift" })
        }

        var kinds: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") {
                for marker in ["widgetKind = \"", "kind = \""] {
                    guard let open = line.range(of: marker),
                          let close = line.range(of: "\"", range: open.upperBound..<line.endIndex)
                    else { continue }
                    kinds.append(String(line[open.upperBound..<close.lowerBound]))
                    break
                }
            }
        }
        return kinds
    }

    private static func complicationSource() throws -> String {
        try String(
            contentsOf: self.worktreeRoot().appendingPathComponent(
                "SolstoneWatchComplication/SolstoneWatchComplication.swift"
            ),
            encoding: .utf8
        )
    }

    private static func section(of text: String, from start: String, to end: String) throws -> String {
        guard let startRange = text.range(of: start),
              let endRange = text.range(of: end, range: startRange.upperBound..<text.endIndex)
        else {
            throw NSError(
                domain: "WatchComplicationBundleCompositionTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "could not bound section \(start) … \(end)"]
            )
        }
        return String(text[startRange.upperBound..<endRange.lowerBound])
    }

    private static func worktreeRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
