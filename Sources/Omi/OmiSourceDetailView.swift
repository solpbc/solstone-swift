// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct OmiSourceDetailView: View {
    @Environment(OmiSourceManager.self) private var manager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var diagnosticsExportURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if self.manager.enabled {
                    self.enabledContent
                } else {
                    self.offContent
                }
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("omi pendant")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            self.refreshDiagnosticsExport()
        }
    }
}

private extension OmiSourceDetailView {
    @ViewBuilder
    var enabledContent: some View {
        SourceDetailBlock(title: "state") {
            self.stateBlock
        }

        SourceDetailBlock(title: "pendant") {
            self.pendantBlock
        }

        SourceDetailBlock(title: "diagnostics") {
            self.diagnosticsBlock
        }
    }

    var offContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("adds pendant audio while this is on. turn it on when you want solstone alongside you.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            SourceDetailBlock(title: "state") {
                VStack(alignment: .leading, spacing: 12) {
                    self.stateLine
                    self.toggleButton
                }
            }
        }
    }

    var stateBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            self.stateLine

            let mapped = self.mappedState
            Text(mapped.state.subtext(activeSubtext: "pendant connected"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let attention = mapped.attention {
                Text(attention.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            self.toggleButton
        }
    }

    var stateLine: some View {
        let sourceState = self.mappedState.state
        return HStack(spacing: 8) {
            Image(systemName: sourceState.symbol)
            Text(sourceState.label)
        }
        .font(.headline)
    }

    var toggleButton: some View {
        Button(self.manager.enabled ? "turn off" : "turn on") {
            if self.manager.enabled {
                self.manager.disable()
            } else {
                self.manager.enable()
            }
            self.refreshDiagnosticsExport()
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityHint(self.manager.enabled ? "turns off omi pendant audio." : "starts omi pendant audio for your journal.")
    }

    var pendantBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("name", value: self.manager.connectedPeripheralName ?? "not connected")
            LabeledContent("signal", value: self.manager.connectedRSSI.map { "\($0)" } ?? "unknown")
            LabeledContent("battery", value: self.batteryText)
        }
        .font(.subheadline)
    }

    var diagnosticsBlock: some View {
        let payload = self.manager.diagnostics.payload
        let rows = OmiDiagnosticsLogic.diagnosticRows(payload: payload, asOf: Date())
        return VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup("technical detail") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows, id: \.label) { row in
                        LabeledContent(row.label, value: row.value)
                    }
                }
            }

            if let diagnosticsExportURL {
                ShareLink(item: diagnosticsExportURL) {
                    Label("share diagnostics", systemImage: "square.and.arrow.up")
                }
                .frame(minHeight: 44)
                .accessibilityHint("shares omi pendant diagnostics.")
            } else {
                Button {
                    self.refreshDiagnosticsExport()
                } label: {
                    Label("share diagnostics", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityHint("prepares omi pendant diagnostics.")
            }
        }
        .font(.subheadline)
    }

    var mappedState: (state: SourceState, attention: SourceAttention?) {
        omiSourceState(for: self.manager.connectionState, enabled: self.manager.enabled)
    }

    var batteryText: String {
        switch self.manager.battery {
        case .value(let level):
            "\(level)%"
        case .notRead, .unavailable:
            self.manager.battery.placeholderText ?? "unknown"
        }
    }

    func refreshDiagnosticsExport() {
        self.diagnosticsExportURL = self.manager.diagnostics.exportFileURL()
    }
}
