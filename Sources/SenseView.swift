// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UIKit

struct SenseView: View {
    @Environment(ObserverManager.self) private var observerManager
    @Environment(ObserverRegistration.self) private var observerRegistration
    @AppStorage("sense.preferredMode") private var preferredMode = ObserverMode.meeting.rawValue
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var manifestItems: [ObserverManifestItem] = []
    @State private var isPulsing = false
    private let manifestClient = ObserverManifestClient()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Picker("mode", selection: self.selectedModeBinding) {
                    ForEach(ObserverMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.top, 8)

                Button {
                    Task {
                        await self.handleListenTap()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(self.buttonFill)
                            .overlay {
                                Circle()
                                    .stroke(self.buttonStroke, lineWidth: self.buttonStroke == .clear ? 0 : 3)
                            }
                            .scaleEffect(self.isActiveState && self.isPulsing ? 1.05 : 1)
                            .animation(self.isActiveState ? .easeInOut(duration: 1).repeatForever(autoreverses: true) : .default, value: self.isPulsing)

                        if self.isLoadingState {
                            ProgressView()
                                .tint(.white)
                        } else {
                            VStack(spacing: 6) {
                                Image(systemName: self.buttonSymbol)
                                    .font(.system(size: 34, weight: .semibold))
                                Text(self.buttonLabel)
                                    .font(.custom("Comfortaa-Bold", size: 18))
                            }
                            .foregroundStyle(self.buttonForeground)
                        }
                    }
                    .frame(width: 120, height: 120)
                }
                .buttonStyle(.plain)
                .disabled(self.observerManager.state == .stopping)

                if let elapsedText = self.elapsedText {
                    Text(elapsedText)
                        .font(.custom("Comfortaa-Bold", size: 16))
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = self.errorMessage {
                    VStack(spacing: 8) {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        if self.observerManager.state == .error(.permissionDenied) {
                            Button("Open Settings") {
                                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Recent")
                        .font(.custom("Comfortaa-Bold", size: 20))

                    if self.manifestItems.isEmpty {
                        Text("no observations yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(self.manifestItems) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                    .font(.headline)
                                Text(item.subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
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
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 520 : .infinity)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("sense")
                    .font(.custom("Comfortaa-Bold", size: 22))
            }
        }
        .task {
            await self.loadManifest()
        }
        .onChange(of: self.observerRegistration.activeLocalPort) { _, _ in
            Task {
                await self.loadManifest()
            }
        }
        .onAppear {
            self.isPulsing = self.isActiveState
        }
        .onChange(of: self.isActiveState) { _, isActive in
            self.isPulsing = isActive
        }
    }
}

private extension SenseView {
    var selectedModeBinding: Binding<ObserverMode> {
        Binding(
            get: {
                ObserverMode(rawValue: self.preferredMode) ?? .meeting
            },
            set: { mode in
                self.preferredMode = mode.rawValue
            }
        )
    }

    var isLoadingState: Bool {
        switch self.observerManager.state {
        case .starting, .stopping:
            true
        case .idle, .active, .error:
            false
        }
    }

    var isActiveState: Bool {
        switch self.observerManager.state {
        case .active:
            true
        case .idle, .starting, .stopping, .error:
            false
        }
    }

    var buttonFill: Color {
        switch self.observerManager.state {
        case .error:
            Color(.systemBackground)
        case .idle, .starting, .active, .stopping:
            Color.solOrange
        }
    }

    var buttonStroke: Color {
        switch self.observerManager.state {
        case .error:
            .red
        case .idle, .starting, .active, .stopping:
            .clear
        }
    }

    var buttonForeground: Color {
        switch self.observerManager.state {
        case .error:
            .red
        case .idle, .starting, .active, .stopping:
            .white
        }
    }

    var buttonSymbol: String {
        switch self.observerManager.state {
        case .active:
            "stop.fill"
        case .idle, .starting, .stopping, .error:
            "ear"
        }
    }

    var buttonLabel: String {
        switch self.observerManager.state {
        case .active:
            "Stop"
        case .error:
            "Retry"
        case .idle, .starting, .stopping:
            "Listen"
        }
    }

    var elapsedText: String? {
        guard case .active(let session) = self.observerManager.state else { return nil }
        let totalSeconds = Int(session.elapsed)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var errorMessage: String? {
        guard case .error(let error) = self.observerManager.state else { return nil }
        return error.message
    }

    func handleListenTap() async {
        switch self.observerManager.state {
        case .idle, .error:
            await self.observerManager.startSession(mode: self.selectedModeBinding.wrappedValue)
        case .starting, .active:
            await self.observerManager.stopSession()
        case .stopping:
            break
        }
    }

    func loadManifest() async {
        guard let localPort = self.observerRegistration.activeLocalPort else {
            self.manifestItems = []
            return
        }

        guard let key = try? await self.observerRegistration.ensureRegistered() else {
            self.manifestItems = []
            return
        }

        self.manifestItems = await self.manifestClient.fetchToday(localPort: localPort, key: key)
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
