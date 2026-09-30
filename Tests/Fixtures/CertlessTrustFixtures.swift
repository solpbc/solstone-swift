// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift

enum CertlessTrustFixtures {
    static let caPEM = CertlessTrustConstants.caPEM
    static let leafPEM = CertlessTrustConstants.leafPEM
    static let wrongCAPEM = CertlessTrustConstants.wrongCAPEM
    static let chainPEM = CertlessTrustConstants.chainPEM
    static let wrongChainPEM = CertlessTrustConstants.wrongChainPEM
}
