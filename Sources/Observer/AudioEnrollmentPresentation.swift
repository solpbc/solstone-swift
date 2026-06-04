// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct AudioEnrollmentPresentation: Equatable, Sendable {
    let preEnrollmentValue: String
    let turnOnAudio: String

    static let current = AudioEnrollmentPresentation(
        preEnrollmentValue: SourceVocabulary.audioEnrollmentValue,
        turnOnAudio: SourceVocabulary.turnOnAudio
    )
}
