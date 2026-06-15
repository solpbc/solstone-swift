// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SwiftUI
import UniformTypeIdentifiers
import UIKit

nonisolated private let shareExtensionLog = Logger(subsystem: "app.solstone.swift", category: "share-extension")

@objc(ShareViewController)
final class ShareViewController: UIViewController {
    enum Screen: Equatable {
        case loading
        case noJournal
        case confirm(journalName: String)
        case saving
        case failure(String)
    }

    private let mirror = AppGroupMirror()
    private lazy var queue = ImportQueue(startPathMonitor: false)
    private lazy var coordinator = ShareImportCoordinator(queue: self.queue)
    private var provider: (any ShareItemProvider)?
    private var hostingController: UIHostingController<ShareExtensionView>?
    private var screen: Screen = .loading

    override func viewDidLoad() {
        super.viewDidLoad()
        self.render(.loading)
        self.prepare()
    }

    private func prepare() {
        self.provider = self.firstProvider()
        let pairing = self.mirror.pairingSnapshot()

        guard pairing.isPaired, let journalName = pairing.journalName, !journalName.isEmpty else {
            self.render(.noJournal)
            return
        }

        guard self.provider?.registeredContentType() != nil else {
            self.showFailure(.unsupported)
            return
        }

        self.render(.confirm(journalName: journalName))
    }

    private func render(_ screen: Screen) {
        self.screen = screen
        let view = ShareExtensionView(
            screen: screen,
            onConnect: { [weak self] in
                self?.openPairingLink()
            },
            onSend: { [weak self] in
                self?.acceptShare()
            },
            onCancel: { [weak self] in
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

    private func openPairingLink() {
        guard let url = URL(string: "https://link.solpbc.org/pair/connect") else {
            self.complete()
            return
        }

        self.extensionContext?.open(url) { [weak self] success in
            Task { @MainActor in
                if !success {
                    shareExtensionLog.error("pairing link open failed")
                }
                self?.complete()
            }
        }
    }

    private func acceptShare() {
        guard let provider else {
            self.showFailure(.unsupported)
            return
        }
        let pairing = self.mirror.pairingSnapshot()
        guard pairing.isPaired, let journalName = pairing.journalName, !journalName.isEmpty else {
            self.render(.noJournal)
            return
        }

        self.render(.saving)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.coordinator.accept(provider: provider, journalName: journalName)
            switch result {
            case .success:
                self.coordinator.saveCommitted()
                self.complete()
            case .failure(let failure):
                self.render(.failure(failure.message))
            }
        }
    }

    private func showFailure(_ failure: ShareImportFailure) {
        self.render(.failure(failure.message))
    }

    private func complete() {
        self.extensionContext?.completeRequest(returningItems: nil)
    }

    private func firstProvider() -> (any ShareItemProvider)? {
        let items = self.extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        for item in items {
            for attachment in item.attachments ?? [] {
                let provider = ShareExtensionItemProvider(provider: attachment)
                if provider.registeredContentType() != nil {
                    return provider
                }
            }
        }
        return nil
    }
}

private struct ShareExtensionView: View {
    let screen: ShareViewController.Screen
    let onConnect: () -> Void
    let onSend: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            switch self.screen {
            case .loading:
                ProgressView()
            case .saving:
                ProgressView()
                    .accessibilityLabel(SourceVocabulary.shareSendingProgress)
            case .noJournal:
                Text(ShareImportCopy.connectFirstBody)
                    .font(.body)
                    .multilineTextAlignment(.center)
                Button(ShareImportCopy.connectJournalButton, action: self.onConnect)
                    .buttonStyle(.borderedProminent)
                    .tint(.solOrangeAccessible)
                    .accessibilityHint("Connects your journal.")
            case .confirm(let journalName):
                Text(ShareImportCopy.sendToYourJournal)
                    .font(.custom("Comfortaa-Bold", size: 22, relativeTo: .title2))
                Text(ShareImportCopy.solCanReadBody)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("journal: \(journalName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button(ShareImportCopy.sendToYourJournal, action: self.onSend)
                    .buttonStyle(.borderedProminent)
                    .tint(.solOrangeAccessible)
                    .accessibilityHint("Sends this to your journal.")
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

@MainActor
private final class ShareExtensionItemProvider: ShareItemProvider {
    private let provider: NSItemProvider

    init(provider: NSItemProvider) {
        self.provider = provider
    }

    func registeredContentType() -> String? {
        ShareImportCoordinator.supportedContentType(from: self.provider.registeredTypeIdentifiers)
    }

    func suggestedFilename() -> String? {
        self.provider.suggestedName
    }

    func loadFileRepresentation() async throws -> URL {
        guard let typeIdentifier = self.registeredContentType() else {
            throw ShareExtensionItemProviderError.unsupported
        }
        let suggestedFilename = self.suggestedFilename()

        return try await withCheckedThrowingContinuation { continuation in
            self.provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { sourceURL, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let sourceURL else {
                    continuation.resume(throwing: ShareExtensionItemProviderError.missingFile)
                    return
                }

                do {
                    let scratchURL = try Self.copyToScratch(
                        sourceURL: sourceURL,
                        suggestedFilename: suggestedFilename
                    )
                    continuation.resume(returning: scratchURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func copyToScratch(
        sourceURL: URL,
        suggestedFilename: String?
    ) throws -> URL {
        let fileManager = FileManager.default
        let scratchDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("SolstoneShareExtension", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)

        let fallbackName = sourceURL.lastPathComponent.isEmpty ? "shared-item" : sourceURL.lastPathComponent
        let filename = suggestedFilename?.isEmpty == false ? suggestedFilename! : fallbackName
        let targetURL = scratchDirectory.appendingPathComponent(filename, isDirectory: false)
        if fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.removeItem(at: targetURL)
        }
        try fileManager.copyItem(at: sourceURL, to: targetURL)
        return targetURL
    }
}

private enum ShareExtensionItemProviderError: Error {
    case unsupported
    case missingFile
}
