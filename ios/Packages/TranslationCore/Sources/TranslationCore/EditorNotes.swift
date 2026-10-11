import Foundation

/// Source-keyed annotations make first occurrence independent of concurrent completion order.
/// Stored drafts retain their keys so subsequent review passes cannot reset book-wide identity.
public enum EditorNotes {
    private struct Note: Decodable { var source: String; var text: String }
    public struct Scope: Sendable {
        private let source: String
        private let ranges: [Int: Range<String.Index>]
        public init(source: String, chunks: [TextChunk]) {
            self.source = source
            var position = source.startIndex
            var owned: [Int: Range<String.Index>] = [:]
            for chunk in chunks {
                guard let range = source.range(of: chunk.text, range: position..<source.endIndex) else { continue }
                owned[chunk.index] = range; position = range.upperBound
            }
            ranges = owned
        }
        public func filter(_ text: String, index: Int, display: Bool = false) -> String {
            EditorNotes.filter(text, source: source, owned: ranges[index], display: display)
        }
    }
    public static func filter(_ text: String, source: String, chunks: [TextChunk], index: Int, display: Bool = false) -> String {
        guard text.contains("⟦编者注:") else { return text }
        return Scope(source: source, chunks: chunks).filter(text, index: index, display: display)
    }
    private static func filter(_ text: String, source: String, owned: Range<String.Index>?, display: Bool) -> String {
        guard text.contains("⟦编者注:"), let regex = try? NSRegularExpression(pattern: "⟦编者注:(\\{[^⟧]*\\})⟧") else { return text }
        let body = text as NSString
        var result = text
        var seen = Set<String>()
        var replacements: [(NSRange, String)] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: body.length)) {
            let json = body.substring(with: match.range(at: 1))
            let prefix = body.substring(to: match.range.location)
            // Preserve all literal code, including strings resembling annotation markers.
            if insideCode(prefix) { continue }
            var replacement = ""
            if let data = json.data(using: .utf8), let note = try? JSONDecoder().decode(Note.self, from: data),
               !note.source.isEmpty, !note.text.isEmpty, note.source.count <= 200, note.text.count <= 800,
               let first = source.range(of: note.source, options: [.caseInsensitive]), let owned,
               owned.contains(first.lowerBound), first.upperBound <= owned.upperBound,
               seen.insert(note.source.lowercased()).inserted {
                replacement = display ? "[编者注：\(note.text)]" : body.substring(with: match.range)
            }
            replacements.append((match.range, replacement))
        }
        for (range, replacement) in replacements.reversed() {
            if let swiftRange = Range(range, in: result) { result.replaceSubrange(swiftRange, with: replacement) }
        }
        return result
    }
    public static func display(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "⟦编者注:(\\{[^⟧]*\\})⟧") else { return text }
        let body = text as NSString
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: body.length)).reversed() {
            if insideCode(body.substring(to: match.range.location)) { continue }
            let json = body.substring(with: match.range(at: 1))
            if let data = json.data(using: .utf8), let note = try? JSONDecoder().decode(Note.self, from: data), let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: "[编者注：\(note.text)]")
            }
        }
        if let start = result.range(of: "⟦编者注:", options: .backwards), !result[start.lowerBound...].contains("⟧"), !insideCode(String(result[..<start.lowerBound])) {
            result.removeSubrange(start.lowerBound...)
        }
        return result
    }
    private static func insideCode(_ prefix: String) -> Bool {
        var active: (Character, Int)?
        let lines = prefix.components(separatedBy: "\n")
        for line in lines {
            let value = line.trimmingCharacters(in: .whitespaces)
            guard let marker = value.first, marker == "`" || marker == "~" else { continue }
            let length = value.prefix { $0 == marker }.count
            guard length >= 3 else { continue }
            if let fence = active {
                if marker == fence.0 && length >= fence.1 && value.dropFirst(length).trimmingCharacters(in: .whitespaces).isEmpty { active = nil }
            } else { active = (marker, length) }
        }
        if active != nil { return true }
        return (lines.last?.filter { $0 == "`" }.count ?? 0) % 2 == 1
    }
}
