// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SwiftUI
import UIKit

@objc(ShareViewController)
final class ShareViewController: UIViewController {
    enum Screen: Equatable {
        case working
        case success(String)
        case failure(String)
    }

    private lazy var queue = ShareImportStore()
    private lazy var coordinator = ShareImportCoordinator(queue: self.queue)
    private var hostingController: UIHostingController<ShareExtensionView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        self.render(.working)
        self.prepare()
    }

    private func prepare() {
        let providers = self.allProviders()
        guard !providers.isEmpty else {
            self.complete()
            return
        }

        self.render(.working)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let results = await self.coordinator.accept(providers: providers)
            let counts = ShareImportCopy.batchCounts(for: results)
            if counts.saved > 0 {
                self.coordinator.saveCommitted()
                self.render(.success(ShareImportCopy.batchStatus(saved: counts.saved, failed: counts.failed)))
            } else if counts.failed == 0 {
                self.complete()
            } else if counts.failed == 1,
                      case .failure(let failure)? = results.first(where: { result in
                          if case .failure = result { return true }
                          return false
                      }) {
                self.render(.failure(failure.message))
            } else {
                self.render(.failure(ShareImportCopy.batchStatus(saved: 0, failed: counts.failed)))
            }
        }
    }

    private func render(_ screen: Screen) {
        let view = ShareExtensionView(
            screen: screen,
            onCancel: { [weak self] in
                self?.complete()
            },
            onAutoDismiss: { [weak self] in
                self?.complete()
            }
        )

        if let hostingController {
            hostingController.rootView = view
            return
        }

        let hostingController = UIHostingController(rootView: view)
        self.hostingController = hostingController
        self.addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: self.view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
        ])
        hostingController.didMove(toParent: self)
    }

    private func complete() {
        self.extensionContext?.completeRequest(returningItems: nil)
    }

    private func allProviders() -> [any ShareItemProvider] {
        let items = self.extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        var providers: [any ShareItemProvider] = []
        for item in items {
            providers.append(contentsOf: (item.attachments ?? []).map { ShareExtensionItemProvider(provider: $0) })
        }
        return providers
    }
}

private struct ShareExtensionView: View {
    let screen: ShareViewController.Screen
    let onCancel: @MainActor @Sendable () -> Void
    let onAutoDismiss: @MainActor @Sendable () -> Void

    var body: some View {
        VStack(spacing: 18) {
            switch self.screen {
            case .working:
                ProgressView()
                    .accessibilityLabel(SourceVocabulary.shareSendingProgress)
            case .success(let status):
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(Color.solSavedGreen)
                        .symbolEffect(.bounce)
                        .accessibilityHidden(true)
                    Text(status)
                        .font(.body)
                        .multilineTextAlignment(.center)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(status)
                .task {
                    try? await Task.sleep(for: .seconds(0.9))
                    self.onAutoDismiss()
                }
            case .failure(let message):
                Text(message)
                    .font(.body)
                    .multilineTextAlignment(.center)
                Button(ShareImportCopy.dismiss, action: self.onCancel)
                    .buttonStyle(.bordered)
                    .accessibilityHint("Closes this message.")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
