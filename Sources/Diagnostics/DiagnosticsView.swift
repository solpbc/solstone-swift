// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct DiagnosticsView: View {
    @Environment(DiagnosticLog.self) private var log
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(VoiceManager.self) private var voiceManager
    @Environment(BrainStatusMonitor.self) private var brainStatusMonitor

    @State private var enabledCategories: Set<DiagnosticCategory> = Set(DiagnosticCategory.allCases)
    @State private var expandedEventID: UUID?
    @State private var justCopied = false
    @State private var copyTask: Task<Void, Never>?

    private var filteredEvents: [DiagnosticEvent] {
        Array(self.log.filtered(by: self.enabledCategories).reversed())
    }

    var body: some View {
        Group {
            if self.log.events.isEmpty {
                ContentUnavailableView {
                    Label("no events yet", systemImage: "clock")
                } description: {
                    Text("they'll appear as things happen.")
                }
            } else {
                List(self.filteredEvents) { event in
                    EventRow(
                        event: event,
                        isExpanded: self.expandedEventID == event.id,
                        onTap: {
                            withAnimation {
                                if self.expandedEventID == event.id {
                                    self.expandedEventID = nil
                                } else {
                                    self.expandedEventID = event.id
                                }
                            }
                        }
                    )
                }
            }
        }
        .navigationTitle("diagnostics")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        self.copySnapshot()
                    } label: {
                        if self.justCopied {
                            Label("copied", systemImage: "checkmark")
                        } else {
                            Label("copy snapshot", systemImage: "doc.on.doc")
                        }
                    }

                    Divider()

                    ForEach(DiagnosticCategory.allCases, id: \.self) { category in
                        Button {
                            if self.enabledCategories.contains(category) {
                                self.enabledCategories.remove(category)
                            } else {
                                self.enabledCategories.insert(category)
                            }
                        } label: {
                            Label(
                                category.rawValue,
                                systemImage: self.enabledCategories.contains(category) ? "checkmark.circle.fill" : "circle"
                            )
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("filter and actions")
            }
        }
        .onDisappear {
            self.copyTask?.cancel()
        }
    }

    private func copySnapshot() {
        let text = self.log.snapshot(
            tunnel: self.tunnelManager,
            voice: self.voiceManager,
            brain: self.brainStatusMonitor
        )
        UIPasteboard.general.string = text
        if UserSettings.haptics {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        self.copyTask?.cancel()
        withAnimation(.easeInOut) {
            self.justCopied = true
        }
        self.copyTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled {
                withAnimation(.easeInOut) {
                    self.justCopied = false
                }
            }
        }
    }
}

private struct EventRow: View {
    let event: DiagnosticEvent
    let isExpanded: Bool
    let onTap: () -> Void

    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self.event.timestamp, relativeTo: Date())
    }

    private var categoryIcon: (name: String, color: Color) {
        switch self.event.category {
        case .tunnel: ("antenna.radiowaves.left.and.right", .orange)
        case .voice: ("mic", .blue)
        case .network: ("wifi", .gray)
        case .upload: ("arrow.up.circle", .green)
        case .brain: ("brain", .purple)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: self.categoryIcon.name)
                    .foregroundStyle(self.categoryIcon.color)
                    .frame(width: 20)
                Text(self.event.message)
                    .font(.subheadline)
                    .lineLimit(self.isExpanded ? nil : 1)
                Spacer()
                Text(self.relativeTime)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if self.isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.event.timestamp, format: .dateTime.year().month().day().hour().minute().second())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    if let detail = self.event.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 28)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: self.onTap)
        .accessibilityLabel("\(self.event.category.rawValue): \(self.event.message), \(self.relativeTime)")
        .accessibilityHint(self.isExpanded ? "tap to collapse" : "tap to expand details")
    }
}
