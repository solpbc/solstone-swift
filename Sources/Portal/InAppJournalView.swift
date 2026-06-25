// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import WebKit
import os

nonisolated private let journalWebLog = Logger(subsystem: "app.solstone.swift", category: "journalweb")

struct JournalWebView: UIViewRepresentable {
    let url: URL
    @Binding var loadState: JournalWebPresentation.LoadState

    func makeCoordinator() -> Coordinator {
        Coordinator { state in
            self.loadState = state
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: self.url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.navigationDelegate = nil
    }

    nonisolated final class Coordinator: NSObject, WKNavigationDelegate {
        private let setState: @MainActor (JournalWebPresentation.LoadState) -> Void

        init(setState: @escaping @MainActor (JournalWebPresentation.LoadState) -> Void) {
            self.setState = setState
        }

        nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            self.apply(.started)
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.apply(.finished)
        }

        nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            self.applyFailure(error)
        }

        nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            self.applyFailure(error)
        }

        private nonisolated func applyFailure(_ error: any Error) {
            let nsError = error as NSError
            journalWebLog.error("journal web navigation failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
            self.apply(.failed(urlErrorCode: nsError.code))
        }

        private nonisolated func apply(_ outcome: JournalWebPresentation.NavigationOutcome) {
            let state = JournalWebPresentation.loadState(for: outcome)
            let setState = self.setState
            Task { @MainActor in
                setState(state)
            }
        }
    }
}

struct InAppJournalView: View {
    @Environment(ObserverRegistration.self) private var observerRegistration
    @Environment(\.dismiss) private var dismiss
    @State private var loadState: JournalWebPresentation.LoadState = .loading

    private var resolvedURL: URL? {
        JournalWebPresentation.resolvedURL(activeLocalPort: self.observerRegistration.activeLocalPort)
    }

    var body: some View {
        NavigationStack {
            self.content
                .navigationTitle("journal")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("done") {
                            self.dismiss()
                        }
                    }
                }
        }
        .onChange(of: self.observerRegistration.activeLocalPort) { _, newPort in
            if newPort == nil {
                self.loadState = JournalWebPresentation.connectionLostState
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let url = self.resolvedURL {
            ZStack {
                JournalWebView(url: url, loadState: self.$loadState)
                self.stateOverlay
            }
        } else {
            self.errorView(message: JournalWebPresentation.connectionLostMessage)
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
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
    }
}
