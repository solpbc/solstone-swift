// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Observation
import SwiftUI

/// Runs the store age check at launch and says what the app shows while it decides.
///
/// Until the first check of a foreground launch settles, the app's own content is not built, so
/// nothing it starts (the connection, a drain, a source) runs ahead of the answer. A launch iOS
/// starts in the background shows the content the last check allowed and asks at the next
/// foreground.
@MainActor
@Observable
final class AgeSignalModel {
    enum Presentation: Equatable {
        case content
        case waiting
        case stopped
        case held
    }

    private(set) var presentation: Presentation
    @ObservationIgnored let gate: AgeSignalGate
    /// Stops what is already running when a check stops or holds the app.
    @ObservationIgnored var onBlocked: @MainActor () -> Void = {}

    @ObservationIgnored private let makePlatform: (@MainActor () -> any AgeSignalPlatform)?
    @ObservationIgnored private let pause: @Sendable (Duration) async -> Void
    @ObservationIgnored private var platform: (any AgeSignalPlatform)?
    @ObservationIgnored private var checkedThisLaunch = false
    @ObservationIgnored private var isChecking = false
    @ObservationIgnored private var answers: Task<Void, Never>?
    @ObservationIgnored private var lastPhase: ScenePhase?
    /// Counts parents' approvals, so a check that began before one cannot undo it.
    @ObservationIgnored private var approvals = 0

    init(
        gate: AgeSignalGate,
        platform makePlatform: (@MainActor () -> any AgeSignalPlatform)?,
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.gate = gate
        self.makePlatform = gate.isEnabled ? makePlatform : nil
        self.pause = pause
        if self.makePlatform == nil {
            self.presentation = .content
        } else {
            switch gate.store.outcome() {
            case .run: self.presentation = .waiting
            case .stopped: self.presentation = .stopped
            case .held: self.presentation = .held
            }
        }
    }

    static func live() -> AgeSignalModel {
#if SOLSTONE_AGE_SIGNAL
#if DEBUG
        if let proof = AgeSignalProofPlatform.requested() {
            return AgeSignalModel(gate: .live, platform: { proof })
        }
#endif
        return AgeSignalModel(gate: .live, platform: {
            if #available(iOS 26.2, *) {
                return AppleAgeSignalPlatform()
            }
            return UnavailableAgeSignalPlatform()
        })
#else
        return AgeSignalModel(gate: .live, platform: nil)
#endif
    }

    /// Whether this build asks at all.
    var isEnabled: Bool {
        self.makePlatform != nil
    }

    /// Whether the app's own work may run now. Off, it always may.
    var allowsActivity: Bool {
        self.presentation == .content
    }

    /// The check runs in its own task: the system's own sheets make the scene inactive, and that
    /// must not cancel a check halfway into a settled-looking answer.
    @discardableResult
    func scenePhaseChanged(_ phase: ScenePhase) -> Task<Void, Never>? {
        guard self.makePlatform != nil else { return nil }
        let previous = self.lastPhase
        self.lastPhase = phase
        switch phase {
        case .active:
            // Asked once per launch; a hold is asked again each time the app comes back from
            // the background (not after a system sheet or Control Center).
            let comingBack = previous == .background && self.presentation == .held
            guard !self.isChecking, !self.checkedThisLaunch || comingBack else { return nil }
            return Task { await self.check() }
        case .background:
            // A launch iOS starts in the background runs as the last check left it; one the person
            // leaves mid-check waits for the answer.
            if self.presentation == .waiting, !self.checkedThisLaunch, !self.isChecking {
                self.presentation = .content
            }
        case .inactive:
            break
        @unknown default:
            break
        }
        return nil
    }

    func check() async {
        guard !self.isChecking, let platform = self.resolvedPlatform() else { return }
        self.isChecking = true
        defer { self.isChecking = false }
        let previous = self.gate.store.outcome()
        let approvals = self.approvals
        let outcome = await AgeSignalCheck(platform: platform, store: self.gate.store, pause: self.pause).run()
        self.checkedThisLaunch = true
        // A parent's approval that arrived meanwhile stands.
        guard approvals == self.approvals else { return }
        self.apply(outcome)
        if outcome == .held, previous != .held {
            await self.askAgain()
        }
    }

    /// Raises the parent's request again from the hold screen.
    func askAgain() async {
        guard let platform = self.resolvedPlatform() else { return }
        try? await platform.askParent()
    }

    private func apply(_ outcome: AgeSignalOutcome) {
        self.gate.store.saveOutcome(outcome)
        switch outcome {
        case .run:
            self.answers?.cancel()
            self.answers = nil
            self.presentation = .content
        case .stopped:
            self.answers?.cancel()
            self.answers = nil
            self.presentation = .stopped
            self.onBlocked()
        case .held:
            self.presentation = .held
            self.onBlocked()
            self.listenForParentAnswers()
        }
    }

    private func listenForParentAnswers() {
        guard self.answers == nil, let platform = self.resolvedPlatform() else { return }
        let stream = platform.parentAnswers()
        self.answers = Task { [weak self] in
            for await approved in stream {
                guard let self else { return }
                guard approved, self.presentation == .held else { continue }
                await self.parentApproved(platform: platform)
            }
        }
    }

    private func parentApproved(platform: any AgeSignalPlatform) async {
        self.approvals += 1
        if let rating = await platform.currentRatingCode() {
            self.gate.store.saveApprovedRatingCode(rating)
        }
        self.apply(.run)
    }

    private func resolvedPlatform() -> (any AgeSignalPlatform)? {
        if let platform { return platform }
        guard let makePlatform else { return nil }
        let made = makePlatform()
        self.platform = made
        return made
    }
}

