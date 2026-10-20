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

    private struct CatalogData: Sendable {
        let signatures: [String: MessageSignature]
        let sourceLocale: String?
    }

    private static let catalog: CatalogData = Self.loadCatalog()

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

    private static func loadCatalog() -> CatalogData {
        guard let irData = Data(base64Encoded: PushCatalogContract.irBase64),
              let historyData = Data(base64Encoded: PushCatalogContract.historyBase64)
        else {
            log.error("unreadable push catalog contract")
            return CatalogData(signatures: [:], sourceLocale: nil)
        }

        do {
            let histObj = try JSONSerialization.jsonObject(with: historyData)
            guard let histDict = histObj as? [String: Any],
                  let records = histDict["records"] as? [[String: Any]]
            else {
                log.error("unreadable push catalog contract")
                return CatalogData(signatures: [:], sourceLocale: nil)
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
                return CatalogData(signatures: [:], sourceLocale: nil)
            }

            let sourceLocale = irDict["source_locale"] as? String

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
            return CatalogData(signatures: sigs, sourceLocale: sourceLocale)
        } catch {
            log.error("unreadable push catalog contract")
            return CatalogData(signatures: [:], sourceLocale: nil)
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

    private static func resolveLprojBundles(
        in bundle: Bundle,
        for locale: Locale
    ) -> (candidateTables: [ResolvedTable], packagedTables: [ResolvedTable]) {
        var candidateTables: [ResolvedTable] = []
        var seenCandidatePaths = Set<String>()
        for name in self.candidateLprojNames(for: locale) {
            if let path = bundle.path(forResource: name, ofType: "lproj"),
               !seenCandidatePaths.contains(path),
               let b = Bundle(path: path) {
                seenCandidatePaths.insert(path)
                candidateTables.append(ResolvedTable(bundle: b, formatLocale: locale))
            }
        }

        var packagedFolderNames: [String] = []
        if let devLoc = bundle.developmentLocalization, devLoc != "Base", !devLoc.isEmpty {
            packagedFolderNames.append(devLoc)
        }
        if let sourceLoc = self.catalog.sourceLocale, !sourceLoc.isEmpty {
            for name in self.candidateLprojNames(for: Locale(identifier: sourceLoc)) {
                if !packagedFolderNames.contains(name) {
                    packagedFolderNames.append(name)
                }
            }
        }

        var packagedTables: [ResolvedTable] = []
        var seenPackagedPaths = Set<String>()
        for name in packagedFolderNames {
            if let path = bundle.path(forResource: name, ofType: "lproj"),
               !seenPackagedPaths.contains(path),
               let b = Bundle(path: path) {
                seenPackagedPaths.insert(path)
                packagedTables.append(ResolvedTable(bundle: b, formatLocale: Locale(identifier: name)))
            }
        }

        return (candidateTables, packagedTables)
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
              let signature = self.catalog.signatures[messageId]
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

        let (candidateTables, packagedTables) = self.resolveLprojBundles(in: bundle, for: locale)
        let sentinel = "\u{0000}__PUSH_SENTINEL__\u{0000}"
        var formatPattern: String? = nil
        var formatLocale: Locale = locale

        for candidate in candidateTables {
            let val = candidate.bundle.localizedString(forKey: resourceKey, value: sentinel, table: "PushMessages")
            if val != sentinel {
                formatPattern = val
                formatLocale = candidate.formatLocale
                break
            }
        }

        if formatPattern == nil {
            for packaged in packagedTables {
                let val = packaged.bundle.localizedString(forKey: resourceKey, value: sentinel, table: "PushMessages")
                if val != sentinel {
                    formatPattern = val
                    formatLocale = packaged.formatLocale
                    break
                }
            }
        }

        guard let pattern = formatPattern else {
            return fallbackEn
        }

        return String(format: pattern, locale: formatLocale, arguments: formatArgs)
    }
}
