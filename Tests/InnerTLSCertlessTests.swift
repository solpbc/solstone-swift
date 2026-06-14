// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation
import Security
@testable import SPLTunnel
import XCTest

nonisolated final class InnerTLSCertlessTests: XCTestCase {
    func testCertlessTrustAcceptsMatchingCAAndRejectsWrongCA() throws {
        let chain = try CertChain.certificates(fromPEM: CertlessTrustFixtures.chainPEM)
        let wrongChain = try CertChain.certificates(fromPEM: CertlessTrustFixtures.wrongChainPEM)
        XCTAssertEqual(chain.count, 2)
        XCTAssertEqual(wrongChain.count, 2)
        XCTAssertNotEqual(Self.der(chain[0]), Self.der(chain[1]))

        let caPin = Self.pin16(chain[1])
        let wrongCAPin = Self.pin16(wrongChain[1])

        XCTAssertTrue(InnerTLS.certlessTrustAccepts(chain: chain, caFingerprintBytes: caPin))
        XCTAssertFalse(InnerTLS.certlessTrustAccepts(chain: chain, caFingerprintBytes: wrongCAPin))
        XCTAssertFalse(InnerTLS.certlessTrustAccepts(chain: wrongChain, caFingerprintBytes: wrongCAPin))
        XCTAssertFalse(InnerTLS.certlessTrustAccepts(chain: chain, caFingerprintBytes: Array(caPin.dropLast())))
    }

    private static func pin16(_ certificate: SecCertificate) -> [UInt8] {
        Array(SHA256.hash(data: der(certificate)).prefix(16))
    }

    private static func der(_ certificate: SecCertificate) -> Data {
        SecCertificateCopyData(certificate) as Data
    }
}
