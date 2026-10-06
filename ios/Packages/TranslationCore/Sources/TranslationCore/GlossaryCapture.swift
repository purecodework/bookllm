import Foundation

/// An optional private trailer rides the initial translation response. It never
/// enters the reader, exported text, or later editing drafts.
public enum GlossaryCapture {
    public static let start = "<bookllm-glossary-v1>"
    public static let end = "</bookllm-glossary-v1>"
    public static let instruction = "After the complete translation, append a PRIVATE metadata trailer: <bookllm-glossary-v1>[JSON entries]</bookllm-glossary-v1>. At most 12 newly observed recurring names/terms missing from the supplied glossary; [] is valid. Each entry follows: " + GlossaryQuery.contract.replacingOccurrences(of: "Return ONLY a JSON array", with: "The trailer JSON is an array") + " Every target must appear verbatim in your translation, every evidence quote must occur in the source. The trailer is bookkeeping, not an editorial note or source content. Never insert it within the translation or omit text to make room."
    public static func text(_ raw: String) -> String {
        guard let marker = raw.range(of: start, options: .backwards) else { return raw }
        return String(raw[..<marker.lowerBound]).trimmingCharacters(in: .newlines)
    }
    public static func partial(_ raw: String) -> String {
        if let marker = raw.range(of: start) { return String(raw[..<marker.lowerBound]).trimmingCharacters(in: .newlines) }
        // Hide a marker even when it arrives across SSE delta boundaries.
        for length in stride(from: min(start.count - 1, raw.count), through: 1, by: -1) {
            if raw.hasSuffix(String(start.prefix(length))) { return String(raw.dropLast(length)) }
        }
        return raw
    }
    public static func proposals(_ raw: String) -> [Term] {
        guard raw.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(end),
              let opening = raw.range(of: start, options: .backwards),
              let closing = raw.range(of: end, options: .backwards), opening.upperBound <= closing.lowerBound else { return [] }
        let payload = String(raw[opening.upperBound..<closing.lowerBound])
        guard payload.utf8.count <= 12_000, let terms = try? JSONDecoder().decode([Term].self, from: Data(payload.utf8)), terms.count <= 12 else { return [] }
        return terms
    }
}
