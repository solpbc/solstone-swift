// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct ProblemReportDetailView: View {
    let reportID: UUID

    @Environment(ProblemReportsManager.self) private var manager
    @Environment(\.dismiss) private var dismiss

    @State private var shareURL: URL?

    private var report: ProblemReport? {
        self.manager.report(id: self.reportID)
    }

    var body: some View {
        Group {
            if let report {
                ScrollView {
                    Text(report.rawJSON)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
                .navigationTitle(report.kind.ownerLabel)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if let shareURL {
                            ShareLink(item: shareURL) {
                                Image(systemName: "square.and.arrow.up")
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel(SourceVocabulary.problemReportsShare)
                            .accessibilityHint(SourceVocabulary.problemReportsShareHint)
                            .accessibilityIdentifier("problemReports.share")
                        }

                        Button(role: .destructive) {
                            self.manager.delete(id: report.id)
                            self.dismiss()
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(SourceVocabulary.problemReportsDelete)
                        .accessibilityHint(SourceVocabulary.problemReportsDeleteHint)
                        .accessibilityIdentifier("problemReports.delete")
                    }
                }
                .onAppear {
                    self.refreshShareURL(report)
                }
                .onChange(of: self.manager.reports) {
                    guard let updated = self.report else {
                        self.shareURL = nil
                        return
                    }
                    self.refreshShareURL(updated)
                }
            } else {
                ContentUnavailableView(
                    SourceVocabulary.problemReportsMissingTitle,
                    systemImage: "doc.text",
                    description: Text(SourceVocabulary.problemReportsMissingBody)
                )
            }
        }
    }

    private func refreshShareURL(_ report: ProblemReport) {
        self.shareURL = self.manager.shareURL(for: report)
    }
}
