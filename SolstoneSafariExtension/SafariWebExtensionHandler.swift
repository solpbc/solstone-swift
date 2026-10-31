// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SafariServices
import os
import Darwin

@objc(SafariWebExtensionHandler)
nonisolated final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let start = Date().timeIntervalSince1970
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        var reply: [String: Any] = ["v": 1, "pid": ProcessInfo.processInfo.processIdentifier,
            "time_ms": start * 1000]
        do {
            guard let message, message["v"] as? Int == 1 else { throw SafariBrowserError.malformed }
            let store = try SafariBrowserStore()
            if message["probe"] as? Bool == true {
                reply["inventory"] = try store.inventory()
                let count = message["replyBytes"] as? Int ?? 0
                guard (0...65536).contains(count) else { throw SafariBrowserError.malformed }
                reply["padding"] = String(repeating: "x", count: count)
            } else {
                guard let c = message["c"] as? String,
                    let root = Bundle.main.resourceURL?.appendingPathComponent("SafariVendor") else { throw SafariBrowserError.malformed }
                let frame = message["f"] as? String
                if let frame, frame.utf8.count > 33554432 { throw SafariBrowserError.full }
                let projection = try BrowserContractProjection(rootURL: root)
                reply["c"] = c
                #if DEBUG
                // Development HIL crash cuts. Release builds cannot request a kill.
                let cut = message["test_cut"] as? String
                reply["f"] = try store.exchange(connection: c, frame: frame, projection: projection,
                    beforeCustodyCommit: { if cut == "before_commit" { kill(getpid(), SIGKILL) } })
                if cut == "after_commit" { kill(getpid(), SIGKILL) }
                #else
                reply["f"] = try store.exchange(connection: c, frame: frame, projection: projection)
                #endif
            }
        } catch {
            reply["closed"] = true
            reply["error"] = error is SafariBrowserError ? String(describing: error) : "native_unavailable"
            if let c = message?["c"] { reply["c"] = c }
            Logger(subsystem: "app.solstone.swift", category: "safari").error("Safari native request refused")
        }
        reply["duration_ms"] = (Date().timeIntervalSince1970 - start) * 1000
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
