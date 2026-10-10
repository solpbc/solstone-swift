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
    case alreadyStartedOrComplete(serverPath: String?, serverTimestamp: String?)
    /// The journal answered `segment_removed`: the owner removed this segment there, so the
    /// journal had received it. That answer is the confirmation, and the phone's copy goes.
    case removedInJournal
}

nonisolated enum TransferAttentionReason: Equatable, Sendable {
    /// A journal refusal. `journalReasonCode` is the refusal body's `reason_code`, when it has one.
    case httpClientError(statusCode: Int, detail: String?, journalReasonCode: String? = nil)
    case decodeFailed(String)
    case missingPayload(String)
    case malformedManifest(String)
}

nonisolated struct ObserverIngestReceiptDescriptor: Decodable, Sendable {
    var submitted: String
    var size: Int
    var sha256: String
    var disposition: String

    enum CodingKeys: String, CodingKey {
        case submitted
        case size
        case sha256
        case disposition
    }
}

nonisolated struct ObserverIngestReceiptResponse: Decodable, Sendable {
    var status: String
    var reasonCode: String?
    var fileDescriptors: [ObserverIngestReceiptDescriptor]?

    enum CodingKeys: String, CodingKey {
        case status
        case reasonCode = "reason_code"
        case fileDescriptors = "file_descriptors"
    }
}

nonisolated enum TransferTransientReason: Equatable, Sendable {
    case httpServerError(statusCode: Int)
    case timeout
    case cancelled
    case transport(String)
}

nonisolated extension TransferTransientReason {
    /// Detail recorded while a transfer is still being retried.
    ///
    /// The state word stays first so a row labelled `last upload error` cannot read as a
    /// settled failure: a bare `cancelled` there reads as a dropped upload, and a cancel
    /// is the ordinary consequence of the app being backgrounded, recovered idempotently.
    ///
    /// Any runtime payload is bounded here, before the value is stored, so every consumer
    /// inherits the bound rather than only the one that redacts at render time.
    var retryDetail: String {
        switch self {
        case .httpServerError(let statusCode):
            "retrying: http \(statusCode)"
        case .timeout:
            "retrying: timeout"
        case .cancelled:
            "retrying: cancelled"
        case .transport(let detail):
            Self.networkDetail(detail)
        }
    }

    private static func networkDetail(_ detail: String) -> String {
        let bounded = WatchTransferFailureFormatter.redactedDescription(detail)
        guard !bounded.isEmpty else { return "retrying: network" }
        return "retrying: network (\(bounded))"
    }
}

