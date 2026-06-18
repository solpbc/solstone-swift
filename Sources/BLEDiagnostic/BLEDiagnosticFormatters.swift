// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreBluetooth
import Foundation

nonisolated enum BLEDiagnosticFormatters {
    static func stateLine(for state: CBManagerState) -> String {
        switch state {
        case .unauthorized:
            "bluetooth is not authorized"
        case .poweredOff:
            "bluetooth is off"
        case .unsupported:
            "bluetooth unsupported on this device"
        case .resetting:
            "bluetooth resetting"
        case .unknown:
            "bluetooth state unknown"
        case .poweredOn:
            "bluetooth on"
        @unknown default:
            "bluetooth state unknown"
        }
    }

    static func propertyLabels(_ properties: CBCharacteristicProperties) -> [String] {
        [
            (.read, "read"),
            (.writeWithoutResponse, "writeWithoutResponse"),
            (.write, "write"),
            (.notify, "notify"),
            (.indicate, "indicate"),
            (.authenticatedSignedWrites, "authenticatedSignedWrites"),
            (.extendedProperties, "extendedProperties"),
            (.notifyEncryptionRequired, "notifyEncryptionRequired"),
            (.indicateEncryptionRequired, "indicateEncryptionRequired")
        ].compactMap { flag, label in
            properties.contains(flag) ? label : nil
        }
    }

    static func hexDump(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    static func asciiDump(_ data: Data) -> String {
        String(data.map { byte in
            if byte >= 0x20 && byte <= 0x7E {
                return Character(UnicodeScalar(byte))
            }
            return "."
        })
    }
}
