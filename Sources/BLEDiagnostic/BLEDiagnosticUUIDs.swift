// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreBluetooth

nonisolated enum BLEDiagnosticUUIDs {
    static var audioService: CBUUID { CBUUID(string: "19B10000-E8F2-537E-4F6C-D104768A1214") }
    static var audioDataCharacteristic: CBUUID { CBUUID(string: "19B10001-E8F2-537E-4F6C-D104768A1214") }
    static var codecCharacteristic: CBUUID { CBUUID(string: "19B10002-E8F2-537E-4F6C-D104768A1214") }
    static var speakerCharacteristic: CBUUID { CBUUID(string: "19B10003-E8F2-537E-4F6C-D104768A1214") }

    static var storageService: CBUUID { CBUUID(string: "30295780-4301-EABD-2904-2849ADFEAE43") }

    static var batteryService: CBUUID { CBUUID(string: "180F") }
    static var batteryLevelCharacteristic: CBUUID { CBUUID(string: "2A19") }

    static var deviceInformationService: CBUUID { CBUUID(string: "180A") }
    static var firmwareRevisionCharacteristic: CBUUID { CBUUID(string: "2A26") }
    static var manufacturerNameCharacteristic: CBUUID { CBUUID(string: "2A29") }
    static var modelNumberCharacteristic: CBUUID { CBUUID(string: "2A24") }
    static var hardwareRevisionCharacteristic: CBUUID { CBUUID(string: "2A27") }

    static var scanServiceUUIDs: [CBUUID] { [
        audioService
    ] }

    static func displayName(for uuid: CBUUID) -> String {
        switch uuid.uuidString.uppercased() {
        case Self.audioService.uuidString.uppercased():
            "audio service"
        case Self.audioDataCharacteristic.uuidString.uppercased():
            "audio data"
        case Self.codecCharacteristic.uuidString.uppercased():
            "codec"
        case Self.speakerCharacteristic.uuidString.uppercased():
            "speaker"
        case Self.storageService.uuidString.uppercased():
            "storage service"
        case Self.batteryService.uuidString.uppercased():
            "battery service"
        case Self.batteryLevelCharacteristic.uuidString.uppercased():
            "battery level"
        case Self.deviceInformationService.uuidString.uppercased():
            "device info"
        case Self.firmwareRevisionCharacteristic.uuidString.uppercased():
            "firmware revision"
        case Self.manufacturerNameCharacteristic.uuidString.uppercased():
            "manufacturer"
        case Self.modelNumberCharacteristic.uuidString.uppercased():
            "model"
        case Self.hardwareRevisionCharacteristic.uuidString.uppercased():
            "hardware revision"
        default:
            uuid.uuidString
        }
    }
}