/// The platform for an OS that predates the eligibility check: it is never eligible.
@MainActor
final class UnavailableAgeSignalPlatform: AgeSignalPlatform {
    func isEligible() async throws -> Bool { false }
    func requestCategory() async throws -> AgeSignalCategory? { nil }
    func requiresParentalConsentForSignificantChange() async throws -> Bool { false }
    func requiresAdultNotificationForSignificantChange() async throws -> Bool { false }
    func currentRatingCode() async -> Int? { nil }
    func installedThisBuild() async throws -> Bool { true }
    func askParent() async throws {}
    func parentAnswers() -> AsyncStream<Bool> { AsyncStream { $0.finish() } }
    func acknowledgeSignificantChange() async -> Bool { false }
}

/// Shows the app's content, or in its place the one plain screen a check calls for. The app
/// feeds the model its phase across all windows, so one window in the background cannot let the
/// content in while another is still asking. With the check off this is the content alone.
struct AgeSignalGateModifier: ViewModifier {
    let model: AgeSignalModel

    func body(content: Content) -> some View {
        if !self.model.isEnabled {
            content
        } else {
            switch self.model.presentation {
            case .content:
                content
            case .waiting:
                Color.deckGround.ignoresSafeArea()
            case .stopped:
                AgeSignalNotice(line: AppStrings.ios_app_agesignalunder13(), identifier: "ageSignal.stopped")
            case .held:
                AgeSignalNotice(
                    line: AppStrings.ios_app_agesignalhold(),
                    identifier: "ageSignal.held",
                    askAgain: { Task { await self.model.askAgain() } }
                )
            }
        }
    }
}

private struct AgeSignalNotice: View {
    let line: String
    let identifier: String
    var askAgain: (() -> Void)? = nil

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                self.stack
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .background(Color.deckGround.ignoresSafeArea())
    }

    private var stack: some View {
        VStack(spacing: 24) {
            Image("SolWordmark")
                .resizable()
                .scaledToFit()
                .frame(width: 104, height: 104)
                .accessibilityHidden(true)
            Text(self.line)
                .font(.body)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier(self.identifier)
            if let askAgain {
                Button(AppStrings.ios_app_agesignalaskagain(), action: askAgain)
                    .buttonStyle(BrandProminentButtonStyle())
                    .controlSize(.large)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("ageSignal.askAgain")
            }
        }
        .padding(24)
    }
}
