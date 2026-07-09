// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum ShareImportSaveBody {
    static func build(
        item: TransferStoredItem,
        spool: TransferSpool,
        observerHandle: String
    ) throws -> Data {
        guard item.manifest.endpoint.destinationKind == .saveThenStart else {
            throw TransferBodyBuildError.malformedManifest("unsupported save destination")
        }
        guard item.manifest.payloadParts.count == 1,
              let part = item.manifest.payloadParts.first
        else {
            throw TransferBodyBuildError.malformedManifest("save requires one payload")
        }

        let rawData: Data
        do {
            rawData = try spool.payloadData(for: part, in: item)
        } catch {
            throw TransferBodyBuildError.missingPayload(part.filename)
        }

        let boundary = TransferTransport.boundary(for: item.manifest.itemID)
        var body = Data()
        body.append(self.multipartField(named: "imported_via", value: "mobile_share", boundary: boundary))
        body.append(self.multipartField(named: "observer_handle", value: observerHandle, boundary: boundary))
        body.append(self.multipartField(
            named: "client_item_id",
            value: item.manifest.itemID.uuidString.lowercased(),
            boundary: boundary
        ))

        switch part.kind {
        case .text:
            guard let text = String(data: rawData, encoding: .utf8) else {
                throw TransferBodyBuildError.malformedManifest("text payload is not utf8")
            }
            body.append(self.multipartField(named: "text", value: text, boundary: boundary))
        case .file:
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(part.filename)\"\r\n".utf8))
            body.append(Data("Content-Type: \(part.contentType)\r\n\r\n".utf8))
            body.append(rawData)
            body.append(Data("\r\n".utf8))
        case .audio, .location, .screen:
            throw TransferBodyBuildError.malformedManifest("unsupported save payload")
        }

        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    private static func multipartField(named name: String, value: String, boundary: String) -> Data {
        Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
    }
}
