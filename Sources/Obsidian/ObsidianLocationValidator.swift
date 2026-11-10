// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import UIKit

nonisolated enum ObsidianLocationRefusal: Error, Equatable, Sendable {
    case unsupportedLocation(sentence: String)
    case invalidFolder(sentence: String)
    case invalidName(sentence: String)

    var sentence: String {
        switch self {
        case .unsupportedLocation(let s), .invalidFolder(let s), .invalidName(let s):
            return s
        }
    }
}

nonisolated struct ObsidianLocationResources: Sendable {
    var isDirectory: Bool?
    var isUbiquitousItem: Bool?
    var volumeIsLocal: Bool?
    var canonicalPath: String?
    var isSymbolicLink: Bool?
    var isObsidianPresent: Bool = true
    var isObsidianDirectory: Bool = true
    var isObsidianSymbolicLink: Bool = false
}

nonisolated enum ObsidianLocationValidator {
    /// Validates a picked vault folder URL.
    /// Checks resource keys, Documents location classification, .obsidian configuration, and usable vault name.
    static func validate(
        url: URL,
        resources: ObsidianLocationResources? = nil,
        isPad: Bool
    ) -> Result<Void, ObsidianLocationRefusal> {
        let name = url.lastPathComponent
        guard ObsidianWire.isUsableVaultName(name) else {
            return .failure(.invalidName(sentence: ObsidianVocabulary.REFUSED_INVALID_NAME))
        }

        let res: ObsidianLocationResources
        if let resources {
            res = resources
        } else {
            guard let read = readProductionResources(for: url) else {
                return .failure(.unsupportedLocation(sentence: ObsidianVocabulary.unsupportedLocationSentence(isPad: isPad)))
            }
            res = read
        }

        // Location classification check
        guard res.isDirectory == true,
              res.isUbiquitousItem == false,
              res.volumeIsLocal == true,
              let canonicalPath = res.canonicalPath,
              isDocumentsClass(canonicalPath: canonicalPath)
        else {
            return .failure(.unsupportedLocation(sentence: ObsidianVocabulary.unsupportedLocationSentence(isPad: isPad)))
        }

        // Folder structure check: root not symlink, .obsidian present, directory, and not symlink
        if res.isSymbolicLink == true {
            return .failure(.invalidFolder(sentence: ObsidianVocabulary.REFUSED_INVALID_FOLDER))
        }
        if !res.isObsidianPresent || !res.isObsidianDirectory || res.isObsidianSymbolicLink {
            return .failure(.invalidFolder(sentence: ObsidianVocabulary.REFUSED_INVALID_FOLDER))
        }

        return .success(())
    }

    @MainActor
    static func validate(
        url: URL,
        resources: ObsidianLocationResources? = nil
    ) -> Result<Void, ObsidianLocationRefusal> {
        self.validate(
            url: url,
            resources: resources,
            isPad: UIDevice.current.userInterfaceIdiom == .pad
        )
    }

    /// Verifies canonicalPath contains the sequence: "Application", one segment, "Documents",
    /// with the picked folder equal to that Documents directory or a descendant.
    static func isDocumentsClass(canonicalPath: String) -> Bool {
        // Disallow known third-party / non-local provider prefixes explicitly if present
        let lower = canonicalPath.lowercased()
        if lower.contains("file provider storage") || lower.contains("livefiles") || lower.contains("mobile documents") {
            return false
        }

        var components = canonicalPath.split(separator: "/").map(String.init)
        if components.first == "private" { components.removeFirst() }
        let prefix = ["var", "mobile", "Containers", "Data", "Application"]
        guard components.starts(with: prefix) else { return false }
        let appIndex = prefix.count - 1
        guard appIndex + 2 < components.count else {
            return false
        }
        guard components[appIndex + 2] == "Documents" else {
            return false
        }
        // Picked folder must be Documents or a descendant (appIndex + 2 is Documents, components.count >= appIndex + 3)
        return components.count >= appIndex + 3
    }

    private static func readProductionResources(for url: URL) -> ObsidianLocationResources? {
        do {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isUbiquitousItemKey,
                .volumeIsLocalKey,
                .canonicalPathKey,
                .isSymbolicLinkKey
            ])
            guard let isDir = values.isDirectory,
                  let isUbiq = values.isUbiquitousItem,
                  let isLocal = values.volumeIsLocal,
                  let canon = values.canonicalPath
            else {
                return nil
            }

            let isSymlink = values.isSymbolicLink ?? checkIsSymlink(path: url.path)

            let obsidianURL = url.appendingPathComponent(".obsidian")
            let fm = FileManager.default
            var isObsDir: ObjCBool = false
            let obsExists = fm.fileExists(atPath: obsidianURL.path, isDirectory: &isObsDir)
            let obsSymlink = checkIsSymlink(path: obsidianURL.path)

            return ObsidianLocationResources(
                isDirectory: isDir,
                isUbiquitousItem: isUbiq,
                volumeIsLocal: isLocal,
                canonicalPath: canon,
                isSymbolicLink: isSymlink,
                isObsidianPresent: obsExists,
                isObsidianDirectory: isObsDir.boolValue,
                isObsidianSymbolicLink: obsSymlink
            )
        } catch {
            return nil
        }
    }

    private static func checkIsSymlink(path: String) -> Bool {
        var statBuf = stat()
        if lstat(path, &statBuf) == 0 {
            return (statBuf.st_mode & S_IFMT) == S_IFLNK
        }
        return false
    }
}
