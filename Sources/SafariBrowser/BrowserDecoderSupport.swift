// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc
import Foundation

nonisolated public enum BrowserBrand: String { case chrome, edge, firefox, safari }

nonisolated public enum NativeHostUTF8 {
    public static func isValid(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i < bytes.count {
                let first = bytes[i]
                if first < 0x80 { i += 1; continue }
                let remaining: Int
                let lower: UInt8
                let upper: UInt8
                switch first {
                case 0xC2...0xDF: remaining = 1; lower = 0x80; upper = 0xBF
                case 0xE0: remaining = 2; lower = 0xA0; upper = 0xBF
                case 0xE1...0xEC, 0xEE...0xEF: remaining = 2; lower = 0x80; upper = 0xBF
                case 0xED: remaining = 2; lower = 0x80; upper = 0x9F
                case 0xF0: remaining = 3; lower = 0x90; upper = 0xBF
                case 0xF1...0xF3: remaining = 3; lower = 0x80; upper = 0xBF
                case 0xF4: remaining = 3; lower = 0x80; upper = 0x8F
                default: return false
                }
                guard i + remaining < bytes.count, bytes[i + 1] >= lower, bytes[i + 1] <= upper else { return false }
                if remaining > 1 {
                    for offset in 2...remaining where bytes[i + offset] < 0x80 || bytes[i + offset] > 0xBF { return false }
                }
                i += remaining + 1
            }
            return true
        }
    }
}
