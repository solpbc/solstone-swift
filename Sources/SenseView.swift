// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import os

struct SenseView: View {
    enum SenseMode: String, CaseIterable, Identifiable {
        case meeting = "Meeting"
        case voiceMemo = "Voice memo"

        var id: String { self.rawValue }
    }

    @State private var mode: SenseMode = .meeting
    private let log = Logger(subsystem: "org.solpbc.solstone-swift", category: "sense")

    var body: some View {
        VStack(spacing: 24) {
            Button {
                self.log.info("sense: listen tapped")
            } label: {
                Circle()
                    .fill(Color.solOrange)
                    .frame(width: 120, height: 120)
                    .overlay {
                        Image(systemName: "ear")
                            .font(.system(size: 36))
                            .foregroundStyle(.white)
                    }
            }
            .buttonStyle(.plain)

            Picker("mode", selection: self.$mode) {
                ForEach(SenseMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 8) {
                Text("Recent")
                    .font(.headline)
                Text("no observations yet")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    SenseChip(label: "Location", systemImage: "location")
                    SenseChip(label: "Health", systemImage: "heart")
                    SenseChip(label: "Photos", systemImage: "photo")
                    SenseChip(label: "Calendar", systemImage: "calendar")
                    SenseChip(label: "Motion", systemImage: "figure.walk")
                    SenseChip(label: "Focus", systemImage: "moon")
                }
            }
            .disabled(true)
            .opacity(0.4)

            Spacer()
        }
        .padding()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("sense")
                    .font(.custom("Comfortaa", size: 22).weight(.bold))
            }
        }
    }
}

private struct SenseChip: View {
    let label: String
    let systemImage: String

    var body: some View {
        Label(self.label, systemImage: self.systemImage)
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground), in: Capsule())
    }
}
