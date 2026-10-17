// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct SourceSyncMessage: Sendable {
    let id: String
    let arguments: [String: Int]
    let resource: LocalizedStringResource
    let legacyEnglish: String
    var rendered: String {
        guard resource.locale.identifier == "en_US" else { return String(localized: resource) }
        let template = Bundle.main.localizedString(forKey: id, value: legacyEnglish, table: "Pilot")
        return String(format: template, locale: Locale(identifier: "en_US_POSIX"), arguments.values.first ?? 0)
    }
}

nonisolated enum PilotCopy {
    static var finishSyncingCardHeadline: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.finishSyncingCardHeadline", defaultValue: "still syncing to your journal", table: "Pilot")
    }
    static var finishSyncingButton: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.finishSyncingButton", defaultValue: "enable background for this sync", table: "Pilot")
    }
    static var finishSyncingInProgress: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.finishSyncingInProgress", defaultValue: "finishing up in the background. you can switch away. the solstone app keeps syncing for as long as ios allows.", table: "Pilot")
    }
    static var finishSyncingCompleted: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.finishSyncingCompleted", defaultValue: "done. everything is in your journal.", table: "Pilot")
    }
    static var finishSyncingInterruptedFallback: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.finishSyncingInterruptedFallback", defaultValue: "stopped before everything synced. what's left is on this device and keeps trying whenever the solstone app is open.", table: "Pilot")
    }
    static var finishSyncingUnavailableUnavailable: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.finishSyncingUnavailableUnavailable", defaultValue: "background syncing isn't available right now.", table: "Pilot")
    }
    static var finishSyncingUnavailableNotPermitted: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.finishSyncingUnavailableNotPermitted", defaultValue: "ios isn't allowing finish syncing right now.", table: "Pilot")
    }
    static var finishSyncingUnavailableTooManyPending: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.finishSyncingUnavailableTooManyPending", defaultValue: "ios already has too many background tasks waiting.", table: "Pilot")
    }
    static var finishSyncingUnavailableImmediateIneligible: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.finishSyncingUnavailableImmediateIneligible", defaultValue: "ios can't start finish syncing right now.", table: "Pilot")
    }
    static var finishSyncingUnavailableFallback: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.finishSyncingUnavailableFallback", defaultValue: "finish syncing couldn't start.", table: "Pilot")
    }
    static var finishSyncingSystemTitle: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.finishSyncingSystemTitle", defaultValue: "finishing sync", table: "Pilot")
    }
    static var finishSyncingSystemDoneTitle: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.finishSyncingSystemDoneTitle", defaultValue: "sync finished", table: "Pilot")
    }
    static var finishSyncingSystemPausedTitle: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.finishSyncingSystemPausedTitle", defaultValue: "sync paused", table: "Pilot")
    }
    static var shareSendingProgress: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.shareSendingProgress", defaultValue: "sending to your journal…", table: "Pilot")
    }
    static var shareDeliveredProgress: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.shareDeliveredProgress", defaultValue: "saved to your journal", table: "Pilot")
    }
    static var sendStateSaved: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.sendStateSaved", defaultValue: "on this device", table: "Pilot")
    }
    static var sendStateSending: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.sendStateSending", defaultValue: "sending", table: "Pilot")
    }
    static var sendStateCompactSaved: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.sendStateCompactSaved", defaultValue: "waiting to sync", table: "Pilot")
    }
    static var sendStateCompactOnTheWay: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.sendStateCompactOnTheWay", defaultValue: "on the way", table: "Pilot")
    }
    static var sendStateCompactInJournal: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.sendStateCompactInJournal", defaultValue: "in your journal", table: "Pilot")
    }
    static var onThisPhoneWaitingExplain: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.onThisPhoneWaitingExplain", defaultValue: "still on this device. syncing to your journal continues automatically. you don't have to do anything.", table: "Pilot")
    }
    static var tryNow: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.tryNow", defaultValue: "try now", table: "Pilot")
    }
    static var screencastDisplayName: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.screencastDisplayName", defaultValue: "screen", table: "Pilot")
    }
    static var screencastActiveSubtext: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.screencastActiveSubtext", defaultValue: "sharing your screen", table: "Pilot")
    }
    static var screencastStartingSubtext: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.screencastStartingSubtext", defaultValue: "waiting for the system sheet", table: "Pilot")
    }
    static var screencastOffSubtext: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.screencastOffSubtext", defaultValue: "off", table: "Pilot")
    }
    static var screencastAttentionSubtext: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.screencastAttentionSubtext", defaultValue: "needs attention", table: "Pilot")
    }
    static var screencastUnavailableSubtext: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.screencastUnavailableSubtext", defaultValue: "unavailable", table: "Pilot")
    }
    static var screencastDetailTitle: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.screencastDetailTitle", defaultValue: "screen", table: "Pilot")
    }
    static var screencastStateTitle: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.screencastStateTitle", defaultValue: "state", table: "Pilot")
    }
    static var screencastRecentTitle: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.screencastRecentTitle", defaultValue: "recent", table: "Pilot")
    }
    static var screencastDeliveryTitle: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.screencastDeliveryTitle", defaultValue: "delivery", table: "Pilot")
    }
    static var screencastStartButton: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.screencastStartButton", defaultValue: "start screen", table: "Pilot")
    }
    static var screencastStopButton: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.screencastStopButton", defaultValue: "stop screen", table: "Pilot")
    }
    static var screencastOpenSystemSheet: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.screencastOpenSystemSheet", defaultValue: "open system sheet", table: "Pilot")
    }
    static var screencastReadyText: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.screencastReadyText", defaultValue: "screen is ready", table: "Pilot")
    }
    static var screencastStartingText: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.screencastStartingText", defaultValue: "waiting for the system sheet", table: "Pilot")
    }
    static var screencastActiveText: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.screencastActiveText", defaultValue: "screen is active", table: "Pilot")
    }
    static var screencastUnavailableText: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.screencastUnavailableText", defaultValue: "screen is unavailable", table: "Pilot")
    }
    static var screencastNoVideoText: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.screencastNoVideoText", defaultValue: "no screen video was saved", table: "Pilot")
    }
    static var screencastFinalizeFailedText: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.screencastFinalizeFailedText", defaultValue: "screen video could not be saved", table: "Pilot")
    }
    static var screencastFinalizeTimeoutText: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.screencastFinalizeTimeoutText", defaultValue: "screen video timed out while saving", table: "Pilot")
    }
    static var screencastFilesystemFailedText: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.screencastFilesystemFailedText", defaultValue: "screen video could not be stored", table: "Pilot")
    }
    static var screencastStorageLowText: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.screencastStorageLowText", defaultValue: "screen stopped. this device is low on storage.", table: "Pilot")
    }
    static var screencastSystemEndedSubtext: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.screencastSystemEndedSubtext", defaultValue: "screen sharing ended", table: "Pilot")
    }
    static var screencastPrimerBodyActive: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.screencastPrimerBodyActive", defaultValue: "to stop sharing your screen, tap \"Stop Broadcast\" in the sheet that comes up.", table: "Pilot")
    }
    static var screencastPrimerBodyOff: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.screencastPrimerBodyOff", defaultValue: "what's on your screen goes into your journal. tap \"Start Broadcast\" in the sheet that comes up. the system ends screen sharing when this device locks.", table: "Pilot")
    }
    static var connectedLabel: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.connectedLabel", defaultValue: "connected", table: "Pilot")
    }
    static var syncingLabel: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.syncingLabel", defaultValue: "syncing", table: "Pilot")
    }
    static var statusConnectingLabel: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.statusConnectingLabel", defaultValue: "connecting…", table: "Pilot")
    }
    static var statusOfflineLabel: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.statusOfflineLabel", defaultValue: "offline", table: "Pilot")
    }
    static var stallWaitingLabel: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.stallWaitingLabel", defaultValue: "waiting", table: "Pilot")
    }
    static var stallNotConnectedLabel: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.stallNotConnectedLabel", defaultValue: "not connected", table: "Pilot")
    }
    static var stallCantReachYourJournal: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.stallCantReachYourJournal", defaultValue: "can't reach your journal", table: "Pilot")
    }
    static var stallTryAgainLabel: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.stallTryAgainLabel", defaultValue: "try again", table: "Pilot")
    }
    static var stallTriesEveryAddress: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.stallTriesEveryAddress", defaultValue: "tries every address your journal gave this phone.", table: "Pilot")
    }
    static var stallTryingLabel: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.stallTryingLabel", defaultValue: "trying…", table: "Pilot")
    }
    static var stallPairAgainLabel: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.stallPairAgainLabel", defaultValue: "pair again", table: "Pilot")
    }
    static var stallPairAgainDetail: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.stallPairAgainDetail", defaultValue: "if your journal's computer is on and this keeps happening, your journal may have new addresses. pairing again gives this phone the current ones.", table: "Pilot")
    }
    static func finishSyncingCardBody(_ count: Int) -> SourceSyncMessage {
        SourceSyncMessage(id: "ios.sourceSync.finishSyncingCardBody", arguments: ["count": count],
            resource: LocalizedStringResource("ios.sourceSync.finishSyncingCardBody", defaultValue: count == 1 ? "\(count) segment hasn't landed yet. tap to keep this syncing in the background after you switch away from the solstone app." : "\(count) segments haven't landed yet. tap to keep this syncing in the background after you switch away from the solstone app.", table: "Pilot"),
            legacyEnglish: count == 1 ? "\(count) segment hasn't landed yet. tap to keep this syncing in the background after you switch away from the solstone app." : "\(count) segments haven't landed yet. tap to keep this syncing in the background after you switch away from the solstone app.")
    }
    static func finishSyncingInterrupted(_ count: Int) -> SourceSyncMessage {
        SourceSyncMessage(id: "ios.sourceSync.finishSyncingInterrupted", arguments: ["count": count],
            resource: LocalizedStringResource("ios.sourceSync.finishSyncingInterrupted", defaultValue: count == 1 ? "stopped. \(count) still waiting. it's on this device and will keep syncing whenever the solstone app is open." : "stopped. \(count) still waiting. they're on this device and will keep syncing whenever the solstone app is open.", table: "Pilot"),
            legacyEnglish: count == 1 ? "stopped. \(count) still waiting. it's on this device and will keep syncing whenever the solstone app is open." : "stopped. \(count) still waiting. they're on this device and will keep syncing whenever the solstone app is open.")
    }
    static func finishSyncingSystemSubtitle(_ remaining: Int) -> SourceSyncMessage {
        SourceSyncMessage(id: "ios.sourceSync.finishSyncingSystemSubtitle", arguments: ["remaining": remaining],
            resource: LocalizedStringResource("ios.sourceSync.finishSyncingSystemSubtitle", defaultValue: remaining == 1 ? "\(remaining) item still waiting for your journal" : "\(remaining) items still waiting for your journal", table: "Pilot"),
            legacyEnglish: remaining == 1 ? "\(remaining) item still waiting for your journal" : "\(remaining) items still waiting for your journal")
    }
    static var standingSyncFootnoteSustaining: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.standingSyncFootnoteSustaining", defaultValue: "syncs while the solstone app is open, and keeps going in the background while location is on.", table: "Pilot")
    }
    static var standingSyncFootnoteLimited: LocalizedStringResource {
        LocalizedStringResource("ios.sourceSync.standingSyncFootnoteLimited", defaultValue: "the solstone app syncs to your journal while it's open, and keeps going in the background for as long as ios allows. with location on, that lasts longer.", table: "Pilot")
    }
    static var allResources: [LocalizedStringResource] { [
        Self.finishSyncingCardHeadline,
        Self.finishSyncingButton,
        Self.finishSyncingInProgress,
        Self.finishSyncingCompleted,
        Self.finishSyncingInterruptedFallback,
        Self.finishSyncingUnavailableUnavailable,
        Self.finishSyncingUnavailableNotPermitted,
        Self.finishSyncingUnavailableTooManyPending,
        Self.finishSyncingUnavailableImmediateIneligible,
        Self.finishSyncingUnavailableFallback,
        Self.finishSyncingSystemTitle,
        Self.finishSyncingSystemDoneTitle,
        Self.finishSyncingSystemPausedTitle,
        Self.shareSendingProgress,
        Self.shareDeliveredProgress,
        Self.sendStateSaved,
        Self.sendStateSending,
        Self.sendStateCompactSaved,
        Self.sendStateCompactOnTheWay,
        Self.sendStateCompactInJournal,
        Self.onThisPhoneWaitingExplain,
        Self.tryNow,
        Self.screencastDisplayName,
        Self.screencastActiveSubtext,
        Self.screencastStartingSubtext,
        Self.screencastOffSubtext,
        Self.screencastAttentionSubtext,
        Self.screencastUnavailableSubtext,
        Self.screencastDetailTitle,
        Self.screencastStateTitle,
        Self.screencastRecentTitle,
        Self.screencastDeliveryTitle,
        Self.screencastStartButton,
        Self.screencastStopButton,
        Self.screencastOpenSystemSheet,
        Self.screencastReadyText,
        Self.screencastStartingText,
        Self.screencastActiveText,
        Self.screencastUnavailableText,
        Self.screencastNoVideoText,
        Self.screencastFinalizeFailedText,
        Self.screencastFinalizeTimeoutText,
        Self.screencastFilesystemFailedText,
        Self.screencastStorageLowText,
        Self.screencastSystemEndedSubtext,
        Self.screencastPrimerBodyActive,
        Self.screencastPrimerBodyOff,
        Self.connectedLabel,
        Self.syncingLabel,
        Self.statusConnectingLabel,
        Self.statusOfflineLabel,
        Self.stallWaitingLabel,
        Self.stallNotConnectedLabel,
        Self.stallCantReachYourJournal,
        Self.stallTryAgainLabel,
        Self.stallTriesEveryAddress,
        Self.stallTryingLabel,
        Self.stallPairAgainLabel,
        Self.stallPairAgainDetail,
        Self.finishSyncingCardBody(2).resource,
        Self.finishSyncingInterrupted(2).resource,
        Self.finishSyncingSystemSubtitle(2).resource,
        Self.standingSyncFootnoteSustaining,
        Self.standingSyncFootnoteLimited,
    ] }
    static func resources(locale: Locale, bundle: LocalizedStringResource.BundleDescription) -> [LocalizedStringResource] {
        [
            LocalizedStringResource("ios.sourceSync.finishSyncingCardHeadline", defaultValue: "still syncing to your journal", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.finishSyncingButton", defaultValue: "enable background for this sync", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.finishSyncingInProgress", defaultValue: "finishing up in the background. you can switch away. the solstone app keeps syncing for as long as ios allows.", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.finishSyncingCompleted", defaultValue: "done. everything is in your journal.", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.finishSyncingInterruptedFallback", defaultValue: "stopped before everything synced. what's left is on this device and keeps trying whenever the solstone app is open.", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.finishSyncingUnavailableUnavailable", defaultValue: "background syncing isn't available right now.", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.finishSyncingUnavailableNotPermitted", defaultValue: "ios isn't allowing finish syncing right now.", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.finishSyncingUnavailableTooManyPending", defaultValue: "ios already has too many background tasks waiting.", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.finishSyncingUnavailableImmediateIneligible", defaultValue: "ios can't start finish syncing right now.", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.finishSyncingUnavailableFallback", defaultValue: "finish syncing couldn't start.", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.finishSyncingSystemTitle", defaultValue: "finishing sync", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.finishSyncingSystemDoneTitle", defaultValue: "sync finished", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.finishSyncingSystemPausedTitle", defaultValue: "sync paused", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.shareSendingProgress", defaultValue: "sending to your journal…", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.shareDeliveredProgress", defaultValue: "saved to your journal", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.sendStateSaved", defaultValue: "on this device", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.sendStateSending", defaultValue: "sending", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.sendStateCompactSaved", defaultValue: "waiting to sync", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.sendStateCompactOnTheWay", defaultValue: "on the way", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.sendStateCompactInJournal", defaultValue: "in your journal", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.onThisPhoneWaitingExplain", defaultValue: "still on this device. syncing to your journal continues automatically. you don't have to do anything.", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.tryNow", defaultValue: "try now", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.screencastDisplayName", defaultValue: "screen", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.screencastActiveSubtext", defaultValue: "sharing your screen", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.screencastStartingSubtext", defaultValue: "waiting for the system sheet", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.screencastOffSubtext", defaultValue: "off", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.screencastAttentionSubtext", defaultValue: "needs attention", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.screencastUnavailableSubtext", defaultValue: "unavailable", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.screencastDetailTitle", defaultValue: "screen", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.screencastStateTitle", defaultValue: "state", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.screencastRecentTitle", defaultValue: "recent", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.screencastDeliveryTitle", defaultValue: "delivery", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.screencastStartButton", defaultValue: "start screen", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.screencastStopButton", defaultValue: "stop screen", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.screencastOpenSystemSheet", defaultValue: "open system sheet", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.screencastReadyText", defaultValue: "screen is ready", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.screencastStartingText", defaultValue: "waiting for the system sheet", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.screencastActiveText", defaultValue: "screen is active", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.screencastUnavailableText", defaultValue: "screen is unavailable", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.screencastNoVideoText", defaultValue: "no screen video was saved", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.screencastFinalizeFailedText", defaultValue: "screen video could not be saved", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.screencastFinalizeTimeoutText", defaultValue: "screen video timed out while saving", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.screencastFilesystemFailedText", defaultValue: "screen video could not be stored", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.screencastStorageLowText", defaultValue: "screen stopped. this device is low on storage.", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.screencastSystemEndedSubtext", defaultValue: "screen sharing ended", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.screencastPrimerBodyActive", defaultValue: "to stop sharing your screen, tap \"Stop Broadcast\" in the sheet that comes up.", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.screencastPrimerBodyOff", defaultValue: "what's on your screen goes into your journal. tap \"Start Broadcast\" in the sheet that comes up. the system ends screen sharing when this device locks.", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.connectedLabel", defaultValue: "connected", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.syncingLabel", defaultValue: "syncing", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.statusConnectingLabel", defaultValue: "connecting…", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.statusOfflineLabel", defaultValue: "offline", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.stallWaitingLabel", defaultValue: "waiting", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.stallNotConnectedLabel", defaultValue: "not connected", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.stallCantReachYourJournal", defaultValue: "can't reach your journal", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.stallTryAgainLabel", defaultValue: "try again", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.stallTriesEveryAddress", defaultValue: "tries every address your journal gave this phone.", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.stallTryingLabel", defaultValue: "trying…", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.stallPairAgainLabel", defaultValue: "pair again", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.stallPairAgainDetail", defaultValue: "if your journal's computer is on and this keeps happening, your journal may have new addresses. pairing again gives this phone the current ones.", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.finishSyncingCardBody", defaultValue: "\(2) segments haven't landed yet. tap to keep this syncing in the background after you switch away from the solstone app.", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.finishSyncingInterrupted", defaultValue: "stopped. \(2) still waiting. they're on this device and will keep syncing whenever the solstone app is open.", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.finishSyncingSystemSubtitle", defaultValue: "\(2) items still waiting for your journal", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.standingSyncFootnoteSustaining", defaultValue: "syncs while the solstone app is open, and keeps going in the background while location is on.", table: "Pilot", locale: locale, bundle: bundle),
            LocalizedStringResource("ios.sourceSync.standingSyncFootnoteLimited", defaultValue: "the solstone app syncs to your journal while it's open, and keeps going in the background for as long as ios allows. with location on, that lasts longer.", table: "Pilot", locale: locale, bundle: bundle),
        ]
    }
}
