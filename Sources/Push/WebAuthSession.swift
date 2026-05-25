// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AuthenticationServices
import UIKit

@MainActor
protocol WebAuthSessionStarting: AnyObject {
    func start(
        url: URL,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    ) throws
}

enum WebAuthSessionError: Error, Equatable, Sendable {
    case failedToStart
}

@MainActor
final class ASWebAuthSessionWrapper: NSObject, WebAuthSessionStarting {
    private var session: ASWebAuthenticationSession?

    func start(
        url: URL,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    ) throws {
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: "solstone-noop"
        ) { _, error in
            Task { @MainActor [weak self] in
                self?.session = nil
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(()))
                }
            }
        }
        session.prefersEphemeralWebBrowserSession = false
        session.presentationContextProvider = self
        guard session.start() else {
            throw WebAuthSessionError.failedToStart
        }
        self.session = session
    }
}

extension ASWebAuthSessionWrapper: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }?
                .windows
                .first { $0.isKeyWindow }
                ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }?
                .windows
                .first
                ?? ASPresentationAnchor()
        }
    }
}
