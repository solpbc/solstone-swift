// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum JournalRequestLocale {
    static let headerName = "X-Solstone-Locale"
    static let english = "en-US"

    /// Returns the app's selected catalog language tag when it is not English,
    /// or `nil` in English so nothing new is sent.
    static func headerValue(for language: String = AppStrings.language) -> String? {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.caseInsensitiveCompare(Self.english) != .orderedSame,
              trimmed.caseInsensitiveCompare("en") != .orderedSame,
              trimmed.utf8.allSatisfy({ $0 != 0x0D && $0 != 0x0A })
        else {
            return nil
        }
        return trimmed
    }

    /// Document-start script that attaches `X-Solstone-Locale` to same-origin
    /// `fetch` and `XMLHttpRequest` calls targeting `origin` only. Returns `nil`
    /// in English so nothing is injected.
    static func fetchLocaleScript(
        origin: String,
        language: String = AppStrings.language
    ) -> String? {
        guard let tag = Self.headerValue(for: language),
              let originJSON = Self.jsonStringLiteral(origin),
              let tagJSON = Self.jsonStringLiteral(tag)
        else {
            return nil
        }
        return """
        (function () {
          var expectedOrigin = new URL(\(originJSON)).origin;
          var localeTag = \(tagJSON);
          var headerName = 'X-Solstone-Locale';
          function isPairedOrigin(input) {
            try {
              var raw = (typeof Request !== 'undefined' && input instanceof Request) ? input.url : String(input);
              return new URL(raw, window.location.href).origin === expectedOrigin;
            } catch (_) {
              return false;
            }
          }
          if (typeof window.fetch === 'function') {
            var nativeFetch = window.fetch.bind(window);
            window.fetch = function (input, init) {
              if (isPairedOrigin(input)) {
                var baseHeaders = (init && init.headers !== undefined)
                  ? init.headers
                  : ((typeof Request !== 'undefined' && input instanceof Request) ? input.headers : undefined);
                var headers = new Headers(baseHeaders);
                headers.set(headerName, localeTag);
                var nextInit = init ? Object.assign({}, init, { headers: headers }) : { headers: headers };
                return nativeFetch(input, nextInit);
              }
              return nativeFetch(input, init);
            };
          }
          if (typeof XMLHttpRequest !== 'undefined' && XMLHttpRequest.prototype) {
            var origOpen = XMLHttpRequest.prototype.open;
            var origSend = XMLHttpRequest.prototype.send;
            var origSetHeader = XMLHttpRequest.prototype.setRequestHeader;
            XMLHttpRequest.prototype.open = function (method, url) {
              this.__solPairedOrigin = isPairedOrigin(url);
              this.__solLocaleSet = false;
              return origOpen.apply(this, arguments);
            };
            XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
              if (typeof name === 'string' && name.toLowerCase() === 'x-solstone-locale') {
                this.__solLocaleSet = true;
              }
              return origSetHeader.apply(this, arguments);
            };
            XMLHttpRequest.prototype.send = function () {
              if (this.__solPairedOrigin && !this.__solLocaleSet) {
                try { origSetHeader.call(this, headerName, localeTag); } catch (_) {}
              }
              return origSend.apply(this, arguments);
            };
          }
        })();
        """
    }

    private static func jsonStringLiteral(_ value: String) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

nonisolated extension URLRequest {
    /// Attaches `X-Solstone-Locale` when the app's catalog language is not
    /// English and this request targets the paired journal's loopback proxy.
    mutating func attachJournalLocale(language: String = AppStrings.language) {
        guard self.url?.host == "127.0.0.1",
              let tag = JournalRequestLocale.headerValue(for: language)
        else { return }
        self.setValue(tag, forHTTPHeaderField: JournalRequestLocale.headerName)
    }

    /// Attaches `X-Solstone-Locale` when the app's catalog language is not
    /// English and this request targets `liveAuthority`.
    mutating func attachJournalLocale(
        matching liveAuthority: JournalWebNavigationPolicy.Authority?,
        language: String = AppStrings.language
    ) {
        guard JournalWebNavigationPolicy.hostPortMatches(requestURL: self.url, liveAuthority: liveAuthority),
              let tag = JournalRequestLocale.headerValue(for: language)
        else { return }
        self.setValue(tag, forHTTPHeaderField: JournalRequestLocale.headerName)
    }
}
