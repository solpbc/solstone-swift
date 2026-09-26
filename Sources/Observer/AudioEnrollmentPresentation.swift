// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct AudioEnrollmentPresentation: Equatable, Sendable {
    let preEnrollmentValue: String
    let turnOnAudio: String

    static func current(isJournalPaired: Bool) -> AudioEnrollmentPresentation {
        AudioEnrollmentPresentation(
            preEnrollmentValue: SourceVocabulary.audioEnrollmentValue(isJournalPaired: isJournalPaired),
            turnOnAudio: SourceVocabulary.turnOnAudio
        )
    }
}
