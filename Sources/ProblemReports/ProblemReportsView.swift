// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct ProblemReportsView: View {
    var showsSupportHeader = false
    @Environment(ProblemReportsManager.self) private var manager

    @State private var shareAllURL: URL?
    @State private var showingDeleteAllConfirm = false

    private func supportRow(glyph: String, title: String, destination: URL) -> some View {
        Link(destination: destination) {
            HStack(spacing: 14) {
                Image(systemName: glyph)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.solOrangeAdaptive)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                Text(title)
                    .font(ShellFont.tileName)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        }
        .accessibilityLabel(title)
    }

    var body: some View {
        List {
            if self.showsSupportHeader {
                // Rows, not buttons. `.bordered` inside a grouped list draws a filled
                // capsule centred in its row, so the two ways to reach support read as
                // a pair of floating chips rather than as the list they sit in.
                Section {
                    self.supportRow(
                        glyph: "lifepreserver",
                        title: SourceVocabulary.supportSiteTitle,
                        destination: URL(string: "https://support.solstone.app")!
                    )
                    self.supportRow(
                        glyph: "envelope",
                        title: SourceVocabulary.journalMarkMismatchEmailSupport,
                        destination: URL(string: "mailto:support@solstone.app")!
                    )
                }
            }

            if !self.manager.isEnabled {
                Section {
                    ProblemReportsEmptyState(
                        systemImage: "doc.text",
                        title: SourceVocabulary.problemReportsOptedOutTitle,
                        message: SourceVocabulary.problemReportsOptedOutBody,
                        accessibilityID: "problemReports.empty.optedOut"
                    )
                }
            } else if self.manager.reports.isEmpty {
                Section {
                    ProblemReportsEmptyState(
                        systemImage: "doc.text",
                        title: SourceVocabulary.problemReportsEmptyTitle,
                        message: SourceVocabulary.problemReportsEmptyBody,
                        accessibilityID: "problemReports.empty.enabled"
                    )
                }
            } else {
                ForEach(self.manager.reports) { report in
                    NavigationLink {
                        ProblemReportDetailView(reportID: report.id)
                    } label: {
                        ProblemReportRow(report: report)
                    }
                    .accessibilityIdentifier("problemReports.report.\(report.id.uuidString)")
                    .accessibilityHint(SourceVocabulary.problemReportsReportRowHint)
                    .swipeActions {
                        Button(role: .destructive) {
                            self.manager.delete(id: report.id)
                            self.refreshShareAllURL()
                        } label: {
                            Label(SourceVocabulary.problemReportsDelete, systemImage: "trash")
                        }
                    }
                }
            }
        }
        // Presented as the shelf's `help` pane, the surface already has a title in the
        // bar; setting a second one rendered `help` inline above a large `problem
        // reports`, naming one screen twice.
        .navigationTitle(self.showsSupportHeader ? "" : SourceVocabulary.problemReportsTitle)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let shareAllURL {
                    ShareLink(item: shareAllURL) {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(SourceVocabulary.problemReportsShareAll)
                    .accessibilityHint(SourceVocabulary.problemReportsShareAllHint)
                    .accessibilityIdentifier("problemReports.shareAll")
                }

                Button(role: .destructive) {
                    self.showingDeleteAllConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 44, height: 44)
                }
                .disabled(self.manager.reports.isEmpty)
                .accessibilityLabel(SourceVocabulary.problemReportsDeleteAll)
                .accessibilityHint(SourceVocabulary.problemReportsDeleteAllHint)
                .accessibilityIdentifier("problemReports.deleteAll")
            }
        }
        .alert(SourceVocabulary.problemReportsDeleteAllConfirmTitle, isPresented: self.$showingDeleteAllConfirm) {
            Button(SourceVocabulary.cancel, role: .cancel) {}
            Button(SourceVocabulary.problemReportsDeleteAll, role: .destructive) {
                self.manager.deleteAll()
                self.refreshShareAllURL()
            }
        } message: {
            Text(SourceVocabulary.problemReportsDeleteAllConfirmBody)
        }
        .onAppear {
            self.manager.refresh()
            self.refreshShareAllURL()
        }
        .onChange(of: self.manager.reports) {
            self.refreshShareAllURL()
        }
    }

    private func refreshShareAllURL() {
        guard !self.manager.reports.isEmpty else {
            self.shareAllURL = nil
            return
        }
        self.shareAllURL = self.manager.shareAllURL()
    }
}

private struct ProblemReportsEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    let accessibilityID: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: self.systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(self.title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(self.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(self.accessibilityID)
    }
}

private struct ProblemReportRow: View {
    let report: ProblemReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.report.kind.ownerLabel)
                .font(.body)
            Text(self.report.date, format: .dateTime.year().month().day().hour().minute())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
