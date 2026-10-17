// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SwiftParser
import SwiftSyntax

// The parser is the toolchain's Apache-2.0 SwiftSyntax, not a textual census.
final class Scan: SyntaxVisitor {
    let file: String
    var rows: [[String: Any]] = []
    init(_ file: String) { self.file = file; super.init(viewMode: .sourceAccurate) }
    func context(_ node: some SyntaxProtocol) -> String {
        var p = node.parent
        while let current = p {
            if let f = current.as(FunctionDeclSyntax.self) { return f.name.text }
            if let v = current.as(VariableDeclSyntax.self), let b = v.bindings.first {
                return b.pattern.trimmedDescription
            }
            p = current.parent
        }
        return "<top>"
    }
    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        rows.append(["kind": "literal", "file": file, "declaration": context(node),
                     "start": node.positionAfterSkippingLeadingTrivia.utf8Offset,
                     "end": node.endPositionBeforeTrailingTrivia.utf8Offset,
                     "source": node.trimmedDescription,
                     "segments": node.segments.count])
        return .visitChildren
    }
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        rows.append(["kind": "member", "file": file, "declaration": context(node),
                     "start": node.positionAfterSkippingLeadingTrivia.utf8Offset,
                     "end": node.endPositionBeforeTrailingTrivia.utf8Offset,
                     "base": node.base?.trimmedDescription ?? "",
                     "name": node.declName.baseName.text,
                     "parent": node.parent.map { String(describing: $0.kind) } ?? ""])
        return .visitChildren
    }
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        if node.parent?.is(MemberAccessExprSyntax.self) == true { return .visitChildren }
        rows.append(["kind":"reference", "file":file, "declaration":context(node),
                     "name":node.baseName.text, "start":node.positionAfterSkippingLeadingTrivia.utf8Offset,
                     "end":node.endPositionBeforeTrailingTrivia.utf8Offset,
                     "parent":node.parent.map { String(describing:$0.kind) } ?? ""])
        return .visitChildren
    }
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.calledExpression.trimmedDescription
        if name.hasPrefix("XCTAssert") || name == "Text" || name.hasPrefix("SourceVocabulary.") || name.hasPrefix("Self.") {
            rows.append(["kind": "call", "file": file, "declaration": context(node),
                         "start": node.positionAfterSkippingLeadingTrivia.utf8Offset,
                         "end": node.endPositionBeforeTrailingTrivia.utf8Offset,
                         "callee": name, "source": node.trimmedDescription])
        }
        return .visitChildren
    }
}

var rows: [[String: Any]] = []
for file in CommandLine.arguments.dropFirst() {
    let tree = Parser.parse(source: try String(contentsOfFile: file, encoding: .utf8))
    guard !tree.hasError else { fatalError("parse error: \(file)") }
    let scan = Scan(file); scan.walk(tree); rows += scan.rows
}
let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
