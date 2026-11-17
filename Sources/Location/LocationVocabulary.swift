// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum LocationVocabulary {
    static let sourceDisplayName = AppStrings.ios_location_sourcedisplayname()
    private static let activeSubtextUnpaired = AppStrings.ios_location_activesubtextunpaired()
    private static let activeSubtextPaired = AppStrings.ios_location_activesubtextpaired()
    private static let preEnrollmentValueUnpaired = AppStrings.ios_location_preenrollmentvalueunpaired()
    private static let preEnrollmentValuePaired = AppStrings.ios_location_preenrollmentvaluepaired()
    static let tierDialHeader = AppStrings.ios_location_tierdialheader()
    static let tierDialSubhead = AppStrings.ios_location_tierdialsubhead()
    static let lightLabel = AppStrings.ios_location_lightlabel()
    static let lightBody = AppStrings.ios_location_lightbody()
    static let balancedLabel = AppStrings.ios_location_balancedlabel()
    static let balancedBody = AppStrings.ios_location_balancedbody()
    static let balancedDefaultBadge = AppStrings.ios_location_balanceddefaultbadge()
    static let fullLabel = AppStrings.ios_location_fulllabel()
    static let fullBody = AppStrings.ios_location_fullbody()
    static let batteryHonesty = AppStrings.ios_location_batteryhonesty()
    static let turnOnLocation = AppStrings.ios_location_turnonlocation()
    static let stateBlockTitle = AppStrings.ios_app_state()
    static let tierBlockTitle = AppStrings.ios_location_tierblocktitle()
    static let recentBlockTitle = AppStrings.ios_app_recent()
    static let deliveryBlockTitle = AppStrings.ios_location_onitsway()
    static let tierChangeFraming = AppStrings.ios_location_tierchangeframing()
    static let deliveryNeedsAttentionTemplate = AppStrings.ios_location_deliveryneedsattentiontemplate_native()
    static let deliverySendingTemplate = AppStrings.ios_location_deliverysendingtemplate_native()
    static let deliveryQuietLine = AppStrings.ios_location_deliveryquietline()
    static let downgradeBodyTemplate = AppStrings.ios_location_downgradebodytemplate_native()
    static let openSettingsAction = AppStrings.ios_location_openiossettings()
    static let matchToAllowedAction = AppStrings.ios_location_matchtoallowedaction()
    static let locationAttentionRestricted = AppStrings.ios_location_locationattentionrestricted()
    static let locationAttentionDenied = AppStrings.ios_location_locationattentiondenied()
    static let locationAttentionServicesOff = AppStrings.ios_location_locationattentionservicesoff()
    static let locationAttentionNotAllowedYet = AppStrings.ios_location_locationattentionnotallowedyet()
    static let locationAttentionBelowChosen = AppStrings.ios_location_locationattentionbelowchosen()
    static let locationAttentionNotRunning = AppStrings.ios_location_locationattentionnotrunning()
    static let restrictedBody = AppStrings.ios_location_restrictedbody()
    static let honestGap = AppStrings.ios_location_honestgap()

    static func activeSubtext(isJournalPaired: Bool) -> String {
        isJournalPaired ? Self.activeSubtextPaired : Self.activeSubtextUnpaired
    }

    static func preEnrollmentValue(isJournalPaired: Bool) -> String {
        isJournalPaired ? Self.preEnrollmentValuePaired : Self.preEnrollmentValueUnpaired
    }

    static func sharingStatus(for capability: LocationCapability) -> String {
        switch capability {
        case .always(accuracy: .full):
            AppStrings.ios_location_sharingstatus()
        case .always(accuracy: .reduced):
            AppStrings.ios_location_sharingstatus2()
        case .whenInUse(accuracy: .full):
            AppStrings.ios_location_sharingstatus7()
        case .whenInUse(accuracy: .reduced):
            AppStrings.ios_location_sharingstatus8()
        case .notDetermined:
            AppStrings.ios_location_sharingstatus3()
        case .servicesDisabled:
            AppStrings.ios_location_sharingstatus5()
        case .denied:
            AppStrings.ios_location_sharingstatus4()
        case .restricted:
            AppStrings.ios_location_sharingstatus6()
        }
    }

    static func downgradeBody(tierLabel: String) -> String {
        AppStrings.ios_location_downgrade_complete(tierLabel)
}

    static func deliveryNeedsAttention(count: Int) -> String {
        AppStrings.ios_location_delivery_attention(count)
}

    static func deliverySending(count: Int) -> String {
        AppStrings.ios_location_delivery_sending(count)
}

    private static func updateNoun(count: Int) -> String {
        AppStrings.ios_plural_locationvocabulary_n90(count)
    }
}
