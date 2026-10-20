// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated public enum CatalogSelect {
    public static func resolveKey(messageId: String, enumArg: String?) -> String {
        switch messageId {
        case "push.proof.count": return "m707573682e70726f6f662e636f756e74"
        case "push.proof.new": return "m707573682e70726f6f662e6e6577"
        case "push.proof.state":
            guard let val = enumArg else { fatalError("Missing enum argument") }
            switch val {
            case "ready": return "m707573682e70726f6f662e7374617465_v7265616479"
            case "waiting": return "m707573682e70726f6f662e7374617465_v77616974696e67"
            default: return "m707573682e70726f6f662e7374617465_v77616974696e67"
            }
        case "push.test.body": return "m707573682e746573742e626f6479"
        case "push.test.title": return "m707573682e746573742e7469746c65"
        default: fatalError("Unknown message identity")
        }
    }

    public static func formatIntegerUngrouped(_ val: Int64) -> String {
        return String(val)
    }

    public static func formatIntegerLocale(_ val: Int64, locale: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: locale)
        return formatter.string(from: NSNumber(value: val)) ?? String(val)
    }
}
