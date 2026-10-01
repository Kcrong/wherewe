import Foundation

enum NativeTranscriptNoise {
    private static let tokens = Set([
        "i", "uh", "um", "umm", "mm", "mmm", "hmm", "ah", "oh", "eh", "huh",
        "하", "어", "음", "흠", "아",
    ])

    static func isLikelyNoise(_ transcript: String) -> Bool {
        let lowercased = transcript.lowercased()
        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        let words = lowercased.unicodeScalars.split { separators.contains($0) }
            .map { String(String.UnicodeScalarView($0)) }
        guard !words.isEmpty else { return true }
        if words.count == 1, words[0].count == 1 { return true }
        if words.count == 1, tokens.contains(words[0]) { return true }
        return false
    }
}
