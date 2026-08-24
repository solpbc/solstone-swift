// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class ShellPresentationGrepTests: XCTestCase {
    func testFetchTaskUsesActiveLocalPort() throws {
        let text = try Self.sourceText("Sources/RootShellView.swift")
        XCTAssertTrue(text.contains(".task(id: self.observerRegistration.activeLocalPort)"))
        let body = try Self.slice(
            in: text,
            from: "private func fetchJournalMark() async {",
            to: "\n    private func applyDebugSeeds()"
        )
        XCTAssertTrue(body.contains("JournalIdentityFetcher"))
        XCTAssertTrue(body.contains("self.observerRegistration.activeLocalPort"))
        XCTAssertTrue(body.contains("fetch(localPort:"))
        XCTAssertFalse(body.contains("self.localPort"))
    }

    func testNoScreenChangedPostsInShellTree() throws {
        let needle = "UIAccessibility.post(notification: .screenChanged"
        let files = [
            "Sources/RootShellView.swift",
        ] + (try Self.relativeSwiftFiles(under: "Sources/Home"))
            + (try Self.relativeSwiftFiles(under: "Sources/Portal"))
        for relative in files {
            let text = try Self.sourceText(relative)
            XCTAssertFalse(text.contains(needle), relative)
            XCTAssertFalse(text.contains("UIAccessibility.Notification.screenChanged"), relative)
        }
    }

    /// The `if self.path.isEmpty` literal this used to pin is gone: the shell is a
    /// `NavigationSplitView` and the deck no longer owns a stack. The strip's real
    /// requirements survive here; that it appears only when the phone shell is at
    /// rest, and never on iPad, is covered behaviourally by
    /// `PaneHostUITests.testHitStripExistsOnlyOnRoot` and
    /// `PadSplitShellUITests.testHitStripIsAbsentOnPad`.
    func testHitStripExistsWithoutDeferringSystemGestures() throws {
        let text = try Self.sourceText("Sources/RootShellView.swift")
        XCTAssertTrue(text.contains("shell.hitStrip"))
        XCTAssertFalse(text.contains("preferredScreenEdgesDeferringSystemGestures"))
    }

    func testShelfUsesVerticalSizeClass() throws {
        let text = try Self.sourceText("Sources/Home/ShelfPane.swift")
        XCTAssertTrue(text.contains("@Environment(\\.verticalSizeClass)"))
        XCTAssertTrue(text.contains("verticalSizeClass == .compact"))
        XCTAssertTrue(text.contains("LazyVGrid"))
    }

    func testPanesCrossFadeWhenPreferred() throws {
        let text = try Self.sourceText("Sources/RootShellView.swift")
        XCTAssertTrue(text.contains("AccessibilityCrossFadePreference()"))
        XCTAssertTrue(text.contains("UIAccessibility.prefersCrossFadeTransitions"))
        XCTAssertTrue(text.contains("UIAccessibility.prefersCrossFadeTransitionsStatusDidChange"))
        XCTAssertFalse(text.contains("extension EnvironmentValues"))
        XCTAssertTrue(text.contains(".transition(self.prefersCrossFade ? .opacity : .move(edge: .leading))"))
        XCTAssertFalse(text.contains(".move(edge: .bottom)"))
        XCTAssertFalse(text.contains(".transition(self.prefersCrossFade ? .opacity : .identity)"))
        XCTAssertTrue(text.contains("self.reduceMotion || self.prefersCrossFade"))
        XCTAssertFalse(text.contains("--accessibility-prefers-cross-fade"))
    }

    func testReduceMotionOmitsStatusZoom() throws {
        let text = try Self.sourceText("Sources/RootShellView.swift")
        XCTAssertTrue(text.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(text.contains("navigationTransition(.zoom(sourceID: HomeChromeID.status, in: self.homeChrome))"))
        let sheet = try Self.slice(
            in: text,
            from: "private var statusSheet: some View {",
            to: "\n    private func fetchJournalMark()"
        )
        XCTAssertTrue(sheet.contains("if self.reduceMotion"))
        XCTAssertTrue(sheet.contains(".navigationTransition(.zoom"))
    }

    func testApplyClearsPendingRoute() throws {
        let text = try Self.sourceText("Sources/RootShellView.swift")
        XCTAssertTrue(text.contains(".onAppear {"))
        XCTAssertTrue(text.contains("self.apply(route)"))
        XCTAssertTrue(text.contains(".onChange(of: self.pendingRoute.route)"))
        let apply = try Self.slice(
            in: text,
            from: "private func apply(_: NotificationRoute) {",
            to: "\n}\n\nprivate extension SourceState"
        )
        XCTAssertTrue(apply.contains("self.pendingRoute.route = nil"))
        XCTAssertTrue(apply.contains("self.presentedPane = nil"))
        XCTAssertFalse(apply.contains("self.showingYourSolstone"))
    }

    func testJournalPaneUsesWebPageAndPolicy() throws {
        let view = try Self.sourceText("Sources/Portal/InAppJournalView.swift")
        XCTAssertTrue(view.contains("WebView("))
        XCTAssertFalse(view.contains("UIViewRepresentable"))
        XCTAssertFalse(view.contains("WKNavigationDelegate"))
        XCTAssertFalse(view.contains("WKScriptMessageHandler"))
        XCTAssertFalse(view.contains("URLSchemeHandler"))

        let controller = try Self.sourceText("Sources/Portal/JournalWebPageController.swift")
        XCTAssertTrue(controller.contains("WebPage"))
        XCTAssertTrue(controller.contains("journalWebActionPolicy"))
        XCTAssertTrue(controller.contains("session.decidePolicy(for: request, isMainFrame: isMainFrame)"))
        XCTAssertTrue(controller.contains("case .rewrite:"))
        XCTAssertTrue(controller.contains("return .cancel"))
        XCTAssertFalse(controller.contains("URLSchemeHandler"))
        XCTAssertFalse(controller.contains("WKScriptMessageHandler"))

        let pane = view + controller
        XCTAssertTrue(pane.contains("JournalWebNavigationDecider") || controller.contains("JournalWebNavigationDecider"))
        XCTAssertFalse(view.contains("navigationTitle(\"journal\")"))
        XCTAssertTrue(view.contains("journalPaneTitle("))
        XCTAssertTrue(controller.contains("page.navigations"))
        XCTAssertFalse(controller.contains("for try await event in page.load"))
    }

    func testJournalPaneDisablesBackForwardGestures() throws {
        let text = try Self.sourceText("Sources/Portal/InAppJournalView.swift")
        XCTAssertTrue(text.contains(".webViewBackForwardNavigationGestures(.disabled)"))
    }

    func testDayHomeStatusPillIsButtonNotNavigationLink() throws {
        let text = try Self.sourceText("Sources/Home/DayHomeView.swift")
        let pill = try Self.slice(
            in: text,
            from: "var statusPill: some View {",
            to: "\n    var statusPillAccessibilityValue"
        )
        XCTAssertTrue(pill.contains("Button(action: self.onOpenStatus)"))
        XCTAssertTrue(pill.contains("dayHome.statusPill"))
        XCTAssertTrue(pill.contains("HomeChromeID.status"))
        XCTAssertFalse(pill.contains("NavigationLink(value: ShellDestination.status)"))
    }

    private static func sourceText(_ relativePath: String) throws -> String {
        let url = StringLiteralGrepSupport.worktreeRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func relativeSwiftFiles(under relativePath: String) throws -> [String] {
        let root = StringLiteralGrepSupport.worktreeRoot()
        let directory = root.appendingPathComponent(relativePath, isDirectory: true)
        return try StringLiteralGrepSupport.swiftFiles(under: directory).map { url in
            String(url.path.dropFirst(root.path.count + 1))
        }
    }

    private static func slice(in text: String, from startToken: String, to endToken: String) throws -> Substring {
        let start = try XCTUnwrap(text.range(of: startToken))
        let remaining = text[start.lowerBound...]
        let end = try XCTUnwrap(remaining.range(of: endToken))
        return text[start.lowerBound..<end.lowerBound]
    }
}
