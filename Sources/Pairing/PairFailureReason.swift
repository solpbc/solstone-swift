// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel

nonisolated struct IPv4Interface: Equatable, Sendable {
    let address: String
    let netmask: String
}

nonisolated enum PairFailureReason: Equatable, Sendable {
    case publicJournalUnreachable(targetAddress: String?)
    case differentNetwork(phoneAddress: String, targetAddress: String)
    case hostUnreachable(targetAddress: String?)
    case loopbackAddress
    case journalUnreachableOffLAN
    case directAddressNotLocal
    case connectionDropped
    case codeExpired
    case wrongSolstone
    case relayInstanceMismatch
    case generic

    static func classify(error: Error, targetAddress: String?, interfaces: [IPv4Interface]) -> PairFailureReason {
        switch error {
        case PairError.nonceExpired,
             PairError.pairingWindowClosed:
            return .codeExpired
        case PairError.lanCAFingerprintMismatch:
            return .wrongSolstone
        case PairError.relayInstanceMismatch:
            return .relayInstanceMismatch
        case PairError.directAddressNotLocal:
            return .directAddressNotLocal
        case PairError.lanClosedBeforeResponse:
            return .connectionDropped
        case PairError.lanResponseInvalid:
            return .generic
        case PairError.lanRequestFailed(underlying: nil):
            return .generic
        case PairError.lanRequestFailed(underlying: .some):
            return classifyConnectivityFailure(targetAddress: targetAddress, interfaces: interfaces)
        default:
            return .generic
        }
    }

    static func classifyExhausted(
        sawCAFingerprintMismatch: Bool,
        candidateAddresses: [String],
        interfaces: [IPv4Interface]
    ) -> PairFailureReason {
        if sawCAFingerprintMismatch {
            return .wrongSolstone
        }

        let usableInterfaces = usableIPv4Interfaces(from: interfaces)
        guard let firstUsable = usableInterfaces.first else {
            if !candidateAddresses.isEmpty, candidateAddresses.allSatisfy(isPublicIPv4Literal) {
                return .publicJournalUnreachable(targetAddress: candidateAddresses.first)
            }
            return .journalUnreachableOffLAN
        }

        for address in candidateAddresses {
            guard let targetOctets = parseIPv4(address) else {
                continue
            }
            let target = packIPv4(targetOctets)
            if usableInterfaces.contains(where: {
                isOnSameSubnet(targetValue: target, addressValue: $0.addressValue, netmaskValue: $0.netmaskValue)
            }) {
                return .hostUnreachable(targetAddress: address)
            }
        }

        if !candidateAddresses.isEmpty, candidateAddresses.allSatisfy(isPublicIPv4Literal) {
            return .publicJournalUnreachable(targetAddress: candidateAddresses.first)
        }

        let targetAddress = candidateAddresses.first(where: { !isPublicIPv4Literal($0) }) ?? candidateAddresses.first ?? ""
        return .differentNetwork(
            phoneAddress: firstUsable.address,
            targetAddress: targetAddress
        )
    }

    /// The same reason with each journal address shown as `address:port`, taken from the
    /// pairing link's candidates. Classification itself stays on the bare address.
    func showingPorts(of candidates: [PairCandidate]) -> PairFailureReason {
        func withPort(_ address: String) -> String {
            let octets = parseIPv4(address)
            guard let candidate = candidates.first(where: {
                $0.address == address || (octets != nil && parseIPv4($0.address) == octets)
            }) else {
                return address
            }
            return JournalAddress.display(host: address, port: Int(candidate.port))
        }
        switch self {
        case .publicJournalUnreachable(let targetAddress):
            return .publicJournalUnreachable(targetAddress: targetAddress.map(withPort))
        case .differentNetwork(let phoneAddress, let targetAddress):
            return .differentNetwork(phoneAddress: phoneAddress, targetAddress: withPort(targetAddress))
        case .hostUnreachable(let targetAddress):
            return .hostUnreachable(targetAddress: targetAddress.map(withPort))
        case .loopbackAddress, .journalUnreachableOffLAN, .directAddressNotLocal, .connectionDropped,
             .codeExpired, .wrongSolstone, .relayInstanceMismatch, .generic:
            return self
        }
    }

    var message: String {
        switch self {
        case .publicJournalUnreachable(let targetAddress):
            if let targetAddress {
                "couldn't reach your journal at \(targetAddress). make sure it's running, then try again."
            } else {
                "couldn't reach your journal. make sure it's running, then try again."
            }
        case .differentNetwork(let phoneAddress, let targetAddress):
            """
            this device and your journal are on different networks.
            this device: \(phoneAddress)
            your journal: \(targetAddress)
            connect both to the same wi-fi, then try again.
            turning on private network on your journal lets your devices reach it from anywhere.
            """
        case .hostUnreachable(let targetAddress):
            if let targetAddress {
                "couldn't reach your journal at \(targetAddress). make sure it's running and on the same wi-fi, then try again. some networks block devices from connecting directly. turning on private network on your journal lets your devices reach it from anywhere."
            } else {
                "couldn't reach your journal. make sure it's running and on the same wi-fi, then try again. turning on private network on your journal lets your devices reach it from anywhere."
            }
        case .loopbackAddress:
            "that address points back at this device. paste the pairing link shown on your journal instead."
        case .journalUnreachableOffLAN:
            "your journal isn't reachable from here. you're on cellular, and pairing needs to reach your journal directly. join the same wi-fi as your journal, or try again when you're home. everything the solstone app has taken in is on this device and syncs once you reconnect."
        case .directAddressNotLocal:
            "that pairing link points to an address that can't be opened. copy the link from your journal again and try again."
        case .connectionDropped:
            "lost the connection to your journal before it answered. try again."
        case .codeExpired:
            "the pairing window closed. show a new pairing code on your journal, then try again."
        case .wrongSolstone:
            "this journal's identity doesn't match the pairing code. double-check which journal you're pairing, then try again with a new code."
        case .relayInstanceMismatch:
            "the relay connected to the wrong journal."
        case .generic:
            "pairing didn't go through. show a new pairing code on your journal and try again."
        }
    }

    private static func classifyConnectivityFailure(
        targetAddress: String?,
        interfaces: [IPv4Interface]
    ) -> PairFailureReason {
        let isPublic = targetAddress.map(isPublicIPv4Literal) ?? false
        guard let targetOctets = parseIPv4(targetAddress),
              !interfaces.isEmpty else {
            if isPublic {
                return .publicJournalUnreachable(targetAddress: targetAddress)
            }
            return .hostUnreachable(targetAddress: targetAddress)
        }

        let target = packIPv4(targetOctets)
        let usableInterfaces = usableIPv4Interfaces(from: interfaces)
        guard let firstUsable = usableInterfaces.first else {
            if isPublic {
                return .publicJournalUnreachable(targetAddress: targetAddress)
            }
            return .hostUnreachable(targetAddress: targetAddress)
        }

        if usableInterfaces.contains(where: {
            isOnSameSubnet(targetValue: target, addressValue: $0.addressValue, netmaskValue: $0.netmaskValue)
        }) {
            return .hostUnreachable(targetAddress: targetAddress)
        }

        if isPublic {
            return .publicJournalUnreachable(targetAddress: targetAddress)
        }

        return .differentNetwork(
            phoneAddress: firstUsable.address,
            targetAddress: dottedIPv4(targetOctets)
        )
    }
}

