import Foundation

public enum DocumentKind: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case fiction, general, technical, poetry, script, academic
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .fiction: "小说"
        case .general: "通用文档"
        case .technical: "技术文档"
        case .poetry: "诗集"
        case .script: "剧本"
        case .academic: "论文"
        }
    }
    /// Leave room for a longer translation, glossary, and later editorial passes.
    public var defaultBudget: Double {
        switch self {
        case .fiction: 1800
        case .general, .academic: 1400
        case .technical: 1100
        case .poetry: 900
        case .script: 1300
        }
    }
}

public enum LayoutPolicy: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case preserve, reading
    public var id: String { rawValue }
    public var title: String { switch self { case .preserve: "保留排版"; case .reading: "阅读排版" } }
}

public struct DocumentSection: Codable, Sendable, Hashable, Identifiable {
    public var index: Int
    public var title: String
    public var text: String
    public var id: Int { index }
    public init(index: Int, title: String, text: String) { self.index = index; self.title = title; self.text = text }
}

public struct ChunkPlan: Codable, Sendable, Equatable {
    public var sections: [DocumentSection]
    public var chunks: [TextChunk]
    /// The section index for every chunk, in the same order as `chunks`.
    public var sectionForChunk: [Int]
    public init(sections: [DocumentSection], chunks: [TextChunk], sectionForChunk: [Int]) {
        self.sections = sections; self.chunks = chunks; self.sectionForChunk = sectionForChunk
    }
}

