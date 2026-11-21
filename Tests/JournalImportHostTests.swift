// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import UniformTypeIdentifiers
import WebKit
import XCTest

@MainActor
final class JournalImportHostTests: XCTestCase {
    private let entryURL = URL(string: "http://127.0.0.1:54321/")!
    private let documentID = UUID().uuidString.lowercased()

    // The conformance kit's own cases (contracts/journal-web-host/conformance/cases.json).
    private let pickCase: [String: Any] = [
        "type": "import.pick", "id": "pick-1", "area": "quick", "accept": [".txt", "text/plain"],
        "multiple": true, "future": ["ignore": true],
        "context": ["setting": "host conformance", "future": ["preserve": true]],
    ]

    func testUnknownTypeIsUnsupportedWithItsID() async throws {
        let host = try self.makeHost(FakeImportIntake())
        let reply = try await self.send(["type": "future.example", "id": "unknown-1", "future": 1], to: host)
        XCTAssertEqual(reply["type"] as? String, "unsupported")
        XCTAssertEqual(reply["id"] as? String, "unknown-1")
    }

    func testInvalidPickIsRefused() async throws {
        let host = try self.makeHost(FakeImportIntake())
        let invalid: [String: Any] = ["type": "import.pick", "id": "invalid-1", "area": "quick", "multiple": true, "accept": [], "context": []]
        let reply = try await self.send(invalid, to: host)
        XCTAssertEqual(reply["outcome"] as? String, "refused")
        XCTAssertEqual(reply["id"] as? String, "invalid-1")
        XCTAssertEqual(reply["type"] as? String, "import.reply")
    }

    func testOverlappingPickIsBusyAndADismissedPickerIsCancelled() async throws {
        var presented: UIDocumentPickerViewController?
        let host = try self.makeHost(FakeImportIntake()) { presented = $0 as? UIDocumentPickerViewController; return true }
        var cancelCase = self.pickCase
        cancelCase["id"] = "cancel-1"
        let cancelPacket = try self.packet(cancelCase)
        let pending = Task { try await host.handle(packet: cancelPacket).get() }
        while presented == nil { await Task.yield() }

        var overlap = self.pickCase
        overlap["id"] = "overlap-1"
        let busy = try await self.send(overlap, to: host)
        XCTAssertEqual(busy["outcome"] as? String, "busy")
        XCTAssertEqual(busy["id"] as? String, "overlap-1")

        host.documentPickerWasCancelled(try XCTUnwrap(presented))
        let cancelled = try self.object(try await pending.value)
        XCTAssertEqual(cancelled["outcome"] as? String, "cancelled")
        XCTAssertEqual(cancelled["id"] as? String, "cancel-1")
    }

