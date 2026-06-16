// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel

nonisolated struct IPv4Interface: Equatable, Sendable {
    let address: String
    let netmask: String
}

nonisolated enum PairFailureReason: Equatable, Sendable {
    case differentNetwork(phoneAddress: String, targetAddress: String)
    case hostUnreachable(targetAddress: String?)
    case loopbackAddress
    case codeExpired
    case wrongSolstone
    case generic

    static func classify(error: Error, targetAddress: String?, interfaces: [IPv4Interface]) -> PairFailureReason {
        switch error {
        case PairError.nonceExpired,
             PairError.pairingWindowClosed:
            return .codeExpired
        case PairError.lanCAFingerprintMismatch:
            return .wrongSolstone
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
            return .hostUnreachable(targetAddress: candidateAddresses.first)
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

        return .differentNetwork(
            phoneAddress: firstUsable.address,
            targetAddress: candidateAddresses.first ?? ""
        )
    }

    var message: String {
        switch self {
        case .differentNetwork(let phoneAddress, let targetAddress):
            """
            this phone and your solstone are on different networks.
            this phone: \(phoneAddress)
            your solstone: \(targetAddress)
            connect both to the same wi-fi, then try again.
            """
        case .hostUnreachable(let targetAddress):
            if let targetAddress {
                "couldn't reach your solstone at \(targetAddress). make sure it's running and on the same wi-fi, then try again. some networks block devices from connecting directly."
            } else {
                "couldn't reach your solstone. make sure it's running and on the same wi-fi, then try again."
            }
        case .loopbackAddress:
            "that address points back at this phone. paste the pairing link shown on your solstone instead."
        case .codeExpired:
            "the pairing window closed. show a new pairing code on your solstone, then try again."
        case .wrongSolstone:
            "this solstone's identity doesn't match the pairing code. double-check which solstone you're pairing, then try again with a new code."
        case .generic:
            "pairing didn't go through. show a new pairing code on your solstone and try again."
        }
    }

    private static func classifyConnectivityFailure(
        targetAddress: String?,
        interfaces: [IPv4Interface]
    ) -> PairFailureReason {
        guard let targetOctets = parseIPv4(targetAddress),
              !interfaces.isEmpty else {
            return .hostUnreachable(targetAddress: targetAddress)
        }

        let target = packIPv4(targetOctets)
        let usableInterfaces = usableIPv4Interfaces(from: interfaces)
        guard let firstUsable = usableInterfaces.first else {
            return .hostUnreachable(targetAddress: targetAddress)
        }

        if usableInterfaces.contains(where: {
            isOnSameSubnet(targetValue: target, addressValue: $0.addressValue, netmaskValue: $0.netmaskValue)
        }) {
            return .hostUnreachable(targetAddress: targetAddress)
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
