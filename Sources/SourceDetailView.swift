// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UIKit

struct SourceDetailView: View {
    @Environment(ObserverManager.self) private var observerManager
    @Environment(MobileSegmentUploader.self) private var mobileSegmentUploader
    @Environment(ObserverRegistration.self) private var observerRegistration
    @Environment(ObserverSourcePauseState.self) private var observerSourcePauseState
    @AppStorage("sense.preferredMode") private var preferredMode = ObserverMode.meeting.rawValue
    @AppStorage(AudioStorageKey.enrolled) private var audioEnrolled = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var manifestResult: ObserverManifestResult = .loadedEmpty
    @State private var isPulsing = false
    @ScaledMetric(relativeTo: .headline) private var listenButtonSize: CGFloat = 120

    private let manifestClient = ObserverManifestClient()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if self.audioEnrolled {
                    self.enrolledContent
                } else {
                    AudioEnrollmentContent(mode: self.selectedModeBinding.wrappedValue)
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
    @ViewBuilder
    var enrolledContent: some View {
        SourceDetailBlock(title: "state") {
            self.stateBlock
        }

        SourceDetailBlock(title: "what it adds") {
            Text(SourceVocabulary.whatItAdds)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }

        SourceDetailBlock(title: "recent") {
            self.recentBlock
        }

        SourceDetailBlock(title: "delivery") {
            self.deliveryBlock
        }

        SourceDetailBlock(title: "remove") {
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

    @ViewBuilder
    var stateBlock: some View {
        VStack(spacing: 16) {
            if self.isActiveState {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color("Listening/Dot"))
                        .frame(width: 10, height: 10)
                    Text(SourceDetailPresentation.listeningIndicatorWord)
                }
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(SourceDetailPresentation.listeningIndicatorWord)
                .accessibilityIdentifier("source.listening")
            } else {
                HStack(spacing: 8) {
                    Image(systemName: self.currentSourceState.symbol)
                    Text(self.currentSourceState.label)
                }
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Picker("mode", selection: self.selectedModeBinding) {
                ForEach(ObserverMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(SourceDetailPresentation.modeExplanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

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
                                .font(.custom("Comfortaa-Bold", size: 18, relativeTo: .headline))
                        }
                        .foregroundStyle(self.buttonForeground)
                    }
                }
                .frame(width: self.listenButtonSize, height: self.listenButtonSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(self.buttonLabel)
            .accessibilityIdentifier("source.listen")
            .disabled(self.observerManager.state == .stopping)

            if let elapsedText = self.elapsedText {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color("Listening/Dot"))
                        .frame(width: 8, height: 8)
                    Text(SourceDetailPresentation.elapsedLine(formatted: elapsedText))
                        .font(.custom("Comfortaa-Bold", size: 16, relativeTo: .callout))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(SourceDetailPresentation.elapsedLine(formatted: elapsedText))
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

    var deliveryBlock: some View {
        let summary = self.mobileSegmentUploader.summary(for: .audio)
        let presentation = LocationDetailPresentation.deliverySummary(
            pending: summary.pendingCount,
            failed: summary.failedCount,
            lastUploadAt: summary.lastUploadAt
        )

        return VStack(alignment: .leading, spacing: 10) {
            Text(presentation.line)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if presentation.showsRetry {
                Button(SourceVocabulary.retry) {
                    Task {
                        await self.mobileSegmentUploader.retryFailed()
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(minWidth: 44, minHeight: 44)
            }
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
            self.observerManager.state == .stopping
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

        guard let handle = try? await self.observerRegistration.ensureRegistered() else {
            self.manifestResult = .failed
            return
        }

        self.manifestResult = await self.manifestClient.fetchToday(localPort: localPort, handle: handle)
    }
}

private struct AudioEnrollmentContent: View {
    @Environment(ObserverManager.self) private var observerManager
    @Environment(ObserverSourcePauseState.self) private var observerSourcePauseState
    @State private var isStarting = false

    private let mode: ObserverMode
    private let presentation = AudioEnrollmentPresentation.current

    init(mode: ObserverMode) {
        self.mode = mode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            self.valueBlock

            Button(self.presentation.turnOnAudio) {
                Task {
                    await self.confirm()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(self.isStarting)
            .accessibilityHint("Starts keeping audio observations on this phone.")

            if let errorMessage = self.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if self.observerManager.state == .error(.permissionDenied) {
                        Button("open settings") {
                            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .frame(minWidth: 44, minHeight: 44)
                    }
                }
            }
        }
    }
}

private extension AudioEnrollmentContent {
    var valueBlock: some View {
        Text(self.presentation.preEnrollmentValue)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityIdentifier("audioEnrollment.value")
    }

    var errorMessage: String? {
        guard case .error(let error) = self.observerManager.state else { return nil }
        return error.message
    }

    func confirm() async {
        guard !self.isStarting else { return }
        self.isStarting = true
        defer { self.isStarting = false }

        self.observerSourcePauseState.isPaused = false
        await self.observerManager.startSession(mode: self.mode)
        self.observerManager.persistEnrolledIfActive()
    }
}
