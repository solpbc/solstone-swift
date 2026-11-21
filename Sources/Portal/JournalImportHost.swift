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
    case waiting
    case uploading
    case attention(reason: String?, importID: String?)
    case delivered(importID: String?)
    case gone

    var reply: [String: Any] {
        switch self {
        case .waiting:
            return ["state": "waiting"]
        case .uploading:
            return ["state": "uploading"]
        case .attention(let reason, let importID):
            var object: [String: Any] = ["state": "attention"]
            if let reason { object["reason"] = reason }
            if let importID { object["import_id"] = importID }
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

    init(holder: ShareTransferHolder, drainGate: ForegroundDrainGate) {
        self.holder = holder
        self.drainGate = drainGate
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
        if let entry = try? store.loadLedger()[itemID] {
            return .delivered(importID: entry.serverTimestamp)
        }
        if let snapshot = await self.holder.transferEngine.itemSnapshot(itemID: item) {
            let importID = snapshot.manifest.saveThenStart?.savedTimestamp
            switch snapshot.state {
            case .dispatching:
                return .uploading
            case .attention:
                return .attention(reason: snapshot.manifest.attention?.ownerFailureReason, importID: importID)
            case .delivered:
                return .delivered(importID: importID)
            case .dropped:
                return .gone
            case .queued, .held, .paused, .salvaged, .staged:
                return .waiting
            }
        }
        if store.fileManager.fileExists(atPath: store.pendingItemDirectoryURL(itemID: itemID).path) {
            return .waiting
        }
        if store.fileManager.fileExists(atPath: store.failedItemDirectoryURL(itemID: itemID).path) {
            return .attention(reason: nil, importID: nil)
        }
        return .gone
    }
}

/// A file the owner picked in the document picker: read from the copy the picker made.
@MainActor
final class PickedFileItemProvider: ShareItemProvider {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func registeredContentType() -> String? {
        let ext = self.url.pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return type.identifier
        }
        return UTType.data.identifier
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
    private var pendingDrop: (token: String, providers: [NSItemProvider])?
    private var isTornDown = false

    /// `nil` when the bundle has no usable contract or the entry address has no origin, so the
    /// page sees no capability and keeps its own upload.
    init?(
        entryURL: URL,
        intake: any JournalImportIntake,
        bundle: Bundle = Bundle(for: AppDelegate.self),
        presentPicker: (@MainActor (UIViewController) -> Bool)? = nil
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
        // A drop lands on the page's content view, which is where WebKit takes drops too.
        let target = webView.scrollView.subviews.first { String(describing: type(of: $0)).contains("WKContentView") } ?? webView
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
        self.pendingDrop = nil
        self.finishPicker(nil)
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
            self.pendingDrop = nil
        }
        let type = message["type"] as? String
        switch type {
        case "host.ready":
            self.pageReady = true
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
            let providers = Array(drop.providers.prefix(Self.maxFiles))
            let names = providers.enumerated().map { $0.element.suggestedName ?? "item \($0.offset + 1)" }
            let result = await self.intake.take(
                providers.map { ShareExtensionItemProvider(provider: $0) },
                names: names,
                handoff: handoff
            )
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

    /// Holds dropped items behind a one-time token and tells the page, which asks for them with
    /// the card the owner dropped on, or as a general import.
    func offerDrop(_ providers: [NSItemProvider]) {
        guard self.pageReady, !providers.isEmpty, let webView = self.webView else { return }
        let token = UUID().uuidString.lowercased()
        self.pendingDrop = (token, providers)
        let event = (try? JSONEncoder().encode(self.contract.drop)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let script = "window.dispatchEvent(new CustomEvent(\(event),{cancelable:true,detail:{token:'\(token)'}}))"
        webView.evaluateJavaScript(script, in: nil, in: .page) { _ in }
    }

    // MARK: - The page side

    /// Defines the capability in the journal's top document only. It reads each queued item's
    /// progress while the document is open and raises the contract's status event.
    var adapterScript: String {
        let origin = (try? JSONEncoder().encode(self.originString)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return """
        ((contract, origin) => {
          if (window !== window.top || location.origin !== origin) return;
          const native = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(Self.handlerName);
          if (!native) return;
          const documentId = crypto.randomUUID();
          const post = async message => JSON.parse(await native.postMessage(JSON.stringify({documentId, message})));
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
                if (['attention', 'delivered', 'gone'].includes(status.state)) delete items[item];
              } catch (_) { /* Read again while the document is open. */ }
            }
            timer = Object.keys(items).length ? setTimeout(update, 400) : undefined;
          }
          Object.defineProperty(window, contract.capability, {value:Object.freeze({
            version:contract.version, types:Object.freeze([contract.pick]),
            async send(message) {
              if (!message || typeof message.id !== 'string' || typeof message.type !== 'string') throw new TypeError();
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
        })(\(self.contractJSON.trimmingCharacters(in: .whitespacesAndNewlines)), \(origin));
        """
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}