nonisolated extension TransferAttentionReason {
    /// The stored reason token for a journal refusal (a 4xx).
    static let httpClientErrorCode = "http_client_error"

    /// The journal's own reason code, for a refusal that carried one.
    var journalReasonCode: String? {
        guard case .httpClientError(_, _, let code) = self else { return nil }
        return code
    }

    /// Detail retained for a terminal attention state.
    ///
    /// Runtime-provided text is bounded before storage because the detail fans out
    /// to the source row, diagnostics, and status mirror. Those consumers must not
    /// each need to remember how to make a server response or NSError safe to share.
    var ownerSafeDetail: String {
        switch self {
        case .httpClientError(let statusCode, let detail, _):
            Self.boundedRuntimeDetail(detail, fallback: "http \(statusCode)")
        case .decodeFailed(let detail):
            detail
        case .missingPayload(let detail):
            Self.boundedRuntimeDetail(detail, fallback: "missing source details")
        case .malformedManifest(let detail):
            detail
        }
    }

    private static func boundedRuntimeDetail(_ detail: String?, fallback: String) -> String {
        guard let detail else { return fallback }
        let bounded = WatchTransferFailureFormatter.redactedDescription(detail)
        return bounded.isEmpty ? fallback : bounded
    }
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

    /// The journal's refusal envelope: `error` is its own owner-safe sentence, `reason_code` and
    /// `detail` are for machines.
    ///
    /// Read leniently: a field is used only when it is a string, and any other value (an object
    /// in `detail`, a number in `reason_code`) is ignored rather than failing the whole read. That
    /// keeps a body that is JSON, in whatever shape, from ever being taken for plain text.
    private struct RefusalEnvelope {
        let error: String?
        let reasonCode: String?
        let detail: String?

        /// `nil` when the body is not JSON. A JSON array is JSON, and has no fields to read.
        init?(body: Data) {
            guard let parsed = try? JSONSerialization.jsonObject(with: body) else { return nil }
            let object = parsed as? [String: Any]
            self.error = object?["error"] as? String
            self.reasonCode = object?["reason_code"] as? String
            self.detail = object?["detail"] as? String
        }
    }

    /// The journal refuses a second save of content it already imported. That content is in the
    /// journal, so the item is delivered. The same reason code also covers a client item id
    /// reused for *different* content, which is a real conflict, so the detail decides.
    private static let contentAlreadyImportedDetail = "content already imported"

    /// Longest journal reason code kept on a record. Every code the journal defines is far
    /// shorter; the bound only stops an unexpected body from growing the record.
    static let journalReasonCodeMaxLength = 64

    /// The refusal body's `reason_code` as stored on the attention record: `nil` when absent or
    /// empty, otherwise the code itself, bounded.
    static func storedJournalReasonCode(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        return String(code.prefix(Self.journalReasonCodeMaxLength))
    }

    private struct ObserverIngestResponse: Decodable {
        let status: String
        let reasonCode: String?

        enum CodingKeys: String, CodingKey {
            case status
            case reasonCode = "reason_code"
        }
    }

    static func classify(result: TransferHTTPResult, endpointPhase: TransferEndpointPhase) -> TransferOutcome {
        if let issue = result.issue {
            switch issue {
            case .timeout:
                return .transientRetry(.timeout)
            case .cancelled:
                // The old path had an uncounted benign re-drive for SAVEs cancelled by a tunnel reconnect (ImportQueue.swift:993-1014). It is intentionally not carried over: cancels are now uniform `.transientRetry(.cancelled)` with persisted backoff, and a SAVE that reached the server before the cancel re-uploads to 2xx via `client_item_id` idempotency.
                return .transientRetry(.cancelled)
            case .transport(let detail):
                return .transientRetry(.transport(detail))
            }
        }

        guard let statusCode = result.statusCode else {
            return .transientRetry(.transport("missing http response"))
        }

        if 200..<300 ~= statusCode {
            switch endpointPhase {
            case .observerIngest:
                return self.classifyObserverIngestSuccess(statusCode: statusCode, data: result.data)
            case .save:
                return self.classifySaveSuccess(data: result.data)
            case .start(let saveResult):
                return self.classifyStartSuccess(data: result.data, saveResult: saveResult)
            }
        }

        let refusal = 400..<500 ~= statusCode ? RefusalEnvelope(body: result.data) : nil

        if statusCode == 400,
           case .start(let saveResult) = endpointPhase,
           refusal?.reasonCode == TransferReasonCodes.invalidOperationForState
        {
            return .terminalSuccess(.alreadyStartedOrComplete(
                serverPath: saveResult?.savedPath,
                serverTimestamp: saveResult?.savedTimestamp
            ))
        }

        if statusCode == 400,
           endpointPhase == .save,
           refusal?.reasonCode == TransferReasonCodes.invalidOperationForState,
           refusal?.detail?.hasPrefix(Self.contentAlreadyImportedDetail) == true
        {
            return .terminalSuccess(.alreadyStartedOrComplete(serverPath: nil, serverTimestamp: nil))
        }

        if 400..<500 ~= statusCode {
            // Never store a JSON body as text, and never its `detail`: some details carry device
            // identifiers, others forward library error text. Only the string `error` and
            // `reason_code` are read from it, whatever else it holds or however its other fields
            // are typed; with neither, the item says only `http <status>`. An import refusal's
            // `error` is a sentence written for the owner; an ingest refusal's is a generic one,
            // so its reason code is kept and turned into owner words only where it is shown. The
            // code itself is also kept on its own, whatever the phase. A body that is not JSON (a
            // proxy's plain-text page, say) is kept as text, bounded later.
            let journalReasonCode = Self.storedJournalReasonCode(refusal?.reasonCode)
            let reasonCodeDetail = journalReasonCode.map { "reason_code=\($0)" }
            let sentence = refusal?.error.flatMap { $0.isEmpty ? nil : $0 }
            let plainText = refusal == nil ? String(data: result.data, encoding: .utf8) : nil
            let detail = endpointPhase == .observerIngest
                ? reasonCodeDetail ?? sentence ?? plainText
                : sentence ?? reasonCodeDetail ?? plainText
            return .terminalAttention(.httpClientError(
                statusCode: statusCode,
                detail: detail,
                journalReasonCode: journalReasonCode
            ))
        }

        if 500..<600 ~= statusCode {
            // Each key is unique within its stream, so a journal that removed this segment had
            // received it. The phone still holding it only means its receipt was lost.
            if endpointPhase == .observerIngest,
               let response = try? JSONDecoder().decode(ObserverIngestResponse.self, from: result.data),
               response.reasonCode == "segment_removed"
            {
                return .terminalSuccess(.removedInJournal)
            }
            return .transientRetry(.httpServerError(statusCode: statusCode))
        }

        return .transientRetry(.transport("unexpected http \(statusCode)"))
    }

    private static func classifyObserverIngestSuccess(statusCode: Int, data: Data) -> TransferOutcome {
        guard !data.isEmpty,
              let response = try? JSONDecoder().decode(ObserverIngestResponse.self, from: data)
        else {
            return .terminalAttention(.decodeFailed("invalid ingest response"))
        }

        switch response.status {
        case "ok", "duplicate", "collision":
            return .terminalSuccess(.delivered(serverPath: nil, serverTimestamp: nil))
        case "failed", "conflict":
            let detail: String
            if let reasonCode = response.reasonCode, !reasonCode.isEmpty {
                detail = "reason_code=\(reasonCode)"
            } else {
                detail = "ingest status \(response.status) without reason_code"
            }
            return .terminalAttention(.httpClientError(
                statusCode: statusCode,
                detail: detail,
                journalReasonCode: Self.storedJournalReasonCode(response.reasonCode)
            ))
        default:
            return .terminalAttention(.decodeFailed("unknown ingest status \(response.status)"))
        }
    }

    private static func classifySaveSuccess(data: Data) -> TransferOutcome {
        guard let response = try? JSONDecoder().decode(SaveResponse.self, from: data) else {
            return .terminalAttention(.decodeFailed("invalid save response"))
        }

        // The old background-session path guarded against a `client_item_id` echo mismatch in the SAVE response and failed the item terminally (ImportQueue.swift:1101-1105). That guard is intentionally not carried over: `client_item_id` is the server's idempotency key, so a mismatched echo cannot cause a duplicate import, and the local re-check only ever converted a benign server quirk into owner-visible failure.
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

}
