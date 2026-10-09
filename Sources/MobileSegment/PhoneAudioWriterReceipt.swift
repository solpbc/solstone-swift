// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

enum PhoneAudioWriterReceiptPhase: String, Codable, Sendable, Equatable {
    case writing
    case completed
    case faulted
}

enum PhoneAudioWriterReceiptReadResult: Sendable, Equatable {
    case absent
    case valid(PhoneAudioWriterReceipt)
    case unusable
}

struct PhoneAudioWriterReceipt: Codable, Sendable, Equatable {
    static let expectedVersion: Int = 1
    static let expectedSampleRate: Int = 16_000
    static let allowedFaultReasons: Set<String> = [
        "audio_writer_backpressure",
        "audio_writer_failed",
        "audio_conversion_failed",
    ]

    var version: Int
    var segmentID: UUID
    var phase: PhoneAudioWriterReceiptPhase
    var sampleRate: Int
    var acceptedFrames: Int64
    var reason: String?

    init(
        version: Int = Self.expectedVersion,
        segmentID: UUID,
        phase: PhoneAudioWriterReceiptPhase,
        sampleRate: Int = Self.expectedSampleRate,
        acceptedFrames: Int64,
        reason: String? = nil
    ) {
        self.version = version
        self.segmentID = segmentID
        self.phase = phase
        self.sampleRate = sampleRate
        self.acceptedFrames = acceptedFrames
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case segmentID
        case phase
        case sampleRate
        case acceptedFrames
        case reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Reject unknown keys
        let allKeys = Set(container.allKeys.map(\.stringValue))
        let expectedKeys = Set(CodingKeys.allCases.map(\.stringValue))
        guard allKeys.isSubset(of: expectedKeys) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown keys present")
            )
        }

        self.version = try container.decode(Int.self, forKey: .version)
        guard self.version == Self.expectedVersion else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid version")
            )
        }

        let segmentIDString = try container.decode(String.self, forKey: .segmentID)
        guard let uuid = UUID(uuidString: segmentIDString) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid segmentID UUID")
            )
        }
        self.segmentID = uuid

        self.phase = try container.decode(PhoneAudioWriterReceiptPhase.self, forKey: .phase)

        self.sampleRate = try container.decode(Int.self, forKey: .sampleRate)
        guard self.sampleRate == Self.expectedSampleRate else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid sampleRate")
            )
        }

        self.acceptedFrames = try container.decode(Int64.self, forKey: .acceptedFrames)
        guard self.acceptedFrames >= 0 else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Negative acceptedFrames")
            )
        }

        switch self.phase {
        case .writing, .completed:
            // reason key must be completely absent (not present, and not null)
            if container.contains(.reason) {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Reason must be absent for writing/completed")
                )
            }
            self.reason = nil
        case .faulted:
            guard let reason = try container.decodeIfPresent(String.self, forKey: .reason),
                  Self.allowedFaultReasons.contains(reason) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid or missing reason for faulted phase")
                )
            }
            self.reason = reason
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.version, forKey: .version)
        try container.encode(self.segmentID.uuidString, forKey: .segmentID)
        try container.encode(self.phase, forKey: .phase)
        try container.encode(self.sampleRate, forKey: .sampleRate)
        try container.encode(self.acceptedFrames, forKey: .acceptedFrames)
        if self.phase == .faulted, let reason = self.reason {
            try container.encode(reason, forKey: .reason)
        }
    }

    static func parse(data: Data, expectedSegmentID: UUID) -> PhoneAudioWriterReceiptReadResult {
        // First, check with JSONSerialization to strictly forbid booleans or floating-point numbers where integers are expected, and check types
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = jsonObject as? [String: Any] else {
            return .unusable
        }

        let allowedKeys: Set<String> = [
            "version",
            "segmentID",
            "phase",
            "sampleRate",
            "acceptedFrames",
            "reason",
        ]
        guard Set(dict.keys).isSubset(of: allowedKeys) else {
            return .unusable
        }

        if let phase = dict["phase"] as? String, (phase == "writing" || phase == "completed") {
            if dict.keys.contains("reason") {
                return .unusable
            }
        }

        // Check for booleans disguised as numbers (NSNumber with objCType "c" in Cocoa) or fractional numbers
        for key in ["version", "sampleRate", "acceptedFrames"] {
            guard let val = dict[key] as? NSNumber else { return .unusable }
            if CFGetTypeID(val) == CFBooleanGetTypeID() {
                return .unusable
            }
            if val.doubleValue != floor(val.doubleValue) {
                return .unusable
            }
        }

        let decoder = JSONDecoder()
        guard let receipt = try? decoder.decode(PhoneAudioWriterReceipt.self, from: data) else {
            return .unusable
        }

        guard receipt.segmentID == expectedSegmentID else {
            return .unusable
        }

        return .valid(receipt)
    }
}
