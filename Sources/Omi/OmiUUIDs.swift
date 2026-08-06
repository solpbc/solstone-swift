// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreBluetooth

nonisolated enum OmiUUIDs {
    static var audioService: CBUUID { CBUUID(string: "19B10000-E8F2-537E-4F6C-D104768A1214") }
    static var audioDataCharacteristic: CBUUID { CBUUID(string: "19B10001-E8F2-537E-4F6C-D104768A1214") }
    static var codecCharacteristic: CBUUID { CBUUID(string: "19B10002-E8F2-537E-4F6C-D104768A1214") }
    static var storageService: CBUUID { CBUUID(string: "30295780-4301-EABD-2904-2849ADFEAE43") }
    static var storageControlCharacteristic: CBUUID { CBUUID(string: "30295782-4301-EABD-2904-2849ADFEAE43") }

    static var batteryService: CBUUID { CBUUID(string: "180F") }
    static var batteryLevelCharacteristic: CBUUID { CBUUID(string: "2A19") }

    static var deviceInformationService: CBUUID { CBUUID(string: "180A") }
    static var firmwareRevisionCharacteristic: CBUUID { CBUUID(string: "2A26") }
    static var manufacturerNameCharacteristic: CBUUID { CBUUID(string: "2A29") }
    static var modelNumberCharacteristic: CBUUID { CBUUID(string: "2A24") }
    static var hardwareRevisionCharacteristic: CBUUID { CBUUID(string: "2A27") }

    static var audioServiceID: String { audioService.uuidString }
    static var audioDataCharacteristicID: String { audioDataCharacteristic.uuidString }
    static var codecCharacteristicID: String { codecCharacteristic.uuidString }
    static var storageServiceID: String { storageService.uuidString }
    static var storageControlCharacteristicID: String { storageControlCharacteristic.uuidString }
    static var batteryServiceID: String { batteryService.uuidString }
    static var batteryLevelCharacteristicID: String { batteryLevelCharacteristic.uuidString }
    static var deviceInformationServiceID: String { deviceInformationService.uuidString }
    static var firmwareRevisionCharacteristicID: String { firmwareRevisionCharacteristic.uuidString }
    static var manufacturerNameCharacteristicID: String { manufacturerNameCharacteristic.uuidString }
    static var modelNumberCharacteristicID: String { modelNumberCharacteristic.uuidString }
    static var hardwareRevisionCharacteristicID: String { hardwareRevisionCharacteristic.uuidString }
}
