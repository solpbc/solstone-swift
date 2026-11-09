// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation
import Observation
import SPLMark
import SPLTunnel
import SwiftUI
import UIKit

@MainActor
@Observable
final class PairingHandoffState {
    var pairURL: PairURL?
    var pairURLError: PairURLError?
    var stagedDraft: String?
    var externalLinkAttemptInFlight = false
    var heldMarkConfirmation = false
    var pairingInProgress = false
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
    nonisolated enum PairFlowStart: Equatable, Sendable {
        case ceremony
        case confirmHeldJournal
    }

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
        let urlToRoute: URL
        if let canonical = PairAliasNormalizer.canonicalURL(from: trimmed) {
            urlToRoute = canonical
        } else if let url = URL(string: trimmed) {
            urlToRoute = url
        } else {
            return .invalid
        }
        switch UniversalLinkRouter.route(urlToRoute) {
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
    /// reuses that string rather than the paste path's "enter a valid pairing link.", which tells
    /// the owner to enter something right after they scanned. A rejected scan shows "this doesn't
    /// look like a pairing link.", not a prompt to enter one.
    static let scannedLinkNotRecognizedMessage = "this doesn't look like a pairing link."

    /// Why the scanner can't run. A denial is the owner's own setting, so it says where to change
    /// it; only a device that truly can't scan is told the camera is unavailable.
    nonisolated static func cameraUnavailableMessage(for status: AVAuthorizationStatus) -> String {
        switch status {
        case .denied:
            "camera access is off for solstone. turn it on in settings, or paste a pairing link instead."
        case .restricted:
            "camera access isn't allowed on this device. paste a pairing link instead."
        default:
            "the camera isn't available on this device. paste a pairing link instead."
        }
    }

    @Environment(AppConfig.self) private var appConfig
    @Environment(JournalSendRelease.self) private var journalSendRelease
    @Environment(PairFlowPresence.self) private var presence
    @Environment(PairingHandoffState.self) private var handoff
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(\.scenePhase) private var scenePhase

    var startMode: PairFlowStart = .ceremony
    let onBack: @MainActor () -> Void
    let onComplete: @MainActor () -> Void
    private let onRenderPhase: ((PairFlowPhase) -> Void)?
    private let onScanPhaseMounted: (() -> Void)?

    @State private var coordinator: PairFlowCoordinator
    @State private var fallbackTimer = PairFlowFallbackTimer()
    @State private var stillTryingTimer = PairFlowStillTryingTimer()
    @State private var completionGate = PairFlowCompletionGate()
    @State private var phase: PairFlowPhase
    @State private var flowTask: Task<Void, Never>?
    @State private var flowGeneration = 0
    @State private var mode: EntryMode = .scan
    @State private var pastedURL = ""
    @State private var errorMessage: String?
    @State private var cameraDenied = false
    @State private var linkAttemptInFlight = false
    @State private var isDismissing = false
    @State private var teardown = PairFlowTeardownState.idle
    @State private var answerNotSaved = false

    init(
        startMode: PairFlowStart = .ceremony,
        pairOperation: PairOperation? = nil,
        onRenderPhase: ((PairFlowPhase) -> Void)? = nil,
        onScanPhaseMounted: (() -> Void)? = nil,
        onBack: @escaping @MainActor () -> Void,
        onComplete: @escaping @MainActor () -> Void = {}
    ) {
        self.startMode = startMode
        self.onBack = onBack
        self.onComplete = onComplete
        self.onRenderPhase = onRenderPhase
        self.onScanPhaseMounted = onScanPhaseMounted
        self._coordinator = State(initialValue: PairFlowCoordinator(pairOperation: pairOperation))
        self._phase = State(initialValue: startMode == .confirmHeldJournal ? .connecting : .pairing)
    }

    var body: some View {
        let _ = self.onRenderPhase?(self.displayedPhase)
        OnboardingScaffold(
            title: self.scaffoldTitle,
            subtitle: self.scaffoldSubtitle,
            titleAccessibilityIdentifier: Self.titleAccessibilityIdentifier
        ) {
            self.phaseContent
        }
        .onAppear {
            self.presence.increment()
            self.updateHandoffFlags()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-test-mark-confirm") {
                self.cancelFlowTask()
                self.fallbackTimer.cancel()
                self.coordinator.hasAutoPaired = true
                self.phase = Self.uiTestMarkPhase(arguments: ProcessInfo.processInfo.arguments)
                return
            }
            #endif
            if self.startMode == .confirmHeldJournal {
                self.startConfirmHeldJournal()
                return
            }
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
                self.prefillStagedDraftIfNeeded()
                self.startFallbackTimerIfNeeded()
            }
        }
        .onDisappear {
            self.presence.decrement()
            self.cancelFlowTask()
            self.coordinator.dropHeldReplacement()
            self.fallbackTimer.cancel()
            self.stillTryingTimer.reset()
            self.clearHandoffFlags()
        }
        .onChange(of: self.linkAttemptInFlight) { _, _ in
            self.updateHandoffFlags()
        }
        .onChange(of: self.phase) { _, _ in
            self.updateHandoffFlags()
        }
        .onChange(of: self.coordinator.state) { _, _ in
            self.updateHandoffFlags()
        }
        .onChange(of: self.handoff.stagedDraft) { _, _ in
            self.prefillStagedDraftIfNeeded()
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
            guard !self.isDismissing, let pairURL else { return }
            self.fallbackTimer.cancel()
            self.linkAttemptInFlight = true
            self.handoff.pairURL = nil
            self.startPairing(pairURL)
        }
        .onChange(of: self.handoff.pairURLError) { _, pairURLError in
            guard !self.isDismissing, let pairURLError else { return }
            self.fallbackTimer.cancel()
            self.mode = .paste
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
        self.cameraDenied = false
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
            self.goAheadContent
        case .mismatch:
            self.mismatchContent
        case .notChanged:
            self.notChangedContent
        }
    }

    @ViewBuilder
    private var pairingContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker(
                "pairing method",
                selection: Binding(
                    get: { self.entryMode },
                    set: { self.selectMode($0) }
                )
            ) {
                Text("scan").tag(EntryMode.scan)
                Text("paste").tag(EntryMode.paste)
            }
            .pickerStyle(.segmented)

            switch self.entryMode {
            case .scan:
                QRScannerView(
                    onURL: { url in
                        self.startPairing(url)
                    },
                    onUnavailable: {
                        let status = AVCaptureDevice.authorizationStatus(for: .video)
                        self.errorMessage = Self.cameraUnavailableMessage(for: status)
                        self.cameraDenied = status == .denied
                        self.fallbackTimer.cancel()
                        self.mode = .paste
                    }
                )
                .frame(minHeight: 320)
                .onAppear { self.onScanPhaseMounted?() }
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
                .buttonStyle(BrandProminentButtonStyle())
                .disabled(self.pastedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .frame(maxWidth: .infinity, minHeight: 44)
                Button("scan a code instead") {
                    self.selectMode(.scan)
                }
                .buttonStyle(BrandQuietButtonStyle())
                .frame(maxWidth: .infinity, minHeight: 44)
            }

            if self.fallbackTimer.shouldShowPasteFallback, self.mode != .paste {
                Button("paste a link instead") {
                    self.fallbackTimer.cancel()
                    self.selectMode(.paste)
                }
                .buttonStyle(BrandProminentButtonStyle())
                .frame(maxWidth: .infinity, minHeight: 44)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.body)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Pairing error: \(errorMessage)")
            }

            if self.cameraDenied {
                Button("open settings") {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                }
                .buttonStyle(BrandQuietButtonStyle())
                .frame(maxWidth: .infinity, minHeight: 44)
            }

            Button("back") {
                self.cancelFlowTask()
                self.fallbackTimer.cancel()
                self.goBack()
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
                self.goBack()
            }
            .frame(minWidth: 44, minHeight: 44)
        }
    }

    @ViewBuilder
    private func confirmContent(_ mark: JournalMark) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            JournalMarkView(identity: .mark(mark))
                .frame(maxWidth: .infinity, alignment: .center)

            self.answerFeedback

            Button(SourceVocabulary.journalMarkConfirmButton) {
                self.recordAnswer()
            }
            .buttonStyle(BrandProminentButtonStyle())
            .disabled(self.teardown == .inProgress)
            .accessibilityIdentifier("pairFlow.answer.confirm")
            .frame(maxWidth: .infinity, minHeight: 44)

            Button(SourceVocabulary.journalMarkMismatchButton) {
                self.startMismatchTeardown()
            }
            .buttonStyle(BrandQuietButtonStyle())
            .disabled(self.teardown == .inProgress)
            .accessibilityIdentifier("pairFlow.answer.mismatch")
            .frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    /// What this screen says while answering takes a moment, and when it could not finish. A
    /// rejection is the worst moment to look like nothing happened.
    @ViewBuilder
    private var answerFeedback: some View {
        switch self.teardown {
        case .idle:
            if self.answerNotSaved {
                Text(SourceVocabulary.journalMarkAnswerNotSaved)
                    .font(.body)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(Self.answerNotSavedAccessibilityIdentifier)
            }
        case .inProgress:
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityIdentifier(Self.teardownProgressAccessibilityIdentifier)
        case .failed:
            Text(SourceVocabulary.journalMarkTeardownFailed)
                .font(.body)
                .foregroundStyle(.red)
                .accessibilityIdentifier(Self.teardownErrorAccessibilityIdentifier)
        }
    }

    @ViewBuilder
    private var goAheadContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            JournalMarkView(identity: .unavailable)
                .frame(maxWidth: .infinity, alignment: .center)

            self.answerFeedback

            Button(SourceVocabulary.journalMarkCouldNotVerifyContinue) {
                self.recordAnswer()
            }
            .buttonStyle(BrandProminentButtonStyle())
            .disabled(self.teardown == .inProgress)
            .accessibilityLabel(SourceVocabulary.journalMarkCouldNotVerifyContinueAccessibility)
            .frame(maxWidth: .infinity, minHeight: 44)

            Button(SourceVocabulary.journalMarkCouldNotVerifyCancel) {
                self.startCouldNotVerifyCancel()
            }
            .buttonStyle(BrandQuietButtonStyle())
            .disabled(self.teardown == .inProgress)
            .accessibilityLabel(SourceVocabulary.journalMarkCouldNotVerifyCancelAccessibility)
            .accessibilityIdentifier("pairFlow.answer.cancel")
            .frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    @ViewBuilder
    private var mismatchContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(SourceVocabulary.journalMarkMismatchScanAgain) {
                self.resetForScan()
            }
            .buttonStyle(BrandProminentButtonStyle())
            .frame(maxWidth: .infinity, minHeight: 44)

            Link(
                SourceVocabulary.journalMarkMismatchEmailSupport,
                destination: URL(string: "mailto:support@solstone.app")!
            )
            .buttonStyle(BrandQuietButtonStyle())
            .frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    @ViewBuilder
    private var notChangedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            self.mismatchContent
            Button("back") {
                self.goBack()
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityIdentifier("pairFlow.notChanged.back")
        }
    }

    /// The one marker every state of this screen carries, so a test can ask whether the pairing
    /// screen is up without caring which tab it is on: the simulator has no camera, so the scan tab
    /// hands over to paste on its own.
    static let titleAccessibilityIdentifier = "pairFlow.title"
    static let teardownProgressAccessibilityIdentifier = "pairFlow.teardown.progress"
    static let teardownErrorAccessibilityIdentifier = "pairFlow.teardown.error"
    static let answerNotSavedAccessibilityIdentifier = "pairFlow.answer.notSaved"

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
            return Self.pairingTitle(for: self.entryMode)
        case .connecting:
            return SourceVocabulary.journalMarkConnecting
        case .confirm:
            return SourceVocabulary.journalMarkConfirmQuestion
        case .couldNotVerify:
            return SourceVocabulary.journalMarkCouldNotVerifyTitle
        case .mismatch:
            return SourceVocabulary.journalMarkMismatchTitle
        case .notChanged:
            return String(localized: "pair_flow.not_changed.title")
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
        case .notChanged:
            return String(localized: "pair_flow.not_changed.body")
        }
    }

    private func startPairing(_ url: URL) {
        self.cancelFlowTask()
        let generation = self.flowGeneration
        self.flowTask = Task { @MainActor in
            defer {
                if self.flowGeneration == generation { self.flowTask = nil }
            }
            await self.handle(url)
        }
    }

    private func startPairing(_ pairURL: PairURL) {
        self.cancelFlowTask()
        let generation = self.flowGeneration
        self.flowTask = Task { @MainActor in
            defer {
                if self.flowGeneration == generation { self.flowTask = nil }
            }
            await self.handle(pairURL)
        }
    }

    private var isHeldMarkPhase: Bool {
        if self.startMode == .confirmHeldJournal { return true }
        switch self.phase {
        case .confirm, .couldNotVerify:
            return true
        default:
            return false
        }
    }

    private func updateHandoffFlags() {
        self.handoff.externalLinkAttemptInFlight = self.linkAttemptInFlight
        self.handoff.heldMarkConfirmation = self.isHeldMarkPhase
        self.handoff.pairingInProgress = self.coordinator.state.isPairingInputInProgress
    }

    private func clearHandoffFlags() {
        self.handoff.externalLinkAttemptInFlight = false
        self.handoff.heldMarkConfirmation = false
        self.handoff.pairingInProgress = false
    }

    private func prefillStagedDraftIfNeeded() {
        guard !self.isDismissing,
              !self.linkAttemptInFlight,
              !self.isHeldMarkPhase,
              !self.coordinator.state.isPairingInputInProgress,
              self.flowTask == nil,
              let draft = self.handoff.stagedDraft
        else { return }
        self.pastedURL = draft
        self.mode = .paste
        self.errorMessage = nil
        self.fallbackTimer.cancel()
        self.handoff.stagedDraft = nil
    }

    private func startPastedURL() {
        self.handoff.stagedDraft = nil
        self.cancelFlowTask()
        let generation = self.flowGeneration
        self.flowTask = Task { @MainActor in
            defer {
                if self.flowGeneration == generation { self.flowTask = nil }
            }
            await self.handlePastedURL()
        }
    }

    private func startMismatchTeardown() {
        if self.declineHeldReplacement() { return }
        self.startTeardown { self.phase = .mismatch }
    }

    private func startCouldNotVerifyCancel() {
        if self.declineHeldReplacement() { return }
        self.startTeardown { self.restoreScanUI() }
    }

    /// A held replacement has nothing to tear down. `false` when the question is about the stored
    /// pairing, which still ends the usual way.
    private func declineHeldReplacement() -> Bool {
        guard self.coordinator.heldReplacement != nil else { return false }
        self.cancelFlowTask()
        self.coordinator.dropHeldReplacement()
        self.answerNotSaved = false
        self.linkAttemptInFlight = false
        self.phase = .notChanged
        return true
    }

    /// Both answers that end the pairing share this: progress from the tap, and either the next
    /// screen or a line saying it didn't finish, with the buttons live again to retry.
    private func startTeardown(onTornDown: @escaping @MainActor () -> Void) {
        self.cancelFlowTask()
        self.answerNotSaved = false
        self.teardown = .inProgress
        let generation = self.flowGeneration
        self.flowTask = Task { @MainActor in
            defer {
                if self.flowGeneration == generation { self.flowTask = nil }
            }
            let didTearDown = await self.tearDownPairing()
            guard !Task.isCancelled else { return }
            guard didTearDown else {
                self.teardown = .failed
                // The line appears away from the button the owner just tapped, and VoiceOver does
                // not move to it on its own.
                UIAccessibility.post(notification: .announcement, argument: SourceVocabulary.journalMarkTeardownFailed)
                return
            }
            self.teardown = .idle
            onTornDown()
        }
    }

    private func tearDownPairing() async -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(Self.uiTestTeardownFailsArgument) {
            try? await Task.sleep(for: .seconds(2))
            return false
        }
        #endif
        return await tearDownMismatchedPairing(
            appConfig: self.appConfig,
            tunnelManager: self.tunnelManager,
            coordinator: self.coordinator
        )
    }

    private func cancelFlowTask() {
        self.flowGeneration &+= 1
        self.flowTask?.cancel()
        self.flowTask = nil
        self.teardown = .idle
    }

    private func goBack() {
        self.isDismissing = true
        self.handoff.stagedDraft = nil
        self.handoff.pairURLError = nil
        self.onBack()
    }

    private var entryMode: EntryMode {
        self.handoff.stagedDraft != nil || self.handoff.pairURLError != nil ? .paste : self.mode
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
        switch self.entryMode {
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
            let committed = try await self.coordinator.handlePairURL(pairURL, shouldCommit: { !Task.isCancelled })
            guard committed else { return }
            if let held = self.coordinator.heldReplacement {
                self.phase = .connecting
                await self.askAboutMark(caChainPEM: held.pairing.caChainPEM, keepingMark: false)
                guard !Task.isCancelled else { return }
                self.linkAttemptInFlight = false
                return
            }
            // The same certificate came back, so the owner's answer still stands. Asking again would
            // offer "that doesn't match" against a pairing nothing has touched.
            if self.coordinator.state == .alreadyConnected, self.appConfig.journalSendConfirmed {
                self.linkAttemptInFlight = false
                self.completeOnce()
                return
            }
            let pairing = try SPLRuntime.keychainStore.load()
            if let pairing { self.appConfig.reflectCommittedPairing(pairing) }
            guard !Task.isCancelled else { return }
            self.phase = .connecting
            await self.askAboutMark(caChainPEM: pairing?.caChainPEM)
            guard !Task.isCancelled else { return }
            self.linkAttemptInFlight = false
        } catch {
            guard !Task.isCancelled else { return }
            if case .failed(let message) = self.coordinator.state {
                self.errorMessage = message
            } else {
                self.errorMessage = PairFlowCoordinator.message(for: error, targetAddress: nil, interfaces: [])
            }
            self.endAttempt()
            self.startFallbackTimerIfNeeded()
        }
    }

    private func startConfirmHeldJournal() {
        self.cancelFlowTask()
        self.phase = .connecting
        let generation = self.flowGeneration
        self.flowTask = Task { @MainActor in
            defer {
                if self.flowGeneration == generation { self.flowTask = nil }
            }
            await self.askAboutMark(caChainPEM: self.appConfig.loadStoredPairing()?.caChainPEM)
        }
    }

    /// The mark question draws what this device computes from the CA the pairing pinned, so it
    /// doesn't wait on the tunnel. If that can't be computed, the mark is unavailable.
    private func askAboutMark(caChainPEM: String?, keepingMark: Bool = true) async {
        var mark: JournalMark?
        if let caChainPEM {
            mark = keepingMark
                ? await JournalMarkDerivation.mark(forCAChainPEM: caChainPEM)
                : await JournalMarkDerivation.markKeepingNothing(forCAChainPEM: caChainPEM)
        }
        guard !Task.isCancelled else { return }
        self.errorMessage = nil
        self.answerNotSaved = false
        self.phase = mark.map(PairFlowPhase.confirm) ?? .couldNotVerify
    }

    /// Both answers that let the pairing send share this. A failed save leaves the screen up, and
    /// has to say so: the owner just answered, and nothing else would change.
    private func recordAnswer() {
        self.answerNotSaved = false
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(Self.uiTestAnswerFailsArgument) {
            self.answerNotSaved = true
            return
        }
        #endif
        if self.coordinator.heldReplacement != nil {
            self.commitHeldAnswer()
            return
        }
        guard completeJournalSend(
            release: self.journalSendRelease,
            appConfig: self.appConfig,
            gate: self.completionGate,
            onComplete: self.onComplete
        ) else {
            self.answerNotSaved = true
            // The line appears away from the button the owner just tapped, and VoiceOver does not
            // move to it on its own.
            UIAccessibility.post(notification: .announcement, argument: SourceVocabulary.journalMarkAnswerNotSaved)
            return
        }
    }

    private func commitHeldAnswer() {
        self.cancelFlowTask()
        let generation = self.flowGeneration
        self.flowTask = Task { @MainActor in
            defer {
                if self.flowGeneration == generation { self.flowTask = nil }
            }
            do {
                guard let pairing = try await self.coordinator.commitHeldReplacement() else { return }
                self.appConfig.reflectCommittedPairing(pairing)
                self.journalSendRelease.noteAnswerRecorded(self.appConfig)
                self.completionGate.completeOnce(self.onComplete)
            } catch {
                self.answerNotSaved = true
                UIAccessibility.post(notification: .announcement, argument: SourceVocabulary.journalMarkAnswerNotSaved)
            }
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

#if DEBUG
extension PairFlowView {
    static let uiTestTeardownFailsArgument = "--ui-test-mark-teardown-fails"
    static let uiTestAnswerFailsArgument = "--ui-test-mark-answer-fails"

    /// Which answer screen `--ui-test-mark-confirm` opens on.
    nonisolated static func uiTestMarkPhase(arguments: [String]) -> PairFlowPhase {
        if arguments.contains("--ui-test-mark-could-not-verify") { return .couldNotVerify }
        if arguments.contains("--ui-test-mark-mismatch") { return .mismatch }
        if arguments.contains("--ui-test-mark-not-changed") { return .notChanged }
        if arguments.contains("--ui-test-mark-derived"),
           let derived = try? markFromJournalID("f30ed159-ef46-8e9c-913f-e49f0fe7d201") {
            return .confirm(JournalMark(derived))
        }
        return .confirm(.uiTestSample)
    }
}
#endif
