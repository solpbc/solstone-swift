// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum TransferReasonCodes {
    static let invalidOperationForState = "invalid_operation_for_state"
}

nonisolated enum TransferEndpointPhase: Equatable, Sendable {
    case observerIngest
    case save
    case start(saveResult: TransferSaveThenStartState?)
}

nonisolated struct TransferHTTPResult: Equatable, Sendable {
    var statusCode: Int?
    var data: Data
    var issue: TransferTransportIssue?

    init(statusCode: Int?, data: Data = Data(), issue: TransferTransportIssue? = nil) {
        self.statusCode = statusCode
        self.data = data
        self.issue = issue
    }
}

nonisolated enum TransferTransportIssue: Equatable, Sendable {
    case timeout
    case cancelled
    case transport(String)
}

nonisolated enum TransferOutcome: Equatable, Sendable {
    case terminalSuccess(TransferSuccessKind)
    case terminalAttention(TransferAttentionReason)
    case transientRetry(TransferTransientReason)
    case continueWithStart(TransferSaveThenStartState)
}

nonisolated enum TransferSuccessKind: Equatable, Sendable {
    case delivered(serverPath: String?, serverTimestamp: String?)
    case alreadyDelivered
    case alreadyStartedOrComplete(serverPath: String?, serverTimestamp: String?)
}

nonisolated enum TransferAttentionReason: Equatable, Sendable {
    case httpClientError(statusCode: Int, detail: String?)
    case decodeFailed(String)
    case missingPayload(String)
    case malformedManifest(String)
}

nonisolated enum TransferTransientReason: Equatable, Sendable {
    case httpServerError(statusCode: Int)
    case timeout
    case cancelled
    case transport(String)
}

nonisolated enum TransferHTTPClassifier {
    private struct SaveResponse: Decodable {
        let path: String?
        let timestamp: String?
        let recommendedAction: String
        let source: String?

        enum CodingKeys: String, CodingKey {
            case path
            case timestamp
            case source
            case recommendedAction = "recommended_action"
        }
    }

    private struct StartResponse: Decodable {
        let status: String?
        let taskID: String?

        enum CodingKeys: String, CodingKey {
            case status
            case taskID = "task_id"
        }
    }

    private struct StartErrorResponse: Decodable {
        let reasonCode: String?

        enum CodingKeys: String, CodingKey {
            case reasonCode = "reason_code"
        }
    }

    static func classify(result: TransferHTTPResult, endpointPhase: TransferEndpointPhase) -> TransferOutcome {
        if let issue = result.issue {
            switch issue {
            case .timeout:
                return .transientRetry(.timeout)
            case .cancelled:
                return .transientRetry(.cancelled)
            case .transport(let detail):
                return .transientRetry(.transport(detail))
            }
        }

        guard let statusCode = result.statusCode else {
            return .transientRetry(.transport("missing http response"))
        }

        if 200..<300 ~= statusCode {
            if self.hasAlreadyDeliveredSignal(result.data) {
                return .terminalSuccess(.alreadyDelivered)
            }

            switch endpointPhase {
            case .observerIngest:
                return .terminalSuccess(.delivered(serverPath: nil, serverTimestamp: nil))
            case .save:
                return self.classifySaveSuccess(data: result.data)
            case .start(let saveResult):
                return self.classifyStartSuccess(data: result.data, saveResult: saveResult)
            }
        }

        if statusCode == 400,
           case .start(let saveResult) = endpointPhase,
           let response = try? JSONDecoder().decode(StartErrorResponse.self, from: result.data),
           response.reasonCode == TransferReasonCodes.invalidOperationForState
        {
            return .terminalSuccess(.alreadyStartedOrComplete(
                serverPath: saveResult?.savedPath,
                serverTimestamp: saveResult?.savedTimestamp
            ))
        }

        if 400..<500 ~= statusCode {
            let detail = String(data: result.data, encoding: .utf8)
            return .terminalAttention(.httpClientError(statusCode: statusCode, detail: detail))
        }

        if 500..<600 ~= statusCode {
            return .transientRetry(.httpServerError(statusCode: statusCode))
        }

        return .transientRetry(.transport("unexpected http \(statusCode)"))
    }

    private static func classifySaveSuccess(data: Data) -> TransferOutcome {
        guard let response = try? JSONDecoder().decode(SaveResponse.self, from: data) else {
            return .terminalAttention(.decodeFailed("invalid save response"))
        }

        switch response.recommendedAction {
        case TransferRecommendedAction.start.rawValue:
            guard let path = response.path, let timestamp = response.timestamp else {
                return .terminalAttention(.decodeFailed("missing path or timestamp"))
            }
            return .continueWithStart(TransferSaveThenStartState(
                phase: .startPending,
                savedPath: path,
                savedTimestamp: timestamp,
                recommendedAction: TransferRecommendedAction.start.rawValue,
                serverSource: response.source
            ))
        case TransferRecommendedAction.doNotStart.rawValue:
            return .terminalSuccess(.delivered(serverPath: response.path, serverTimestamp: response.timestamp))
        default:
            return .terminalAttention(.decodeFailed("unknown recommended action"))
        }
    }

    private static func classifyStartSuccess(
        data: Data,
        saveResult: TransferSaveThenStartState?
    ) -> TransferOutcome {
        guard let response = try? JSONDecoder().decode(StartResponse.self, from: data),
              response.status == "ok",
              let taskID = response.taskID,
              !taskID.isEmpty
        else {
            return .terminalAttention(.decodeFailed("invalid start response"))
        }
        return .terminalSuccess(.delivered(
            serverPath: saveResult?.savedPath,
            serverTimestamp: saveResult?.savedTimestamp
        ))
    }

    private static func hasAlreadyDeliveredSignal(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        for key in ["status", "reason", "result"] {
            if object[key] as? String == "already_delivered" {
                return true
            }
        }
        return false
    }
}
