// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum LocationVocabulary {
    static let sourceDisplayName = "location"
    static let activeSubtext = "adds where your day happens to your journal while this is on."
    static let preEnrollmentValue = "where your day happens — kept by you, in your journal, and nowhere else. as light or as complete as you want."
    static let tierDialHeader = "how much of your day to keep"
    static let tierDialSubhead = "your day, your call. you can change this any time."
    static let lightLabel = "places only"
    static let lightBody = "the places you stop — home, work, an event."
    static let balancedLabel = "places + comings and goings"
    static let balancedBody = "your stops, plus the shape of how you move between them."
    static let balancedDefaultBadge = "recommended"
    static let fullLabel = "the complete picture"
    static let fullBody = "the full, detailed picture of where your day happened. uses more battery."
    static let batteryHonesty = "the fuller settings keep solstone aware in the background, which uses more battery. iOS shows its location arrow whenever location is on — that's iOS keeping you honest."
    static let alwaysBackgroundPrimer = "to keep this when solstone isn't open, iOS will ask to allow location \"Always.\" you can change it any time in iOS Settings."
    static let turnOnLocation = "turn on location"
    static let alwaysPrimerHeader = "before iOS asks"
    static let alwaysPrimerContinue = "continue"
    static let stateBlockTitle = "state"
    static let tierBlockTitle = "detail level"
    static let recentBlockTitle = "recent"
    static let deliveryBlockTitle = "on its way"
    static let tierChangeFraming = "changes apply from now on — nothing already in your journal is altered."
    static let deliveryNeedsAttentionTemplate = "{N} location {update} {needs} attention."
    static let deliverySendingTemplate = "{N} location {update} on the way to your journal."
    static let deliveryLastSavedTemplate = "last saved to your journal at {time}."
    static let deliveryQuietLine = "nothing waiting right now."
    static let deleteSeamLine = "removing location's contributions from your journal arrives in a later update."
    static let downgradeBodyTemplate = "you chose {tier}, but iOS is only sharing location while solstone is open. your journal will show the gaps honestly — solstone never fills them in."
    static let openSettingsAction = "open iOS Settings"
    static let matchToAllowedAction = "match it to what's allowed"
    static let restrictedBody = "location is turned off for solstone by a restriction on this device. solstone can't keep your day until that's lifted."
    static let honestGap = "gap here — location wasn't available."
    static let liveActivityText = "solstone is adding where your day happens"
    static let deleteConfirmBody = "delete everything location added to your journal? this removes where your day happened. other things in your journal stay. this can't be undone."
    static let deleteConfirmButton = "delete location's contributions"
    static let deleteReceiptHeadlineTemplate = "deleted. removed from your journal: where your day happened, across {N} days."

    static func downgradeBody(tier: LocationTier) -> String {
        self.downgradeBodyTemplate.replacingOccurrences(of: "{tier}", with: tier.label)
    }

    static func deleteReceiptHeadline(days: Int) -> String {
        self.deleteReceiptHeadlineTemplate.replacingOccurrences(of: "{N}", with: String(days))
    }

    static func deliveryNeedsAttention(count: Int) -> String {
        self.deliveryNeedsAttentionTemplate
            .replacingOccurrences(of: "{N}", with: String(count))
            .replacingOccurrences(of: "{update}", with: self.updateNoun(count: count))
            .replacingOccurrences(of: "{needs}", with: count == 1 ? "needs" : "need")
    }

    static func deliverySending(count: Int) -> String {
        self.deliverySendingTemplate
            .replacingOccurrences(of: "{N}", with: String(count))
            .replacingOccurrences(of: "{update}", with: self.updateNoun(count: count))
    }

    static func deliveryLastSaved(time: String) -> String {
        self.deliveryLastSavedTemplate.replacingOccurrences(of: "{time}", with: time)
    }

    private static func updateNoun(count: Int) -> String {
        count == 1 ? "update" : "updates"
    }
}
