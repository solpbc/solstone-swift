// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AuthenticationServices
import Foundation
import os
import Security
import UIKit
import WebKit

/// The journal's external-service OAuth broker contract (version 2), packaged alongside
/// `import-host-contract.json`.
nonisolated struct JournalAuthHostContract: Decodable, Equatable, Sendable {
    let version: Int
    let capability: String
    let prepare: String
    let prepared: String
    let authorize: String
    let cancel: String
    let result: String
    let unsupported: String

    static func load(bundle: Bundle = Bundle(for: AppDelegate.self)) -> (contract: Self, json: String)? {
        guard let url = bundle.url(forResource: "auth-host-contract", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let contract = try? JSONDecoder().decode(Self.self, from: data),
              contract.version == 2,
              !contract.capability.isEmpty,
              !contract.prepare.isEmpty,
              !contract.prepared.isEmpty,
              !contract.authorize.isEmpty,
              !contract.cancel.isEmpty,
              !contract.result.isEmpty,
              !contract.unsupported.isEmpty,
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return (contract, json.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Exact allowlisted custom-scheme callback targets supported by the iOS / iPadOS app.
nonisolated enum JournalAuthCustomSchemeTarget: String, Equatable, Sendable, CaseIterable {
    case solstoneOAuth = "solstone://oauth/callback"
    case appSolstone = "app.solstone:/callback"

    var scheme: String {
        switch self {
        case .solstoneOAuth: return "solstone"
        case .appSolstone: return "app.solstone"
        }
    }

    var expectedHost: String? {
        switch self {
        case .solstoneOAuth: return "oauth"
        case .appSolstone: return nil
        }
    }

    var expectedPath: String { "/callback" }
}

nonisolated enum JournalAuthPreference: Equatable, Sendable {
    case loopback(host: String, path: String, port: UInt16)
    case customScheme(uri: String)
    case other(mode: String)
}

nonisolated enum JournalAuthSessionFailure: Equatable, Sendable {
    case cancelled
    case refused(reason: String)
    case error(reason: String)
}

@MainActor
protocol JournalAuthSessionHandle: AnyObject {
    func cancel()
}

/// Runs one OS-managed browser authentication session (`ASWebAuthenticationSession` in production).
/// `onCallback` returns `true` only when the returned URL passes exact scheme + host + path,
/// duplicate-key, and constant-time state verification; returning `false` leaves the session
/// unconsumed if another callback can still arrive.
@MainActor
protocol JournalAuthSessionRunning: AnyObject {
    func start(
        url: URL,
        callbackScheme: String,
        anchorProvider: @escaping @MainActor () -> ASPresentationAnchor?,
        onCallback: @escaping @MainActor (URL) -> Bool,
        onClosed: @escaping @MainActor (JournalAuthSessionFailure) -> Void
    ) -> (any JournalAuthSessionHandle)?
}

@MainActor
private final class WindowPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchorProvider: @MainActor () -> ASPresentationAnchor?

    init(anchorProvider: @escaping @MainActor () -> ASPresentationAnchor?) {
        self.anchorProvider = anchorProvider
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let anchor = self.anchorProvider() {
            return anchor
        }
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene,
               windowScene.activationState == .foregroundActive,
               let keyWindow = windowScene.windows.first(where: \.isKeyWindow) ?? windowScene.windows.first {
                return keyWindow
            }
        }
        return ASPresentationAnchor()
    }
}

@MainActor
private final class LiveAuthSessionHandle: JournalAuthSessionHandle {
    private var session: ASWebAuthenticationSession?
    private var contextProvider: WindowPresentationContextProvider?

    init(session: ASWebAuthenticationSession, contextProvider: WindowPresentationContextProvider) {
        self.session = session
        self.contextProvider = contextProvider
    }

    func cancel() {
        self.session?.cancel()
        self.session = nil
        self.contextProvider = nil
    }
}

@MainActor
final class LiveJournalAuthSessionRunner: JournalAuthSessionRunning {
    func start(
        url: URL,
        callbackScheme: String,
        anchorProvider: @escaping @MainActor () -> ASPresentationAnchor?,
        onCallback: @escaping @MainActor (URL) -> Bool,
        onClosed: @escaping @MainActor (JournalAuthSessionFailure) -> Void
    ) -> (any JournalAuthSessionHandle)? {
        let contextProvider = WindowPresentationContextProvider(anchorProvider: anchorProvider)
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: callbackScheme
        ) { @Sendable callbackURL, error in
            let isCanceled: Bool = {
                guard let nsError = error as NSError? else { return false }
                return nsError.domain == ASWebAuthenticationSessionError.errorDomain
                    && nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
            }()
            let hasError = error != nil
            Task { @MainActor in
                if let callbackURL {
                    if !onCallback(callbackURL) {
                        onClosed(.refused(reason: "callback_mismatch"))
                    }
                    return
                }
                if isCanceled {
                    onClosed(.cancelled)
                } else if hasError {
                    onClosed(.error(reason: "auth_session_failed"))
                } else {
                    onClosed(.cancelled)
                }
            }
        }
        // Keep Safari cookies and passkeys available for sign-in.
        session.prefersEphemeralWebBrowserSession = false
        session.presentationContextProvider = contextProvider
        guard session.start() else {
            return nil
        }
        return LiveAuthSessionHandle(session: session, contextProvider: contextProvider)
    }
}

nonisolated struct JournalAuthValidationError: Error, Equatable, Sendable {
    let reason: String
}

/// Pure validation helpers for the iOS / iPadOS OAuth broker. Never logs callback URLs.
nonisolated enum JournalAuthValidation {
    static let maxIDLength = 128
    static let maxPreferences = 16
    static let maxPathBytes = 256
    static let maxAuthorizeURLBytes = 8192
    static let maxStateBytes = 1024
    static let minTimeoutSeconds: TimeInterval = 1
    static let maxTimeoutSeconds: TimeInterval = 600
    static let defaultTimeoutSeconds: TimeInterval = 600

    static func validID(_ raw: Any?) -> String? {
        guard let id = raw as? String, !id.isEmpty, id.utf8.count <= self.maxIDLength else { return nil }
        return id
    }

    static func isOAuthCallbackURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "app.solstone" {
            return true
        }
        return scheme == "solstone" && url.host?.lowercased() == "oauth"
    }

    static func parsePreferences(_ raw: Any?) -> Result<[JournalAuthPreference], JournalAuthValidationError> {
        guard let list = raw as? [Any], !list.isEmpty, list.count <= self.maxPreferences else {
            return .failure(JournalAuthValidationError(reason: "invalid_preferences"))
        }
        var parsed: [JournalAuthPreference] = []
        parsed.reserveCapacity(list.count)
        for item in list {
            guard let object = item as? [String: Any],
                  let mode = object["mode"] as? String, !mode.isEmpty
            else {
                return .failure(JournalAuthValidationError(reason: "invalid_preferences"))
            }
            switch mode {
            case "loopback":
                guard let host = object["host"] as? String,
                      host == "127.0.0.1" || host == "localhost"
                else {
                    return .failure(JournalAuthValidationError(reason: "invalid_loopback_host"))
                }
                guard let path = object["path"] as? String, self.isValidLoopbackPath(path) else {
                    return .failure(JournalAuthValidationError(reason: "invalid_loopback_path"))
                }
                let port: UInt16
                switch object["port"] {
                case nil, is NSNull:
                    port = 0
                case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
                    let doubleVal = number.doubleValue
                    guard doubleVal.isFinite, doubleVal.rounded(.towardZero) == doubleVal else {
                        return .failure(JournalAuthValidationError(reason: "invalid_loopback_port"))
                    }
                    let intVal = number.int64Value
                    if intVal == 0 {
                        port = 0
                    } else if (1024...65535).contains(intVal) {
                        port = UInt16(intVal)
                    } else {
                        return .failure(JournalAuthValidationError(reason: "invalid_loopback_port"))
                    }
                default:
                    return .failure(JournalAuthValidationError(reason: "invalid_loopback_port"))
                }
                parsed.append(.loopback(host: host, path: path, port: port))
            case "custom_scheme":
                guard let uri = object["uri"] as? String, !uri.isEmpty else {
                    return .failure(JournalAuthValidationError(reason: "invalid_custom_scheme"))
                }
                parsed.append(.customScheme(uri: uri))
            default:
                parsed.append(.other(mode: mode))
            }
        }
        return .success(parsed)
    }

    static func isValidLoopbackPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"),
              path.utf8.count >= 1,
              path.utf8.count <= self.maxPathBytes,
              !path.contains("?"),
              !path.contains("#"),
              !path.contains("..")
        else { return false }
        return path.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }

    static func validateAuthorizeURL(_ raw: Any?) -> URL? {
        guard let text = raw as? String,
              !text.isEmpty,
              text.utf8.count <= self.maxAuthorizeURLBytes
        else { return nil }
        for scalar in text.unicodeScalars {
            if scalar.value <= 0x20 || scalar.value == 0x7F || scalar.properties.isWhitespace {
                return nil
            }
        }
        guard text.prefix(8).lowercased() == "https://" else { return nil }
        let afterScheme = text.dropFirst(8)
        let authorityEnd = afterScheme.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? afterScheme.endIndex
        let authority = afterScheme[..<authorityEnd]
        guard !authority.isEmpty, !authority.contains("@") else { return nil }
        guard let components = URLComponents(string: text),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host, !host.isEmpty,
              let url = components.url
        else { return nil }
        return url
    }

    static func validateExpectedState(_ raw: Any?) -> String? {
        guard let state = raw as? String,
              !state.isEmpty,
              state.utf8.count <= self.maxStateBytes,
              state.utf8.allSatisfy({ (0x21...0x7E).contains($0) })
        else { return nil }
        return state
    }

    static func parseTimeoutSeconds(_ raw: Any?) -> Result<TimeInterval, JournalAuthValidationError> {
        switch raw {
        case nil, is NSNull:
            return .success(self.defaultTimeoutSeconds)
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            let value = number.doubleValue
            guard value.isFinite else { return .failure(JournalAuthValidationError(reason: "invalid_timeout")) }
            return .success(min(max(value, self.minTimeoutSeconds), self.maxTimeoutSeconds))
        default:
            return .failure(JournalAuthValidationError(reason: "invalid_timeout"))
        }
    }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }

    static func percentDecode(_ value: String) -> String? {
        let bytes = Array(value.utf8)
        var decoded: [UInt8] = []
        decoded.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte == 0x2B {
                decoded.append(0x20)
                i += 1
            } else if byte == 0x25 {
                guard i + 2 < bytes.count,
                      let hi = self.hexNibble(bytes[i + 1]),
                      let lo = self.hexNibble(bytes[i + 2])
                else { return nil }
                decoded.append((hi << 4) | lo)
                i += 3
            } else {
                decoded.append(byte)
                i += 1
            }
        }
        return String(bytes: decoded, encoding: .utf8)
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    static func parseQueryRefusingDuplicates(_ query: String) -> [String: String]? {
        var params: [String: String] = [:]
        for rawPair in query.split(separator: "&", omittingEmptySubsequences: false) {
            if rawPair.isEmpty { continue }
            let keyPart: Substring
            let valuePart: Substring
            if let eq = rawPair.firstIndex(of: "=") {
                keyPart = rawPair[..<eq]
                valuePart = rawPair[rawPair.index(after: eq)...]
            } else {
                keyPart = rawPair
                valuePart = ""
            }
            guard let key = self.percentDecode(String(keyPart)),
                  let value = self.percentDecode(String(valuePart))
            else { return nil }
            if params[key] != nil {
                return nil
            }
            params[key] = value
        }
        return params
    }

    /// Validates an OAuth callback URL returned to iOS / iPadOS against the exact prepared
    /// scheme + host + path, duplicate-query-key prohibition, and constant-time state match.
    static func validateCallbackURL(
        _ url: URL,
        expectedTarget: JournalAuthCustomSchemeTarget,
        expectedState: String
    ) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == expectedTarget.scheme,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.percentEncodedPath == expectedTarget.expectedPath
        else { return nil }

        switch expectedTarget {
        case .solstoneOAuth:
            guard components.host?.lowercased() == "oauth" else { return nil }
        case .appSolstone:
            guard (components.host ?? "").isEmpty else { return nil }
            // Also ensure authority did not carry a non-empty host or double-slash ambiguity.
            let raw = url.absoluteString
            if raw.lowercased().hasPrefix("app.solstone://") {
                return nil
            }
        }

        guard let rawQuery = components.percentEncodedQuery, !rawQuery.isEmpty,
              let params = self.parseQueryRefusingDuplicates(rawQuery),
              let state = params["state"],
              self.constantTimeEqual(state, expectedState),
              params["code"] != nil || params["error"] != nil
        else { return nil }

        return url.absoluteString
    }

    static func randomSessionID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            for i in bytes.indices {
                bytes[i] = UInt8.random(in: 0...255, using: &rng)
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Manages the single active OAuth custom-scheme brokerage session for an iOS / iPadOS journal
/// web view. Keeps the open `WKWebView` alive while `ASWebAuthenticationSession` runs, holds zero
/// tokens or PKCE verifiers, and never logs `callback_url`.
@MainActor
final class JournalAuthHost {
    let contract: JournalAuthHostContract
    let contractJSON: String
    private let runner: any JournalAuthSessionRunning
    private let anchorProvider: @MainActor () -> ASPresentationAnchor?

    private struct ActiveSession {
        let sessionID: String
        let target: JournalAuthCustomSchemeTarget
        var authorizingID: String?
        var expectedState: String?
        var handle: (any JournalAuthSessionHandle)?
        var continuation: CheckedContinuation<[String: Any], Never>?
        var timerTask: Task<Void, Never>?
    }

    private var active: ActiveSession?

    init(
        contract: JournalAuthHostContract,
        contractJSON: String,
        runner: any JournalAuthSessionRunning = LiveJournalAuthSessionRunner(),
        anchorProvider: @escaping @MainActor () -> ASPresentationAnchor? = { nil }
    ) {
        self.contract = contract
        self.contractJSON = contractJSON
        self.runner = runner
        self.anchorProvider = anchorProvider
    }

    func handles(type: String) -> Bool {
        type == self.contract.prepare || type == self.contract.authorize || type == self.contract.cancel
    }

    func handle(_ message: [String: Any], type: String) async -> [String: Any] {
        switch type {
        case self.contract.prepare:
            return self.prepare(message)
        case self.contract.authorize:
            return await self.authorize(message)
        case self.contract.cancel:
            return self.cancel(message)
        default:
            var reply: [String: Any] = ["type": self.contract.unsupported]
            if let id = message["id"] as? String { reply["id"] = id }
            return reply
        }
    }

    func tearDown() {
        self.settleActive(outcome: "cancelled")
    }

    private func prepare(_ message: [String: Any]) -> [String: Any] {
        guard let id = JournalAuthValidation.validID(message["id"]) else {
            return ["type": self.contract.unsupported]
        }
        func reply(_ outcome: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            var body: [String: Any] = ["type": self.contract.prepared, "id": id, "outcome": outcome]
            for (k, v) in extra { body[k] = v }
            return body
        }

        let preferences: [JournalAuthPreference]
        switch JournalAuthValidation.parsePreferences(message["preferences"]) {
        case .success(let parsed):
            preferences = parsed
        case .failure(let error):
            return reply("refused", ["reason": error.reason])
        }

        // Tear down any prior idle or in-flight session first so an earlier auth.authorize
        // Promise settles cleanly as `cancelled`.
        self.settleActive(outcome: "cancelled")

        for pref in preferences {
            guard case .customScheme(let uri) = pref,
                  let target = JournalAuthCustomSchemeTarget(rawValue: uri)
            else {
                continue
            }
            let sessionID = JournalAuthValidation.randomSessionID()
            let timerTask = self.startTimer(
                sessionID: sessionID,
                seconds: JournalAuthValidation.defaultTimeoutSeconds,
                isAuthorizing: false
            )
            self.active = ActiveSession(
                sessionID: sessionID,
                target: target,
                authorizingID: nil,
                expectedState: nil,
                handle: nil,
                continuation: nil,
                timerTask: timerTask
            )
            journalWebLog.notice("auth-host: prepared custom_scheme session")
            return reply("ready", [
                "session_id": sessionID,
                "mode": "custom_scheme",
                "redirect_uri": target.rawValue,
            ])
        }

        return reply("no_compatible_mode")
    }

    private func authorize(_ message: [String: Any]) async -> [String: Any] {
        guard let id = JournalAuthValidation.validID(message["id"]) else {
            return ["type": self.contract.unsupported]
        }
        func result(_ outcome: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            var body: [String: Any] = ["type": self.contract.result, "id": id, "outcome": outcome]
            for (k, v) in extra { body[k] = v }
            return body
        }

        guard let sessionID = message["session_id"] as? String, !sessionID.isEmpty else {
            return result("refused", ["reason": "invalid_session"])
        }
        guard let authorizeURL = JournalAuthValidation.validateAuthorizeURL(message["authorize_url"]) else {
            return result("refused", ["reason": "invalid_authorize_url"])
        }
        guard let expectedState = JournalAuthValidation.validateExpectedState(message["expected_state"]) else {
            return result("refused", ["reason": "invalid_state"])
        }
        let timeoutSeconds: TimeInterval
        switch JournalAuthValidation.parseTimeoutSeconds(message["timeout_seconds"]) {
        case .success(let value):
            timeoutSeconds = value
        case .failure(let error):
            return result("refused", ["reason": error.reason])
        }

        guard let current = self.active, current.sessionID == sessionID, current.authorizingID == nil else {
            return result("refused", ["reason": "invalid_session"])
        }

        let target = current.target
        current.timerTask?.cancel()
        self.active?.authorizingID = id
        self.active?.expectedState = expectedState
        self.active?.timerTask = self.startTimer(sessionID: sessionID, seconds: timeoutSeconds, isAuthorizing: true)

        return await withCheckedContinuation { continuation in
            self.active?.continuation = continuation
            let handle = self.runner.start(
                url: authorizeURL,
                callbackScheme: target.scheme,
                anchorProvider: self.anchorProvider,
                onCallback: { [weak self] callbackURL in
                    self?.deliverCallback(sessionID: sessionID, callbackURL: callbackURL) ?? false
                },
                onClosed: { [weak self] failure in
                    switch failure {
                    case .cancelled:
                        self?.settleIfMatching(sessionID: sessionID, outcome: "cancelled")
                    case .refused(let reason):
                        self?.settleIfMatching(sessionID: sessionID, outcome: "refused", reason: reason)
                    case .error(let reason):
                        self?.settleIfMatching(sessionID: sessionID, outcome: "error", reason: reason)
                    }
                }
            )
            if let handle {
                if self.active?.sessionID == sessionID {
                    self.active?.handle = handle
                } else {
                    handle.cancel()
                }
            } else {
                journalWebLog.notice("auth-host: auth session start failed")
                self.settleIfMatching(sessionID: sessionID, outcome: "error", reason: "session_start_failed")
            }
        }
    }

    private func cancel(_ message: [String: Any]) -> [String: Any] {
        guard let id = JournalAuthValidation.validID(message["id"]) else {
            return ["type": self.contract.unsupported]
        }
        let requestedSessionID = message["session_id"] as? String
        if let current = self.active {
            if requestedSessionID == nil || requestedSessionID?.isEmpty == true || current.sessionID == requestedSessionID {
                self.settleActive(outcome: "cancelled")
            }
        }
        return ["type": self.contract.result, "id": id, "outcome": "cancelled"]
    }

    /// Returns `true` if the callback matched and consumed the session; `false` if rejected so a
    /// stray or wrong-state delivery never consumes the active session.
    private func deliverCallback(sessionID: String, callbackURL: URL) -> Bool {
        guard let current = self.active,
              current.sessionID == sessionID,
              let authorizeID = current.authorizingID,
              let expectedState = current.expectedState,
              let validated = JournalAuthValidation.validateCallbackURL(
                  callbackURL,
                  expectedTarget: current.target,
                  expectedState: expectedState
              )
        else {
            return false
        }
        self.active = nil
        current.timerTask?.cancel()
        current.handle?.cancel()
        journalWebLog.notice("auth-host: callback delivered outcome=callback")
        current.continuation?.resume(returning: [
            "type": self.contract.result,
            "id": authorizeID,
            "outcome": "callback",
            "callback_url": validated,
        ])
        return true
    }

    private func startTimer(sessionID: String, seconds: TimeInterval, isAuthorizing: Bool) -> Task<Void, Never> {
        let clampedNanos = UInt64(max(0.01, seconds) * 1_000_000_000)
        return Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: clampedNanos)
            } catch {
                return
            }
            guard let self else { return }
            if isAuthorizing {
                journalWebLog.notice("auth-host: session timed out")
                self.settleIfMatching(sessionID: sessionID, outcome: "timeout")
            } else {
                self.settleIfMatching(sessionID: sessionID, outcome: "cancelled")
            }
        }
    }

    private func settleIfMatching(sessionID: String, outcome: String, reason: String? = nil) {
        guard self.active?.sessionID == sessionID else { return }
        self.settleActive(outcome: outcome, reason: reason)
    }

    private func settleActive(outcome: String, reason: String? = nil) {
        guard let current = self.active else { return }
        self.active = nil
        current.timerTask?.cancel()
        current.handle?.cancel()
        if let authorizeID = current.authorizingID, let continuation = current.continuation {
            var body: [String: Any] = [
                "type": self.contract.result,
                "id": authorizeID,
                "outcome": outcome,
            ]
            if let reason { body["reason"] = reason }
            continuation.resume(returning: body)
        }
    }
}
