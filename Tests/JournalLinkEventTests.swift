// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel
import Testing
@testable import solstone_swift

struct JournalLinkEventTests {
    @Test func peerResetReasonsStayDistinctFromCarrierLoss() {
        #expect(JournalLinkEventKind(peerReset: .streamLimitExceeded) == .streamLimitRefused)
        #expect(JournalLinkEventKind(peerReset: .internalError) == .streamReset)
        #expect(JournalLinkEventKind(peerReset: .cancel) == .streamReset)
    }

    @Test @MainActor func evidenceSurvivesLogReplacementAndBurstAndExpires() throws {
        let suite = "JournalLinkEventTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let log = DiagnosticLog(capacity: 1, defaults: defaults)
        log.noteJournalLinkEvent(.streamLimitRefused, at: now)
        log.noteJournalLinkEvent(.transportClosed, at: now.addingTimeInterval(1))
        for _ in 0..<20 { log.append(category: .upload, message: "sending") }

        let reopened = DiagnosticLog(defaults: defaults)
        #expect(Set(reopened.recentJournalLinkEvents().map(\.kind)) == [.streamLimitRefused, .transportClosed])
        #expect(reopened.journalLinkReport().contains(JournalLinkEventKind.streamLimitRefused.rawValue))
        #expect(reopened.snapshot(tunnel: TunnelManager()).contains(reopened.journalLinkReport()))
        #expect(reopened.recentJournalLinkEvents(now: now.addingTimeInterval(8 * 24 * 60 * 60)).isEmpty)
        reopened.clear()
        #expect(DiagnosticLog(defaults: defaults).recentJournalLinkEvents().isEmpty)
    }

    @Test @MainActor func historyIsBoundedToLatestOfEachKind() {
        let log = DiagnosticLog()
        let now = Date()
        for second in 0..<20 {
            log.noteJournalLinkEvent(.streamLimitRefused, at: now.addingTimeInterval(Double(second)))
        }
        log.noteJournalLinkEvent(.streamReset, at: now)
        #expect(log.recentJournalLinkEvents().count == 2)
        #expect(log.recentJournalLinkEvents().first?.timestamp == now.addingTimeInterval(19))
    }

    @Test @MainActor func supportFragmentCarriesTheSameEvidence() throws {
        let log = DiagnosticLog()
        log.noteJournalLinkEvent(.streamLimitRefused)
        let report = log.journalLinkReport()
        let url = SupportReportURL.make(version: "1", build: "1", osVersion: "", state: "", about: "", recent: report)
        let fragment = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedFragment)
        let recent = try #require(fragment.split(separator: "&").first { $0.hasPrefix("recent=") })
        let decoded = String(recent.dropFirst("recent=".count))
            .replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        #expect(decoded == report)
        #expect(url.query == nil)
    }
}
