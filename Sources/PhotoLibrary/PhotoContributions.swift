// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

/// What the journal has done with a photo it took in.
nonisolated enum PhotoProcessingStatus: Equatable, Sendable {
    case processing
    case described
    /// Saved, but no model could describe it.
    case notDescribed
    case failed

    var isSettled: Bool {
        self != .processing
    }

    /// The journal's import detail (`GET /app/import/api/{id}`): its `status`, and
    /// `unavailable_description` when an image was saved without one. A status this
    /// app does not know reads as unknown, never as a guess.
    static func parse(_ data: Data) -> PhotoProcessingStatus? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let status = object["status"] as? String
        else {
            return nil
        }
        switch status {
        case "pending", "running":
            return .processing
        case "failed":
            return .failed
        case "success":
            return self.isPresent(object["unavailable_description"]) ? .notDescribed : .described
        default:
            return nil
        }
    }

    private static func isPresent(_ value: Any?) -> Bool {
        switch value {
        case let string as String:
            return !string.isEmpty
        case let flag as Bool:
            return flag
        case nil, is NSNull:
            return false
        default:
            return true
        }
    }
}

nonisolated struct PhotoProcessingStatusReader: Sendable {
    func fetch(localPort: Int, importID: String) async -> PhotoProcessingStatus? {
        let log = Logger(subsystem: "app.solstone.swift", category: "photo-library")
        guard let encoded = importID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = ConveyURL.url(localPort: localPort, path: "/app/import/api/\(encoded)")
        else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.attachLoopbackCapability()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                log.debug("photo processing status unavailable: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0, privacy: .public)")
                return nil
            }
            return PhotoProcessingStatus.parse(data)
        } catch {
            log.debug("photo processing status unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// One photo that came in from Photos, picked or from the library, as the photo library
/// screen lists it.
nonisolated struct PhotoContribution: Equatable, Sendable, Identifiable {
    let id: String
    let filename: String?
    let itemTime: Date?
    let sendState: OnThisPhoneSendState
    /// The journal's import id, once the photo is in the journal.
    let importID: String?
    var processing: PhotoProcessingStatus?

    /// The newest photo contributions, from the import items this device knows about.
    static func recent(
        items: [OnThisPhoneItem],
        ledger: [String: ShareImportStore.LedgerEntry],
        limit: Int = 8
    ) -> [PhotoContribution] {
        let photos = items.filter { $0.sourceKind == .share && $0.originApp == ShareImportOrigin.photos }
        return OnThisPhoneItemSort.newestFirst(photos).prefix(limit).map { item in
            PhotoContribution(
                id: item.id,
                filename: item.filename,
                itemTime: item.itemTime ?? item.deliveredAt,
                sendState: item.sendState,
                importID: item.sendState == .inYourJournal ? ledger[item.id]?.serverTimestamp : nil,
                processing: nil
            )
        }
    }
}
