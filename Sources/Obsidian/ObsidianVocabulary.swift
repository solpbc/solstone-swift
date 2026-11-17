// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import UIKit

nonisolated enum ObsidianVocabulary {
    static let TITLE = AppStrings.ios_obsidian_obsidian()
    static let EXPLAINER = AppStrings.ios_obsidian_notesfromyourchosenvault()
    static let CHOOSE_BUTTON = AppStrings.ios_obsidian_chooseavault()
    static let PICKER_GUIDANCE_IPHONE = AppStrings.ios_obsidian_chooseyourvaultinsidethe()
    static let PICKER_GUIDANCE_IPAD = AppStrings.ios_obsidian_chooseyourvaultinsidethe2()
    static let TIMING_SETUP = AppStrings.ios_obsidian_checkswhilethisappis()
    static let REFUSED_INVALID_FOLDER = AppStrings.ios_obsidian_thisfolderhasnoreadable()
    static let REFUSED_UNSUPPORTED_LOCATION_IPHONE = AppStrings.ios_obsidian_chooseavaultinon()
    static let REFUSED_UNSUPPORTED_LOCATION_IPAD = AppStrings.ios_obsidian_chooseavaultinon2()
    static let REFUSED_INVALID_NAME = AppStrings.ios_obsidian_thisvaultsnamecantbe()
    static let ACCESS_LOST = AppStrings.ios_obsidian_cantreadthisvaultchoose()
    static let DELIVERY_ATTENTION = AppStrings.ios_obsidian_somenotesneedattentionbefore()
    static let PRIVATE_SAVE_FAULT = AppStrings.ios_obsidian_thischangecouldntbesaved()
    static let PRIVATE_STORE_FAULT = AppStrings.ios_obsidian_savedobsidianchangescantbe()
    static let INCOMPLETE_SCAN = AppStrings.ios_obsidian_couldntfinishcheckingthevault()
    static let CAPABILITY_NOT_LISTED = AppStrings.ios_obsidian_waitingforajournalupdate()
    static let CAPABILITY_UNKNOWN = AppStrings.ios_obsidian_waitingtocheckyourjournal()
    static let SAME_NAME_TITLE = AppStrings.ios_obsidian_avaultwiththisname()
    static let CONTINUE = AppStrings.ios_home_alwaysprimercontinue()
    static let CANCEL = AppStrings.ios_migration_picker_cancel()
    static let PAUSE = AppStrings.ios_photolibrary_pause()
    static let RESUME = AppStrings.ios_photolibrary_resume()
    static let SWITCH_LABEL = AppStrings.ios_obsidian_obsidian()
    static let VAULT_FACT = AppStrings.ios_obsidian_vault()
    static let CHECKED_FACT = AppStrings.ios_obsidian_lastchecked()
    static let WAITING_FACT = AppStrings.ios_obsidian_waitingtogotoyour()
    static let UNAVAILABLE_FACT = AppStrings.ios_obsidian_notonthisdevice()
    static let SIZE_FACT = AppStrings.ios_obsidian_notestoolargetosend()
    static let MANUAL_CHECK = AppStrings.ios_obsidian_checknow()
    static let HELD_EARLIER_VAULT = AppStrings.ios_obsidian_changesfromanothervaultstay()
    static let NOT_CHECKED_YET = AppStrings.ios_obsidian_notcheckedyet()

    static func unsupportedLocationSentence(isPad: Bool) -> String {
        isPad ? REFUSED_UNSUPPORTED_LOCATION_IPAD : REFUSED_UNSUPPORTED_LOCATION_IPHONE
    }

    static func pickerGuidanceSentence(isPad: Bool) -> String {
        isPad ? PICKER_GUIDANCE_IPAD : PICKER_GUIDANCE_IPHONE
    }

    static func sameNameBody(vault: String, device: String?, date: String) -> String {
        if let device, !device.isEmpty {
            return AppStrings.ios_obsidian_waslastsharedfromon("\(vault)", "\(device)", "\(date)")
        } else {
            return AppStrings.ios_obsidian_waslastsharedoncontinue("\(vault)", "\(date)")
        }
    }

    static func progress(delivered: Int, found: Int) -> String {
        AppStrings.ios_obsidian_ofnotesinyourjournal_native("\(delivered)", "\(found)")
    }
}