public enum Chunker {
    /// Conservative Unicode-aware estimate. Exact provider token counts vary.
    public static func tokenCost(_ character: Character) -> Double {
        character.unicodeScalars.contains { $0.value > 0x2FF } ? 1.5 : 0.32
    }
    public static func split(_ text: String, budget: Double = 1800) -> [TextChunk] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return makeChunks(splitRaw(text, budget: safeBudget(budget)))
    }

    /// Follow chapters, poems, scenes, or document headings. Keep fitting stanzas,
    /// speaker turns, citations, code fences, and Markdown tables together.
    /// Neither section detection nor chunking inserts, trims, or normalizes source text.
    public static func plan(text: String, kind: DocumentKind, budget: Double? = nil) -> ChunkPlan {
        let limit = safeBudget(budget ?? kind.defaultBudget)
        let sections = makeSections(text, kind: kind)
        var pieces: [String] = [], sectionForChunk: [Int] = []
        for section in sections {
            let sectionPieces = pack(blocks(in: section.text, kind: kind), budget: limit)
            pieces.append(contentsOf: sectionPieces)
            sectionForChunk.append(contentsOf: repeatElement(section.index, count: sectionPieces.count))
        }
        return ChunkPlan(sections: sections, chunks: makeChunks(pieces), sectionForChunk: sectionForChunk)
    }
    public static func points(source: String, quality: Quality, glossary: Bool) -> Int {
        let chunks = split(source)
        let translation = chunks.reduce(0) { $0 + max(1, Int(ceil(Double($1.text.unicodeScalars.count) / 1000))) * quality.stages.count }
        return translation + (glossary && !chunks.isEmpty ? max(1, Int(ceil(Double(source.prefix(12000).unicodeScalars.count) / 1000))) : 0)
    }

    private struct Fence {
        let character: Character
        let length: Int
    }
    private struct Block {
        let text: String
        let protected: Bool
    }

    private static func safeBudget(_ value: Double) -> Double { value.isFinite ? max(64, value) : 1800 }
    private static func cost(_ text: String) -> Double { text.reduce(0) { $0 + tokenCost($1) } }
    private static func makeChunks(_ pieces: [String]) -> [TextChunk] {
        pieces.enumerated().map { TextChunk(index: $0.offset, text: $0.element, context: $0.offset == 0 ? "" : String(pieces[$0.offset - 1].suffix(350))) }
    }

    private static func splitRaw(_ text: String, budget: Double, sentences: Bool = true) -> [String] {
        var pieces: [String] = [], buffer: [Character] = [], used = 0.0
        var boundary: Int?
        for character in text {
            let next = tokenCost(character)
            // A very early punctuation boundary can leave almost an entire chunk
            // behind. Check again before adding the next character in that case.
            while used + next > budget, !buffer.isEmpty {
                let end = boundary ?? buffer.count
                pieces.append(String(buffer.prefix(end)))
                buffer = Array(buffer.dropFirst(end))
                used = buffer.reduce(0) { $0 + tokenCost($1) }
                boundary = nil
            }
            buffer.append(character); used += next
            if character.isNewline || (sentences && "。！？.!?".contains(character)) { boundary = buffer.count }
        }
        if !buffer.isEmpty { pieces.append(String(buffer)) }
        return pieces
    }

    /// Read lines using String indices so CRLF, combining characters, and emoji
    /// stay byte-for-byte identical when the resulting lines are joined.
    private static func lines(in text: String) -> [String] {
        var result: [String] = [], start = text.startIndex, cursor = start
        while cursor < text.endIndex {
            let next = text.index(after: cursor)
            if text[cursor].isNewline { result.append(String(text[start..<next])); start = next }
            cursor = next
        }
        if start < text.endIndex { result.append(String(text[start...])) }
        return result
    }

    private static func content(_ line: String) -> String { line.trimmingCharacters(in: .newlines) }
    private static func isBlank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private static func fence(in line: String, closing existing: Fence? = nil) -> Fence? {
        let raw = content(line)
        let indent = raw.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let body = raw.dropFirst(indent)
        guard let marker = body.first, marker == "`" || marker == "~" else { return nil }
        let count = body.prefix { $0 == marker }.count
        guard count >= 3 else { return nil }
        let tail = body.dropFirst(count)
        if let existing {
            guard marker == existing.character, count >= existing.length,
                  tail.allSatisfy({ $0.isWhitespace }) else { return nil }
        } else if marker == "`", tail.contains("`") { return nil }
        return Fence(character: marker, length: count)
    }

    private static func heading(in line: String, kind: DocumentKind) -> String? {
        let raw = content(line)
        // Four-space and tab-indented lines belong to Markdown code blocks.
        guard raw.prefix(while: { $0 == " " }).count <= 3, raw.first != "\t" else { return nil }
        if let range = raw.range(of: #"^ {0,3}#{1,6}(?:[ \t]+|$)"#, options: .regularExpression) {
            let title = String(raw[range.upperBound...])
                .replacingOccurrences(of: #"[ \t]+#+[ \t]*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? "未命名章节" : title
        }
        let title = raw.trimmingCharacters(in: .whitespaces)
        let number = "[零〇一二三四五六七八九十百千万两壹贰叁肆伍陆柒捌玖拾佰仟0-9０-９]+"
        switch kind {
        case .fiction:
            if FictionChapterHeading.matches(title) { return title }
        case .script:
            if matches(title, "^第" + number + "[幕场].*$") ||
                matches(title, #"^(?:ACT|SCENE)[ \t]+(?:[0-9]+|[IVXLCDM]+)(?:[ \t]+.*|[.:：—–-].*)?$"#) ||
                matches(title, #"^(?:INT|EXT|INT\./EXT|I/E)\.[ \t]+.+$"#) { return title }
        case .academic:
            if matches(title, #"^(?:Abstract|Introduction|Methods?|Results|Discussion|Conclusions?|References|摘要|引言|方法|结果|讨论|结论|参考文献)[：:]?$"#) { return title }
            if !isCitationEntry(title), matches(title, #"^[1-9][0-9]?(?:\.[0-9]{1,2})*(?:\.[ \t]*|[ \t]+)[^\d\[\]].{0,100}$"#) { return title }
        case .general, .technical, .poetry: break
        }
        return nil
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isSpeaker(_ line: String) -> Bool {
        let title = content(line).trimmingCharacters(in: .whitespaces)
        let inline = #"^(?:[\p{Han}·]{1,12}|[A-Za-z][A-Za-z ._'’\-]{0,30})[：:][ \t]*(?!//).*$"#
        let standalone = #"^[A-Z][A-Z ._'’\-]{0,30}(?:[ \t]+\((?:V\.O\.|O\.S\.|CONT'D)\))?$"#
        return matches(title, inline) || title.range(of: standalone, options: .regularExpression) != nil
    }

    private static func isCitationEntry(_ line: String) -> Bool {
        let title = content(line).trimmingCharacters(in: .whitespaces)
        return matches(title, #"^\[[0-9]{1,4}\][ \t]+.+$"#) ||
            matches(title, #"^[0-9]{1,4}\.[ \t]+.+(?:\b(?:19|20)[0-9]{2}\b|doi[:/]).*$"#)
    }

    private static func makeSections(_ text: String, kind: DocumentKind) -> [DocumentSection] {
        var result: [DocumentSection] = [], buffer = "", title = "正文", activeFence: Fence?
        for line in lines(in: text) {
            if let current = activeFence {
                buffer += line
                if fence(in: line, closing: current) != nil { activeFence = nil }
                continue
            }
            if let opening = fence(in: line) { activeFence = opening; buffer += line; continue }
            if let nextTitle = heading(in: line, kind: kind) {
                if !isBlank(buffer) {
                    result.append(DocumentSection(index: result.count, title: title, text: buffer))
                    buffer = ""
                }
                title = nextTitle
            }
            buffer += line
        }
        if !buffer.isEmpty { result.append(DocumentSection(index: result.count, title: title, text: buffer)) }
        return result
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        let raw = content(line).trimmingCharacters(in: .whitespaces)
        guard raw.contains("|") else { return false }
        var cells = raw.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return !cells.isEmpty && cells.allSatisfy { $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }
    }

    private static func blocks(in text: String, kind: DocumentKind) -> [Block] {
        let sourceLines = lines(in: text)
        var result: [Block] = [], prose = "", index = 0
        let technical = kind == .technical || kind == .academic
        let wholeLines = kind == .poetry || kind == .script
        var proseProtected = wholeLines
        while index < sourceLines.count {
            let line = sourceLines[index]
            if technical, let opening = fence(in: line) {
                if !prose.isEmpty { result.append(Block(text: prose, protected: proseProtected)); prose = "" }
                proseProtected = wholeLines
                var code = line; index += 1
                while index < sourceLines.count {
                    let next = sourceLines[index]; code += next; index += 1
                    if fence(in: next, closing: opening) != nil { break }
                }
                result.append(Block(text: code, protected: true))
                continue
            }
            if technical, index + 1 < sourceLines.count, line.contains("|"), !isBlank(line),
               isTableDelimiter(sourceLines[index + 1]) {
                if !prose.isEmpty { result.append(Block(text: prose, protected: proseProtected)); prose = "" }
                proseProtected = wholeLines
                var table = line + sourceLines[index + 1]; index += 2
                while index < sourceLines.count {
                    let next = sourceLines[index]
                    guard !isBlank(next), next.contains("|"), fence(in: next) == nil,
                          heading(in: next, kind: .technical) == nil else { break }
                    table += next; index += 1
                }
                result.append(Block(text: table, protected: true))
                continue
            }
            let citation = kind == .academic && isCitationEntry(line)
            if (kind == .script && isSpeaker(line)) || citation {
                if !prose.isEmpty { result.append(Block(text: prose, protected: proseProtected)); prose = "" }
                proseProtected = wholeLines || citation
            }
            prose += line; index += 1
            if isBlank(line) {
                result.append(Block(text: prose, protected: proseProtected)); prose = ""; proseProtected = wholeLines
            }
        }
        if !prose.isEmpty { result.append(Block(text: prose, protected: proseProtected)) }
        return result
    }

    private static func pack(_ blocks: [Block], budget: Double) -> [String] {
        var result: [String] = [], buffer = "", used = 0.0
        for block in blocks {
            let blockCost = cost(block.text)
            if blockCost <= budget {
                if used + blockCost > budget, !buffer.isEmpty { result.append(buffer); buffer = ""; used = 0 }
                buffer += block.text; used += blockCost
            } else {
                if !buffer.isEmpty { result.append(buffer); buffer = ""; used = 0 }
                // Hard fallback for oversized structures, preferring complete
                // verse, dialogue, citation, code, and table lines over sentences.
                let pieces = splitRaw(block.text, budget: budget, sentences: !block.protected)
                result.append(contentsOf: pieces.dropLast())
                if let last = pieces.last { buffer = last; used = cost(last) }
            }
        }
        if !buffer.isEmpty { result.append(buffer) }
        return result
    }
}
