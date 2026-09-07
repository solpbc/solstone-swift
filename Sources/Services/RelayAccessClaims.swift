// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum RelayAccessClaims {
    // Note: Decode is claim-shape validation against the paired home's contract, NOT signature authentication.
    // Inner TLS over loopback provides transport authentication from the home journal.

    static func isValidOrigin(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "wss",
              let host = url.host,
              !host.isEmpty else {
            return false
        }
        return true
    }

    static func validateReadyPayload(
        _ payload: RelayAccessReadyPayload,
        pairedInstanceID: String,
        now: Date = Date()
    ) -> Bool {
        guard payload.protocolVersion == 2,
              payload.status == "ready",
              payload.instanceID == pairedInstanceID,
              self.isValidOrigin(payload.relayOrigin) else {
            return false
        }

        guard let tokenPayload = self.decodeAndValidateTokenClaims(
            payload.deviceToken,
            pairedInstanceID: pairedInstanceID,
            now: now
        ) else {
            return false
        }

        guard let expiresAtDate = self.parseRFC3339(payload.expiresAt) else {
            return false
        }

        let expiresAtSec = Int(expiresAtDate.timeIntervalSince1970)
        guard expiresAtSec == tokenPayload.exp else {
            return false
        }

        guard expiresAtDate > now else {
            return false
        }

        return true
    }

    struct TokenClaims: Equatable, Sendable {
        let iss: String
        let sub: String
        let aud: String
        let scope: String
        let ver: Int
        let instanceID: String
        let iat: Int
        let exp: Int
        let jti: String
    }

    static func decodeAndValidateTokenClaims(
        _ token: String,
        pairedInstanceID: String,
        now: Date = Date()
    ) -> TokenClaims? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else {
            return nil
        }

        guard let payloadData = self.base64URLDecode(String(parts[1])),
              let jsonObject = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }

        let requiredKeys: Set<String> = [
            "iss", "sub", "aud", "scope", "ver", "instance_id", "iat", "exp", "jti"
        ]
        guard Set(jsonObject.keys) == requiredKeys else {
            return nil
        }

        guard let iss = jsonObject["iss"] as? String, !iss.isEmpty,
              let sub = jsonObject["sub"] as? String,
              let aud = jsonObject["aud"] as? String, aud == "spl-relay",
              let scope = jsonObject["scope"] as? String, scope == "session.dial",
              let ver = jsonObject["ver"] as? Int, ver == 2,
              let instanceID = jsonObject["instance_id"] as? String, instanceID == pairedInstanceID,
              let jti = jsonObject["jti"] as? String, !jti.isEmpty else {
            return nil
        }

        guard sub == "instance:\(pairedInstanceID)" else {
            return nil
        }

        guard let iatNumber = jsonObject["iat"] as? NSNumber,
              let expNumber = jsonObject["exp"] as? NSNumber else {
            return nil
        }

        let iatDouble = iatNumber.doubleValue
        let expDouble = expNumber.doubleValue

        guard iatDouble.rounded() == iatDouble,
              expDouble.rounded() == expDouble else {
            return nil
        }

        let iat = Int(iatDouble)
        let exp = Int(expDouble)

        guard exp > iat else {
            return nil
        }

        guard Double(exp) > now.timeIntervalSince1970 else {
            return nil
        }

        return TokenClaims(
            iss: iss,
            sub: sub,
            aud: aud,
            scope: scope,
            ver: ver,
            instanceID: instanceID,
            iat: iat,
            exp: exp,
            jti: jti
        )
    }

    private static func parseRFC3339(_ dateString: String) -> Date? {
        let formatterWithFraction = ISO8601DateFormatter()
        formatterWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatterWithFraction.date(from: dateString) {
            return date
        }
        let standardFormatter = ISO8601DateFormatter()
        standardFormatter.formatOptions = [.withInternetDateTime]
        return standardFormatter.date(from: dateString)
    }

    private static func base64URLDecode(_ base64URL: String) -> Data? {
        var base64 = base64URL
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}
