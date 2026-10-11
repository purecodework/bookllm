import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

public struct GlossaryCandidate: Sendable {
    public let source: String
    public let context: String
    public let chunk: Int
    public let priority: Int
}
public enum GlossaryCandidates {
    private static let ordinary = Set("the a an this that these those he she it they we you i his her its their my our your and but or then when where what why how after before once first last next chapter part book act scene introduction abstract conclusion morning evening today tomorrow yesterday however therefore finally meanwhile yes no thank thanks please well here there only also all every some any one two three four five six seven eight nine ten monday tuesday wednesday thursday friday saturday sunday january february april june july august september october november december der die das ein eine und aber les le la un une des et mais el los las una uno y pero il lo gli une ce cette je tu nous vous sie wir ich du он она они мы вы это что но и как нет да если вдруг потом теперь тогда только еще здесь там каждый было был была".split(separator: " ").map(String.init))
    public static func find(in chunk: TextChunk, kind: DocumentKind) -> [GlossaryCandidate] {
        let source = chunk.text
        var ranges: [Range<String.Index>] = []
        var tagged = Set<String>()
        #if canImport(NaturalLanguage)
        let tagger = NLTagger(tagSchemes: [.nameType]); tagger.string = source
        tagger.enumerateTags(in: source.startIndex..<source.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .personalName || tag == .placeName || tag == .organizationName { ranges.append(range); tagged.insert(String(source[range]).lowercased()) }
            return true
        }
        #endif
        let patterns = [
            #"\b[\p{Lu}][\p{L}\p{M}’'-]{1,}(?:[ \t]+(?:[\p{Lu}][\p{L}\p{M}’'-]{1,}|of|de|van|von)){0,3}\b"#,
            #"[\p{Han}]{1,4}(?:先生|女士|小姐|博士|教授|さん|様|氏|君)"#,
            #"[\p{Han}]{2,8}(?:庄园|城堡|大学|公司|株式会社|市|郡|省|岛|港)"#,
            #"[\p{Hangul}]{2,8}(?:대학교|회사|시|군)"#
        ] + (kind == .technical || kind == .academic ? [#"\*\*([^*\n]{2,80})\*\*"#, #"[\p{L}][\p{L} -]{1,60}(?=\s*[:：])"#] : [])
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let capture = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                if let range = Range(capture, in: source) { ranges.append(range) }
            }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var seen = Set<String>(), result: [GlossaryCandidate] = []
        for originalRange in ranges {
            var range = originalRange
            // Remove sentence starters without dropping the name that follows.
            let words = source[range].split(whereSeparator: { $0.isWhitespace })
            if let first = words.first, words.count > 1, ordinary.contains(first.lowercased()) {
                let start = source.index(range.lowerBound, offsetBy: first.count)
                var trimmed = start
                while trimmed < range.upperBound && source[trimmed].isWhitespace { trimmed = source.index(after: trimmed) }
                range = trimmed..<range.upperBound
            }
            let name = String(source[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count <= 100, !ordinary.contains(name.lowercased()), seen.insert(GlossaryMemory.fold(name)).inserted else { continue }
            let lower = source.index(range.lowerBound, offsetBy: -75, limitedBy: source.startIndex) ?? source.startIndex
            let upper = source.index(range.upperBound, offsetBy: 75, limitedBy: source.endIndex) ?? source.endIndex
            result.append(.init(source: name, context: String(source[lower..<upper]), chunk: chunk.index, priority: tagged.contains(name.lowercased()) ? 0 : 1))
        }
        return result
    }
}
