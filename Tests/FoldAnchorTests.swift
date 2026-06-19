@testable import solstone_swift
import XCTest

nonisolated final class FoldAnchorTests: XCTestCase {
    @MainActor
    func testAnchorsWhenOriginUserMessageExists() {
        let user = ChatMessage(role: .user, text: "what changed?", useID: "turn-1")
        let other = ChatMessage(role: .user, text: "other", useID: "turn-2")

        let placement = FoldAnchor.resolve(
            origin: ChatSolOrigin(logicalUseID: "turn-1", ask: "what changed?"),
            messages: [other, user]
        )

        XCTAssertEqual(placement, .anchored(toMessageID: user.id))
    }

    @MainActor
    func testInlineAskWhenAnchorIsMissing() {
        let placement = FoldAnchor.resolve(
            origin: ChatSolOrigin(logicalUseID: "turn-1", ask: "what changed?"),
            messages: []
        )

        XCTAssertEqual(placement, .inlineAsk("what changed?"))
    }

    @MainActor
    func testInlineFallbackWhenAnchorAndAskAreMissing() {
        let placement = FoldAnchor.resolve(
            origin: ChatSolOrigin(logicalUseID: "turn-1"),
            messages: []
        )

        XCTAssertEqual(placement, .inlineAsk(SourceVocabulary.chatFoldOriginalQuestionUnavailable))
    }
}
