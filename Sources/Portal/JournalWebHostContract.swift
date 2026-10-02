// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import WebKit

@MainActor
enum JournalWebHostContractConfiguration {
    struct Contract: Equatable {
        let userAgentProduct: String
        let javascriptCapability: String
        let initializationScript: String
    }

    enum DecodeFailure: Error, Equatable {
        case malformed
        case unsupported
    }

    private enum UnavailableReason: String {
        case missing
        case malformed
        case unsupported
    }

    private struct Payload: Decodable {
        let version: Int
        let userAgentProduct: String
        let javascriptCapability: String
        let initializationScript: String

        enum CodingKeys: String, CodingKey {
            case version
            case userAgentProduct = "user_agent_product"
            case javascriptCapability = "javascript_capability"
            case initializationScript = "initialization_script"
        }
    }

    static func make(
        bundle: Bundle = Bundle(for: AppDelegate.self),
        diagnosticLog: DiagnosticLog? = nil
    ) -> WKWebViewConfiguration {
        guard let url = bundle.url(forResource: "host-contract", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else {
            let configuration = WKWebViewConfiguration()
            configuration.applicationNameForUserAgent = nil
            self.emitUnavailable(.missing, to: diagnosticLog)
            return configuration
        }

        return self.decode(data, diagnosticLog: diagnosticLog)
    }

    static func decode(_ data: Data, diagnosticLog: DiagnosticLog? = nil) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.applicationNameForUserAgent = nil
        switch self.decodePayload(data) {
        case .success(let contract):
            configuration.applicationNameForUserAgent = contract.userAgentProduct
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: contract.initializationScript,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
        case .failure(.malformed):
            self.emitUnavailable(.malformed, to: diagnosticLog)
        case .failure(.unsupported):
            self.emitUnavailable(.unsupported, to: diagnosticLog)
        }
        return configuration
    }

    private static func decodePayload(_ data: Data) -> Result<Contract, DecodeFailure> {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            return .failure(.malformed)
        }
        guard payload.version == 1 else { return .failure(.unsupported) }
        guard !payload.userAgentProduct.isEmpty,
              !payload.javascriptCapability.isEmpty,
              !payload.initializationScript.isEmpty
        else {
            return .failure(.malformed)
        }
        return .success(
            Contract(
                userAgentProduct: payload.userAgentProduct,
                javascriptCapability: payload.javascriptCapability,
                initializationScript: payload.initializationScript
            )
        )
    }

    private static func emitUnavailable(_ reason: UnavailableReason, to diagnosticLog: DiagnosticLog?) {
        let detail = "reason=\(reason.rawValue)"
        diagnosticLog?.append(
            category: .journal,
            severity: .warning,
            message: "contract_unavailable",
            detail: detail
        )
        switch reason {
        case .missing:
            journalWebLog.error("event=contract_unavailable reason=missing")
        case .malformed:
            journalWebLog.error("event=contract_unavailable reason=malformed")
        case .unsupported:
            journalWebLog.error("event=contract_unavailable reason=unsupported")
        }
    }
}
