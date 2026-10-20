// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

/// Tests envelope decryption against vectors from docs/design/push-envelope-vectors.json
/// generated at journal commit b52c584be.

@testable import solstone_swift
import CryptoKit
import Foundation
import UserNotifications
import XCTest

private struct PushVectorsFile: Decodable {
    let vectors: [PushVector]
}

private struct PushVector: Decodable {
    let id: String
    let key: String
    let nonce: String?
    let plaintext_json: String?
    let envelope: String?
    let expect: String
}

nonisolated final class PushEnvelopeTests: XCTestCase {
    func testPushEnvelopeVectorsFromFixture() throws {
        guard let fixtureURL = Bundle(for: PushEnvelopeTests.self).url(
            forResource: "push-envelope-vectors",
            withExtension: "json"
        ) ?? Bundle.main.url(
            forResource: "push-envelope-vectors",
            withExtension: "json"
        ) else {
            let sourcePath = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/PushEnvelope/push-envelope-vectors.json")
            let data = try Data(contentsOf: sourcePath)
            try self.runVectors(from: data)
            return
        }

        let data = try Data(contentsOf: fixtureURL)
        try self.runVectors(from: data)
    }

    private func runVectors(from data: Data) throws {
        let fixture = try JSONDecoder().decode(PushVectorsFile.self, from: data)

        for vector in fixture.vectors {
            let key = try Self.dataFromHex(vector.key)

            switch vector.id {
            case "a", "a2", "b", "c":
                guard let envelope = vector.envelope else {
                    XCTFail("Vector \(vector.id) expected envelope")
                    continue
                }
                let payload = try PushEnvelope.unsealThrowing(envelopeString: envelope, keyBytes: key)
                XCTAssertEqual(payload.rawJSON, vector.plaintext_json, "Vector \(vector.id) rawJSON mismatch")
            case "d":
                XCTAssertNil(vector.envelope, "Vector d has no envelope, skipped")
                XCTAssertEqual(vector.expect, "too_large")
            case "e":
                guard let envelope = vector.envelope else {
                    XCTFail("Vector e expected envelope")
                    continue
                }
                XCTAssertThrowsError(try PushEnvelope.unsealThrowing(envelopeString: envelope, keyBytes: key)) { error in
                    XCTAssertEqual(error as? PushEnvelopeError, .authFailed, "Vector e expected authFailed")
                }
            case "f":
                guard let envelope = vector.envelope else {
                    XCTFail("Vector f expected envelope")
                    continue
                }
                XCTAssertThrowsError(try PushEnvelope.unsealThrowing(envelopeString: envelope, keyBytes: key)) { error in
                    XCTAssertEqual(error as? PushEnvelopeError, .badVersion, "Vector f expected badVersion")
                }
            default:
                break
            }
        }
    }

    func testLiteralVectorAOpensAndPinsDecodedSHA256() throws {
        let literalEnvelope = "AQABAgMEBQYHCAkKCzwgoDn_1O457DW1sZPbSF-1-7cN3UlrKAhX37UtUzCCWzKC3sSofPxWnl2Z7fRcGsJ7FOQuusb4BbVZdnSQgYGeWeRW8bNJBWV2kEyb6n2cGOSmFh8FOgucifejFtDf_6SVeZ_LNLo69HNLwCYUTVGYGuKr48Ulmk3_V82C5m4Ou1IAxrTXy1MI4UihPdpMwjb04zU1EZNKjF_od_rS6e6Tl54V6f_Mfqdj3frfgIa7nc7KIourc7xl38DHccW38xNMivoN3dbJN1bT5rpB2YThfvh2PQC68XGRmsdBSI_6QyPUr-YgAyVSR7gItRF8UaiTuXWdMImlF2tnc4ucQoEU0fKQndpIPnffcge3LToK2rTKzYCLga9xL21RCvS6SwED3ki6xc4Xkjw6WgqVoNOYylteSZTPF5gxHRaXPUXpyZV_KotgeOmj4HsgXdMdYpMa14ScFIUISaN4Zo2xSP9ZL_nZhVRyyyCvpCOXtWIohP0fee7xAMGf5TTc3FdZMqWDwNmHB9PcoXD-fz5AEofiC2y7nyBS1D0Q3kZN5rtWGXpXa8PRUXKguNxS__iwpV1rRBIcgyDl57nj7YarH3h6eq7drle_fesa4FfxlNVRaYprUsOaHjxDxbqwEf-GtBnvKQGXk9_OUaoEjeis7YCQrNGaPa7hILcCkV3H6FMcoWzq-L8x3FdBu-F9OhJhuIeyOzpue9K0j2VAN7dUHrBsDzaH7EewCzDUV6bKb1vtRq-XP63FdGUK5yrAiiCKUXPtyg40ADdM0KC2g4SYTYcHlp60FYnx77YPuqUj2Cvdt0CXKtp3tJY1m9yDEGbWVXmTRC00vLnfGxIJEt3Wpyol0Y1AtsMY0RfObSbyPw2Ubn2JsRopkOxA2r_k0OWYzYOVRy0YS35ctyXIuxlBMoRvQcW9d8fK98XgNyvDcBARWKfeUwZgzTlmA0e4yvYlh3lLPlWoStjiyv-QjrmA0MauUj3L7MctzhfOhwbx0B2sQxFwWOEBr_e24LmBx2eaj-vrAV3OANH3nIRC5mtemuKM21EjvYD1hnfz5FOAvZaYsNNbB3fAHd8fob2apzYjjfYKRqh3moHQNnfErzZNoaA38ll4vL7Di8D7_4LWCLugF9N1VUQF8n4qIPHppVD4ogdz7lvoxJ1Oj6e0X8N-VqzY0L1c4nLbkIGe5nbE3le2AcSgz8e3Ljt_OoDOTz2HJ2rXXsN3o8a0GOLKLcPDWNeu9iw4Zr-TrVNvZSTBRSom5vUYjUgvsbDZZ_l_DVVgqjIYmBqmBfHJLNG2HcsJV4JQKTHG-wpHQFKx1iyssa5N7PKiXkO5dCXRrkf1SfQbTITj9acKMSs4iO9dkptWTq_Xjj59SFOxPrU7hIt1FJEz"
        let key = Data(0..<32)

        let decoded = try XCTUnwrap(PushEnvelope.decodeBase64URL(literalEnvelope))
        XCTAssertEqual(decoded.count, 1053)
        let hash = SHA256.hash(data: decoded).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, "824015e69eb95a3edb150c4e9e1b8c3e0df60a8d2064bc5681b565a543639070")

        let payload = try PushEnvelope.unsealThrowing(envelopeString: literalEnvelope, keyBytes: key)
        XCTAssertEqual(payload.rawJSON, "{\"v\":1,\"at\":\"2026-09-24T00:00:00Z\",\"kind\":\"test\",\"title\":\"solstone\",\"body\":\"test notification from your journal.\"}")
        XCTAssertEqual(payload.title, "solstone")
        XCTAssertEqual(payload.body, "test notification from your journal.")
        XCTAssertEqual(payload.kind, "test")
        XCTAssertNil(payload.open)
    }

    func testBadVersionFromBuffer() {
        var buffer = Data(repeating: 0x00, count: 1053)
        buffer[0] = 0x02
        let envelope = buffer.base64URLEncodedString()
        let key = Data(repeating: 0x01, count: 32)
        XCTAssertThrowsError(try PushEnvelope.unsealThrowing(envelopeString: envelope, keyBytes: key)) { error in
            XCTAssertEqual(error as? PushEnvelopeError, .badVersion)
        }
    }

    func testEnvelopeStringValidation() {
        let key = Data(repeating: 0x01, count: 32)
        let len1403 = String(repeating: "a", count: 1403)
        let len1405 = String(repeating: "a", count: 1405)
        var withPlus = String(repeating: "a", count: 1404)
        withPlus.replaceSubrange(withPlus.startIndex...withPlus.startIndex, with: "+")
        var withSlash = String(repeating: "a", count: 1404)
        withSlash.replaceSubrange(withSlash.startIndex...withSlash.startIndex, with: "/")

        XCTAssertThrowsError(try PushEnvelope.unsealThrowing(envelopeString: len1403, keyBytes: key)) { error in
            XCTAssertEqual(error as? PushEnvelopeError, .badEnvelope)
        }
        XCTAssertThrowsError(try PushEnvelope.unsealThrowing(envelopeString: len1405, keyBytes: key)) { error in
            XCTAssertEqual(error as? PushEnvelopeError, .badEnvelope)
        }
        XCTAssertThrowsError(try PushEnvelope.unsealThrowing(envelopeString: withPlus, keyBytes: key)) { error in
            XCTAssertEqual(error as? PushEnvelopeError, .badEnvelope)
        }
        XCTAssertThrowsError(try PushEnvelope.unsealThrowing(envelopeString: withSlash, keyBytes: key)) { error in
            XCTAssertEqual(error as? PushEnvelopeError, .badEnvelope)
        }
    }

    func testErrorMappingNoKeyKeyUnavailableAuthFailedBadPlaintext() throws {
        let key = Data(repeating: 0x01, count: 32)
        let wrongKey = Data(repeating: 0x02, count: 32)

        // No key
        XCTAssertThrowsError(try PushEnvelope.unsealThrowing(envelopeString: String(repeating: "a", count: 1404), keyBytes: Data())) { error in
            XCTAssertEqual(error as? PushEnvelopeError, .noKey)
        }

        // keyUnavailable from interactionNotAllowed
        let lockedSeam = PushKeyStore.SecItemSeam(
            copy: { _ in (errSecInteractionNotAllowed, nil) },
            add: { _ in errSecInteractionNotAllowed },
            delete: { _ in errSecInteractionNotAllowed }
        )
        let lockedStore = PushKeyStore(seam: lockedSeam, prefix: "7QCG8V4M6H.")
        let mutableReq = UNMutableNotificationContent()
        mutableReq.userInfo = ["e": String(repeating: "a", count: 1404)]
        let request = UNNotificationRequest(identifier: "test", content: mutableReq, trigger: nil)
        XCTAssertThrowsError(try PushEnvelope.mutateContent(
            request: request,
            keyStore: lockedStore,
            locale: Locale(identifier: "en_US"),
            bundle: Bundle(for: PushEnvelope.self)
        )) { error in
            XCTAssertEqual(error as? PushEnvelopeError, .keyUnavailable)
        }

        // Missing e returns badEnvelope
        let emptyReq = UNMutableNotificationContent()
        let emptyRequest = UNNotificationRequest(identifier: "empty", content: emptyReq, trigger: nil)
        let memStore = PushKeyStore.memory()
        _ = try memStore.loadOrCreate()
        XCTAssertThrowsError(try PushEnvelope.mutateContent(
            request: emptyRequest,
            keyStore: memStore,
            locale: Locale(identifier: "en_US"),
            bundle: Bundle(for: PushEnvelope.self)
        )) { error in
            XCTAssertEqual(error as? PushEnvelopeError, .badEnvelope)
        }

        // Right shape under wrong key -> authFailed
        let literalEnvelope = "AQABAgMEBQYHCAkKCzwgoDn_1O457DW1sZPbSF-1-7cN3UlrKAhX37UtUzCCWzKC3sSofPxWnl2Z7fRcGsJ7FOQuusb4BbVZdnSQgYGeWeRW8bNJBWV2kEyb6n2cGOSmFh8FOgucifejFtDf_6SVeZ_LNLo69HNLwCYUTVGYGuKr48Ulmk3_V82C5m4Ou1IAxrTXy1MI4UihPdpMwjb04zU1EZNKjF_od_rS6e6Tl54V6f_Mfqdj3frfgIa7nc7KIourc7xl38DHccW38xNMivoN3dbJN1bT5rpB2YThfvh2PQC68XGRmsdBSI_6QyPUr-YgAyVSR7gItRF8UaiTuXWdMImlF2tnc4ucQoEU0fKQndpIPnffcge3LToK2rTKzYCLga9xL21RCvS6SwED3ki6xc4Xkjw6WgqVoNOYylteSZTPF5gxHRaXPUXpyZV_KotgeOmj4HsgXdMdYpMa14ScFIUISaN4Zo2xSP9ZL_nZhVRyyyCvpCOXtWIohP0fee7xAMGf5TTc3FdZMqWDwNmHB9PcoXD-fz5AEofiC2y7nyBS1D0Q3kZN5rtWGXpXa8PRUXKguNxS__iwpV1rRBIcgyDl57nj7YarH3h6eq7drle_fesa4FfxlNVRaYprUsOaHjxDxbqwEf-GtBnvKQGXk9_OUaoEjeis7YCQrNGaPa7hILcCkV3H6FMcoWzq-L8x3FdBu-F9OhJhuIeyOzpue9K0j2VAN7dUHrBsDzaH7EewCzDUV6bKb1vtRq-XP63FdGUK5yrAiiCKUXPtyg40ADdM0KC2g4SYTYcHlp60FYnx77YPuqUj2Cvdt0CXKtp3tJY1m9yDEGbWVXmTRC00vLnfGxIJEt3Wpyol0Y1AtsMY0RfObSbyPw2Ubn2JsRopkOxA2r_k0OWYzYOVRy0YS35ctyXIuxlBMoRvQcW9d8fK98XgNyvDcBARWKfeUwZgzTlmA0e4yvYlh3lLPlWoStjiyv-QjrmA0MauUj3L7MctzhfOhwbx0B2sQxFwWOEBr_e24LmBx2eaj-vrAV3OANH3nIRC5mtemuKM21EjvYD1hnfz5FOAvZaYsNNbB3fAHd8fob2apzYjjfYKRqh3moHQNnfErzZNoaA38ll4vL7Di8D7_4LWCLugF9N1VUQF8n4qIPHppVD4ogdz7lvoxJ1Oj6e0X8N-VqzY0L1c4nLbkIGe5nbE3le2AcSgz8e3Ljt_OoDOTz2HJ2rXXsN3o8a0GOLKLcPDWNeu9iw4Zr-TrVNvZSTBRSom5vUYjUgvsbDZZ_l_DVVgqjIYmBqmBfHJLNG2HcsJV4JQKTHG-wpHQFKx1iyssa5N7PKiXkO5dCXRrkf1SfQbTITj9acKMSs4iO9dkptWTq_Xjj59SFOxPrU7hIt1FJEz"
        XCTAssertThrowsError(try PushEnvelope.unsealThrowing(envelopeString: literalEnvelope, keyBytes: wrongKey)) { error in
            XCTAssertEqual(error as? PushEnvelopeError, .authFailed)
        }

        // v of 2 -> badPlaintext
        let v2Envelope = try self.sealPlaintext("{\"v\":2,\"kind\":\"test\",\"title\":\"t\",\"body\":\"b\"}", key: key)
        XCTAssertThrowsError(try PushEnvelope.unsealThrowing(envelopeString: v2Envelope, keyBytes: key)) { error in
            XCTAssertEqual(error as? PushEnvelopeError, .badPlaintext)
        }

        // missing title -> badPlaintext
        let noTitleEnvelope = try self.sealPlaintext("{\"v\":1,\"kind\":\"test\",\"body\":\"b\"}", key: key)
        XCTAssertThrowsError(try PushEnvelope.unsealThrowing(envelopeString: noTitleEnvelope, keyBytes: key)) { error in
            XCTAssertEqual(error as? PushEnvelopeError, .badPlaintext)
        }

        // missing body -> badPlaintext
        let noBodyEnvelope = try self.sealPlaintext("{\"v\":1,\"kind\":\"test\",\"title\":\"t\"}", key: key)
        XCTAssertThrowsError(try PushEnvelope.unsealThrowing(envelopeString: noBodyEnvelope, keyBytes: key)) { error in
            XCTAssertEqual(error as? PushEnvelopeError, .badPlaintext)
        }

        // missing kind -> badPlaintext
        let noKindEnvelope = try self.sealPlaintext("{\"v\":1,\"title\":\"t\",\"body\":\"b\"}", key: key)
        XCTAssertThrowsError(try PushEnvelope.unsealThrowing(envelopeString: noKindEnvelope, keyBytes: key)) { error in
            XCTAssertEqual(error as? PushEnvelopeError, .badPlaintext)
        }
    }

    private func sealPlaintext(_ json: String, key: Data) throws -> String {
        var data = json.data(using: .utf8)!
        data.append(0x80)
        let padLen = 1024 - data.count
        if padLen > 0 {
            data.append(Data(repeating: 0x00, count: padLen))
        }
        let symKey = SymmetricKey(data: key)
        let nonce = try AES.GCM.Nonce(data: Data(0..<12))
        let box = try AES.GCM.seal(data, using: symKey, nonce: nonce, authenticating: Data([0x01]))
        var combined = Data([0x01])
        combined.append(box.combined!)
        return combined.base64URLEncodedString()
    }

    func testMutateContentPreservesMetadataAndLeavesOriginalUnchanged() throws {
        let originalContent = UNMutableNotificationContent()
        originalContent.title = "original title"
        originalContent.body = "original body"
        originalContent.sound = .default
        originalContent.categoryIdentifier = "SOLSTONE_CUSTOM"
        originalContent.badge = 3
        originalContent.userInfo = [
            "aps": ["alert": "test"],
            "e": "AQABAgMEBQYHCAkKCzwgoDn_1O457DW1sZPbSF-1-7cN3UlrKAhX37UtUzCCWzKC3sSofPxWnl2Z7fRcGsJ7FOQuusb4BbVZdnSQgYGeWeRW8bNJBWV2kEyb6n2cGOSmFh8FOgucifejFtDf_6SVeZ_LNLo69HNLwCYUTVGYGuKr48Ulmk3_V82C5m4Ou1IAxrTXy1MI4UihPdpMwjb04zU1EZNKjF_od_rS6e6Tl54V6f_Mfqdj3frfgIa7nc7KIourc7xl38DHccW38xNMivoN3dbJN1bT5rpB2YThfvh2PQC68XGRmsdBSI_6QyPUr-YgAyVSR7gItRF8UaiTuXWdMImlF2tnc4ucQoEU0fKQndpIPnffcge3LToK2rTKzYCLga9xL21RCvS6SwED3ki6xc4Xkjw6WgqVoNOYylteSZTPF5gxHRaXPUXpyZV_KotgeOmj4HsgXdMdYpMa14ScFIUISaN4Zo2xSP9ZL_nZhVRyyyCvpCOXtWIohP0fee7xAMGf5TTc3FdZMqWDwNmHB9PcoXD-fz5AEofiC2y7nyBS1D0Q3kZN5rtWGXpXa8PRUXKguNxS__iwpV1rRBIcgyDl57nj7YarH3h6eq7drle_fesa4FfxlNVRaYprUsOaHjxDxbqwEf-GtBnvKQGXk9_OUaoEjeis7YCQrNGaPa7hILcCkV3H6FMcoWzq-L8x3FdBu-F9OhJhuIeyOzpue9K0j2VAN7dUHrBsDzaH7EewCzDUV6bKb1vtRq-XP63FdGUK5yrAiiCKUXPtyg40ADdM0KC2g4SYTYcHlp60FYnx77YPuqUj2Cvdt0CXKtp3tJY1m9yDEGbWVXmTRC00vLnfGxIJEt3Wpyol0Y1AtsMY0RfObSbyPw2Ubn2JsRopkOxA2r_k0OWYzYOVRy0YS35ctyXIuxlBMoRvQcW9d8fK98XgNyvDcBARWKfeUwZgzTlmA0e4yvYlh3lLPlWoStjiyv-QjrmA0MauUj3L7MctzhfOhwbx0B2sQxFwWOEBr_e24LmBx2eaj-vrAV3OANH3nIRC5mtemuKM21EjvYD1hnfz5FOAvZaYsNNbB3fAHd8fob2apzYjjfYKRqh3moHQNnfErzZNoaA38ll4vL7Di8D7_4LWCLugF9N1VUQF8n4qIPHppVD4ogdz7lvoxJ1Oj6e0X8N-VqzY0L1c4nLbkIGe5nbE3le2AcSgz8e3Ljt_OoDOTz2HJ2rXXsN3o8a0GOLKLcPDWNeu9iw4Zr-TrVNvZSTBRSom5vUYjUgvsbDZZ_l_DVVgqjIYmBqmBfHJLNG2HcsJV4JQKTHG-wpHQFKx1iyssa5N7PKiXkO5dCXRrkf1SfQbTITj9acKMSs4iO9dkptWTq_Xjj59SFOxPrU7hIt1FJEz",
            "data": ["key": "value"],
            "solstone.open": "/app/injected"
        ]

        let key = Data(0..<32)
        let keyStore = PushKeyStore(
            seam: PushKeyStore.SecItemSeam(
                copy: { _ in (errSecSuccess, key) },
                add: { _ in errSecSuccess },
                delete: { _ in errSecSuccess }
            ),
            prefix: "7QCG8V4M6H."
        )

        let request = UNNotificationRequest(identifier: "test-req", content: originalContent, trigger: nil)
        let mutated = try PushEnvelope.mutateContent(
            request: request,
            keyStore: keyStore,
            locale: Locale(identifier: "en_US"),
            bundle: Bundle(for: PushEnvelope.self)
        )

        // Mutated content has decrypted title and body
        XCTAssertEqual(mutated.title, "solstone")
        XCTAssertEqual(mutated.body, "test notification from your journal.")
        XCTAssertEqual(mutated.threadIdentifier, "test")

        // Mutated content preserves sound, badge, aps and e, and drops routing the delivered alert carried
        XCTAssertEqual(mutated.sound, originalContent.sound)
        XCTAssertEqual(mutated.categoryIdentifier, "")
        XCTAssertEqual(mutated.badge, originalContent.badge)
        XCTAssertEqual(mutated.userInfo["aps"] as? [String: String], ["alert": "test"])
        XCTAssertEqual(mutated.userInfo["e"] as? String, originalContent.userInfo["e"] as? String)
        XCTAssertNil(mutated.userInfo["data"])
        XCTAssertNil(mutated.userInfo["solstone.open"])

        // Original content object is unchanged
        XCTAssertEqual(originalContent.title, "original title")
        XCTAssertEqual(originalContent.body, "original body")
    }

    func testFallbackContentIsBuiltFromConstants() {
        let fallback = PushEnvelope.fallbackContent()
        XCTAssertEqual(fallback.title, "solstone")
        XCTAssertEqual(fallback.body, "you have a new notification.")
        XCTAssertTrue(fallback.userInfo.isEmpty)
        XCTAssertEqual(fallback.categoryIdentifier, "")
    }

    func testOpenPathValidation() {
        XCTAssertTrue(isValidOpenPath("/app/health"))
        XCTAssertTrue(isValidOpenPath("/app/network/devices"))

        XCTAssertFalse(isValidOpenPath("/"))
        XCTAssertFalse(isValidOpenPath("/entries/2026-09-24"))
        XCTAssertFalse(isValidOpenPath("/search?q=journal#heading"))
        XCTAssertFalse(isValidOpenPath(""))
        XCTAssertFalse(isValidOpenPath("relative/path"))
        XCTAssertFalse(isValidOpenPath("https://evil.com"))
        XCTAssertFalse(isValidOpenPath("//evil.com"))
        XCTAssertFalse(isValidOpenPath("/app/../evil"))
        XCTAssertFalse(isValidOpenPath("/app/./bar"))
        XCTAssertFalse(isValidOpenPath("/app/foo\\bar"))
    }

    func testMutateContentWithKnownPresentation() throws {
        let key = Data(0..<32)
        let payload = """
        {
            "v": 1,
            "kind": "proof",
            "title": "legacy title marker",
            "body": "legacy body marker",
            "open": "/app/health",
            "presentation": {
                "title": {
                    "v": 1,
                    "catalog_epoch": 1,
                    "code": "push.proof.new",
                    "args": {},
                    "fallback_en": "fallback title marker"
                },
                "body": {
                    "v": 1,
                    "catalog_epoch": 1,
                    "code": "push.proof.count",
                    "args": {"count": 2},
                    "fallback_en": "fallback body marker"
                }
            }
        }
        """
        let envelope = try self.sealPlaintext(payload, key: key)
        let originalContent = UNMutableNotificationContent()
        originalContent.title = "original title"
        originalContent.body = "original body"
        originalContent.categoryIdentifier = "SOLSTONE_CUSTOM"
        originalContent.userInfo = [
            "aps": ["alert": "test"],
            "e": envelope,
            "data": ["key": "value"],
            "solstone.open": "/app/injected"
        ]

        let keyStore = PushKeyStore(
            seam: PushKeyStore.SecItemSeam(
                copy: { _ in (errSecSuccess, key) },
                add: { _ in errSecSuccess },
                delete: { _ in errSecSuccess }
            ),
            prefix: "7QCG8V4M6H."
        )

        let request = UNNotificationRequest(identifier: "test-known", content: originalContent, trigger: nil)
        let mutated = try PushEnvelope.mutateContent(
            request: request,
            keyStore: keyStore,
            locale: Locale(identifier: "en_US"),
            bundle: Bundle(for: PushEnvelope.self)
        )

        XCTAssertEqual(mutated.title, "a new test message is ready.")
        XCTAssertEqual(mutated.body, "\u{2068}2\u{2069} items are ready.")
        XCTAssertEqual(mutated.threadIdentifier, "proof")
        XCTAssertEqual(mutated.categoryIdentifier, "")
        XCTAssertNil(mutated.userInfo["data"])
        XCTAssertEqual(mutated.userInfo["solstone.open"] as? String, "/app/health")
    }

    func testMutateContentWithUnknownPresentationId() throws {
        let key = Data(0..<32)
        let payload = """
        {
            "v": 1,
            "kind": "proof",
            "title": "legacy title marker",
            "body": "legacy body marker",
            "open": "/app/health",
            "presentation": {
                "title": {
                    "v": 1,
                    "catalog_epoch": 1,
                    "code": "push.not.a.catalog.id",
                    "args": {},
                    "fallback_en": "fallback title marker"
                },
                "body": {
                    "v": 1,
                    "catalog_epoch": 1,
                    "code": "push.not.a.catalog.id",
                    "args": {},
                    "fallback_en": "fallback body marker"
                }
            }
        }
        """
        let envelope = try self.sealPlaintext(payload, key: key)
        let originalContent = UNMutableNotificationContent()
        originalContent.userInfo = ["e": envelope]

        let keyStore = PushKeyStore(
            seam: PushKeyStore.SecItemSeam(
                copy: { _ in (errSecSuccess, key) },
                add: { _ in errSecSuccess },
                delete: { _ in errSecSuccess }
            ),
            prefix: "7QCG8V4M6H."
        )

        let request = UNNotificationRequest(identifier: "test-unknown", content: originalContent, trigger: nil)
        let mutated = try PushEnvelope.mutateContent(
            request: request,
            keyStore: keyStore,
            locale: Locale(identifier: "en_US"),
            bundle: Bundle(for: PushEnvelope.self)
        )

        XCTAssertEqual(mutated.title, "fallback title marker")
        XCTAssertEqual(mutated.body, "fallback body marker")
    }

    func testMutateContentWithoutPresentationKey() throws {
        let key = Data(0..<32)
        let payload = """
        {
            "v": 1,
            "kind": "proof",
            "title": "legacy title marker",
            "body": "legacy body marker",
            "open": "/app/health"
        }
        """
        let envelope = try self.sealPlaintext(payload, key: key)
        let originalContent = UNMutableNotificationContent()
        originalContent.userInfo = ["e": envelope]

        let keyStore = PushKeyStore(
            seam: PushKeyStore.SecItemSeam(
                copy: { _ in (errSecSuccess, key) },
                add: { _ in errSecSuccess },
                delete: { _ in errSecSuccess }
            ),
            prefix: "7QCG8V4M6H."
        )

        let request = UNNotificationRequest(identifier: "test-no-pres", content: originalContent, trigger: nil)
        let mutated = try PushEnvelope.mutateContent(
            request: request,
            keyStore: keyStore,
            locale: Locale(identifier: "en_US"),
            bundle: Bundle(for: PushEnvelope.self)
        )

        XCTAssertEqual(mutated.title, "legacy title marker")
        XCTAssertEqual(mutated.body, "legacy body marker")
    }

    func testMutateContentIndependentTitleAndBody() throws {
        let key = Data(0..<32)
        let keyStore = PushKeyStore(
            seam: PushKeyStore.SecItemSeam(
                copy: { _ in (errSecSuccess, key) },
                add: { _ in errSecSuccess },
                delete: { _ in errSecSuccess }
            ),
            prefix: "7QCG8V4M6H."
        )

        // Title has bad code and no fallback_en, body has valid push.proof.new
        let payload1 = """
        {
            "v": 1,
            "kind": "proof",
            "title": "legacy title marker",
            "body": "legacy body marker",
            "presentation": {
                "title": {
                    "v": 1,
                    "catalog_epoch": 1,
                    "code": "push.not.a.catalog.id",
                    "args": {}
                },
                "body": {
                    "v": 1,
                    "catalog_epoch": 1,
                    "code": "push.proof.new",
                    "args": {},
                    "fallback_en": "fallback body marker"
                }
            }
        }
        """
        let envelope1 = try self.sealPlaintext(payload1, key: key)
        let content1 = UNMutableNotificationContent()
        content1.userInfo = ["e": envelope1]
        let req1 = UNNotificationRequest(identifier: "indep1", content: content1, trigger: nil)
        let mutated1 = try PushEnvelope.mutateContent(
            request: req1,
            keyStore: keyStore,
            locale: Locale(identifier: "en_US"),
            bundle: Bundle(for: PushEnvelope.self)
        )
        XCTAssertEqual(mutated1.title, "legacy title marker")
        XCTAssertEqual(mutated1.body, "a new test message is ready.")

        // Reverse: valid title push.proof.new, body has bad code and no fallback_en
        let payload2 = """
        {
            "v": 1,
            "kind": "proof",
            "title": "legacy title marker",
            "body": "legacy body marker",
            "presentation": {
                "title": {
                    "v": 1,
                    "catalog_epoch": 1,
                    "code": "push.proof.new",
                    "args": {},
                    "fallback_en": "fallback title marker"
                },
                "body": {
                    "v": 1,
                    "catalog_epoch": 1,
                    "code": "push.not.a.catalog.id",
                    "args": {}
                }
            }
        }
        """
        let envelope2 = try self.sealPlaintext(payload2, key: key)
        let content2 = UNMutableNotificationContent()
        content2.userInfo = ["e": envelope2]
        let req2 = UNNotificationRequest(identifier: "indep2", content: content2, trigger: nil)
        let mutated2 = try PushEnvelope.mutateContent(
            request: req2,
            keyStore: keyStore,
            locale: Locale(identifier: "en_US"),
            bundle: Bundle(for: PushEnvelope.self)
        )
        XCTAssertEqual(mutated2.title, "a new test message is ready.")
        XCTAssertEqual(mutated2.body, "legacy body marker")
    }

    func testMutateContentOperatorReviewCases() throws {
        let key = Data(0..<32)
        let keyStore = PushKeyStore(
            seam: PushKeyStore.SecItemSeam(
                copy: { _ in (errSecSuccess, key) },
                add: { _ in errSecSuccess },
                delete: { _ in errSecSuccess }
            ),
            prefix: "7QCG8V4M6H."
        )

        // 1. Title known push.proof.new with args: {} and no fallback_en -> title stays legacy title marker.
        // Body valid push.proof.new with string fallback_en -> catalog line.
        let payload1 = """
        {
            "v": 1,
            "kind": "proof",
            "title": "legacy title marker",
            "body": "legacy body marker",
            "presentation": {
                "title": {
                    "v": 1,
                    "catalog_epoch": 1,
                    "code": "push.proof.new",
                    "args": {}
                },
                "body": {
                    "v": 1,
                    "catalog_epoch": 1,
                    "code": "push.proof.new",
                    "args": {},
                    "fallback_en": "fallback body marker"
                }
            }
        }
        """
        let env1 = try self.sealPlaintext(payload1, key: key)
        let content1 = UNMutableNotificationContent()
        content1.userInfo = ["e": env1]
        let req1 = UNNotificationRequest(identifier: "rev1", content: content1, trigger: nil)
        let mut1 = try PushEnvelope.mutateContent(
            request: req1,
            keyStore: keyStore,
            locale: Locale(identifier: "en_US"),
            bundle: Bundle(for: PushEnvelope.self)
        )
        XCTAssertEqual(mut1.title, "legacy title marker")
        XCTAssertEqual(mut1.body, "a new test message is ready.")

        // 2. Title known push.proof.new with args: {} and fallback_en set to a JSON number -> legacy title marker.
        // Body still renders.
        let payload2 = """
        {
            "v": 1,
            "kind": "proof",
            "title": "legacy title marker",
            "body": "legacy body marker",
            "presentation": {
                "title": {
                    "v": 1,
                    "catalog_epoch": 1,
                    "code": "push.proof.new",
                    "args": {},
                    "fallback_en": 42
                },
                "body": {
                    "v": 1,
                    "catalog_epoch": 1,
                    "code": "push.proof.new",
                    "args": {},
                    "fallback_en": "fallback body marker"
                }
            }
        }
        """
        let env2 = try self.sealPlaintext(payload2, key: key)
        let content2 = UNMutableNotificationContent()
        content2.userInfo = ["e": env2]
        let req2 = UNNotificationRequest(identifier: "rev2", content: content2, trigger: nil)
        let mut2 = try PushEnvelope.mutateContent(
            request: req2,
            keyStore: keyStore,
            locale: Locale(identifier: "en_US"),
            bundle: Bundle(for: PushEnvelope.self)
        )
        XCTAssertEqual(mut2.title, "legacy title marker")
        XCTAssertEqual(mut2.body, "a new test message is ready.")

        // 3. Title push.proof.new with a string fallback_en and no args key -> fallback_en.
        // Body valid and still renders.
        let payload3 = """
        {
            "v": 1,
            "kind": "proof",
            "title": "legacy title marker",
            "body": "legacy body marker",
            "presentation": {
                "title": {
                    "v": 1,
                    "catalog_epoch": 1,
                    "code": "push.proof.new",
                    "fallback_en": "fallback title marker"
                },
                "body": {
                    "v": 1,
                    "catalog_epoch": 1,
                    "code": "push.proof.new",
                    "args": {},
                    "fallback_en": "fallback body marker"
                }
            }
        }
        """
        let env3 = try self.sealPlaintext(payload3, key: key)
        let content3 = UNMutableNotificationContent()
        content3.userInfo = ["e": env3]
        let req3 = UNNotificationRequest(identifier: "rev3", content: content3, trigger: nil)
        let mut3 = try PushEnvelope.mutateContent(
            request: req3,
            keyStore: keyStore,
            locale: Locale(identifier: "en_US"),
            bundle: Bundle(for: PushEnvelope.self)
        )
        XCTAssertEqual(mut3.title, "fallback title marker")
        XCTAssertEqual(mut3.body, "a new test message is ready.")

        // 4. Title uses id instead of code for push.proof.new, with args: {} and string fallback_en -> fallback_en.
        // Body uses code plus arguments instead of args, with string fallback_en -> fallback_en.
        let payload4 = """
        {
            "v": 1,
            "kind": "proof",
            "title": "legacy title marker",
            "body": "legacy body marker",
            "presentation": {
                "title": {
                    "v": 1,
                    "catalog_epoch": 1,
                    "id": "push.proof.new",
                    "args": {},
                    "fallback_en": "fallback title marker"
                },
                "body": {
                    "v": 1,
                    "catalog_epoch": 1,
                    "code": "push.proof.new",
                    "arguments": {},
                    "fallback_en": "fallback body marker"
                }
            }
        }
        """
        let env4 = try self.sealPlaintext(payload4, key: key)
        let content4 = UNMutableNotificationContent()
        content4.userInfo = ["e": env4]
        let req4 = UNNotificationRequest(identifier: "rev4", content: content4, trigger: nil)
        let mut4 = try PushEnvelope.mutateContent(
            request: req4,
            keyStore: keyStore,
            locale: Locale(identifier: "en_US"),
            bundle: Bundle(for: PushEnvelope.self)
        )
        XCTAssertEqual(mut4.title, "fallback title marker")
        XCTAssertEqual(mut4.body, "fallback body marker")

        // 5. mutateContent called with Locale(identifier: "fr_FR").
        // Title is push.proof.count at 0 with args and string fallback_en.
        // Title is "\u{2068}0\u{2069} items are ready." and is NOT the one-branch line.
        let payload5 = """
        {
            "v": 1,
            "kind": "proof",
            "title": "legacy title marker",
            "body": "legacy body marker",
            "presentation": {
                "title": {
                    "v": 1,
                    "catalog_epoch": 1,
                    "code": "push.proof.count",
                    "args": {"count": 0},
                    "fallback_en": "fallback title marker"
                },
                "body": {
                    "v": 1,
                    "catalog_epoch": 1,
                    "code": "push.proof.new",
                    "args": {},
                    "fallback_en": "fallback body marker"
                }
            }
        }
        """
        let env5 = try self.sealPlaintext(payload5, key: key)
        let content5 = UNMutableNotificationContent()
        content5.userInfo = ["e": env5]
        let req5 = UNNotificationRequest(identifier: "rev5", content: content5, trigger: nil)
        let mut5 = try PushEnvelope.mutateContent(
            request: req5,
            keyStore: keyStore,
            locale: Locale(identifier: "fr_FR"),
            bundle: Bundle(for: PushEnvelope.self)
        )
        XCTAssertEqual(mut5.title, "\u{2068}0\u{2069} items are ready.")
        XCTAssertNotEqual(mut5.title, "\u{2068}0\u{2069} item is ready.")
    }

    func testMutateContentAuthFailureAndMissingTitle() throws {
        let key = Data(0..<32)
        let wrongKey = Data(1..<33)
        let payload = "{\"v\":1,\"kind\":\"proof\",\"title\":\"t\",\"body\":\"b\"}"
        let envelope = try self.sealPlaintext(payload, key: key)
        let content = UNMutableNotificationContent()
        content.userInfo = ["e": envelope]

        let wrongStore = PushKeyStore(
            seam: PushKeyStore.SecItemSeam(
                copy: { _ in (errSecSuccess, wrongKey) },
                add: { _ in errSecSuccess },
                delete: { _ in errSecSuccess }
            ),
            prefix: "7QCG8V4M6H."
        )
        let reqWrongKey = UNNotificationRequest(identifier: "wrong-key", content: content, trigger: nil)
        XCTAssertThrowsError(try PushEnvelope.mutateContent(
            request: reqWrongKey,
            keyStore: wrongStore,
            locale: Locale(identifier: "en_US"),
            bundle: Bundle(for: PushEnvelope.self)
        )) { error in
            XCTAssertEqual(error as? PushEnvelopeError, .authFailed)
        }

        // Missing title in payload -> badPlaintext
        let noTitlePayload = "{\"v\":1,\"kind\":\"proof\",\"body\":\"b\"}"
        let noTitleEnvelope = try self.sealPlaintext(noTitlePayload, key: key)
        let noTitleContent = UNMutableNotificationContent()
        noTitleContent.userInfo = ["e": noTitleEnvelope]

        let correctStore = PushKeyStore(
            seam: PushKeyStore.SecItemSeam(
                copy: { _ in (errSecSuccess, key) },
                add: { _ in errSecSuccess },
                delete: { _ in errSecSuccess }
            ),
            prefix: "7QCG8V4M6H."
        )
        let reqNoTitle = UNNotificationRequest(identifier: "no-title", content: noTitleContent, trigger: nil)
        XCTAssertThrowsError(try PushEnvelope.mutateContent(
            request: reqNoTitle,
            keyStore: correctStore,
            locale: Locale(identifier: "en_US"),
            bundle: Bundle(for: PushEnvelope.self)
        )) { error in
            XCTAssertEqual(error as? PushEnvelopeError, .badPlaintext)
        }
    }

    private static func dataFromHex(_ hex: String) throws -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                throw NSError(domain: "HexError", code: -1)
            }
            data.append(byte)
            index = nextIndex
        }
        return data
    }
}
