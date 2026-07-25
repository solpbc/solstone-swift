// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import SPLTunnel
import SwiftUI

@MainActor
@Observable
final class PairingHandoffState {
    var pairURL: PairURL?
    var pairURLError: PairURLError?
}

@MainActor
@Observable
final class PairFlowFallbackTimer {
    var shouldShowPasteFallback = false

    private let delay: Duration
    @ObservationIgnored
    private var task: Task<Void, Never>?

    init(delay: Duration = .seconds(5)) {
        self.delay = delay
    }

    func start() {
        guard task == nil, !shouldShowPasteFallback else {
            return
        }
        task = Task { @MainActor in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            shouldShowPasteFallback = true
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func reset() {
        cancel()
        shouldShowPasteFallback = false
    }
}

struct PairFlowView: View {
    enum EntryMode: String, CaseIterable, Identifiable {
        case scan
        case paste

        var id: String { rawValue }
    }

    private enum Phase: Equatable {
        case pairing
        case connecting
        case confirm(JournalMark)
        case mismatch
    }

    nonisolated enum PastedLinkOutcome: Equatable {
        case loopback
        case pair(PairURL)
        case routeFailure(PairURLError)
        case invalid
    }

    nonisolated static func classifyPastedLink(_ raw: String) -> PastedLinkOutcome {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isLoopbackHost(trimmed) {
            return .loopback
        }
        guard let url = URL(string: trimmed) else {
            return .invalid
        }
        switch UniversalLinkRouter.route(url) {
        case nil:
            return .invalid
        case .success(let pairURL):
            return .pair(pairURL)
        case .failure(let error):
            return .routeFailure(error)
        }
    }

    @Environment(AppConfig.self) private var appConfig
    @Environment(PairingHandoffState.self) private var handoff
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(\.scenePhase) private var scenePhase

    let onBack: () -> Void
    let onComplete: () -> Void

    @State private var coordinator = PairFlowCoordinator()
    @State private var fallbackTimer = PairFlowFallbackTimer()
    @State private var completionGate = PairFlowCompletionGate()
    @State private var phase: Phase = .pairing
    @State private var flowTask: Task<Void, Never>?
    @State private var mode: EntryMode = .scan
    @State private var pastedURL = ""
    @State private var errorMessage: String?

    var body: some View {
        OnboardingScaffold(
            title: self.scaffoldTitle,
            subtitle: self.scaffoldSubtitle
        ) {
            self.phaseContent
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-test-mark-confirm") {
                self.cancelFlowTask()
                self.fallbackTimer.cancel()
                self.coordinator.hasAutoPaired = true
                self.phase = .confirm(.uiTestSample)
                return
            }
            #endif
            guard !self.coordinator.hasAutoPaired else { return }
            if let pairURLError = self.handoff.pairURLError {
                self.fallbackTimer.cancel()
                self.errorMessage = PairFlowCoordinator.message(for: pairURLError, targetAddress: nil, interfaces: [])
                self.handoff.pairURLError = nil
            } else if let pairURL = self.handoff.pairURL {
                self.fallbackTimer.cancel()
                self.coordinator.hasAutoPaired = true
                self.handoff.pairURL = nil
                self.startPairing(pairURL)
            } else {
                self.startFallbackTimerIfNeeded()
            }
        }
        .onDisappear {
            self.cancelFlowTask()
            self.fallbackTimer.cancel()
        }
        .onChange(of: self.handoff.pairURL) { _, pairURL in
            guard let pairURL else { return }
            self.fallbackTimer.cancel()
            self.handoff.pairURL = nil
            self.startPairing(pairURL)
        }
        .onChange(of: self.handoff.pairURLError) { _, pairURLError in
            guard let pairURLError else { return }
            self.fallbackTimer.cancel()
            self.errorMessage = PairFlowCoordinator.message(for: pairURLError, targetAddress: nil, interfaces: [])
            self.handoff.pairURLError = nil
        }
        .onChange(of: self.mode) { _, mode in
            if mode == .scan {
                self.startFallbackTimerIfNeeded()
            } else {
                self.fallbackTimer.cancel()
            }
        }
        .onChange(of: self.scenePhase) { _, phase in
            switch phase {
            case .active:
                self.startFallbackTimerIfNeeded()
            case .background, .inactive:
                self.fallbackTimer.cancel()
            @unknown default:
                break
            }
        }
    }

    private func selectMode(_ newMode: EntryMode) {
        self.errorMessage = nil
        self.mode = newMode
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch self.phase {
        case .pairing:
            self.pairingContent
        case .connecting:
            self.connectingContent
        case .confirm(let mark):
            self.confirmContent(mark)
        case .mismatch:
            self.mismatchContent
        }
    }

    @ViewBuilder
    private var pairingContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker(
                "pairing method",
                selection: Binding(
                    get: { self.mode },
                    set: { self.selectMode($0) }
                )
            ) {
                Text("scan").tag(EntryMode.scan)
                Text("paste").tag(EntryMode.paste)
            }
            .pickerStyle(.segmented)

            switch self.mode {
            case .scan:
                QRScannerView(
                    onURL: { url in
                        self.startPairing(url)
                    },
                    onUnavailable: {
                        self.errorMessage = "camera access is unavailable on this device. paste a pairing link instead."
                        self.fallbackTimer.cancel()
                        self.mode = .paste
                    }
                )
                .frame(minHeight: 320)
            case .paste:
                TextField("https://go.solstone.app/p#...", text: self.$pastedURL, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                Button(self.pairButtonTitle) {
                    self.startPastedURL()
                }
                .buttonStyle(.borderedProminent)
                .disabled(self.pastedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.coordinator.state.isPairingInputInProgress)
                .frame(maxWidth: .infinity, minHeight: 44)
                Button("scan a code instead") {
                    self.selectMode(.scan)
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, minHeight: 44)
            }

            if self.fallbackTimer.shouldShowPasteFallback, self.mode != .paste {
                Button("paste a link instead") {
                    self.fallbackTimer.cancel()
                    self.selectMode(.paste)
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, minHeight: 44)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.body)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Pairing error: \(errorMessage)")
            }

            Button("back") {
                self.cancelFlowTask()
                self.fallbackTimer.cancel()
                self.onBack()
            }
            .frame(minWidth: 44, minHeight: 44)
        }
    }

    @ViewBuilder
    private var connectingContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProgressView()
            Button("back") {
                self.cancelFlowTask()
                self.fallbackTimer.cancel()
                self.onBack()
            }
            .frame(minWidth: 44, minHeight: 44)
        }
    }

    @ViewBuilder
    private func confirmContent(_ mark: JournalMark) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            JournalMarkView(mark: mark)
                .frame(maxWidth: .infinity, alignment: .center)

            Button(SourceVocabulary.journalMarkConfirmButton) {
                self.completeOnce()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, minHeight: 44)

            Button(SourceVocabulary.journalMarkMismatchButton) {
                self.startMismatchTeardown()
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    @ViewBuilder
    private var mismatchContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(SourceVocabulary.journalMarkMismatchScanAgain) {
                self.resetForScan()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, minHeight: 44)

            Link(
                SourceVocabulary.journalMarkMismatchEmailSupport,
                destination: URL(string: "mailto:support@solstone.app")!
            )
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    private var scaffoldTitle: String {
        switch self.phase {
        case .pairing:
            return "scan your pairing code"
        case .connecting:
            return SourceVocabulary.journalMarkConnecting
        case .confirm:
            return SourceVocabulary.journalMarkConfirmQuestion
        case .mismatch:
            return SourceVocabulary.journalMarkMismatchTitle
        }
    }

    private var scaffoldSubtitle: String {
        switch self.phase {
        case .pairing:
            return self.subtitleForMode
        case .connecting:
            return ""
        case .confirm:
            return SourceVocabulary.journalMarkConfirmSubtext
        case .mismatch:
            return SourceVocabulary.journalMarkMismatchBody
        }
    }

    private func startPairing(_ url: URL) {
        self.cancelFlowTask()
        self.flowTask = Task { @MainActor in
            await self.handle(url)
        }
    }

    private func startPairing(_ pairURL: PairURL) {
        self.cancelFlowTask()
        self.flowTask = Task { @MainActor in
            await self.handle(pairURL)
        }
    }

    private func startPastedURL() {
        self.cancelFlowTask()
        self.flowTask = Task { @MainActor in
            await self.handlePastedURL()
        }
    }

    private func startMismatchTeardown() {
        self.cancelFlowTask()
        self.flowTask = Task { @MainActor in
            await tearDownMismatchedPairing(
                appConfig: self.appConfig,
                tunnelManager: self.tunnelManager,
                coordinator: self.coordinator
            )
            guard !Task.isCancelled else { return }
            self.phase = .mismatch
        }
    }

    private func cancelFlowTask() {
        self.flowTask?.cancel()
        self.flowTask = nil
    }

    private func completeOnce() {
        self.completionGate.completeOnce {
            self.onComplete()
        }
    }

    private func resetForScan() {
        self.cancelFlowTask()
        self.errorMessage = nil
        self.pastedURL = ""
        self.coordinator.hasAutoPaired = false
        self.phase = .pairing
        self.selectMode(.scan)
    }

    private func handlePastedURL() async {
        self.errorMessage = nil
        self.fallbackTimer.cancel()
        switch Self.classifyPastedLink(self.pastedURL) {
        case .loopback:
            self.errorMessage = PairFailureReason.loopbackAddress.message
        case .invalid:
            self.errorMessage = "enter a valid pairing link."
        case .pair(let pairURL):
            await self.handle(pairURL)
        case .routeFailure(let error):
            self.errorMessage = PairFlowCoordinator.message(for: error, targetAddress: nil, interfaces: [])
        }
    }

    private var subtitleForMode: String {
        switch self.mode {
        case .scan:
            return "on your computer, open your journal's dashboard and go to the network app — it shows your pairing code."
        case .paste:
            return "copy the pairing link from your journal's network app and paste it here."
        }
    }

    private var pairButtonTitle: String {
        switch self.coordinator.state {
        case .pairing:
            return "pairing..."
        case .reconnecting:
            return SourceVocabulary.pairingReconnecting
        case .idle, .scanning, .failed, .connected, .alreadyConnected, .reconnected:
            return "pair this device"
        }
    }

    private func handle(_ url: URL) async {
        self.errorMessage = nil
        self.fallbackTimer.cancel()
        guard let result = UniversalLinkRouter.route(url) else {
            self.errorMessage = "enter a valid pairing link."
            return
        }
        switch result {
        case .success(let pairURL):
            await self.handle(pairURL)
        case .failure(let error):
            self.errorMessage = PairFlowCoordinator.message(for: error, targetAddress: nil, interfaces: [])
        }
    }

    private func handle(_ pairURL: PairURL) async {
        self.errorMessage = nil
        self.fallbackTimer.cancel()
        if pairURL.candidates.first.map({ isLoopbackHost($0.address) }) ?? false {
            self.errorMessage = PairFailureReason.loopbackAddress.message
            return
        }
        do {
            try await self.coordinator.handlePairURL(pairURL)
            if let pairing = try SPLRuntime.keychainStore.load() {
                try self.appConfig.applyPairing(pairing)
            }
            guard !Task.isCancelled else { return }
            self.phase = .connecting
            let fetcher = JournalIdentityFetcher()
            let outcome = await resolveConfirmation(
                connectedPort: {
                    if case .connected(let port, _) = self.tunnelManager.state {
                        return port
                    }
                    return nil
                },
                fetchMark: { port in
                    await fetcher.fetch(localPort: port)
                }
            )
            guard !Task.isCancelled else { return }
            self.errorMessage = nil
            switch outcome {
            case .confirm(let mark):
                self.phase = .confirm(mark)
            case .fallback(.cancelled):
                break
            case .fallback:
                self.completeOnce()
            }
        } catch {
            if case .failed(let message) = self.coordinator.state {
                self.errorMessage = message
            } else {
                self.errorMessage = PairFlowCoordinator.message(for: error, targetAddress: nil, interfaces: [])
            }
            self.startFallbackTimerIfNeeded()
        }
    }

    private func startFallbackTimerIfNeeded() {
        guard self.mode == .scan,
              self.coordinator.canStartPairingInput,
              !self.coordinator.hasAutoPaired,
              self.handoff.pairURL == nil,
              self.handoff.pairURLError == nil
        else { return }
        self.fallbackTimer.start()
    }
}
