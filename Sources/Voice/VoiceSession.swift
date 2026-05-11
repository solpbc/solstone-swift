// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct VoiceSession: Codable, Sendable {
    let startTime: Date
    var endTime: Date? = nil
    var callId: String? = nil
    var errorDetail: String? = nil

    var duration: TimeInterval? {
        guard let endTime else { return nil }
        return endTime.timeIntervalSince(self.startTime)
    }

    var endedNormally: Bool {
        self.errorDetail == nil && self.endTime != nil
    }

    private static let defaultsKey = "lastVoiceSession"

    func saveToDefaults() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    static func loadFromDefaults() -> VoiceSession? {
        guard let data = UserDefaults.standard.data(forKey: self.defaultsKey) else { return nil }
        return try? JSONDecoder().decode(VoiceSession.self, from: data)
    }

    static func clearDefaults() {
        UserDefaults.standard.removeObject(forKey: self.defaultsKey)
    }
}
