// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import os
import SwiftUI

/// The third-party notices file the app carries, as it ships. An owner can't open an app bundle on
/// a phone, so this is how the file reaches anyone.
nonisolated enum LicensesText {
    enum Block: Equatable, Sendable {
        case heading(level: Int, String)
        case divider
        case text(String)
    }

    private static let log = Logger(subsystem: "app.solstone.swift", category: "licenses")

    static func load(bundle: Bundle = .main) -> String {
        guard let url = bundle.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            Self.log.error("third-party notices file missing from the app")
            return ""
        }
        return text
    }

    /// Reads the file line by line: heading lines lose their markers, a `---` line is a divider, and
    /// every other line is kept as it is, in runs between blank lines so VoiceOver can move through
    /// the text and the list lays out only what's on screen.
    static func blocks(of text: String) -> [Block] {
        var blocks: [Block] = []
        var run: [String] = []
        func endRun() {
            guard !run.isEmpty else { return }
            blocks.append(.text(run.joined(separator: "\n")))
            run = []
        }
        // enumerateLines, not a split on "\n": some licence texts in the file end their lines CRLF.
        text.enumerateLines { line, _ in
            if line.allSatisfy(\.isWhitespace) {
                endRun()
            } else if line == "---" {
                endRun()
                blocks.append(.divider)
            } else if let heading = Self.heading(in: line) {
                endRun()
                blocks.append(heading)
            } else {
                run.append(line)
            }
        }
        endRun()
        return blocks
    }

    private static func heading(in line: String) -> Block? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        return .heading(level: level, String(rest.dropFirst()))
    }
}

struct LicensesPane: View {
    @AccessibilityFocusState private var headingFocused: Bool
    @State private var blocks = LicensesText.blocks(of: LicensesText.load())

    var body: some View {
        // A list row's card, not the shell's ground: the ground moves through the day, and small
        // text doesn't stay readable on all of it.
        List {
            Section {
                ForEach(Array(self.blocks.enumerated()), id: \.offset) { _, block in
                    self.row(block)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                }
            }
        }
        .accessibilityIdentifier("shell.pane.licenses.text")
        .navigationTitle(Text("about.licenses"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("about.licenses")
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("shell.pane.licenses.heading")
                    .accessibilityFocused(self.$headingFocused)
            }
        }
        .onAppear { self.headingFocused = true }
    }

    @ViewBuilder
    private func row(_ block: LicensesText.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(verbatim: text)
                .font(level == 1 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
        case .divider:
            // why: a bare Divider in a list row takes the row's horizontal layout and draws upright.
            VStack(spacing: 0) { Divider() }
        case .text(let text):
            Text(verbatim: text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }
}
