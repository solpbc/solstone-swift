// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import UIKit

nonisolated enum ObsidianVocabulary {
    static let TITLE = "Obsidian"
    static let EXPLAINER = "notes from your chosen vault go into your journal"
    static let CHOOSE_BUTTON = "choose a vault"
    static let PICKER_GUIDANCE_IPHONE = "choose your vault inside the Obsidian folder in On My iPhone"
    static let PICKER_GUIDANCE_IPAD = "choose your vault inside the Obsidian folder in On My iPad"
    static let TIMING_SETUP = "checks while this app is open. ios may also allow a check in the background."
    static let REFUSED_INVALID_FOLDER = "this folder has no readable Obsidian configuration. choose the vault folder itself."
    static let REFUSED_UNSUPPORTED_LOCATION_IPHONE = "choose a vault in On My iPhone. iCloud and other file providers aren't supported yet."
    static let REFUSED_UNSUPPORTED_LOCATION_IPAD = "choose a vault in On My iPad. iCloud and other file providers aren't supported yet."
    static let REFUSED_INVALID_NAME = "this vault's name can't be sent to your journal. choose another vault."
    static let ACCESS_LOST = "can't read this vault. choose it again to restore access."
    static let DELIVERY_ATTENTION = "some notes need attention before they can reach your journal."
    static let PRIVATE_SAVE_FAULT = "this change couldn't be saved. try again."
    static let PRIVATE_STORE_FAULT = "saved Obsidian changes can't be read right now. try opening the app again."
    static let INCOMPLETE_SCAN = "couldn't finish checking the vault. the next check will try again."
    static let CAPABILITY_NOT_LISTED = "waiting for a journal update"
    static let CAPABILITY_UNKNOWN = "waiting to check your journal"
    static let SAME_NAME_TITLE = "a vault with this name is already in your journal"
    static let CONTINUE = "continue"
    static let CANCEL = "cancel"
    static let PAUSE = "pause"
    static let RESUME = "resume"
    static let SWITCH_LABEL = "Obsidian"
    static let VAULT_FACT = "vault"
    static let CHECKED_FACT = "last checked"
    static let WAITING_FACT = "waiting to go to your journal"
    static let UNAVAILABLE_FACT = "not on this device"
    static let SIZE_FACT = "notes too large to send"
    static let MANUAL_CHECK = "check now"
    static let HELD_EARLIER_VAULT = "changes from another vault stay on this device. choose that vault to send them."
    static let NOT_CHECKED_YET = "not checked yet"

    static func unsupportedLocationSentence(isPad: Bool) -> String {
        isPad ? REFUSED_UNSUPPORTED_LOCATION_IPAD : REFUSED_UNSUPPORTED_LOCATION_IPHONE
    }

    static func pickerGuidanceSentence(isPad: Bool) -> String {
        isPad ? PICKER_GUIDANCE_IPAD : PICKER_GUIDANCE_IPHONE
    }

    static func sameNameBody(vault: String, device: String?, date: String) -> String {
        if let device, !device.isEmpty {
            return "\(vault) was last shared from \(device) on \(date). continue with this vault?"
        } else {
            return "\(vault) was last shared on \(date). continue with this vault?"
        }
    }

    static func progress(delivered: Int, found: Int) -> String {
        "\(delivered) of \(found) notes in your journal"
    }
}
