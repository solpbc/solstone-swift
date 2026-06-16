// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation

nonisolated protocol OwnNetworkReading: Sendable {
    func interfaces() -> [IPv4Interface]
}

nonisolated struct GetifaddrsNetworkReader: OwnNetworkReading {
    init() {}

    func interfaces() -> [IPv4Interface] {
        var rawInterfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&rawInterfaces) == 0,
              let rawInterfaces else {
            return []
        }
        defer {
            freeifaddrs(rawInterfaces)
        }

        var result: [IPv4Interface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = rawInterfaces
        while let current = cursor {
            let interface = current.pointee
            cursor = interface.ifa_next

            let flags = interface.ifa_flags
            guard flags & UInt32(IFF_UP) != 0,
                  flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = interface.ifa_addr,
                  let netmask = interface.ifa_netmask,
                  address.pointee.sa_family == sa_family_t(AF_INET),
                  netmask.pointee.sa_family == sa_family_t(AF_INET),
                  let addressString = Self.ipv4String(from: address),
                  let netmaskString = Self.ipv4String(from: netmask),
                  Self.isUsableAddress(addressString) else {
                continue
            }

            result.append(IPv4Interface(address: addressString, netmask: netmaskString))
        }
        return result
    }

    static func isUsableAddress(_ address: String) -> Bool {
        guard let octets = parseIPv4(address) else {
            return false
        }
        if octets[0] == 127 {
            return false
        }
        if octets[0] == 169 && octets[1] == 254 {
            return false
        }
        return true
    }

    private static func ipv4String(from address: UnsafePointer<sockaddr>) -> String? {
        var ipv4Address = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            $0.pointee.sin_addr
        }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &ipv4Address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
        }
        return String(cString: buffer)
    }
}
