// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SPLTunnel
import SwiftUI

struct ManualCodeEntryView: View {
    private enum ManualCodeError: Error {
        case invalidFormat
        case network
        case codeExpired
        case codeInvalid
    }

    private struct CodeRequest: Encodable {
        let code: String
    }

    private struct CodeResponse: Decodable {
        let url: String?
        let link: String?
        let universalLink: String?

        enum CodingKeys: String, CodingKey {
            case url
            case link
            case universalLink = "universal_link"
        }

        var linkString: String? {
            url ?? link ?? universalLink
        }
    }

    let onPairURL: @MainActor (PairURL) -> Void

    @State private var code = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("pairing code", text: self.$code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .textContentType(.oneTimeCode)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .onChange(of: self.code) { _, newValue in
                    self.code = Self.formatted(newValue)
                }

            Button(self.isSubmitting ? "checking…" : "pair with code") {
                Task {
                    await self.submit()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(self.isSubmitting || !Self.isValid(self.code))
            .frame(maxWidth: .infinity, minHeight: 44)

            if let errorMessage {
                Text(errorMessage)
                    .font(.body)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Pairing error: \(errorMessage)")
            }
        }
    }

    private func submit() async {
        guard Self.isValid(self.code) else {
            self.errorMessage = Self.message(for: .invalidFormat)
            return
        }

        self.isSubmitting = true
        defer { self.isSubmitting = false }

        do {
            guard let pairURL = try await self.lookup(code: self.code) else { return }
            self.errorMessage = nil
            self.onPairURL(pairURL)
        } catch let error as ManualCodeError {
            self.errorMessage = Self.message(for: error)
        } catch {
            self.errorMessage = Self.message(for: .network)
        }
    }

    private func lookup(code: String) async throws -> PairURL? {
        let url = try Self.endpointURL()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(CodeRequest(code: code))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ManualCodeError.network
        }

        switch http.statusCode {
        case 200..<300:
            let decoded = try JSONDecoder().decode(CodeResponse.self, from: data)
            guard let link = decoded.linkString,
                  let url = URL(string: link),
                  let result = UniversalLinkRouter.route(url) else {
                throw ManualCodeError.network
            }
            switch result {
            case .success(let pairURL):
                return pairURL
            case .failure(let error):
                self.errorMessage = PairFlowCoordinator.message(for: error)
                return nil
            }
        case 410:
            throw ManualCodeError.codeExpired
        case 400, 401, 404:
            throw ManualCodeError.codeInvalid
        default:
            throw ManualCodeError.network
        }
    }

    private static func endpointURL() throws -> URL {
        guard let url = URL(string: "/app/link/by-code", relativeTo: SPLPairingConstants.relayEndpoint)?.absoluteURL else {
            throw ManualCodeError.network
        }
        return url
    }

    private static func formatted(_ value: String) -> String {
        String(value.uppercased().filter { isAllowed($0) }.prefix(8))
    }

    private static func isValid(_ value: String) -> Bool {
        value.count == 8 && value.allSatisfy(isAllowed)
    }

    private static func isAllowed(_ character: Character) -> Bool {
        "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains(character)
    }

    private static func message(for error: ManualCodeError) -> String {
        switch error {
        case .invalidFormat:
            "enter the 8-character pairing code."
        case .network:
            "network error while pairing."
        case .codeExpired:
            "this pairing code has expired."
        case .codeInvalid:
            "this pairing code is invalid."
        }
    }
}
