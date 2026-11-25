// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import UIKit
import UniformTypeIdentifiers
import WebKit

/// The journal's import host contract (version 2): the names the page and the app agree on.
/// The bytes are pinned from the journal's repository; see `import-host-contract.provenance.txt`.
nonisolated struct JournalImportHostContract: Decodable, Equatable, Sendable {
    let version: Int
    let capability: String
    let pick: String
    let status: String
    let event: String
    let drop: String
    let unsupported: String
    let contextMaxBytes: Int
    let reply: String

    static func load(bundle: Bundle = Bundle(for: AppDelegate.self)) -> (contract: Self, json: String)? {
        guard let url = bundle.url(forResource: "import-host-contract", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let contract = try? JSONDecoder().decode(Self.self, from: data),
              contract.version == 2,
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return (contract, json)
    }
}

/// Where a handed-off item stands, as the page hears it.
nonisolated enum JournalImportItemState: Equatable, Sendable {
    case waiting(deviceNoun: String? = nil, sizeBytes: Int64? = nil)
    case uploading(deviceNoun: String? = nil, sizeBytes: Int64? = nil)
    case attention(
        reason: String?,
        importID: String?,
        reviewRequired: Bool = false,
        reviewExpired: Bool = false,
        reasonCode: String? = nil,
        kind: String? = nil,
        retryable: Bool? = nil
    )
    case delivered(importID: String?)
    case gone

    static var waiting: JournalImportItemState {
        .waiting(deviceNoun: nil, sizeBytes: nil)
    }

    static var uploading: JournalImportItemState {
        .uploading(deviceNoun: nil, sizeBytes: nil)
    }

    var reply: [String: Any] {
        switch self {
        case .waiting(let deviceNoun, let sizeBytes):
            var object: [String: Any] = ["state": "waiting"]
            if let deviceNoun, !deviceNoun.isEmpty { object["device_noun"] = deviceNoun }
            if let sizeBytes { object["size_bytes"] = sizeBytes }
            return object
        case .uploading(let deviceNoun, let sizeBytes):
            var object: [String: Any] = ["state": "uploading"]
            if let deviceNoun, !deviceNoun.isEmpty { object["device_noun"] = deviceNoun }
            if let sizeBytes { object["size_bytes"] = sizeBytes }
            return object
        case .attention(let reason, let importID, let reviewRequired, let reviewExpired, let reasonCode, let kind, let retryable):
            var object: [String: Any] = [
                "state": "attention",
                "review_required": reviewRequired,
            ]
            if reviewExpired { object["review_expired"] = true }
            if let reason { object["reason"] = reason }
            if let importID { object["import_id"] = importID }
            if let reasonCode { object["reason_code"] = reasonCode }
            if let kind { object["kind"] = kind }
            if let retryable { object["retryable"] = retryable }
            return object
        case .delivered(let importID):
            var object: [String: Any] = ["state": "delivered"]
            if let importID { object["import_id"] = importID }
            return object
        case .gone:
            return ["state": "gone"]
        }
    }
}

/// What a handed-off selection became: each accepted item with its queue ID, and each refusal.
nonisolated struct JournalImportIntakeResult: Equatable, Sendable {
    struct Accepted: Equatable, Sendable {
        let item: UUID
        let name: String
        let size: Int64?
    }

    struct Refused: Equatable, Sendable {
        let name: String
        let reason: String
    }

    var accepted: [Accepted] = []
    var refused: [Refused] = []
}

/// The app's import queue as the handoff sees it: the same durable store the share sheet and
/// the import pane use, and the transfer engine that drains it.
@MainActor
protocol JournalImportIntake: AnyObject {
    func take(_ providers: [any ShareItemProvider], names: [String], handoff: ShareImportHandoff) async -> JournalImportIntakeResult
    func state(of item: UUID) async -> JournalImportItemState
}

@MainActor
final class JournalImportQueueIntake: JournalImportIntake {
    private let holder: ShareTransferHolder
    private let drainGate: ForegroundDrainGate
    private let deviceNounProvider: @MainActor () -> String

    init(
        holder: ShareTransferHolder,
        drainGate: ForegroundDrainGate,
        deviceNounProvider: @escaping @MainActor () -> String = { JournalImportQueueIntake.currentDeviceNoun() }
    ) {
        self.holder = holder
        self.drainGate = drainGate
        self.deviceNounProvider = deviceNounProvider
    }

    static func currentDeviceNoun(idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom) -> String {
        idiom == .pad ? "ipad" : "iphone"
    }

    func take(_ providers: [any ShareItemProvider], names: [String], handoff: ShareImportHandoff) async -> JournalImportIntakeResult {
        let coordinator = ShareImportCoordinator(queue: self.holder.store, handoff: handoff)
        var result = JournalImportIntakeResult()
        for (provider, name) in zip(providers, names) {
            switch await coordinator.accept(provider: provider) {
            case .success(let item):
                let bytes = (self.holder.store.readNoteObject(
                    itemID: ShareImportStore.itemIDString(item),
                    status: .pending
                )?["bytes"] as? NSNumber)?.int64Value
                result.accepted.append(.init(item: item, name: name, size: bytes))
            case .failure(let failure):
                result.refused.append(.init(name: name, reason: failure.message))
            case .dropped:
                result.refused.append(.init(name: name, reason: ShareImportFailure.unreadable.message))
            }
        }
        if !result.accepted.isEmpty {
            // The same drain a share wakes when the app comes forward; it runs whether or not the
            // journal stays open.
            let drainGate = self.drainGate
            Task { await drainGate.requestDrain() }
        }
        return result
    }

    func state(of item: UUID) async -> JournalImportItemState {
        let store = self.holder.store
        let itemID = ShareImportStore.itemIDString(item)
        let deviceNoun = self.deviceNounProvider()
        if let entry = try? store.loadLedger()[itemID] {
            return .delivered(importID: ShareImportID.validated(entry.serverTimestamp))
        }
        if let snapshot = await self.holder.transferEngine.itemSnapshot(itemID: item) {
            let attention = snapshot.manifest.attention
            let importID = ShareImportID.validated(attention?.importID ?? snapshot.manifest.saveThenStart?.savedTimestamp)
            let fields = try? ShareImportTransferMetadata.fields(from: snapshot.manifest)
            let sizeBytes = fields?.bytes ?? snapshot.manifest.payloadParts.first?.byteCount.map(Int64.init)
            switch snapshot.state {
            case .dispatching:
                return .uploading(deviceNoun: deviceNoun, sizeBytes: sizeBytes)
            case .attention:
                if let attention, attention.isReadyToReview {
                    return .attention(
                        reason: AppStrings.ios_app_importreviewdetail(),
                        importID: importID,
                        reviewRequired: true,
                        reviewExpired: false,
                        reasonCode: TransferReasonCodes.importPreviewRequired,
                        kind: attention.importPreviewKind,
                        retryable: false
                    )
                }
                if let attention, attention.isReviewExpired {
                    return .attention(
                        reason: AppStrings.ios_app_importreviewexpired(),
                        importID: importID,
                        reviewRequired: false,
                        reviewExpired: true,
                        reasonCode: attention.journalReasonCode,
                        kind: attention.importPreviewKind,
                        retryable: true
                    )
                }
                return .attention(
                    reason: attention?.ownerFailureReason,
                    importID: importID,
                    reviewRequired: false,
                    reviewExpired: false,
                    reasonCode: attention?.journalReasonCode,
                    kind: attention?.importPreviewKind,
                    retryable: attention?.isRetryableAttention ?? true
                )
            case .delivered:
                return .delivered(importID: importID)
            case .dropped:
                return .gone
            case .queued, .held, .paused, .salvaged, .staged:
                return .waiting(deviceNoun: deviceNoun, sizeBytes: sizeBytes)
            }
        }
        if store.fileManager.fileExists(atPath: store.pendingItemDirectoryURL(itemID: itemID).path) {
            let sizeBytes = (store.readNoteObject(itemID: itemID, status: .pending)?["bytes"] as? NSNumber)?.int64Value
            return .waiting(deviceNoun: deviceNoun, sizeBytes: sizeBytes)
        }
        if store.fileManager.fileExists(atPath: store.failedItemDirectoryURL(itemID: itemID).path) {
            let failure = store.loadFailureRecordIfPresent(itemID: itemID, status: .failed)
            return .attention(
                reason: failure?.reason,
                importID: nil,
                reviewRequired: false,
                reviewExpired: false,
                reasonCode: nil,
                kind: nil,
                retryable: failure?.classification != .terminal
            )
        }
        return .gone
    }
}

/// A file the owner picked or dropped: read from a local copy the host owns until intake finishes.
@MainActor
final class PickedFileItemProvider: ShareItemProvider {
    private let url: URL
    private let fallbackContentType: String?

    init(url: URL, fallbackContentType: String? = nil) {
        self.url = url
        self.fallbackContentType = fallbackContentType
    }

    func registeredContentType() -> String? {
        let ext = self.url.pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return type.identifier
        }
        return self.fallbackContentType ?? UTType.data.identifier
    }

    func suggestedFilename() -> String? {
        self.url.lastPathComponent
    }

    func deliverFile(to sink: any ShareFileSink) async throws -> ShareFileDelivery {
        try sink.consume(sourceURL: self.url, isInPlace: true)
    }

    func loadText() async throws -> String {
        throw ShareExtensionItemProviderError.unsupported
    }
}