private typealias UsableIPv4Interface = (address: String, addressValue: UInt32, netmaskValue: UInt32)

private nonisolated func usableIPv4Interfaces(from interfaces: [IPv4Interface]) -> [UsableIPv4Interface] {
    interfaces.compactMap { interface -> UsableIPv4Interface? in
        guard let addressOctets = parseIPv4(interface.address),
              let netmaskOctets = parseIPv4(interface.netmask) else {
            return nil
        }
        return (
            address: interface.address,
            addressValue: packIPv4(addressOctets),
            netmaskValue: packIPv4(netmaskOctets)
        )
    }
}

nonisolated func isOnSameSubnet(targetValue: UInt32, addressValue: UInt32, netmaskValue: UInt32) -> Bool {
    (targetValue & netmaskValue) == (addressValue & netmaskValue)
}

nonisolated func orderCandidatesBySubnet(_ candidates: [PairCandidate], interfaces: [IPv4Interface]) -> [PairCandidate] {
    let usableInterfaces = usableIPv4Interfaces(from: interfaces)
    guard !usableInterfaces.isEmpty else {
        return candidates
    }

    var onSubnet: [PairCandidate] = []
    var offSubnet: [PairCandidate] = []
    onSubnet.reserveCapacity(candidates.count)
    offSubnet.reserveCapacity(candidates.count)

    for candidate in candidates {
        guard let targetOctets = parseIPv4(candidate.address) else {
            offSubnet.append(candidate)
            continue
        }
        let target = packIPv4(targetOctets)
        if usableInterfaces.contains(where: {
            isOnSameSubnet(targetValue: target, addressValue: $0.addressValue, netmaskValue: $0.netmaskValue)
        }) {
            onSubnet.append(candidate)
        } else {
            offSubnet.append(candidate)
        }
    }

    return onSubnet + offSubnet
}

