import Foundation

nonisolated
enum ChatSendDecision {
    static func isReturnSend(old: String, new: String, shiftJustInserted: inout Bool) -> Bool {
        if shiftJustInserted {
            shiftJustInserted = false
            return false
        }
        return new.count == old.count + 1 && new.hasPrefix(old) && new.last == "\n"
    }

    static func canSend(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
