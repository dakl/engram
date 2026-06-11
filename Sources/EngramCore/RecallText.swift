import Foundation

/// Tokenization shared by lexical retrieval (`MemoryStore.ftsMatchExpression`)
/// and the recall gate (`RecallGate`). Keeping one tokenizer means the gate's
/// "how many query tokens does this memory share" signal stays aligned with the
/// FTS5 keyword stage that produced the lexical candidates in the first place.
public enum RecallText {
    /// Common English words that would otherwise cause spurious lexical matches
    /// (e.g. "the" matching nearly every memory).
    public static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "for", "with",
        "as", "at", "by", "from", "is", "are", "was", "were", "be", "been", "being",
        "do", "does", "did", "doing", "what", "which", "who", "whom", "whose", "how",
        "why", "when", "where", "this", "that", "these", "those", "it", "its", "we",
        "you", "your", "our", "my", "me", "i", "they", "them", "their", "he", "she",
        "his", "her", "if", "then", "than", "so", "about", "into", "over", "can",
        "could", "should", "would", "will", "have", "has", "had", "not", "no",
    ]

    /// Splits text into lowercased alphanumeric tokens, dropping stopwords. Single
    /// character tokens are kept (only stopwords like "a"/"i" are dropped) so a
    /// one-letter identifier still carries a lexical signal.
    public static func tokens(_ text: String) -> [String] {
        text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty && !stopwords.contains($0) }
    }

    /// Count of distinct query tokens that also appear in `text`. This is the
    /// strength of the lexical overlap — 1 means a single shared keyword (often a
    /// coincidence), higher means the prompt and memory genuinely share vocabulary.
    public static func lexicalTokenHits(query: String, in text: String) -> Int {
        let queryTokens = Set(tokens(query))
        guard !queryTokens.isEmpty else { return 0 }
        return queryTokens.intersection(Set(tokens(text))).count
    }
}