nonisolated func parseIPv4(_ string: String?) -> [UInt8]? {
    guard let string else {
        return nil
    }
    let parts = string.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else {
        return nil
    }

    var octets: [UInt8] = []
    octets.reserveCapacity(4)
    for part in parts {
        guard !part.isEmpty,
              part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let value = UInt8(part) else {
            return nil
        }
        octets.append(value)
    }
    return octets
}

nonisolated func isPublicIPv4Literal(_ address: String) -> Bool {
    guard let octets = parseIPv4(address) else {
        return false
    }
    // RFC 1918: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
    if octets[0] == 10 {
        return false
    }
    if octets[0] == 172 && (16...31).contains(octets[1]) {
        return false
    }
    if octets[0] == 192 && octets[1] == 168 {
        return false
    }
    // RFC 6598: 100.64.0.0/10
    if octets[0] == 100 && (64...127).contains(octets[1]) {
        return false
    }
    // Loopback: 127.0.0.0/8
    if octets[0] == 127 {
        return false
    }
    // Link-local: 169.254.0.0/16
    if octets[0] == 169 && octets[1] == 254 {
        return false
    }
    return true
}

nonisolated func packIPv4(_ octets: [UInt8]) -> UInt32 {
    precondition(octets.count == 4)
    return UInt32(octets[0]) << 24
        | UInt32(octets[1]) << 16
        | UInt32(octets[2]) << 8
        | UInt32(octets[3])
}

nonisolated func isLoopbackHost(_ raw: String) -> Bool {
    var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let schemeRange = host.range(of: "://") {
        host = String(host[schemeRange.upperBound...])
    }
    if let slashIndex = host.firstIndex(of: "/") {
        host = String(host[..<slashIndex])
    }
    if host.hasPrefix("["),
       let closingBracket = host.firstIndex(of: "]") {
        host = String(host[host.index(after: host.startIndex)..<closingBracket])
    } else if host.filter({ $0 == ":" }).count == 1,
              let colonIndex = host.firstIndex(of: ":") {
        host = String(host[..<colonIndex])
    }

    if host == "localhost" || host == "::1" {
        return true
    }
    return parseIPv4(host)?.first == 127
}

private nonisolated func dottedIPv4(_ octets: [UInt8]) -> String {
    octets.map(String.init).joined(separator: ".")
}
