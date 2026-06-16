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
    @Environment(\.scenePhase) private var scenePhase

    let onBack: () -> Void
    let onComplete: () -> Void

    @State private var coordinator = PairFlowCoordinator()
    @State private var fallbackTimer = PairFlowFallbackTimer()
    @State private var mode: EntryMode = .scan
    @State private var pastedURL = ""
    @State private var errorMessage: String?
    @State private var didAutoPair = false

    var body: some View {
        OnboardingScaffold(
            title: "pair your solstone",
            subtitle: "scan the pairing code, or paste the pairing link from your solstone."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Picker("pairing method", selection: self.$mode) {
                    Text("scan").tag(EntryMode.scan)
                    Text("paste").tag(EntryMode.paste)
                }
                .pickerStyle(.segmented)

                switch self.mode {
                case .scan:
                    QRScannerView(
                        onURL: { url in
                            Task {
                                await self.handle(url)
                            }
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
                    Button(self.coordinator.state == .pairing ? "pairing..." : "pair this device") {
                        Task {
                            await self.handlePastedURL()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(self.pastedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.coordinator.state == .pairing)
                    .frame(maxWidth: .infinity, minHeight: 44)
                }

                if self.fallbackTimer.shouldShowPasteFallback, self.mode != .paste {
                    Button("paste a link instead") {
                        self.fallbackTimer.cancel()
                        self.mode = .paste
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
                    self.fallbackTimer.cancel()
                    self.onBack()
                }
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
        .onAppear {
            guard !self.didAutoPair else { return }
            if let pairURLError = self.handoff.pairURLError {
                self.fallbackTimer.cancel()
                self.errorMessage = PairFlowCoordinator.message(for: pairURLError, targetAddress: nil, interfaces: [])
                self.handoff.pairURLError = nil
            } else if let pairURL = self.handoff.pairURL {
                self.fallbackTimer.cancel()
                self.didAutoPair = true
                self.handoff.pairURL = nil
                Task {
                    await self.handle(pairURL)
                }
            } else {
                self.startFallbackTimerIfNeeded()
            }
        }
        .onDisappear {
            self.fallbackTimer.cancel()
        }
        .onChange(of: self.handoff.pairURL) { _, pairURL in
            guard let pairURL else { return }
            self.fallbackTimer.cancel()
            self.handoff.pairURL = nil
            Task {
                await self.handle(pairURL)
            }
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

    private func handlePastedURL() async {
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

    private func handle(_ url: URL) async {
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
        self.fallbackTimer.cancel()
        if isLoopbackHost(pairURL.addressString) {
            self.errorMessage = PairFailureReason.loopbackAddress.message
            return
        }
        do {
            try await self.coordinator.handlePairURL(pairURL)
            if let pairing = try SPLKeychain.load() {
                try self.appConfig.applyPairing(pairing)
            }
            self.errorMessage = nil
            self.onComplete()
        } catch {
            if case .failed(let message) = self.coordinator.state {
                self.errorMessage = message
            } else {
                self.errorMessage = PairFlowCoordinator.message(for: error, targetAddress: nil, interfaces: [])
            }
        }
    }

    private func startFallbackTimerIfNeeded() {
        guard self.mode == .scan,
              self.coordinator.state == .idle,
              !self.didAutoPair,
              self.handoff.pairURL == nil,
              self.handoff.pairURLError == nil
        else { return }
        self.fallbackTimer.start()
    }
}
