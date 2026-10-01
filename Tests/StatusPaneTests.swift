// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class StatusPaneTests: XCTestCase {
    func testScreenOnlyWaitingPresentationUsesScreenRouteAndAggregateTotal() {
        let presentation = StatusPaneWaitingPresentation.build(
            mobileAggregateCount: 1,
            audioCount: 0,
            locationCount: 0,
            screencastCount: 1,
            watchCount: 0
        )

        XCTAssertEqual(presentation.total, 1)
        XCTAssertEqual(presentation.rows, [StatusPaneWaitingRow(source: .screencast, count: 1)])
        XCTAssertEqual(presentation.rows.first?.route, .screencast)
        XCTAssertEqual(presentation.rows.first?.kind, .screencast)
    }

    func testMixedBundleRendersThreeFacetsWithoutTripleCountingHeadline() {
        let presentation = StatusPaneWaitingPresentation.build(
            mobileAggregateCount: 1,
            audioCount: 1,
            locationCount: 1,
            screencastCount: 1,
            watchCount: 0
        )

        XCTAssertEqual(presentation.total, 1)
        XCTAssertEqual(presentation.rows.map(\.source), [.audio, .location, .screencast])
        XCTAssertEqual(presentation.rows.map(\.route), [.audio, .location, .screencast])
        XCTAssertEqual(presentation.rows.map(\.kind), [.observer, .location, .screencast])
        XCTAssertEqual(presentation.rows.map(\.count), [1, 1, 1])
    }

    func testAddressesTriedListsEachAddressWithoutAMoreLineWhenNothingOmitted() {
        let tried = TriedAddresses(
            entries: [
                TriedAddresses.Entry(address: "192.168.1.20:7657", outcome: .couldNotProveJournal),
                TriedAddresses.Entry(address: "192.168.1.21:7657", outcome: .noAnswer),
            ],
            omittedCount: 0
        )

        XCTAssertEqual(tried.ownerLines, [
            "192.168.1.20:7657 · answered, but couldn't prove it's your journal",
            "192.168.1.21:7657 · no answer",
        ])
        XCTAssertFalse(tried.ownerLines.contains { $0.hasSuffix(" more") })
    }

    func testAddressesTriedEndsWithAndNMoreWhenOutcomesWereOmitted() {
        let entry = TriedAddresses.Entry(address: "journal-1.example:7657", outcome: .noAnswer)

        XCTAssertEqual(
            TriedAddresses(entries: [entry], omittedCount: 2).ownerLines,
            ["journal-1.example:7657 · no answer", "and 2 more"]
        )
        XCTAssertEqual(
            TriedAddresses(entries: [entry], omittedCount: 1).ownerLines.last,
            "and 1 more"
        )
    }

    func testAddressesTriedRowRendersTheOwnerLines() throws {
        let text = try String(
            contentsOf: StringLiteralGrepSupport.worktreeRoot()
                .appendingPathComponent("Sources/Home/StatusPane.swift"),
            encoding: .utf8
        )
        let row = try Self.slice(
            in: text,
            from: "Text(\"addresses tried\")",
            to: "shell.pane.status.addressesTried"
        )

        XCTAssertTrue(row.contains("tried.ownerLines"))
    }

    func testConnectionDetailsRequireAnActiveTunnelDespitePairedStaleContext() throws {
        let text = try String(
            contentsOf: StringLiteralGrepSupport.worktreeRoot()
                .appendingPathComponent("Sources/Home/StatusPane.swift"),
            encoding: .utf8
        )
        let gate = try Self.slice(
            in: text,
            from: "private var showsConnectionDetails: Bool {",
            to: "\n    private var probeDisplay"
        )
        let pane = try Self.slice(
            in: text,
            from: "private var paneContent: some View {",
            to: "\n            Section(\"diagnostics\")"
        )

        XCTAssertTrue(gate.contains("self.appConfig.isPaired && self.tunnelManager.state.isConnected"))
        XCTAssertTrue(pane.contains("if self.showsConnectionDetails {"))
        XCTAssertTrue(pane.contains("LabeledContent(\n                        \"method\","))
        XCTAssertTrue(pane.contains("LabeledContent(\"uptime\")"))
        XCTAssertTrue(pane.contains("shell.pane.status.transferRate"))
    }

    func testStallTryAgainResolution() {
        XCTAssertEqual(StatusPaneStallTryAgain.resolve(.connecting), .trying)
        XCTAssertEqual(StatusPaneStallTryAgain.resolve(.connected(localPort: 1, via: .lan)), .trying)
        XCTAssertEqual(StatusPaneStallTryAgain.resolve(.waitingForHome), .ready)
        XCTAssertEqual(StatusPaneStallTryAgain.resolve(.disconnected), .ready)
        XCTAssertEqual(StatusPaneStallTryAgain.resolve(.error(.unreachable)), .ready)
        XCTAssertEqual(StatusPaneStallTryAgain.resolve(.error(.muxTeardown)), .ready)
        XCTAssertEqual(StatusPaneStallTryAgain.resolve(.error(.revoked)), .hidden)
    }

    func testStallTryAgainPerform() {
        var readyCount = 0
        StatusPaneStallTryAgain.ready.perform { readyCount += 1 }
        XCTAssertEqual(readyCount, 1)

        var tryingCount = 0
        StatusPaneStallTryAgain.trying.perform { tryingCount += 1 }
        XCTAssertEqual(tryingCount, 0)

        var hiddenCount = 0
        StatusPaneStallTryAgain.hidden.perform { hiddenCount += 1 }
        XCTAssertEqual(hiddenCount, 0)
    }

    func testStallJournalRowsCompositionAndOrder() {
        let states: [TunnelState] = [
            .connecting,
            .connected(localPort: 1, via: .lan),
            .error(.unreachable),
            .waitingForHome,
            .disconnected,
            .error(.revoked),
        ]

        for state in states {
            for displayable in [false, true] {
                for hasAddresses in [false, true] {
                    let tryAgain = StatusPaneStallTryAgain.resolve(state)
                    let rows = StatusPaneStallJournal.rows(
                        tryAgain: tryAgain,
                        hasDisplayableLastHeard: displayable,
                        hasTriedAddresses: hasAddresses
                    )

                    var expected: [StatusPaneStallJournalRow] = []
                    if displayable {
                        expected.append(.reason)
                    }
                    if case .hidden = tryAgain {} else {
                        expected.append(.tryAgain(tryAgain))
                    }
                    expected.append(.pairAgain)
                    if hasAddresses {
                        expected.append(.addresses)
                    }

                    XCTAssertEqual(rows, expected)

                    let first = try? XCTUnwrap(rows.first)
                    if displayable {
                        XCTAssertEqual(first, .reason)
                    } else if case .hidden = tryAgain {
                        XCTAssertEqual(first, .pairAgain)
                    } else {
                        XCTAssertEqual(first, .tryAgain(tryAgain))
                    }
                }
            }
        }
    }

    func testStatusPaneLeadResolveAwaitingMarkConfirmation() {
        // N = 0
        let lead0 = StatusPaneLead.resolve(
            pillState: .awaitingMarkConfirmation,
            waitingTotal: 0,
            showsConnectionDetails: false
        )
        XCTAssertEqual(lead0.region.accessibilityIdentifier, "shell.pane.status.awaitingMarkConfirmation")
        switch lead0.lead {
        case .headline(let headline):
            XCTAssertEqual(headline, SourceVocabulary.awaitingMarkConfirmationLine)
            XCTAssertNotEqual(headline, SourceVocabulary.syncedHeadline)
        case .count:
            XCTFail("expected headline lead for N = 0")
        }
        XCTAssertEqual(lead0.subline, SourceVocabulary.awaitingMarkConfirmationSubline)
        XCTAssertEqual(lead0.buttonTitle, SourceVocabulary.confirmTheMarkAction)
        if case .confirmMark(let title, let identifier) = lead0.region {
            XCTAssertEqual(title, SourceVocabulary.confirmTheMarkAction)
            XCTAssertEqual(identifier, "shell.pane.status.awaitingMarkConfirmation")
        } else {
            XCTFail("expected confirmMark region")
        }
        XCTAssertFalse(lead0.showsStandingSyncFootnote)

        // N > 0
        let lead3 = StatusPaneLead.resolve(
            pillState: .awaitingMarkConfirmation,
            waitingTotal: 3,
            showsConnectionDetails: true
        )
        XCTAssertEqual(lead3.region.accessibilityIdentifier, "shell.pane.status.awaitingMarkConfirmation")
        switch lead3.lead {
        case .count(let count, let caption, let statusLine):
            XCTAssertEqual(count, 3)
            XCTAssertEqual(caption, SourceVocabulary.waitingToSync)
            XCTAssertEqual(statusLine, SourceVocabulary.awaitingMarkConfirmationLine)
        case .headline:
            XCTFail("expected count lead for N > 0")
        }
        XCTAssertEqual(lead3.subline, SourceVocabulary.awaitingMarkConfirmationSubline)
        XCTAssertEqual(lead3.buttonTitle, SourceVocabulary.confirmTheMarkAction)
        if case .confirmMark(let title, let identifier) = lead3.region {
            XCTAssertEqual(title, SourceVocabulary.confirmTheMarkAction)
            XCTAssertEqual(identifier, "shell.pane.status.awaitingMarkConfirmation")
        } else {
            XCTFail("expected confirmMark region")
        }
        XCTAssertFalse(lead3.showsStandingSyncFootnote)
    }

    func testStatusPaneLeadResolveNonAwaitingStates() {
        let statuses: [ConnectionSyncStatus] = [
            .offline,
            .connecting,
            .waitingForHome,
            .reconnecting,
            .unreachable,
            .connectedIdle,
            .connectedWaiting,
            .connectedTransferring,
        ]
        for isPaired in [false, true] {
            for status in statuses {
                for showsConnectionDetails in [false, true] {
                    let pill = HomeStatusPillState.resolve(
                        isPaired: isPaired,
                        status: status,
                        hasBacklog: false,
                        isStalled: false,
                        awaitingMarkConfirmation: false
                    )
                    let lead = StatusPaneLead.resolve(
                        pillState: pill,
                        waitingTotal: 0,
                        showsConnectionDetails: showsConnectionDetails
                    )
                    XCTAssertNotEqual(lead.region.accessibilityIdentifier, "shell.pane.status.awaitingMarkConfirmation")
                    XCTAssertNil(lead.subline)
                    XCTAssertNil(lead.buttonTitle)
                    if showsConnectionDetails && pill != .stalled {
                        XCTAssertTrue(lead.showsStandingSyncFootnote)
                    } else {
                        XCTAssertFalse(lead.showsStandingSyncFootnote)
                    }
                }
            }
        }

        // Stalled pill
        let stalledPill = HomeStatusPillState.resolve(
            isPaired: true,
            status: .connectedIdle,
            hasBacklog: true,
            isStalled: true,
            awaitingMarkConfirmation: false
        )
        let stalledLead = StatusPaneLead.resolve(
            pillState: stalledPill,
            waitingTotal: 2,
            showsConnectionDetails: true
        )
        XCTAssertEqual(stalledLead.region.accessibilityIdentifier, "shell.pane.status.degraded")
        XCTAssertFalse(stalledLead.showsStandingSyncFootnote)
    }

    func testStatusPaneAwaitingMarkConfirmationMarkup() throws {
        let text = try String(
            contentsOf: StringLiteralGrepSupport.worktreeRoot()
                .appendingPathComponent("Sources/Home/StatusPane.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(text.contains("shell.pane.status.awaitingMarkConfirmation"))
        XCTAssertFalse(text.contains("shell.pane.status.confirmMark"))
        XCTAssertTrue(text.contains("confirmMarkTapped()"))
        XCTAssertTrue(text.contains("leadModel.subline"))
        XCTAssertTrue(text.contains("leadModel.showsStandingSyncFootnote"))
    }

    private static func slice(in text: String, from startToken: String, to endToken: String) throws -> Substring {
        let start = try XCTUnwrap(text.range(of: startToken))
        let remaining = text[start.lowerBound...]
        let end = try XCTUnwrap(remaining.range(of: endToken))
        return text[start.lowerBound..<end.lowerBound]
    }
}
