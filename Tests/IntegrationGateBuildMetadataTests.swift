// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

// criterion 10: build metadata uses real generated values.
@MainActor
final class IntegrationGateBuildMetadataTests: XCTestCase {
    func testAppVersionReportsResolvedSPLSwiftMetadata() throws {
        let resolved = try Self.resolvedSPLSwift()
        let head = try Self.gitHead()
        XCTAssertEqual(AppVersion.splSwiftIdentity, "spl-swift")
        XCTAssertEqual(AppVersion.splSwiftVersion, resolved.version)
        XCTAssertEqual(AppVersion.splSwiftRevision, resolved.revision)
        XCTAssertEqual(AppVersion.sourceCommit, head)
        XCTAssertFalse(AppVersion.buildConfiguration.isEmpty)
        XCTAssertNotEqual(AppVersion.sourceCommit, "unknown", "source commit metadata must be generated from git rev-parse HEAD")
        XCTAssertNotEqual(AppVersion.buildConfiguration, "unknown", "build configuration metadata must come from the generated xcconfig")
        XCTAssertNotEqual(AppVersion.splSwiftVersion, "unknown", "spl-swift version metadata must come from Package.resolved")
        XCTAssertNotEqual(AppVersion.splSwiftRevision, "unknown", "spl-swift revision metadata must come from Package.resolved")
    }

    private static func resolvedSPLSwift() throws -> (version: String, revision: String) {
        let url = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("solstone-swift.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let pins = try XCTUnwrap(object?["pins"] as? [[String: Any]])
        let pin = try XCTUnwrap(pins.first { $0["identity"] as? String == "spl-swift" })
        let state = try XCTUnwrap(pin["state"] as? [String: Any])
        return (
            try XCTUnwrap(state["version"] as? String),
            try XCTUnwrap(state["revision"] as? String)
        )
    }

    private static func gitHead() throws -> String {
        let root = StringLiteralGrepSupport.worktreeRoot()
        let gitURL = try Self.gitDirectoryURL(root: root)
        let head = try Self.trimmedContents(of: gitURL.appendingPathComponent("HEAD"))
        guard head.hasPrefix("ref: ") else {
            return head
        }
        let refPath = String(head.dropFirst("ref: ".count))
        let localRef = gitURL.appendingPathComponent(refPath)
        if let commit = try? Self.trimmedContents(of: localRef) {
            return commit
        }
        let commonURL = try Self.commonGitDirectoryURL(gitURL: gitURL)
        return try Self.trimmedContents(of: commonURL.appendingPathComponent(refPath))
    }

    private static func gitDirectoryURL(root: URL) throws -> URL {
        let dotGit = root.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return dotGit
        }
        let content = try Self.trimmedContents(of: dotGit)
        let prefix = "gitdir: "
        guard content.hasPrefix(prefix) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let path = String(content.dropFirst(prefix.count))
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return root.appendingPathComponent(path, isDirectory: true)
    }

    private static func commonGitDirectoryURL(gitURL: URL) throws -> URL {
        let commonDirURL = gitURL.appendingPathComponent("commondir")
        guard let value = try? Self.trimmedContents(of: commonDirURL) else {
            return gitURL
        }
        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return gitURL.appendingPathComponent(value, isDirectory: true)
    }

    private static func trimmedContents(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
