// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

nonisolated private let log = Logger(subsystem: "app.solstone.swift", category: "push-presentation")

nonisolated enum PushPresentation {
    private enum MessageSignature: Sendable {
        case noArgs
        case cardinal(argName: String, min: Int64, max: Int64)
        case enumString(argName: String)
    }

    private struct ResolvedTable {
        let bundle: Bundle
        let formatLocale: Locale
    }

    private static let signatures: [String: MessageSignature] = Self.loadSignatures()

    private static func asExactInt64(_ value: Any?) -> Int64? {
        guard let value else { return nil }
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
            return nil
        }
        let doubleVal = number.doubleValue
        guard doubleVal.isFinite, !doubleVal.isNaN else { return nil }
        guard doubleVal.rounded(.towardZero) == doubleVal else { return nil }
        guard doubleVal >= Double(Int64.min), doubleVal <= Double(Int64.max) else { return nil }
        return number.int64Value
    }

    private static func loadSignatures() -> [String: MessageSignature] {
        guard let irData = Data(base64Encoded: PushCatalogContract.irBase64),
              let historyData = Data(base64Encoded: PushCatalogContract.historyBase64)
        else {
            log.error("unreadable push catalog contract")
            return [:]
        }

        do {
            let histObj = try JSONSerialization.jsonObject(with: historyData)
            guard let histDict = histObj as? [String: Any],
                  let records = histDict["records"] as? [[String: Any]]
            else {
                log.error("unreadable push catalog contract")
                return [:]
            }

            var tombstones = Set<String>()
            for rec in records {
                if let id = rec["id"] as? String,
                   let isTombstone = rec["tombstone"] as? Bool,
                   isTombstone {
                    tombstones.insert(id)
                }
            }

            let irObj = try JSONSerialization.jsonObject(with: irData)
            guard let irDict = irObj as? [String: Any],
                  let messages = irDict["messages"] as? [[String: Any]]
            else {
                log.error("unreadable push catalog contract")
                return [:]
            }

            var sigs: [String: MessageSignature] = [:]
            for msg in messages {
                guard let id = msg["id"] as? String else { continue }
                if tombstones.contains(id) { continue }

                let argsList = msg["arguments"] as? [[String: Any]] ?? []
                let selector = msg["selector"] as? [String: Any]

                if argsList.isEmpty && selector == nil {
                    sigs[id] = .noArgs
                } else if argsList.count == 1 {
                    let arg = argsList[0]
                    guard let argName = arg["name"] as? String,
                          let argType = arg["type"] as? String
                    else { continue }

                    if argType == "cardinal" {
                        let numStyle = arg["numeric_style"] as? String
                        guard numStyle == "ungrouped" else { continue }
                        guard let minVal = asExactInt64(arg["min"]),
                              let maxVal = asExactInt64(arg["max"])
                        else { continue }
                        sigs[id] = .cardinal(argName: argName, min: minVal, max: maxVal)
                    } else if argType == "string" {
                        guard let sel = selector,
                              let selType = sel["type"] as? String,
                              selType == "string"
                        else { continue }
                        sigs[id] = .enumString(argName: argName)
                    }
                }
            }
            return sigs
        } catch {
            log.error("unreadable push catalog contract")
            return [:]
        }
    }

    private static func candidateLprojNames(for locale: Locale) -> [String] {
        var names: [String] = []
        let bcp47 = locale.identifier(.bcp47)
        if !bcp47.isEmpty && !names.contains(bcp47) {
            names.append(bcp47)
        }
        let ident = locale.identifier
        if !ident.isEmpty && !names.contains(ident) {
            names.append(ident)
        }
        if let langCode = locale.language.languageCode?.identifier, !langCode.isEmpty, !names.contains(langCode) {
            names.append(langCode)
        }
        return names
    }

    private static func resolveLprojBundles(in bundle: Bundle, for locale: Locale) -> (candidate: ResolvedTable?, packaged: ResolvedTable?) {
        var packagedTable: ResolvedTable? = nil
        if let devLoc = bundle.developmentLocalization,
           devLoc != "Base",
           let path = bundle.path(forResource: devLoc, ofType: "lproj"),
           let b = Bundle(path: path) {
            packagedTable = ResolvedTable(bundle: b, formatLocale: Locale(identifier: devLoc))
        }
        if packagedTable == nil {
            for loc in bundle.localizations where loc != "Base" {
                if let path = bundle.path(forResource: loc, ofType: "lproj"),
                   let b = Bundle(path: path) {
                    packagedTable = ResolvedTable(bundle: b, formatLocale: Locale(identifier: loc))
                    break
                }
            }
        }

        var candidateTable: ResolvedTable? = nil
        for name in self.candidateLprojNames(for: locale) {
            if let path = bundle.path(forResource: name, ofType: "lproj"),
               let b = Bundle(path: path) {
                candidateTable = ResolvedTable(bundle: b, formatLocale: locale)
                break
            }
        }

        return (candidateTable, packagedTable)
    }

    static func render(
        entry: Any?,
        legacy: String,
        locale: Locale,
        bundle: Bundle
    ) -> String {
        guard let dict = entry as? [String: Any] else {
            return legacy
        }

        guard let fallbackEn = dict["fallback_en"] as? String else {
            return legacy
        }

        guard let v = self.asExactInt64(dict["v"]), v == 1,
              let epoch = self.asExactInt64(dict["catalog_epoch"]), epoch == 1,
              let messageId = dict["code"] as? String,
              let signature = self.signatures[messageId]
        else {
            return fallbackEn
        }

        let argsRaw = dict["args"]
        let resourceKey: String
        let formatArgs: [CVarArg]

        switch signature {
        case .noArgs:
            guard let argsDict = argsRaw as? [String: Any], argsDict.isEmpty else {
                return fallbackEn
            }
            resourceKey = CatalogSelect.resolveKey(messageId: messageId, enumArg: nil)
            formatArgs = []

        case .cardinal(let argName, let minVal, let maxVal):
            guard let argsDict = argsRaw as? [String: Any],
                  argsDict.count == 1,
                  let argVal = argsDict[argName],
                  let quantity = self.asExactInt64(argVal),
                  quantity >= minVal,
                  quantity <= maxVal
            else {
                return fallbackEn
            }
            resourceKey = CatalogSelect.resolveKey(messageId: messageId, enumArg: nil)
            formatArgs = [quantity, CatalogSelect.formatIntegerUngrouped(quantity)]

        case .enumString(let argName):
            guard let argsDict = argsRaw as? [String: Any],
                  argsDict.count == 1,
                  let argVal = argsDict[argName],
                  let enumStr = argVal as? String
            else {
                return fallbackEn
            }
            resourceKey = CatalogSelect.resolveKey(messageId: messageId, enumArg: enumStr)
            formatArgs = []
        }

        let (candidateTable, packagedTable) = self.resolveLprojBundles(in: bundle, for: locale)
        let sentinel = "\u{0000}__PUSH_SENTINEL__\u{0000}"
        var formatPattern: String? = nil
        var formatLocale: Locale = locale

        if let candidate = candidateTable {
            let val = candidate.bundle.localizedString(forKey: resourceKey, value: sentinel, table: "PushMessages")
            if val != sentinel {
                formatPattern = val
                formatLocale = candidate.formatLocale
            }
        }

        if formatPattern == nil, let packaged = packagedTable, packaged.bundle.bundlePath != candidateTable?.bundle.bundlePath {
            let val = packaged.bundle.localizedString(forKey: resourceKey, value: sentinel, table: "PushMessages")
            if val != sentinel {
                formatPattern = val
                formatLocale = packaged.formatLocale
            }
        }

        guard let pattern = formatPattern else {
            return fallbackEn
        }

        return String(format: pattern, locale: formatLocale, arguments: formatArgs)
    }
}
