// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import WebKit

struct InAppJournalView: View {
    var mark: JournalMark? = nil
    var presentation: ShellPanePresentation = .phoneModal
    @Environment(ObserverRegistration.self) private var observerRegistration
    @Environment(\.dismiss) private var dismiss
    @AccessibilityFocusState private var headingFocused: Bool
    @State private var loadState: JournalWebPresentation.LoadState = .loading
    @State private var reloadToken = 0
    @State private var controller: JournalWebPageController?

    private var resolvedURL: URL? {
        JournalWebPresentation.resolvedURL(activeLocalPort: self.observerRegistration.activeLocalPort)
    }

    private var headingString: String {
        journalPaneTitle(mark: self.mark, pageTitle: self.controller?.page.title ?? "")
    }

    @ViewBuilder
    var body: some View {
        if self.presentation.isPhoneModal {
            NavigationStack {
                self.paneContent
            }
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape) {
                self.dismiss()
            }
            .containerShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            self.paneContent
        }
    }

    private var paneContent: some View {
        self.content
            .navigationTitle(self.headingString)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if self.presentation.isPhoneModal {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("done") {
                            self.dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(self.headingString)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("shell.pane.journal.heading")
                        .accessibilityFocused(self.$headingFocused)
                }
            }
        .accessibilityIdentifier("shell.pane.journal")
        .onAppear { self.headingFocused = true }
        .onChange(of: self.observerRegistration.activeLocalPort) { _, newPort in
            if newPort == nil {
                self.loadState = JournalWebPresentation.connectionLostState
            }
        }
        .onDisappear {
            self.controller?.teardown()
            self.controller = nil
        }
    }

    @ViewBuilder
    private var content: some View {
        if let url = self.resolvedURL {
            ZStack {
                self.webCanvas(url: url)
                self.stateOverlay
            }
        } else {
            self.errorView(message: JournalWebPresentation.connectionLostMessage)
        }
    }

    private func webCanvas(url: URL) -> some View {
        Group {
            if let controller = self.controller {
                WebView(controller.page)
                    .webViewBackForwardNavigationGestures(.disabled)
            }
        }
        .onAppear {
            self.ensureController().requestLoad(url: url, reloadToken: self.reloadToken)
        }
        .onChange(of: url) { _, newURL in
            self.controller?.requestLoad(url: newURL, reloadToken: self.reloadToken)
        }
        .onChange(of: self.reloadToken) { _, newToken in
            self.controller?.requestLoad(url: url, reloadToken: newToken)
        }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch self.loadState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground).opacity(0.75))
        case .loaded:
            EmptyView()
        case .error(let message):
            self.errorView(message: message)
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("try again", action: self.retry)
                .buttonStyle(.borderedProminent)
                .accessibilityHint("attempts to reconnect to your journal")
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private func retry() {
        guard self.resolvedURL != nil else {
            self.loadState = JournalWebPresentation.connectionLostState
            return
        }
        self.reloadToken += 1
    }

    @discardableResult
    private func ensureController() -> JournalWebPageController {
        if let controller = self.controller {
            return controller
        }
        let controller = JournalWebPageController { state in
            self.loadState = state
        }
        self.controller = controller
        return controller
    }
}
