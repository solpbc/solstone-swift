// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

nonisolated enum OmiReadState<Value: Equatable>: Equatable {
    case notRead
    case unavailable
    case value(Value)
}

extension OmiReadState: Sendable where Value: Sendable {}

nonisolated struct OmiAudioCodecInfo: Equatable, Sendable {
    let rawByte: UInt8
    let label: String

    var isOpus: Bool {
        self.rawByte == 20 || self.rawByte == 21
    }

    static func label(for byte: UInt8) -> String {
        switch byte {
        case 0:
            "pcm16 16 kHz mono"
        case 1:
            "pcm16 8 kHz mono"
        case 10:
            "µ-law 16 kHz mono"
        case 11:
            "µ-law 8 kHz mono"
        case 20:
            "opus 16 kHz mono"
        case 21:
            "opus 16 kHz mono (fs320)"
        default:
            "unknown (raw \(byte))"
        }
    }
}
