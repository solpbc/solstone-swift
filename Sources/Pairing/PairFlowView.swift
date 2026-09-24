// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import SPLTunnel
import SwiftUI
import UIKit

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

/// Flips `showsStillTrying` once a connect has run long enough that a bare spinner reads as
/// silence. It only ever adds a line to the screen. It never bounds the attempt: pairing is
/// committed the moment its request is written, and abandoning one the journal already accepted
/// would strand the owner, so any deadline on the attempt itself belongs to the library that can
/// tell whether the request was sent.
@MainActor
@Observable
final class PairFlowStillTryingTimer {
    var showsStillTrying = false

    private let delay: Duration
    @ObservationIgnored
    private var task: Task<Void, Never>?

    init(delay: Duration = .seconds(8)) {
        self.delay = delay
    }

    func start() {
        guard task == nil, !showsStillTrying else {
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
            showsStillTrying = true
            task = nil
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        showsStillTrying = false
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

    /// Same router call as `classifyPastedLink`, without the loopback pre-check: a scanned QR never
    /// encodes the dashboard's own local address the way a mis-paste can, so there's no case for it.
    nonisolated enum ScannedURLOutcome: Equatable {
        case notRecognized
        case pair(PairURL)
        case routeFailure(PairURLError)
    }

    nonisolated static func classifyScannedURL(_ url: URL) -> ScannedURLOutcome {
        switch UniversalLinkRouter.route(url) {
        case nil:
            return .notRecognized
        case .success(let pairURL):
            return .pair(pairURL)
        case .failure(let error):
            return .routeFailure(error)
        }
    }

    /// The router's nil means "not a pairing link by host, scheme or path" — the same failure the
    /// paste path's `wrongHost`/`wrongScheme`/`wrongPath` message already names. A rejected scan
    /// reuses that string (CMO voice pass `req_d3zyiw6s`, 2026-05-20) rather than the paste path's
    /// "enter a valid pairing link.", which tells the owner to enter something right after they
    /// scanned. Decision: `records/decisions/260920-vpx-a-rejected-scan-shows-this-doesnt-look-like-a-pairing-link-not-enter-one.md`.
    static let scannedLinkNotRecognizedMessage = "this doesn't look like a pairing link."

    @Environment(AppConfig.self) private var appConfig
    @Environment(PairingHandoffState.self) private var handoff
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(\.scenePhase) private var scenePhase

    let onBack: () -> Void
    let onComplete: () -> Void

    @State private var coordinator = PairFlowCoordinator()
    @State private var fallbackTimer = PairFlowFallbackTimer()
    @State private var stillTryingTimer = PairFlowStillTryingTimer()
    @State private var completionGate = PairFlowCompletionGate()
    @State private var phase: PairFlowPhase = .pairing
    @State private var flowTask: Task<Void, Never>?
    @State private var mode: EntryMode = .scan
    @State private var pastedURL = ""
    @State private var errorMessage: String?
    @State private var linkAttemptInFlight = false

    var body: some View {
        OnboardingScaffold(
            title: self.scaffoldTitle,
            subtitle: self.scaffoldSubtitle,
            titleAccessibilityIdentifier: Self.titleAccessibilityIdentifier
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
                self.mode = .paste
                self.handoff.pairURLError = nil
            } else if let pairURL = self.handoff.pairURL {
                self.fallbackTimer.cancel()
                self.coordinator.hasAutoPaired = true
                self.linkAttemptInFlight = true
                self.handoff.pairURL = nil
                self.startPairing(pairURL)
            } else {
                self.startFallbackTimerIfNeeded()
            }
        }
        .onDisappear {
            self.cancelFlowTask()
            self.fallbackTimer.cancel()
            self.stillTryingTimer.reset()
        }
        .onChange(of: self.isWaitingOnPairRequest, initial: true) { _, isWaiting in
            if isWaiting {
                self.stillTryingTimer.start()
            } else {
                self.stillTryingTimer.reset()
            }
        }
        .onChange(of: self.stillTryingTimer.showsStillTrying) { _, showsStillTrying in
            // The caption appears under a title that has not changed, and VoiceOver does not
            // announce a label that changes in place.
            if showsStillTrying {
                UIAccessibility.post(notification: .announcement, argument: SourceVocabulary.pairingStillTrying)
            }
        }
        .onChange(of: self.handoff.pairURL) { _, pairURL in
            guard let pairURL else { return }
            self.fallbackTimer.cancel()
            self.linkAttemptInFlight = true
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

    /// True from the first render until a link's pairing attempt ends: the link is waiting to be
    /// consumed, or its attempt is running. `phase` stays `.pairing` for that whole attempt, and
    /// the scan screen's scanner asks for camera access the moment it mounts, even briefly, and
    /// unmounting it doesn't withdraw the request. Nothing here needs scanning, so it never shows.
    private var isPairingFromLink: Bool {
        self.linkAttemptInFlight || self.handoff.pairURL != nil || self.handoff.pairURLError != nil
    }

    private var displayedPhase: PairFlowPhase {
        Self.displayedPhase(
            self.phase,
            attemptInHand: self.isPairingFromLink || self.coordinator.state.isPairingInputInProgress
        )
    }

    /// The connecting screen while the pairing request is still out. It ends when the request
    /// returns, so the caption never shows over the short wait for the journal's mark that follows
    /// a pairing that already went through, when "still trying to reach" would be untrue.
    private var isWaitingOnPairRequest: Bool {
        self.displayedPhase == .connecting && self.coordinator.state.isPairingInputInProgress
    }

    /// `phase`, except that a pairing attempt reads as connecting for as long as it is in hand: from
    /// a link's first frame, and from the moment a scanned or pasted code's request goes out. The
    /// pairing screen has nothing left to say to an owner who has already given a code: its
    /// instruction is stale, its scanner would read the code again, and a disabled button can only
    /// repeat what the spinner says.
    nonisolated static func displayedPhase(_ phase: PairFlowPhase, attemptInHand: Bool) -> PairFlowPhase {
        if case .pairing = phase, attemptInHand {
            return .connecting
        }
        return phase
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch self.displayedPhase {
        case .pairing:
            self.pairingContent
        case .connecting:
            self.connectingContent
        case .confirm(let mark):
            self.confirmContent(mark)
        case .couldNotVerify:
            self.couldNotVerifyContent
        case .mismatch:
            self.mismatchContent
        }
    }

    @ViewBuilder
    private var pairingContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            JournalUnpairNoticeBanner()

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
                    .background(Color.deckSurface, in: ShellMetrics.cardShape)
                    .accessibilityIdentifier("pairFlow.pasteField")
                Button("pair this device") {
                    self.startPastedURL()
                }
                .buttonStyle(.borderedProminent)
                .disabled(self.pastedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
    private var couldNotVerifyContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(SourceVocabulary.journalMarkCouldNotVerifyContinue) {
                self.completeOnce()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(SourceVocabulary.journalMarkCouldNotVerifyContinueAccessibility)
            .frame(maxWidth: .infinity, minHeight: 44)

            Button(SourceVocabulary.journalMarkCouldNotVerifyCancel) {
                self.startCouldNotVerifyCancel()
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(SourceVocabulary.journalMarkCouldNotVerifyCancelAccessibility)
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

    /// The one marker every state of this screen carries, so a test can ask whether the pairing
    /// screen is up without caring which tab it is on: the simulator has no camera, so the scan tab
    /// hands over to paste on its own.
    static let titleAccessibilityIdentifier = "pairFlow.title"

    /// The title names the tab the owner is on, in the same order as the subtitle under it.
    static func pairingTitle(for mode: EntryMode) -> String {
        switch mode {
        case .scan:
            return "scan your pairing code"
        case .paste:
            return "paste your pairing link"
        }
    }

    /// Nothing under `connecting…` until a connect has gone on long enough to read as silence.
    static func connectingSubtitle(stillTrying: Bool) -> String {
        stillTrying ? SourceVocabulary.pairingStillTrying : ""
    }

    private var scaffoldTitle: String {
        switch self.displayedPhase {
        case .pairing:
            return Self.pairingTitle(for: self.mode)
        case .connecting:
            return SourceVocabulary.journalMarkConnecting
        case .confirm:
            return SourceVocabulary.journalMarkConfirmQuestion
        case .couldNotVerify:
            return SourceVocabulary.journalMarkCouldNotVerifyTitle
        case .mismatch:
            return SourceVocabulary.journalMarkMismatchTitle
        }
    }

    private var scaffoldSubtitle: String {
        switch self.displayedPhase {
        case .pairing:
            return self.subtitleForMode
        case .connecting:
            return Self.connectingSubtitle(stillTrying: self.stillTryingTimer.showsStillTrying)
        case .confirm:
            return SourceVocabulary.journalMarkConfirmSubtext
        case .couldNotVerify:
            return SourceVocabulary.journalMarkCouldNotVerifyBody
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

    private func startCouldNotVerifyCancel() {
        self.cancelFlowTask()
        self.flowTask = Task { @MainActor in
            await tearDownMismatchedPairing(
                appConfig: self.appConfig,
                tunnelManager: self.tunnelManager,
                coordinator: self.coordinator
            )
            guard !Task.isCancelled else { return }
            self.restoreScanUI()
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
        self.restoreScanUI()
    }

    private func restoreScanUI() {
        self.errorMessage = nil
        self.pastedURL = ""
        self.coordinator.hasAutoPaired = false
        self.linkAttemptInFlight = false
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
            return "on your computer, open your journal's dashboard, go to the network app, and choose \"pair a device\"."
        case .paste:
            return "on your computer, open your journal's dashboard, go to the network app, choose \"pair a device\", then copy the link."
        }
    }

    private func handle(_ url: URL) async {
        self.errorMessage = nil
        self.fallbackTimer.cancel()
        switch Self.classifyScannedURL(url) {
        case .notRecognized:
            self.errorMessage = Self.scannedLinkNotRecognizedMessage
        case .pair(let pairURL):
            await self.handle(pairURL)
        case .routeFailure(let error):
            self.errorMessage = PairFlowCoordinator.message(for: error, targetAddress: nil, interfaces: [])
        }
    }

    private func handle(_ pairURL: PairURL) async {
        let arrivedByLink = self.linkAttemptInFlight
        self.errorMessage = nil
        self.fallbackTimer.cancel()
        if pairURL.candidates.first.map({ isLoopbackHost($0.address) }) ?? false {
            self.errorMessage = PairFailureReason.loopbackAddress.message
            if arrivedByLink {
                self.endAttempt()
            }
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
            let applicator = PairFlowConfirmationApplicator(
                initialPhase: self.phase,
                completionGate: self.completionGate,
                tearDown: {}
            )
            applicator.apply(outcome)
            self.phase = applicator.phase
            self.linkAttemptInFlight = false
        } catch {
            if case .failed(let message) = self.coordinator.state {
                self.errorMessage = message
            } else {
                self.errorMessage = PairFlowCoordinator.message(for: error, targetAddress: nil, interfaces: [])
            }
            self.endAttempt()
            self.startFallbackTimerIfNeeded()
        }
    }

    /// A failed pairing attempt leaves the owner on paste with the error, whichever way it began. A
    /// link's owner didn't choose to scan, and a scan's scanner was off the screen for the wait:
    /// bringing it back while the code is still in frame would read the code again at once, and a
    /// failure that came fast would loop with its error never readable. "scan a code instead" is
    /// one tap away. A cancelled attempt is left alone, because a newer attempt may own the flag by
    /// now.
    private func endAttempt() {
        guard !Task.isCancelled else { return }
        self.linkAttemptInFlight = false
        self.mode = .paste
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
