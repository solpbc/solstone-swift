// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import SPLTunnel
import XCTest

private struct StubNetworkReader: OwnNetworkReading {
    let value: [IPv4Interface]

    func interfaces() -> [IPv4Interface] {
        value
    }
}

private struct DummyError: Error, Sendable {}

private final class ThrowingLANPairTransport: LANPairTransport, @unchecked Sendable {
    private let error: any Error & Sendable

    init(error: any Error & Sendable) {
        self.error = error
    }

    func send(
        host _: String,
        port _: Int,
        caFingerprintBytes _: [UInt8],
        requestBytes _: Data
    ) async throws -> (status: Int, body: Data) {
        throw error
    }
}

nonisolated final class PairFailureReasonTests: XCTestCase {
    func testPairErrorMappingCases() {
        XCTAssertEqual(self.classify(PairError.nonceExpired), .codeExpired)
        XCTAssertEqual(self.classify(PairError.pairingWindowClosed), .codeExpired)
        XCTAssertEqual(self.classify(PairError.lanCAFingerprintMismatch), .wrongSolstone)
        XCTAssertEqual(self.classify(PairError.lanResponseInvalid(status: 400)), .generic)
        XCTAssertEqual(self.classify(PairError.lanResponseInvalid(status: nil)), .generic)
        XCTAssertEqual(self.classify(PairError.lanRequestFailed(underlying: nil)), .generic)

        let expectedDifferentNetwork = PairFailureReason.differentNetwork(
            phoneAddress: "192.168.1.20",
            targetAddress: "10.0.0.5"
        )
        XCTAssertEqual(
            self.classify(PairError.lanRequestFailed(underlying: URLError(.cannotConnectToHost))),
            expectedDifferentNetwork
        )
        XCTAssertEqual(
            self.classify(PairError.lanRequestFailed(underlying: URLError(.timedOut))),
            expectedDifferentNetwork
        )
        XCTAssertEqual(
            self.classify(PairError.lanRequestFailed(underlying: URLError(.networkConnectionLost))),
            expectedDifferentNetwork
        )
        XCTAssertEqual(
            self.classify(PairError.lanRequestFailed(underlying: URLError(.cannotFindHost))),
            expectedDifferentNetwork
        )
        XCTAssertEqual(
            self.classify(PairError.lanRequestFailed(underlying: DummyError())),
            expectedDifferentNetwork
        )

        XCTAssertEqual(self.classify(PairError.csrBuildFailed), .generic)
        XCTAssertEqual(self.classify(PairError.attestationRejected(status: 403)), .generic)
        XCTAssertEqual(self.classify(PairError.relayRequestFailed(underlying: URLError(.timedOut))), .generic)
    }

    func testOnlyConnectionNeverEstablishedUsesCrossNetworkDecision() {
        let target = "10.0.0.5"
        let interfaces = [IPv4Interface(address: "192.168.1.20", netmask: "255.255.255.0")]

        XCTAssertEqual(
            PairFailureReason.classify(
                error: PairError.pairingWindowClosed,
                targetAddress: target,
                interfaces: interfaces
            ),
            .codeExpired
        )
        XCTAssertEqual(
            PairFailureReason.classify(
                error: PairError.lanResponseInvalid(status: nil),
                targetAddress: target,
                interfaces: interfaces
            ),
            .generic
        )
        XCTAssertEqual(
            PairFailureReason.classify(
                error: PairError.lanCAFingerprintMismatch,
                targetAddress: target,
                interfaces: interfaces
            ),
            .wrongSolstone
        )
    }

    func testCrossNetworkDecisionSubnetCases() {
        XCTAssertEqual(
            self.classifyConnectionFailure(
                targetAddress: "10.0.0.5",
                interfaces: [IPv4Interface(address: "192.168.1.20", netmask: "255.255.255.0")]
            ),
            .differentNetwork(phoneAddress: "192.168.1.20", targetAddress: "10.0.0.5")
        )
        XCTAssertEqual(
            self.classifyConnectionFailure(
                targetAddress: "192.168.1.99",
                interfaces: [IPv4Interface(address: "192.168.1.20", netmask: "255.255.255.0")]
            ),
            .hostUnreachable(targetAddress: "192.168.1.99")
        )
        XCTAssertEqual(
            self.classifyConnectionFailure(
                targetAddress: "10.0.250.9",
                interfaces: [IPv4Interface(address: "10.0.5.4", netmask: "255.255.0.0")]
            ),
            .hostUnreachable(targetAddress: "10.0.250.9")
        )
        XCTAssertEqual(
            self.classifyConnectionFailure(
                targetAddress: "10.1.0.9",
                interfaces: [IPv4Interface(address: "10.0.5.4", netmask: "255.255.0.0")]
            ),
            .differentNetwork(phoneAddress: "10.0.5.4", targetAddress: "10.1.0.9")
        )
        XCTAssertEqual(
            self.classifyConnectionFailure(
                targetAddress: "192.168.1.5",
                interfaces: [
                    IPv4Interface(address: "10.8.0.2", netmask: "255.255.255.0"),
                    IPv4Interface(address: "192.168.1.20", netmask: "255.255.255.0")
                ]
            ),
            .hostUnreachable(targetAddress: "192.168.1.5")
        )
        XCTAssertEqual(
            self.classifyConnectionFailure(
                targetAddress: "192.168.1.5",
                interfaces: [IPv4Interface(address: "100.64.10.2", netmask: "255.192.0.0")]
            ),
            .differentNetwork(phoneAddress: "100.64.10.2", targetAddress: "192.168.1.5")
        )
        XCTAssertEqual(
            self.classifyConnectionFailure(targetAddress: "192.168.1.5", interfaces: []),
            .hostUnreachable(targetAddress: "192.168.1.5")
        )
    }

    func testMalformedTargetsNeverClassifyAsDifferentNetwork() {
        let interfaces = [IPv4Interface(address: "192.168.1.20", netmask: "255.255.255.0")]

        XCTAssertEqual(
            self.classifyConnectionFailure(targetAddress: "mymac.local", interfaces: interfaces),
            .hostUnreachable(targetAddress: "mymac.local")
        )
        XCTAssertEqual(
            self.classifyConnectionFailure(targetAddress: "192.168.1.999", interfaces: interfaces),
            .hostUnreachable(targetAddress: "192.168.1.999")
        )
        XCTAssertEqual(
            self.classifyConnectionFailure(targetAddress: nil, interfaces: interfaces),
            .hostUnreachable(targetAddress: nil)
        )
        XCTAssertEqual(
            self.classifyConnectionFailure(targetAddress: "192.168.1.5", interfaces: []),
            .hostUnreachable(targetAddress: "192.168.1.5")
        )
    }

    func testIPv4ParsingSubnetMathAndReaderAddressFilters() {
        XCTAssertEqual(parseIPv4("192.168.1.5"), [192, 168, 1, 5])
        XCTAssertEqual(parseIPv4("001.002.003.004"), [1, 2, 3, 4])
        XCTAssertNil(parseIPv4(nil))
        XCTAssertNil(parseIPv4("192.168.1"))
        XCTAssertNil(parseIPv4("192.168.1.999"))
        XCTAssertNil(parseIPv4("192.168.1.5:8443"))
        XCTAssertNil(parseIPv4("::ffff:192.168.1.5"))
        XCTAssertNil(parseIPv4("mymac.local"))
        XCTAssertNil(parseIPv4("192.168..1"))

        let mask24 = packIPv4([255, 255, 255, 0])
        XCTAssertEqual(
            packIPv4([192, 168, 1, 44]) & mask24,
            packIPv4([192, 168, 1, 20]) & mask24
        )
        XCTAssertNotEqual(
            packIPv4([192, 168, 2, 44]) & mask24,
            packIPv4([192, 168, 1, 20]) & mask24
        )

        XCTAssertFalse(GetifaddrsNetworkReader.isUsableAddress("127.0.0.1"))
        XCTAssertFalse(GetifaddrsNetworkReader.isUsableAddress("169.254.1.2"))
        XCTAssertTrue(GetifaddrsNetworkReader.isUsableAddress("192.168.1.20"))
        _ = GetifaddrsNetworkReader().interfaces()
    }

    func testLoopbackHostDetection() {
        XCTAssertTrue(isLoopbackHost("localhost"))
        XCTAssertTrue(isLoopbackHost("LOCALHOST"))
        XCTAssertTrue(isLoopbackHost("127.0.0.1"))
        XCTAssertTrue(isLoopbackHost("127.0.0.2"))
        XCTAssertTrue(isLoopbackHost("127.1.2.3"))
        XCTAssertTrue(isLoopbackHost("localhost:5015"))
        XCTAssertTrue(isLoopbackHost("::1"))

        XCTAssertFalse(isLoopbackHost("192.168.1.5"))
        XCTAssertFalse(isLoopbackHost("mymac.local"))
        XCTAssertFalse(isLoopbackHost("10.0.0.1"))
    }

    func testOrderCandidatesBySubnetStablePartitionKeepsOffSubnet() {
        let candidates = [
            PairCandidate(address: "198.51.100.10", port: 7657),
            PairCandidate(address: "192.168.1.90", port: 7657),
            PairCandidate(address: "203.0.113.8", port: 7657),
            PairCandidate(address: "10.0.250.9", port: 7657),
            PairCandidate(address: "journal.local", port: 7657)
        ]
        let interfaces = [
            IPv4Interface(address: "192.168.1.20", netmask: "255.255.255.0"),
            IPv4Interface(address: "10.0.5.4", netmask: "255.255.0.0")
        ]

        XCTAssertEqual(
            orderCandidatesBySubnet(candidates, interfaces: interfaces),
            [
                PairCandidate(address: "192.168.1.90", port: 7657),
                PairCandidate(address: "10.0.250.9", port: 7657),
                PairCandidate(address: "198.51.100.10", port: 7657),
                PairCandidate(address: "203.0.113.8", port: 7657),
                PairCandidate(address: "journal.local", port: 7657)
            ]
        )
    }

    func testOrderCandidatesBySubnetWithEmptyInterfacesKeepsOriginalOrder() {
        let candidates = [
            PairCandidate(address: "198.51.100.10", port: 7657),
            PairCandidate(address: "192.168.1.90", port: 7657)
        ]

        XCTAssertEqual(orderCandidatesBySubnet(candidates, interfaces: []), candidates)
    }

    func testClassifyExhaustedPrecedence() {
        let interfaces = [IPv4Interface(address: "192.168.1.20", netmask: "255.255.255.0")]

        XCTAssertEqual(
            PairFailureReason.classifyExhausted(
                sawCAFingerprintMismatch: true,
                candidateAddresses: ["192.168.1.90"],
                interfaces: interfaces
            ),
            .wrongSolstone
        )
        XCTAssertEqual(
            PairFailureReason.classifyExhausted(
                sawCAFingerprintMismatch: false,
                candidateAddresses: ["10.0.0.5", "192.168.1.90"],
                interfaces: interfaces
            ),
            .hostUnreachable(targetAddress: "192.168.1.90")
        )
        XCTAssertEqual(
            PairFailureReason.classifyExhausted(
                sawCAFingerprintMismatch: false,
                candidateAddresses: ["10.0.0.5", "198.51.100.10"],
                interfaces: interfaces
            ),
            .differentNetwork(phoneAddress: "192.168.1.20", targetAddress: "10.0.0.5")
        )
        XCTAssertEqual(
            PairFailureReason.classifyExhausted(
                sawCAFingerprintMismatch: false,
                candidateAddresses: ["10.0.0.5"],
                interfaces: []
            ),
            .journalUnreachableOffLAN
        )
    }

    func testPairFailureMessageCopyIsLocked() {
        XCTAssertEqual(
            PairFailureReason.differentNetwork(phoneAddress: "192.168.1.20", targetAddress: "10.0.0.5").message,
            """
            this phone and your solstone are on different networks.
            this phone: 192.168.1.20
            your solstone: 10.0.0.5
            connect both to the same wi-fi, then try again.
            """
        )
        XCTAssertEqual(
            PairFailureReason.hostUnreachable(targetAddress: "192.168.1.99").message,
            "couldn't reach your solstone at 192.168.1.99. make sure it's running and on the same wi-fi, then try again. some networks block devices from connecting directly."
        )
        XCTAssertEqual(
            PairFailureReason.journalUnreachableOffLAN.message,
            "your journal isn't reachable from here — you're on cellular, and pairing needs to reach your journal directly. join the same wi-fi as your journal, or try again when you're home. nothing's lost — anything you've gathered stays safe on this phone and syncs once you reconnect."
        )
        XCTAssertEqual(
            PairFailureReason.wrongSolstone.message,
            "this solstone's identity doesn't match the pairing code. double-check which solstone you're pairing, then try again with a new code."
        )
    }

    @MainActor
    func testCoordinatorPassesPairURLAddressToClassifier() async throws {
        let client = PairClient(lanTransport: ThrowingLANPairTransport(error: DummyError()))
        let coordinator = PairFlowCoordinator(
            pairClient: client,
            networkReader: StubNetworkReader(value: [
                IPv4Interface(address: "192.168.1.20", netmask: "255.255.255.0")
            ])
        )

        do {
            try await coordinator.handlePairURL(try PairURL.parse(Self.canonicalDirectURL()))
            XCTFail("expected direct pairing to fail")
        } catch {}

        XCTAssertEqual(
            coordinator.state,
            .failed(error: PairFailureReason.differentNetwork(
                phoneAddress: "192.168.1.20",
                targetAddress: "192.0.2.42"
            ).message)
        )
    }

    private func classify(
        _ error: Error,
        targetAddress: String? = "10.0.0.5",
        interfaces: [IPv4Interface] = [IPv4Interface(address: "192.168.1.20", netmask: "255.255.255.0")]
    ) -> PairFailureReason {
        PairFailureReason.classify(error: error, targetAddress: targetAddress, interfaces: interfaces)
    }

    private func classifyConnectionFailure(
        targetAddress: String?,
        interfaces: [IPv4Interface]
    ) -> PairFailureReason {
        self.classify(PairError.lanRequestFailed(underlying: DummyError()), targetAddress: targetAddress, interfaces: interfaces)
    }

    private static func canonicalDirectURL() -> URL {
        URL(string: "https://go.solstone.app/p#0G0W000258DSX8DJRFAEBXG7308J4CT4ANK7F26YNPZEZJQYQAZ028T5CY4TQKFF")!
    }
}
