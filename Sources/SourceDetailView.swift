// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UIKit

struct SourceDetailView: View {
    @Environment(ObserverManager.self) private var observerManager
    @Environment(ObserverRegistration.self) private var observerRegistration
    @Environment(ObserverSourcePauseState.self) private var observerSourcePauseState
    @AppStorage("sense.preferredMode") private var preferredMode = ObserverMode.meeting.rawValue
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var manifestResult: ObserverManifestResult = .loadedEmpty
    @State private var isPulsing = false

    private let manifestClient = ObserverManifestClient()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailBlock(title: "state") {
                    self.stateBlock
                }

                DetailBlock(title: "what it adds") {
                    Text(SourceVocabulary.whatItAdds)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                DetailBlock(title: "recent") {
                    self.recentBlock
                }

                DetailBlock(title: "pending & gaps") {
                    Text(SourceVocabulary.pendingSeam)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                DetailBlock(title: "remove") {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("remove") {}
                            .buttonStyle(.bordered)
                            .disabled(true)

                        Text(SourceVocabulary.removeSeam)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("audio")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: self.observerRegistration.activeLocalPort) {
            await self.loadManifest()
        }
        .onAppear {
            self.isPulsing = self.isActiveState
        }
        .onChange(of: self.isActiveState) { _, isActive in
            self.isPulsing = isActive
        }
    }
}

private extension SourceDetailView {
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

    var currentSourceState: SourceState {
        sourceState(for: self.observerManager.state, paused: self.observerSourcePauseState.isPaused)
    }

    var isJournalConnected: Bool {
        self.observerRegistration.activeLocalPort != nil
    }

    @ViewBuilder
    var stateBlock: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: self.currentSourceState.symbol)
                Text(self.currentSourceState.label)
            }
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("mode", selection: self.selectedModeBinding) {
                ForEach(ObserverMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

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
            .disabled(self.observerManager.state == .stopping || !self.isJournalConnected)

            if !self.isJournalConnected {
                Text(SourceVocabulary.notConnectedDetailHelper)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

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
                        Button("open settings") {
                            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                }
            }

            Button(self.pauseButtonLabel) {
                Task {
                    await self.handlePauseResumeTap()
                }
            }
            .buttonStyle(.bordered)
            .disabled(self.pauseButtonDisabled)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    var recentBlock: some View {
        switch self.manifestResult {
        case .loaded(let items):
            ForEach(items) { item in
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
        case .loadedEmpty:
            Text(SourceVocabulary.recentEmpty)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .failed:
            Text(SourceVocabulary.recentFailed)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
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
            "stop"
        case .error:
            "retry"
        case .idle, .starting, .stopping:
            "listen"
        }
    }

    var pauseButtonLabel: String {
        self.currentSourceState == .paused ? "resume" : "pause"
    }

    var pauseButtonDisabled: Bool {
        switch self.currentSourceState {
        case .active, .paused:
            self.observerManager.state == .stopping || !self.isJournalConnected
        case .off, .enrolling, .needsAttention:
            true
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
            self.observerSourcePauseState.isPaused = false
            await self.observerManager.startSession(mode: self.selectedModeBinding.wrappedValue)
        case .starting, .active:
            self.observerSourcePauseState.isPaused = false
            await self.observerManager.stopSession()
        case .stopping:
            break
        }
    }

    func handlePauseResumeTap() async {
        switch self.currentSourceState {
        case .active:
            await self.observerManager.stopSession()
            self.observerSourcePauseState.isPaused = true
        case .paused:
            self.observerSourcePauseState.isPaused = false
            await self.observerManager.startSession(mode: self.selectedModeBinding.wrappedValue)
        case .off, .enrolling, .needsAttention:
            break
        }
    }

    func loadManifest() async {
        guard let localPort = self.observerRegistration.activeLocalPort else {
            self.manifestResult = .loadedEmpty
            return
        }

        guard let key = try? await self.observerRegistration.ensureRegistered() else {
            self.manifestResult = .failed
            return
        }

        self.manifestResult = await self.manifestClient.fetchToday(localPort: localPort, key: key)
    }
}

private struct DetailBlock<Content: View>: View {
    let title: String
    private let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(self.title)
                .font(.custom("Comfortaa-Bold", size: 18))

            self.content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
