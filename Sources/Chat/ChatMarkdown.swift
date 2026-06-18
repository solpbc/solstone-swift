import Foundation

nonisolated enum ChatMarkdown {
    static func attributedString(from text: String) -> AttributedString? {
        let sanitized = self.stripSolCitations(from: text).text
        guard var attributed = try? AttributedString(markdown: sanitized) else { return nil }
        self.removeSolLinks(from: &attributed)
        return attributed
    }

    static func stripSolCitations(from text: String) -> (text: String, sources: [AnswerProvenance.ProvenanceSource]) {
        let pattern = #"\[([^\]]+)\]\((sol://[^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (text, [])
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return (text, []) }

        var rewritten = text
        var sources: [AnswerProvenance.ProvenanceSource] = []
        var seenRefs = Set<String>()

        for match in matches.reversed() {
            let label = nsText.substring(with: match.range(at: 1))
            let ref = nsText.substring(with: match.range(at: 2))
            if !seenRefs.contains(ref) {
                seenRefs.insert(ref)
                sources.insert(AnswerProvenance.ProvenanceSource(ref: ref, label: label), at: 0)
            }
            if let range = Range(match.range, in: rewritten) {
                rewritten.replaceSubrange(range, with: label)
            }
        }

        return (rewritten, sources)
    }

    private static func removeSolLinks(from attributed: inout AttributedString) {
        for run in attributed.runs {
            if run.link?.scheme?.lowercased() == "sol" {
                attributed[run.range].link = nil
            }
        }
    }
}
