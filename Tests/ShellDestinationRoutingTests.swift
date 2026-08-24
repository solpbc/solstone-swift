// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class ShellDestinationRoutingTests: XCTestCase {
    func testEveryShellDestinationViewBranchIsRealAndStubFree() throws {
        let root = StringLiteralGrepSupport.worktreeRoot()
        let destinationURL = root.appendingPathComponent("Sources/Home/ShellDestination.swift")
        let text = try String(contentsOf: destinationURL, encoding: .utf8)
        let viewStart = try XCTUnwrap(text.range(of: "struct ShellDestinationView: View {"))
        let viewText = String(text[viewStart.lowerBound...])

        let routes = [
            ("case .source(.audio):", "SourceDetailView()"),
            ("case .source(.location):", "LocationSourceDetailView()"),
            ("case .source(.screencast):", "ScreencastSourceDetailView()"),
            ("case .source(.omi):", "OmiSourceDetailView()"),
            ("case .source(.watch):", "WatchSourceDetailView()"),
            ("case .status:", "StatusPane(presentation: .detail)"),
            ("case .journal:", "InAppJournalView(mark: self.journalMark, presentation: .detail)"),
            ("case .journalSetup:", "JournalLivesPane()"),
            ("case .addMore:", "AddMoreView"),
            ("case .import:", "ImportView()"),
            ("case .shelf:", "ShelfPane("),
            ("case .shelfJournal:", "JournalSettingsPane"),
            ("case .shelfThisDevice:", "ThisDevicePane()"),
            ("case .shelfNotifications:", "NotificationsPane()"),
            ("case .shelfHelp:", "HelpPane()"),
            ("case .shelfAbout:", "AboutPane()"),
            ("case .diagnostics:", "DiagnosticsView()"),
            ("case .problemReports:", "ProblemReportsView()"),
            ("case .pairFlow:", "PairFlowView("),
        ]

        for route in routes {
            let branch = try XCTUnwrap(viewText.range(of: route.0), "missing \(route.0)")
            let branchText = viewText[branch.lowerBound...]
            let nextBranch = branchText.dropFirst().range(of: "\n        case ")
            let body = nextBranch.map { branchText[..<$0.lowerBound] } ?? branchText
            XCTAssertTrue(body.contains(route.1), "\(route.0) does not route to \(route.1)")
        }

        XCTAssertEqual(text.components(separatedBy: "ShellPaneStub(").count - 1, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/Home/ShellPaneStub.swift").path))
    }
}
