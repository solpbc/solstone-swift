// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct BLEDrainedFileRecord: Sendable, Equatable {
    let fileNumber: UInt8?
    let epoch: UInt32?
    let bytes: Int
    let sampleCount: Int
    let decodeOK: Int
    let decodeErrors: Int
    let status: String
}

nonisolated enum BLEDrainReconcileLogic {
    private static let pre2021Epoch: UInt32 = 1_609_459_200
    private static let posixLocale = Locale(identifier: "en_US_POSIX")
    private static let utcDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter
    }()

    static func voicedSeconds(sampleCount: Int) -> Double {
        Double(sampleCount) / 16_000
    }

    static func makeRecord(
        fileNumber: UInt8?,
        epoch: UInt32?,
        bytes: Int,
        sampleCount: Int,
        decodeOK: Int,
        decodeErrors: Int,
        status: String
    ) -> BLEDrainedFileRecord {
        BLEDrainedFileRecord(
            fileNumber: fileNumber,
            epoch: epoch,
            bytes: bytes,
            sampleCount: sampleCount,
            decodeOK: decodeOK,
            decodeErrors: decodeErrors,
            status: status
        )
    }

    static func renderSummary(records: [BLEDrainedFileRecord]) -> String {
        var lines = [
            "solstone-swift sd-card drain reconciliation",
            "records: \(records.count)"
        ]

        if records.isEmpty {
            lines.append("---")
            lines.append("no sd-card drain reconciliation records yet")
            return lines.joined(separator: "\n")
        }

        for record in records {
            lines.append("---")
            lines.append("file#: \(record.fileNumber.map(String.init) ?? "unknown")")
            if let epoch = record.epoch {
                let date = Date(timeIntervalSince1970: Double(epoch))
                lines.append("creation epoch: \(epoch) (utc: \(Self.utcDateFormatter.string(from: date)))")
                if epoch < Self.pre2021Epoch {
                    lines.append("epoch flag: pre-2021 / possible RTC-unsynced")
                }
            } else {
                lines.append("creation epoch: none (no frames)")
            }
            lines.append("bytes: \(record.bytes)")
            lines.append("voiced seconds (decoded-frame seconds, not wall-clock): \(Self.voicedSecondsText(sampleCount: record.sampleCount))")
            lines.append("decode ok/err: \(record.decodeOK)/\(record.decodeErrors)")
            lines.append("final status: \(record.status)")
        }

        return lines.joined(separator: "\n")
    }

    private static func voicedSecondsText(sampleCount: Int) -> String {
        String(
            format: "%.1f",
            locale: Self.posixLocale,
            Self.voicedSeconds(sampleCount: sampleCount)
        )
    }
}
