// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import UIKit
import WebKit

/// The journal's pages ask the owner with `alert()`, `confirm()` and `prompt()`
/// before unpairing a device, closing a door or redoing a day. `WKWebView` draws
/// no dialog for these on its own: without its panel delegate methods it answers
/// every one as cancel, and the action silently does nothing. This draws each
/// one natively and answers with what the owner chose. A panel still open when
/// the pane goes away answers cancel, so the page is never left waiting.
@MainActor
final class JournalWebPanels {
    enum Kind: Equatable {
        case alert
        case confirm
        case prompt(defaultText: String?)
    }

    enum Answer: Equatable {
        case accepted(text: String?)
        case cancelled
    }

    private enum Copy {
        static let ok = "ok"
        static let cancel = "cancel"
    }

    private var open: (alert: UIAlertController, continuation: CheckedContinuation<Answer, Never>)?
    private var isTornDown = false

    nonisolated init() {}

    /// The panel on screen now, if any.
    var openAlert: UIAlertController? {
        self.open?.alert
    }

    func present(_ kind: Kind, message: String, over webView: WKWebView) async -> Answer {
        guard !self.isTornDown, self.open == nil, let presenter = Self.topController(above: webView) else {
            return .cancelled
        }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        if case .prompt(let defaultText) = kind {
            alert.addTextField { field in
                field.text = defaultText
            }
        }
        if kind != .alert {
            alert.addAction(UIAlertAction(title: Copy.cancel, style: .cancel) { [weak self] _ in
                self?.answer(accepted: false)
            })
        }
        alert.addAction(UIAlertAction(title: Copy.ok, style: .default) { [weak self] _ in
            self?.answer(accepted: true)
        })
        return await withCheckedContinuation { continuation in
            self.open = (alert, continuation)
            presenter.present(alert, animated: true)
            // UIKit refuses a presentation it can't make without saying so;
            // answer cancel rather than leave the page blocked on a panel nobody sees.
            if alert.presentingViewController == nil {
                self.resolve(.cancelled)
            }
        }
    }

    /// The owner's choice: the panel's buttons answer through here, with what
    /// is in its text field for a prompt.
    func answer(accepted: Bool) {
        guard let alert = self.open?.alert else { return }
        self.resolve(accepted ? .accepted(text: alert.textFields?.first?.text) : .cancelled)
    }

    func teardown() {
        self.isTornDown = true
        guard let alert = self.open?.alert else { return }
        self.resolve(.cancelled)
        alert.dismiss(animated: false)
    }

    private func resolve(_ answer: Answer) {
        guard let open = self.open else { return }
        self.open = nil
        open.continuation.resume(returning: answer)
    }

    private static func topController(above view: UIView) -> UIViewController? {
        guard var top = view.window?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