/// Stages dropped `NSItemProvider` items into a temporary directory synchronously during
/// `UIDropInteractionDelegate.dropInteraction(_:performDrop:)`. UIKit only guarantees that
/// cross-process drag representations remain valid when requested inside `performDrop`;
/// requesting them after the page's JavaScript round-trip can lose external file grants.
nonisolated final class JournalDropStaging: @unchecked Sendable {
    enum Entry: Sendable {
        case staged(url: URL, name: String, contentType: String)
        case refused(name: String, reason: String)
    }

    let directory: URL
    private let lock = NSLock()
    private var slots: [Entry?]
    private var remaining: Int
    private var completedEntries: [Entry]?
    private var continuation: CheckedContinuation<[Entry], Never>?
    private var progresses: [Progress] = []
    private var cleanupRequested = false

    private init(directory: URL, count: Int) {
        self.directory = directory
        self.slots = Array(repeating: nil, count: count)
        self.remaining = count
        if count == 0 {
            self.completedEntries = []
        }
    }

    static func start(
        providers: [NSItemProvider],
        token: String,
        maxFiles: Int,
        temporaryRoot: URL = FileManager.default.temporaryDirectory
    ) -> JournalDropStaging {
        let capped = Array(providers.prefix(maxFiles))
        let directory = temporaryRoot.appendingPathComponent("journal-drop-\(token)", isDirectory: true)
        let staging = JournalDropStaging(directory: directory, count: capped.count)
        guard !capped.isEmpty else { return staging }

        for (index, provider) in capped.enumerated() {
            let suggestedName = provider.suggestedName
            let fallbackName = Self.sanitizedFilename(suggestedName) ?? "item \(index + 1)"
            guard let typeIdentifier = ShareImportCoordinator.supportedContentType(from: provider.registeredTypeIdentifiers) else {
                staging.finishSlot(index, entry: .refused(name: fallbackName, reason: ShareImportFailure.unsupported.message))
                continue
            }
            let progress = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { @Sendable sourceURL, error in
                let entry: Entry
                if staging.isCleanupRequested {
                    entry = .refused(name: fallbackName, reason: ShareImportFailure.unreadable.message)
                } else {
                    entry = Self.copyLoadedFile(
                        sourceURL: sourceURL,
                        error: error,
                        directory: directory,
                        index: index,
                        suggestedName: suggestedName,
                        fallbackName: fallbackName,
                        contentType: typeIdentifier
                    )
                }
                staging.finishSlot(index, entry: entry)
            }
            staging.recordProgress(progress)
        }
        return staging
    }

    func waitForEntries() async -> [Entry] {
        await withCheckedContinuation { continuation in
            self.lock.lock()
            if let completed = self.completedEntries {
                self.lock.unlock()
                continuation.resume(returning: completed)
                return
            }
            self.continuation = continuation
            self.lock.unlock()
        }
    }

    func cancelAndCleanup() {
        self.lock.lock()
        self.cleanupRequested = true
        let progresses = self.progresses
        self.progresses = []
        let done = self.remaining == 0
        let directory = self.directory
        self.lock.unlock()
        for progress in progresses {
            progress.cancel()
        }
        if done {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private var isCleanupRequested: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cleanupRequested
    }

    private func recordProgress(_ progress: Progress) {
        self.lock.lock()
        let shouldCancel = self.cleanupRequested
        if !shouldCancel, self.remaining > 0 {
            self.progresses.append(progress)
        }
        self.lock.unlock()
        if shouldCancel {
            progress.cancel()
        }
    }

    private func finishSlot(_ index: Int, entry: Entry) {
        self.lock.lock()
        self.slots[index] = entry
        self.remaining -= 1
        guard self.remaining == 0 else {
            self.lock.unlock()
            return
        }
        let completed = self.slots.compactMap { $0 }
        self.completedEntries = completed
        self.progresses = []
        let continuation = self.continuation
        self.continuation = nil
        let shouldDelete = self.cleanupRequested
        let directory = self.directory
        self.lock.unlock()

        if shouldDelete {
            try? FileManager.default.removeItem(at: directory)
        }
        continuation?.resume(returning: completed)
    }

    private static func copyLoadedFile(
        sourceURL: URL?,
        error: (any Error)?,
        directory: URL,
        index: Int,
        suggestedName: String?,
        fallbackName: String,
        contentType: String
    ) -> Entry {
        if let error {
            let failure: ShareImportFailure = ShareImportNoRoom.matches(error) ? .noRoom : .unreadable
            return .refused(name: fallbackName, reason: failure.message)
        }
        guard let sourceURL else {
            return .refused(name: fallbackName, reason: ShareImportFailure.unreadable.message)
        }
        let filename = Self.stagedFilename(suggestedName: suggestedName, sourceURL: sourceURL, fallbackIndex: index)
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        if let size = Self.fileByteCount(at: sourceURL), size > ShareImportFileSink.maxFileBytes {
            return .refused(name: filename, reason: ShareImportFailure.tooLarge.message)
        }
        let slotDirectory = directory.appendingPathComponent("\(index)", isDirectory: true)
        let destinationURL = slotDirectory.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(at: slotDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return .staged(url: destinationURL, name: filename, contentType: contentType)
        } catch {
            let failure: ShareImportFailure = ShareImportNoRoom.matches(error) ? .noRoom : .unreadable
            return .refused(name: filename, reason: failure.message)
        }
    }

    private static func fileByteCount(at url: URL) -> Int64? {
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            return Int64(size)
        }
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    static func stagedFilename(suggestedName: String?, sourceURL: URL, fallbackIndex: Int) -> String {
        let sourceName = Self.sanitizedFilename(sourceURL.lastPathComponent)
        let sourceExtension = sourceName.map { ($0 as NSString).pathExtension } ?? ""
        if let suggested = Self.sanitizedFilename(suggestedName) {
            if !(suggested as NSString).pathExtension.isEmpty || sourceExtension.isEmpty {
                return suggested
            }
            return "\(suggested).\(sourceExtension)"
        }
        return sourceName ?? "item-\(fallbackIndex + 1)"
    }

    static func sanitizedFilename(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let leaf = URL(fileURLWithPath: trimmed).lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != "..", leaf != "/" else { return nil }
        return leaf
    }
}

/// The app side of the journal's import handoff. The journal's own pages, in the journal
/// pane's top document on the paired journal's exact origin, may ask the app to pick files and
/// queue them for the journal. The page never sees a path, the bytes or the pairing credential;
/// it gets queue item IDs, display names and their progress.
@MainActor
final class JournalImportHost: NSObject, WKScriptMessageHandlerWithReply, UIDocumentPickerDelegate, UIDropInteractionDelegate {
    static let handlerName = "journalImport"
    private static let maxPacketBytes = 65536
    private static let maxFiles = 64

    let contract: JournalImportHostContract
    private let contractJSON: String
    private(set) var authHost: JournalAuthHost?
    private let origin: JournalWebNavigationPolicy.Authority
    private let intake: any JournalImportIntake
    private let presentPicker: @MainActor (UIViewController) -> Bool
    private weak var webView: WKWebView?
    private weak var dropView: UIView?
    private var dropInteraction: UIDropInteraction?
    private var documentID: String?
    private var documentGeneration = 0
    private var pageReady = false
    private var busy = false
    private var pickerContinuation: CheckedContinuation<[URL]?, Never>?
    private var pendingDrop: (token: String, staging: JournalDropStaging)?
    private var isTornDown = false

    /// `nil` when the bundle has no usable contract or the entry address has no origin, so the
    /// page sees no capability and keeps its own upload.
    init?(
        entryURL: URL,
        intake: any JournalImportIntake,
        bundle: Bundle = Bundle(for: AppDelegate.self),
        presentPicker: (@MainActor (UIViewController) -> Bool)? = nil,
        authRunner: (any JournalAuthSessionRunning)? = nil
    ) {
        guard let loaded = JournalImportHostContract.load(bundle: bundle),
              let origin = JournalWebNavigationPolicy.authority(for: entryURL),
              origin.scheme == "http" || origin.scheme == "https"
        else { return nil }
        self.contract = loaded.contract
        self.contractJSON = loaded.json
        self.origin = origin
        self.intake = intake
        self.presentPicker = presentPicker ?? { _ in false }
        super.init()
        if let loadedAuth = JournalAuthHostContract.load(bundle: bundle) {
            self.authHost = JournalAuthHost(
                contract: loadedAuth.contract,
                contractJSON: loadedAuth.json,
                runner: authRunner ?? LiveJournalAuthSessionRunner(),
                anchorProvider: { [weak self] in self?.webView?.window }
            )
        }
    }

    var originString: String {
        let defaultPort = self.origin.scheme == "https" ? 443 : 80
        let port = self.origin.port == defaultPort ? "" : ":\(self.origin.port)"
        return "\(self.origin.scheme)://\(self.origin.host)\(port)"
    }

    /// Installs the handler and the top-document adapter. Call before the web view is created.
    func install(in controller: WKUserContentController) {
        controller.addScriptMessageHandler(self, contentWorld: .page, name: Self.handlerName)
        controller.addUserScript(WKUserScript(
            source: self.adapterScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        ))
    }

    func attach(to webView: WKWebView) {
        self.webView = webView
        self.ensureDropInteraction()
    }

    /// Keeps the host's drop interaction attached to the web view's current content view and
    /// ordered after WebKit's own drop interaction. At initial view creation `WKContentView` has
    /// not installed its own interactions yet, so WebKit later appends its `UIDropInteraction`
    /// after ours and shadows it when both return `true` from `canHandle`. Re-running once the
    /// page is ready keeps ours last while leaving WebKit's intact for non-import drags.
    func ensureDropInteraction() {
        guard !self.isTornDown, let webView = self.webView else { return }
        let target = webView.scrollView.subviews.first {
            String(describing: type(of: $0)).contains("WKContentView")
        } ?? webView
        if let existing = self.dropInteraction {
            if self.dropView === target {
                let oursIndex = target.interactions.firstIndex { $0 === existing }
                let lastDropIndex = target.interactions.lastIndex { $0 is UIDropInteraction }
                if let oursIndex, let lastDropIndex, oursIndex == lastDropIndex {
                    return
                }
                target.removeInteraction(existing)
                target.addInteraction(existing)
                return
            }
            self.dropView?.removeInteraction(existing)
        }
        let interaction = UIDropInteraction(delegate: self)
        target.addInteraction(interaction)
        self.dropView = target
        self.dropInteraction = interaction
    }

    func teardown(controller: WKUserContentController?) {
        self.isTornDown = true
        controller?.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .page)
        if let interaction = self.dropInteraction {
            self.dropView?.removeInteraction(interaction)
        }
        self.dropView = nil
        self.dropInteraction = nil
        self.clearPendingDrop()
        self.authHost?.tearDown()
        self.finishPicker(nil)
    }

    private func clearPendingDrop() {
        self.pendingDrop?.staging.cancelAndCleanup()
        self.pendingDrop = nil
    }

    // MARK: - Messages

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        let frame = message.frameInfo
        let security = frame.securityOrigin
        let sender = JournalWebNavigationPolicy.Authority(
            scheme: security.protocol.lowercased(),
            host: security.host.lowercased(),
            port: security.port == 0 ? (security.protocol.lowercased() == "https" ? 443 : 80) : security.port
        )
        let current = message.webView?.url.flatMap(JournalWebNavigationPolicy.authority(for:))
        guard frame.isMainFrame, sender == self.origin, current == self.origin,
              let packet = message.body as? String
        else {
            journalWebLog.notice("import host refused a message outside the journal's top document")
            return (nil, "unavailable")
        }
        switch await self.handle(packet: packet) {
        case .success(let reply):
            return (reply, nil)
        case .failure(let refusal):
            return (nil, refusal.message)
        }
    }

    struct Refusal: Error, Equatable {
        let message: String
    }

    /// The page's packet, `{documentId, message}`, after the frame and origin checks. Returns the
    /// reply as JSON text.
    func handle(packet: String) async -> Result<String, Refusal> {
        guard !self.isTornDown,
              packet.utf8.count <= Self.maxPacketBytes,
              let envelope = (try? JSONSerialization.jsonObject(with: Data(packet.utf8))) as? [String: Any],
              let documentID = envelope["documentId"] as? String,
              UUID(uuidString: documentID) != nil
        else { return .failure(Refusal(message: "unavailable")) }
        guard let message = envelope["message"] as? [String: Any] else {
            return .failure(Refusal(message: "invalid message"))
        }
        if documentID != self.documentID {
            // A new journal document. Anything the old one was waiting on no longer has a page.
            self.documentID = documentID
            self.documentGeneration += 1
            self.pageReady = false
            self.clearPendingDrop()
            self.authHost?.tearDown()
        }
        let type = message["type"] as? String
        switch type {
        case "host.ready":
            self.pageReady = true
            self.ensureDropInteraction()
            return .success("{}")
        case "host.status":
            guard let item = (message["item"] as? String).flatMap(UUID.init(uuidString:)) else {
                return .success(Self.json(JournalImportItemState.gone.reply))
            }
            return .success(Self.json(await self.intake.state(of: item).reply))
        case self.contract.pick:
            guard let id = message["id"] as? String, !id.isEmpty, id.utf8.count <= 128 else {
                return .success(Self.json(["type": self.contract.unsupported]))
            }
            var reply = await self.pick(message)
            reply["id"] = id
            reply["type"] = self.contract.reply
            return .success(Self.json(reply))
        default:
            if let type, let authHost = self.authHost, authHost.handles(type: type) {
                return .success(Self.json(await authHost.handle(message, type: type)))
            }
            var reply: [String: Any] = ["type": self.contract.unsupported]
            if let id = message["id"] as? String { reply["id"] = id }
            return .success(Self.json(reply))
        }
    }

    private func pick(_ message: [String: Any]) async -> [String: Any] {
        guard !self.busy else { return ["outcome": "busy"] }
        guard let area = message["area"] as? String, !area.isEmpty, area.utf8.count <= 96,
              let context = message["context"] as? [String: Any],
              let flag = message["multiple"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(),
              let accept = message["accept"] as? [Any],
              let contextData = try? JSONSerialization.data(withJSONObject: context),
              contextData.count <= self.contract.contextMaxBytes,
              let contextText = String(data: contextData, encoding: .utf8)
        else { return ["outcome": "refused"] }
        self.busy = true
        defer { self.busy = false }
        let handoff = ShareImportHandoff(area: area, context: contextText)
        let generation = self.documentGeneration

        if let token = message["drop"] as? String {
            guard let drop = self.pendingDrop, drop.token == token else { return ["outcome": "refused"] }
            self.pendingDrop = nil
            defer { drop.staging.cancelAndCleanup() }
            let entries = await drop.staging.waitForEntries()
            var providers: [any ShareItemProvider] = []
            var names: [String] = []
            var preRefused: [JournalImportIntakeResult.Refused] = []
            for entry in entries {
                switch entry {
                case .staged(let url, let name, let contentType):
                    providers.append(PickedFileItemProvider(url: url, fallbackContentType: contentType))
                    names.append(name)
                case .refused(let name, let reason):
                    preRefused.append(.init(name: name, reason: reason))
                }
            }
            var result = providers.isEmpty
                ? JournalImportIntakeResult()
                : await self.intake.take(providers, names: names, handoff: handoff)
            result.refused.insert(contentsOf: preRefused, at: 0)
            return Self.reply(for: result)
        }

        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: Self.contentTypes(accept: accept.compactMap { $0 as? String }),
            asCopy: true
        )
        picker.allowsMultipleSelection = flag.boolValue
        picker.delegate = self
        let urls: [URL]? = await withCheckedContinuation { continuation in
            self.pickerContinuation = continuation
            if !self.present(picker) {
                self.finishPicker(nil)
            }
        }
        defer {
            // The picker's copies were ours to read; the queue holds its own durable copy now.
            for url in urls ?? [] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        guard let urls, !urls.isEmpty, generation == self.documentGeneration, !self.isTornDown else {
            return ["outcome": "cancelled"]
        }
        let chosen = Array(urls.prefix(Self.maxFiles))
        let result = await self.intake.take(
            chosen.map { PickedFileItemProvider(url: $0) },
            names: chosen.map(\.lastPathComponent),
            handoff: handoff
        )
        return Self.reply(for: result)
    }

    private static func reply(for result: JournalImportIntakeResult) -> [String: Any] {
        [
            "outcome": result.accepted.isEmpty ? "refused" : "queued",
            "items": result.accepted.map { accepted -> [String: Any] in
                var item: [String: Any] = ["item": ShareImportStore.itemIDString(accepted.item), "name": accepted.name]
                if let size = accepted.size { item["size"] = size }
                return item
            },
            "refused": result.refused.map { ["name": $0.name, "reason": $0.reason] },
        ]
    }

    /// The page's filters, as the picker's types: `.txt`, `text/plain` and `image/*` each name a
    /// type. A filter the system has no type for is skipped; none at all offers any file.
    nonisolated static func contentTypes(accept: [String]) -> [UTType] {
        var types: [UTType] = []
        for token in accept.prefix(64) {
            let token = token.trimmingCharacters(in: .whitespaces).lowercased()
            guard !token.isEmpty, token.utf8.count <= 128 else { continue }
            let type: UTType?
            if token.hasPrefix(".") {
                type = UTType(filenameExtension: String(token.dropFirst()))
            } else if token.hasSuffix("/*") {
                switch token {
                case "image/*": type = .image
                case "audio/*": type = .audio
                case "video/*": type = .movie
                case "text/*": type = .text
                default: type = nil
                }
            } else if token.contains("/") {
                type = UTType(mimeType: token)
            } else {
                type = nil
            }
            if let type, !types.contains(type) {
                types.append(type)
            }
        }
        return types.isEmpty ? [.item] : types
    }

    private func present(_ picker: UIViewController) -> Bool {
        if self.presentPicker(picker) { return true }
        guard var top = self.webView?.window?.rootViewController else { return false }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        top.present(picker, animated: true)
        return true
    }

    private func finishPicker(_ urls: [URL]?) {
        guard let continuation = self.pickerContinuation else { return }
        self.pickerContinuation = nil
        continuation.resume(returning: urls)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        self.finishPicker(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        self.finishPicker(nil)
    }

    // MARK: - Drops

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        self.pageReady && !self.isTornDown && session.hasItemsConforming(toTypeIdentifiers: [UTType.data.identifier])
            && session.items.contains { item in
                ShareImportCoordinator.supportedContentType(from: item.itemProvider.registeredTypeIdentifiers) != nil
            }
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        self.offerDrop(session.items.map(\.itemProvider))
    }

    /// Starts staging dropped items immediately inside `performDrop`, holds them behind a one-time
    /// token, and tells the page, which asks for them with the card the owner dropped on, or as a
    /// general import.
    @discardableResult
    func offerDrop(_ providers: [NSItemProvider]) -> String? {
        guard self.pageReady, !providers.isEmpty, let webView = self.webView else { return nil }
        self.clearPendingDrop()
        let token = UUID().uuidString.lowercased()
        let staging = JournalDropStaging.start(providers: providers, token: token, maxFiles: Self.maxFiles)
        self.pendingDrop = (token, staging)
        let event = (try? JSONEncoder().encode(self.contract.drop)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let script = "window.dispatchEvent(new CustomEvent(\(event),{cancelable:true,detail:{token:'\(token)'}}))"
        webView.evaluateJavaScript(script, in: nil, in: .page) { _ in }
        return token
    }

    // MARK: - The page side

    /// Defines the capability in the journal's top document only. It reads each queued item's
    /// progress while the document is open and raises the contract's status event.
    var adapterScript: String {
        let origin = (try? JSONEncoder().encode(self.originString)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let authJSON = self.authHost?.contractJSON ?? "null"
        return """
        ((contract, origin, auth) => {
          if (window !== window.top || location.origin !== origin) return;
          const native = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(Self.handlerName);
          if (!native) return;
          const documentId = crypto.randomUUID();
          const post = async message => JSON.parse(await native.postMessage(JSON.stringify({documentId, message})));
          const authTypes = auth ? [auth.prepare, auth.authorize, auth.cancel] : [];
          const types = Object.freeze([contract.pick, ...authTypes]);
          const items = {};
          let timer;
          async function update() {
            for (const [item, record] of Object.entries(items)) {
              try {
                const status = await post({type:'host.status', item});
                const serial = JSON.stringify(status);
                if (record.last !== serial) {
                  record.last = serial;
                  window.dispatchEvent(new CustomEvent(contract.event, {detail:{
                    ...status, type:contract.status, item, name:record.name, id:record.id,
                  }}));
                }
                const holdForReview = status.state === 'attention' && status.review_required === true;
                record.reviewWaiting = holdForReview;
                if (['delivered', 'gone'].includes(status.state) || (status.state === 'attention' && !holdForReview)) {
                  delete items[item];
                }
              } catch (_) { /* Read again while the document is open. */ }
            }
            const remaining = Object.values(items);
            if (remaining.length) {
              const onlyReview = remaining.every(r => r.reviewWaiting);
              timer = setTimeout(update, onlyReview ? 2000 : 400);
            } else {
              timer = undefined;
            }
          }
          Object.defineProperty(window, contract.capability, {value:Object.freeze({
            version:contract.version, types,
            async send(message) {
              if (!message || typeof message.id !== 'string' || typeof message.type !== 'string') throw new TypeError();
              if (authTypes.includes(message.type)) return await post(message);
              if (message.type !== contract.pick) return {type:contract.unsupported, id:message.id};
              const reply = await post(message);
              for (const item of reply.items || []) items[item.item] = {id:message.id, name:item.name};
              if (Object.keys(items).length && !timer) timer = setTimeout(update, 0);
              return reply;
            }
          })});
          window.addEventListener(contract.drop, event => {
            // A card can take the drop as its own. A drop anywhere else is a general import.
            queueMicrotask(() => {
              if (!event.defaultPrevented && event.detail && event.detail.token)
                window[contract.capability].send({type:contract.pick, id:crypto.randomUUID(), area:'quick',
                  accept:[], multiple:true, context:{}, drop:event.detail.token}).catch(() => {});
            });
          });
          const ready = () => {
            if (window.solstoneImportContract && window.solstoneImportContract.version === contract.version)
              post({type:'host.ready'}).catch(() => {});
          };
          document.addEventListener('DOMContentLoaded', ready, {once:true});
        })(\(self.contractJSON.trimmingCharacters(in: .whitespacesAndNewlines)), \(origin), \(authJSON));
        """
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}
