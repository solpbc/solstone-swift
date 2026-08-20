// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum ShareImportSaveBody {
    static func build(
        item: TransferStoredItem,
        spool: TransferSpool,
        observerHandle: String
    ) throws -> TransferBodyPayload {
        guard item.manifest.endpoint.destinationKind == .saveThenStart else {
            throw TransferBodyBuildError.malformedManifest("unsupported save destination")
        }
        guard item.manifest.payloadParts.count == 1,
              let part = item.manifest.payloadParts.first
        else {
            throw TransferBodyBuildError.malformedManifest("save requires one payload")
        }

        let boundary = TransferTransport.boundary(for: item.manifest.itemID)
        switch part.kind {
        case .text:
            let rawData: Data
            do {
                rawData = try spool.payloadData(for: part, in: item)
            } catch {
                throw TransferBodyBuildError.missingPayload(part.filename)
            }
            guard let text = String(data: rawData, encoding: .utf8) else {
                throw TransferBodyBuildError.malformedManifest("text payload is not utf8")
            }
            var body = Data()
            body.append(self.prefixFields(item: item, observerHandle: observerHandle, boundary: boundary))
            body.append(self.multipartField(named: "text", value: text, boundary: boundary))
            body.append(self.closing(boundary: boundary))
            return .inMemory(body)
        case .file:
            guard let payloadURL = try spool.existingPayloadURL(for: part, in: item) else {
                throw TransferBodyBuildError.missingPayload(part.filename)
            }
            let payloadLength = try spool.payloadByteCount(for: part, in: item)
            let wrapping = self.fileWrapping(
                item: item,
                part: part,
                observerHandle: observerHandle,
                boundary: boundary
            )
            let expected = wrapping.prefix.count + payloadLength + wrapping.suffix.count
            let written = try spool.writeBodyStream(for: item) { sink in
                try sink.append(wrapping.prefix)
                try sink.append(contentsOf: payloadURL)
                try sink.append(wrapping.suffix)
            }
            guard written.byteCount == expected else {
                throw TransferBodyBuildError.malformedManifest("body length mismatch")
            }
            return .written(url: written.url, byteCount: written.byteCount)
        case .audio, .location, .screen:
            throw TransferBodyBuildError.malformedManifest("unsupported save payload")
        }
    }

    static func fileWrappingByteCount(
        item: TransferStoredItem,
        observerHandle: String
    ) throws -> Int {
        guard item.manifest.payloadParts.count == 1,
              let part = item.manifest.payloadParts.first
        else {
            throw TransferBodyBuildError.malformedManifest("save requires one payload")
        }
        let wrapping = self.fileWrapping(
            item: item,
            part: part,
            observerHandle: observerHandle,
            boundary: TransferTransport.boundary(for: item.manifest.itemID)
        )
        return wrapping.prefix.count + wrapping.suffix.count
    }

    private static func fileWrapping(
        item: TransferStoredItem,
        part: TransferPayloadPartDescriptor,
        observerHandle: String,
        boundary: String
    ) -> (prefix: Data, suffix: Data) {
        var prefix = self.prefixFields(item: item, observerHandle: observerHandle, boundary: boundary)
        prefix.append(Data("--\(boundary)\r\n".utf8))
        prefix.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(part.filename)\"\r\n".utf8))
        prefix.append(Data("Content-Type: \(part.contentType)\r\n\r\n".utf8))
        var suffix = Data("\r\n".utf8)
        suffix.append(self.closing(boundary: boundary))
        return (prefix, suffix)
    }

    private static func prefixFields(
        item: TransferStoredItem,
        observerHandle: String,
        boundary: String
    ) -> Data {
        var fields = Data()
        fields.append(self.multipartField(named: "imported_via", value: "mobile_share", boundary: boundary))
        fields.append(self.multipartField(named: "observer_handle", value: observerHandle, boundary: boundary))
        fields.append(self.multipartField(
            named: "client_item_id",
            value: item.manifest.itemID.uuidString.lowercased(),
            boundary: boundary
        ))
        return fields
    }

    private static func closing(boundary: String) -> Data {
        Data("--\(boundary)--\r\n".utf8)
    }

    private static func multipartField(named name: String, value: String, boundary: String) -> Data {
        Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
    }
}