    func testPickedFilesQueueWithTheirNamesAreaAndWholeContext() async throws {
        let intake = FakeImportIntake()
        var presented: UIDocumentPickerViewController?
        let host = try self.makeHost(intake) { presented = $0 as? UIDocumentPickerViewController; return true }
        let pickPacket = try self.packet(self.pickCase)
        let pending = Task { try await host.handle(packet: pickPacket).get() }
        while presented == nil { await Task.yield() }
        let picker = try XCTUnwrap(presented)
        XCTAssertTrue(picker.allowsMultipleSelection)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = directory.appendingPathComponent("sample.txt")
        try Data("sample \(UUID())".utf8).write(to: sample)
        host.documentPicker(picker, didPickDocumentsAt: [sample])

        let reply = try self.object(try await pending.value)
        XCTAssertEqual(reply["outcome"] as? String, "queued")
        let items = try XCTUnwrap(reply["items"] as? [[String: Any]])
        XCTAssertEqual(items.first?["name"] as? String, "sample.txt")
        XCTAssertEqual(items.first?["item"] as? String, ShareImportStore.itemIDString(intake.issued[0]))
        XCTAssertEqual(intake.names, [["sample.txt"]])
        let handoff = try XCTUnwrap(intake.handoffs.first)
        XCTAssertEqual(handoff.area, "quick")
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(handoff.context.utf8)) as? NSDictionary)
        XCTAssertEqual(context, ["setting": "host conformance", "future": ["preserve": true]] as NSDictionary)
        // The picker's copy is released once the queue holds its own.
        XCTAssertFalse(FileManager.default.fileExists(atPath: sample.path))
    }

    func testStatusReportsTheQueueItemsStateAndRow() async throws {
        let intake = FakeImportIntake()
        let item = UUID()
        intake.states[item] = .delivered(importID: "20261120_190754")
        let host = try self.makeHost(intake)
        let reply = try await self.send(["type": "host.status", "item": item.uuidString.lowercased()], to: host)
        XCTAssertEqual(reply["state"] as? String, "delivered")
        XCTAssertEqual(reply["import_id"] as? String, "20261120_190754")
        let unknown = try await self.send(["type": "host.status", "item": UUID().uuidString], to: host)
        XCTAssertEqual(unknown["state"] as? String, "gone")
    }

    func testADropTokenTheAppNeverIssuedIsRefused() async throws {
        var presented = false
        let host = try self.makeHost(FakeImportIntake()) { _ in presented = true; return true }
        var drop = self.pickCase
        drop["drop"] = "not-issued"
        let reply = try await self.send(drop, to: host)
        XCTAssertEqual(reply["outcome"] as? String, "refused")
        XCTAssertFalse(presented)
    }

    func testPickerTypesFollowThePagesFilters() {
        XCTAssertEqual(JournalImportHost.contentTypes(accept: [".txt", "text/plain"]), [.plainText])
        XCTAssertEqual(JournalImportHost.contentTypes(accept: [".zip", "application/zip", "image/*"]), [.zip, .image])
        XCTAssertEqual(JournalImportHost.contentTypes(accept: []), [.item])
        XCTAssertEqual(JournalImportHost.contentTypes(accept: ["nonsense"]), [.item])
    }

    /// Run in a real web view: the journal's top document gets the capability, an embedded
    /// document gets none and is refused if it calls the handler itself, and a page on another
    /// origin gets nothing.
    func testTheCapabilityLivesOnlyInTheJournalsTopDocument() async throws {
        let intake = FakeImportIntake()
        let (webView, host) = try self.makeWebView(intake: intake)
        defer { host.teardown(controller: webView.configuration.userContentController) }
        try await self.load(
            #"<!doctype html><title>journal</title><iframe srcdoc="<p>frame</p>"></iframe>"#,
            baseURL: self.entryURL,
            in: webView
        )

        let version = try await webView.evaluateJavaScript("window.solstoneJournalHost.version") as? Int
        XCTAssertEqual(version, 2)
        let types = try await webView.evaluateJavaScript("window.solstoneJournalHost.types.join()") as? String
        XCTAssertEqual(types, "import.pick")
        let unsupported = try await webView.callAsyncJavaScript(
            "return JSON.stringify(await window.solstoneJournalHost.send({type:'future.example', id:'unknown-1'}))",
            contentWorld: .page
        ) as? String
        XCTAssertEqual(unsupported, #"{"type":"unsupported","id":"unknown-1"}"#)
        let mainFrame = try await webView.callAsyncJavaScript(
            "return await window.webkit.messageHandlers.journalImport.postMessage(JSON.stringify({documentId: crypto.randomUUID(), message: {type: 'host.status', item: 'x'}}))",
            contentWorld: .page
        ) as? String
        XCTAssertEqual(mainFrame, #"{"state":"gone"}"#)

        let inFrame = try await webView.evaluateJavaScript("typeof document.querySelector('iframe').contentWindow.solstoneJournalHost") as? String
        XCTAssertEqual(inFrame, "undefined")
        let frameCall = try await webView.callAsyncJavaScript(
            """
            const frame = document.querySelector('iframe').contentWindow;
            try {
              await frame.webkit.messageHandlers.journalImport.postMessage(JSON.stringify({documentId: frame.crypto.randomUUID(), message: {type: 'host.status', item: 'x'}}));
              return 'answered';
            } catch (error) { return 'refused'; }
            """,
            contentWorld: .page
        ) as? String
        XCTAssertEqual(frameCall, "refused")

        let (other, otherHost) = try self.makeWebView(intake: intake)
        defer { otherHost.teardown(controller: other.configuration.userContentController) }
        try await self.load("<!doctype html><title>elsewhere</title>", baseURL: URL(string: "http://127.0.0.1:54322/")!, in: other)
        let otherOrigin = try await other.evaluateJavaScript("typeof window.solstoneJournalHost") as? String
        XCTAssertEqual(otherOrigin, "undefined")
        let elsewhere = try await other.callAsyncJavaScript(
            """
            try {
              await window.webkit.messageHandlers.journalImport.postMessage(JSON.stringify({documentId: crypto.randomUUID(), message: {type: 'host.status', item: 'x'}}));
              return 'answered';
            } catch (error) { return 'refused'; }
            """,
            contentWorld: .page
        ) as? String
        XCTAssertEqual(elsewhere, "refused")
    }

    // MARK: - Helpers

    private func makeHost(
        _ intake: FakeImportIntake,
        presentPicker: (@MainActor (UIViewController) -> Bool)? = nil
    ) throws -> JournalImportHost {
        try XCTUnwrap(JournalImportHost(entryURL: self.entryURL, intake: intake, presentPicker: presentPicker))
    }

    private func makeWebView(intake: FakeImportIntake) throws -> (WKWebView, JournalImportHost) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let host = try self.makeHost(intake)
        host.install(in: configuration.userContentController)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        host.attach(to: webView)
        return (webView, host)
    }

    private func load(_ html: String, baseURL: URL, in webView: WKWebView) async throws {
        webView.loadHTMLString(html, baseURL: baseURL)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            if !webView.isLoading,
               (try? await webView.evaluateJavaScript("document.readyState")) as? String == "complete" {
                return
            }
        }
        XCTFail("page did not load")
    }

    private func send(_ message: [String: Any], to host: JournalImportHost) async throws -> [String: Any] {
        try self.object(try await host.handle(packet: try self.packet(message)).get())
    }

    private func packet(_ message: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["documentId": self.documentID, "message": message])
        return String(decoding: data, as: UTF8.self)
    }

    private func object(_ reply: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    }
}

@MainActor
private final class FakeImportIntake: JournalImportIntake {
    var handoffs: [ShareImportHandoff] = []
    var names: [[String]] = []
    var issued: [UUID] = []
    var states: [UUID: JournalImportItemState] = [:]

    func take(_ providers: [any ShareItemProvider], names: [String], handoff: ShareImportHandoff) async -> JournalImportIntakeResult {
        self.handoffs.append(handoff)
        self.names.append(names)
        var result = JournalImportIntakeResult()
        for name in names {
            let item = UUID()
            self.issued.append(item)
            result.accepted.append(.init(item: item, name: name, size: nil))
        }
        return result
    }

    func state(of item: UUID) async -> JournalImportItemState {
        self.states[item] ?? .gone
    }
}
