// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Foundation
import UserNotifications
import os

private let envelopeLog = Logger(subsystem: "app.solstone.swift", category: "push-envelope")

enum PushEnvelopeError: Error, Equatable, Sendable {
    case badEnvelope
    case badVersion
    case authFailed
    case badPlaintext
    case noKey
    case keyUnavailable
    case pushKeyFailed

    var reasonCode: String {
        switch self {
        case .badEnvelope:
            "bad_envelope"
        case .badVersion:
            "bad_version"
        case .authFailed:
            "auth_failed"
        case .badPlaintext:
            "bad_plaintext"
        case .noKey:
            "no_key"
        case .keyUnavailable:
            "key_unavailable"
        case .pushKeyFailed:
            "push_key_failed"
        }
    }
}

nonisolated struct DecryptedPushPayload: Sendable, Equatable {
    let version: Int
    let timestamp: String?
    let kind: String
    let title: String
    let body: String
    let open: String?
    let rawJSON: String
}

extension Data {
    func base64URLEncodedString() -> String {
        self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

nonisolated func isValidOpenPath(_ path: String) -> Bool {
    PushEnvelope.isValidOpenPath(path)
}

nonisolated enum PushEnvelope {
    static func isValidOpenPath(_ path: String) -> Bool {
        guard path.hasPrefix("/app/") else { return false }
        guard !path.contains("//") else { return false }
        guard !path.contains("\\") else { return false }

        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        for segment in segments {
            if segment == "." || segment == ".." {
                return false
            }
        }

        let regex = try? NSRegularExpression(pattern: "^/[A-Za-z0-9._~/-]*$")
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        return regex?.firstMatch(in: path, range: range) != nil
    }

    static func unpadPlaintext(_ paddedBytes: Data) throws -> Data {
        var endIndex = paddedBytes.count
        while endIndex > 0 && paddedBytes[endIndex - 1] == 0x00 {
            endIndex -= 1
        }
        guard endIndex > 0 && paddedBytes[endIndex - 1] == 0x80 else {
            throw PushEnvelopeError.badPlaintext
        }
        return paddedBytes.subdata(in: 0..<(endIndex - 1))
    }

    static func decodeBase64URL(_ string: String) -> Data? {
        guard string.count == 1404 else { return nil }
        let regex = try? NSRegularExpression(pattern: "^[A-Za-z0-9_-]{1404}$")
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard regex?.firstMatch(in: string, range: range) != nil else { return nil }

        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }

    static func unseal(envelope: String, key: Data) -> DecryptedPushPayload? {
        try? self.unsealThrowing(envelopeString: envelope, keyBytes: key)
    }

    static func unsealThrowing(envelopeString: String, keyBytes: Data) throws -> DecryptedPushPayload {
        guard keyBytes.count == 32 else {
            throw PushEnvelopeError.noKey
        }
        guard let envelopeData = self.decodeBase64URL(envelopeString),
              envelopeData.count == 1053
        else {
            throw PushEnvelopeError.badEnvelope
        }

        guard envelopeData[0] == 0x01 else {
            throw PushEnvelopeError.badVersion
        }

        let combined = envelopeData.subdata(in: 1..<1053)
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(combined: combined)
        } catch {
            throw PushEnvelopeError.badEnvelope
        }

        let key = SymmetricKey(data: keyBytes)
        let decryptedPadded: Data
        do {
            decryptedPadded = try AES.GCM.open(sealedBox, using: key, authenticating: Data([0x01]))
        } catch {
            throw PushEnvelopeError.authFailed
        }

        guard decryptedPadded.count == 1024 else {
            throw PushEnvelopeError.badPlaintext
        }

        let unpaddedData = try self.unpadPlaintext(decryptedPadded)
        guard let jsonString = String(data: unpaddedData, encoding: .utf8) else {
            throw PushEnvelopeError.badPlaintext
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: unpaddedData),
              let dict = jsonObject as? [String: Any]
        else {
            throw PushEnvelopeError.badPlaintext
        }

        guard let version = dict["v"] as? Int, version == 1,
              let kind = dict["kind"] as? String,
              let title = dict["title"] as? String,
              let body = dict["body"] as? String
        else {
            throw PushEnvelopeError.badPlaintext
        }

        let timestamp = dict["at"] as? String
        let open: String?
        if let rawOpen = dict["open"] {
            guard let openString = rawOpen as? String else {
                throw PushEnvelopeError.badPlaintext
            }
            open = openString
        } else {
            open = nil
        }

        return DecryptedPushPayload(
            version: version,
            timestamp: timestamp,
            kind: kind,
            title: title,
            body: body,
            open: open,
            rawJSON: jsonString
        )
    }

    static let fallbackTitle = "solstone"
    static let fallbackBody = "you have a new notification."

    /// What the phone shows when a notification can't be opened. Built here, never taken from the delivered alert.
    static func fallbackContent() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = self.fallbackTitle
        content.body = self.fallbackBody
        content.sound = .default
        return content
    }

    static func mutateContent(
        request: UNNotificationRequest,
        keyStore: PushKeyStore
    ) throws -> UNMutableNotificationContent {
        guard let envelopeString = request.content.userInfo["e"] as? String else {
            throw PushEnvelopeError.badEnvelope
        }

        let keyData: Data?
        do {
            keyData = try keyStore.load()
        } catch PushKeyStoreError.interactionNotAllowed {
            throw PushEnvelopeError.keyUnavailable
        } catch {
            throw PushEnvelopeError.noKey
        }

        guard let keyData else {
            throw PushEnvelopeError.noKey
        }

        let payload = try self.unsealThrowing(envelopeString: envelopeString, keyBytes: keyData)

        guard let mutableContent = request.content.mutableCopy() as? UNMutableNotificationContent else {
            throw PushEnvelopeError.badPlaintext
        }

        // Routing reads only what was decrypted: drop any routing keys the delivered alert carried.
        mutableContent.userInfo.removeValue(forKey: "solstone.open")
        mutableContent.userInfo.removeValue(forKey: "data")
        mutableContent.categoryIdentifier = ""
        mutableContent.title = payload.title
        mutableContent.body = payload.body
        mutableContent.threadIdentifier = payload.kind

        if let open = payload.open, isValidOpenPath(open) {
            mutableContent.userInfo["solstone.open"] = open
        }

        return mutableContent
    }
}
