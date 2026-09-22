// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if DEBUG && targetEnvironment(simulator)
import Foundation

enum WatchFaceDebugScene {
    static func pin(from arguments: [String], now: Date = Date()) -> (presentation: WatchCaptureOwnerPresentation, isReachable: Bool)? {
        for arg in arguments {
            switch arg {
            case "--watch-face-off":
                let presentation = WatchCaptureOwnerPresentation(
                    status: .off,
                    queuedCount: 0,
                    isSessionRunning: false,
                    sessionStartedAt: nil
                )
                return (presentation, true)

            case "--watch-face-off-saved":
                let presentation = WatchCaptureOwnerPresentation(
                    status: .off,
                    queuedCount: 3,
                    isSessionRunning: false,
                    sessionStartedAt: nil
                )
                return (presentation, false)

            case "--watch-face-setting-up":
                let presentation = WatchCaptureOwnerPresentation(
                    status: .enrolling,
                    queuedCount: 0,
                    isSessionRunning: false,
                    sessionStartedAt: nil
                )
                return (presentation, true)

            case "--watch-face-on-10s":
                let presentation = WatchCaptureOwnerPresentation(
                    status: .active,
                    queuedCount: 0,
                    isSessionRunning: true,
                    sessionStartedAt: now.addingTimeInterval(-10)
                )
                return (presentation, true)

            case "--watch-face-on-1h12m":
                let presentation = WatchCaptureOwnerPresentation(
                    status: .active,
                    queuedCount: 4,
                    isSessionRunning: true,
                    sessionStartedAt: now.addingTimeInterval(-4320)
                )
                return (presentation, false)

            case "--watch-face-needs-attention":
                let presentation = WatchCaptureOwnerPresentation(
                    status: .needsAttention(.unavailable(reason: SourceVocabulary.watchMicrophoneUnavailable)),
                    queuedCount: 0,
                    isSessionRunning: false,
                    sessionStartedAt: nil
                )
                return (presentation, true)

            default:
                continue
            }
        }
        return nil
    }

    static func isWristDown(from arguments: [String]) -> Bool {
        arguments.contains("--watch-face-wrist-down")
    }
}
#endif
