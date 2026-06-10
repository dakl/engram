import Foundation
import NaturalLanguage

/// Produces fixed-size sentence embeddings entirely on-device (ADR 0012).
///
/// Prefers `NLContextualEmbedding` — Apple's transformer-based contextual model
/// (macOS 14+) — mean-pooling its per-token vectors into one sentence vector.
/// Its assets download on demand; until they're present this falls back to the
/// older static `NLEmbedding`, kicking off the download for next launch. The
/// chosen backend (and thus the vector dimension) is fixed for the instance's
/// lifetime, so a run never mixes models or dimensions.
public final class Embedder {
    private enum Backend {
        case contextual(NLContextualEmbedding)
        case word(NLEmbedding)
    }

    private let backend: Backend
    private let language: NLLanguage

    /// The vector length this embedder produces — the live model's dimension,
    /// not a compile-time constant.
    public let dimension: Int

    /// Identifies the backend + dimension so the store can detect a change and
    /// re-embed (e.g. `"contextual-512"` or `"word-512"`).
    public let signature: String

    /// True when the contextual model's assets weren't available and this fell
    /// back to the weaker static `NLEmbedding` — recall is degraded for the
    /// instance's lifetime. Lets the app surface "running on degraded embeddings".
    public let isFallback: Bool

    public enum EmbedderError: Error {
        case unavailable(NLLanguage)
    }

    public init(language: NLLanguage = .english) throws {
        self.language = language

        // Prefer the contextual model when its assets are already on device.
        if let contextual = NLContextualEmbedding(language: language) {
            do {
                try contextual.load()
                self.backend = .contextual(contextual)
                self.dimension = contextual.dimension
                self.signature = "contextual-\(contextual.dimension)"
                self.isFallback = false
                return
            } catch {
                // Assets not downloaded yet — fetch them for next launch, fall back now.
                contextual.requestAssets { _, _ in }
            }
        }

        guard let word = NLEmbedding.sentenceEmbedding(for: language) else {
            throw EmbedderError.unavailable(language)
        }
        self.backend = .word(word)
        self.dimension = 512
        self.signature = "word-512"
        self.isFallback = true
    }

    /// Returns a `dimension`-length float vector for the given text. Empty or
    /// unembeddable input yields a zero vector rather than throwing, so storing
    /// whitespace-only content never crashes a hook.
    public func vector(for text: String) throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return zeros }

        switch backend {
        case let .word(model):
            guard let doubles = model.vector(for: trimmed) else { return zeros }
            return doubles.map(Float.init)
        case let .contextual(model):
            return try meanPooled(trimmed, model: model)
        }
    }

    /// Mean-pools the contextual model's per-token vectors into one sentence vector.
    private func meanPooled(_ text: String, model: NLContextualEmbedding) throws -> [Float] {
        let result = try model.embeddingResult(for: text, language: language)
        var sum = [Double](repeating: 0, count: dimension)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            for index in 0..<min(dimension, vector.count) { sum[index] += vector[index] }
            count += 1
            return true
        }
        guard count > 0 else { return zeros }
        return sum.map { Float($0 / Double(count)) }
    }

    private var zeros: [Float] { [Float](repeating: 0, count: dimension) }
}
