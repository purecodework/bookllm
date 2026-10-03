import Foundation

/// A conservative, local hint for choosing translation and chunking defaults.
/// Importers can always let the reader override the detected kind.
public enum DocumentClassifier {
    public static func detect(text: String, title: String = "", format: String = "") -> DocumentKind {
        let sample = String(text.prefix(20_000))
        guard !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .general }
        let title = String(title.prefix(512))
        let evidence = Evidence(sample: sample)

        // These genres often contain code, so their explicit structure comes first.
        if evidence.isScript(title: title) { return .script }
        if evidence.isAcademic(title: title) { return .academic }
        if evidence.isPoetry(title: title) { return .poetry }
        if evidence.isTechnical || technicalTitle(title) { return .technical }
        if evidence.chapterCount > 0 || matches(title, #"(?:\bnovels?\b|\bnovellas?\b|小说)"#) { return .fiction }

        let format = String(format.prefix(512)).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if format == "epub" || format == ".epub" || format == "application/epub+zip" ||
            format.hasSuffix(".epub") || title.lowercased().hasSuffix(".epub") { return .fiction }
        return .general
    }

    private struct Fence {
        var character: Character
        var length: Int
    }

    private struct Line {
        let text: String
        let indented: Bool
        var heading: String { normalizedHeading(text) }
    }

    private struct Evidence {
        var lines: [Line] = []
        var fenceCount = 0
        var chapterCount = 0
        var actOrSceneCount = 0
        var screenplaySceneCount = 0
        var speakerTurns = 0
        var inlineSpeakerTurns = 0
        var inlineSpeakers = Set<String>()
        var codeLineCount = 0
        var tableCount = 0
        var listLineCount = 0
        var colonLineCount = 0
        var abstract = false
        var keywords = false
        var references = false
        var doi = false

        init(sample: String) {
            var activeFence: Fence?
            for raw in sample.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
                let raw = String(raw)
                if let current = activeFence {
                    if fence(in: raw, closing: current) != nil {
                        activeFence = nil
                        lines.append(Line(text: "", indented: false))
                    }
                    continue
                }
                if let opening = fence(in: raw) {
                    activeFence = opening
                    fenceCount += 1
                    lines.append(Line(text: "", indented: false))
                    continue
                }
                lines.append(Line(text: raw.trimmingCharacters(in: .whitespaces),
                                  indented: raw.first == "\t" || raw.prefix { $0 == " " }.count >= 4))
            }

            for (index, line) in lines.enumerated() {
                let text = line.text
                if text.isEmpty { continue }
                if isCodeLine(text) { codeLineCount += 1 }
                if matches(text, #"^\|?\s*:?-{3,}:?\s*\|(?:\s*:?-{3,}:?\s*\|?)+$"#) { tableCount += 1 }
                if matches(text, #"^(?:[-*+]\s+|\d+[.)]\s+|[•▪◦]\s*)"#) { listLineCount += 1 }
                if text.contains(":") || text.contains("：") { colonLineCount += 1 }
                if line.indented { continue }

                let heading = line.heading
                if matches(heading, #"^(?:abstract|摘要)(?:\s*[:：].*|\s*)$"#) { abstract = true }
                if matches(heading, #"^(?:key\s*words?|index terms|关键词|关键字)(?:\s*[:：].*|\s*)$"#) { keywords = true }
                if matches(heading, #"^(?:references|bibliography|参考文献|参考书目)\s*[:：]?\s*$"#) { references = true }
                if matches(text, #"\b(?:doi\s*[:：]\s*|https?://(?:dx\.)?doi\.org/)10\.\d{4,9}/\S+"#) { doi = true }

                if FictionChapterHeading.matches(heading) { chapterCount += 1 }
                if matches(heading, #"^(?:(?:act|scene)\s+(?:\d+|[ivxlcdm]+)(?:\s.*|[.:：—–-].*)?|第[零〇一二三四五六七八九十百千万两0-9０-９]+[幕场](?:.*))$"#) { actOrSceneCount += 1 }
                if matches(text, #"^(?:int\.?/ext|ext\.?/int|int|ext|i/e)\.\s+\S+"#) { screenplaySceneCount += 1 }

                if let speaker = inlineSpeaker(text) {
                    speakerTurns += 1
                    inlineSpeakerTurns += 1
                    inlineSpeakers.insert(speaker)
                } else if index + 1 < lines.count, standaloneSpeaker(text) != nil,
                          !lines[index + 1].text.isEmpty,
                          !isCodeLine(lines[index + 1].text),
                          !matches(lines[index + 1].heading, #"^(?:act|scene)\s+|^(?:int|ext)\."#) {
                    speakerTurns += 1
                }
            }
        }

        var isTechnical: Bool { fenceCount > 0 || codeLineCount >= 2 || tableCount > 0 }

        func isAcademic(title: String) -> Bool {
            if abstract && (keywords || references || doi) { return true }
            let words = title.replacingOccurrences(of: #"[_/\\.\-]"#, with: " ", options: .regularExpression)
            let titleHint = matches(words, #"(?:\b(?:thesis|dissertation)\b|\bresearch paper\b|\bjournal article\b|论文)"#)
            return titleHint && (abstract || keywords || references || doi)
        }

        func isScript(title: String) -> Bool {
            if screenplaySceneCount >= 2 { return true }
            if (actOrSceneCount > 0 || screenplaySceneCount > 0) && speakerTurns >= 2 { return true }
            if matches(title, #"(?:\bscreenplay\b|\bstage play\b|剧本|戏剧)"#), speakerTurns >= 2 { return true }
            return chapterCount == 0 && inlineSpeakerTurns >= 4 && inlineSpeakers.count >= 2 && codeLineCount == 0 && listLineCount == 0
        }

        func isPoetry(title: String) -> Bool {
            // Short code, lists, speaker labels, and chapter prose can resemble verse.
            guard !isTechnical, !technicalTitle(title), listLineCount == 0, colonLineCount == 0,
                  inlineSpeakerTurns == 0, actOrSceneCount == 0, screenplaySceneCount == 0,
                  chapterCount == 0 else { return false }

            let titleHint = matches(title, #"(?:\bpoems?\b|\bpoetry\b|诗集|诗选|诗歌)"#) ||
                lines.prefix(3).contains { matches($0.heading, #"^(?:selected\s+)?(?:poems?|poetry|诗集|诗选|诗歌)$"#) }
            var stanzas: [[String]] = [], stanza: [String] = []
            for line in lines {
                if line.text.isEmpty || line.text.hasPrefix("#") ||
                    matches(line.heading, #"^(?:selected\s+)?(?:poems?|poetry|诗集|诗选|诗歌)$"#) {
                    if !stanza.isEmpty { stanzas.append(stanza); stanza = [] }
                } else {
                    stanza.append(line.text)
                }
            }
            if !stanza.isEmpty { stanzas.append(stanza) }
            let content = stanzas.flatMap { $0 }
            guard content.count >= 4 else { return false }
            let verseCount = content.filter(isShortVerseLine).count
            let verseRatio = Double(verseCount) / Double(content.count)
            let terminalRatio = Double(content.filter { ".!?。！？".contains($0.last ?? " ") }.count) / Double(content.count)
            if titleHint { return verseRatio >= 0.8 && terminalRatio <= 0.65 }

            // An untitled run of short sentences is too ambiguous. Require sustained
            // verse across at least two stanzas, with little sentence-final punctuation.
            let verseStanzas = stanzas.filter { $0.count >= 3 && $0.allSatisfy(isShortVerseLine) }.count
            return content.count >= 8 && verseRatio >= 0.9 && verseStanzas >= 2 && terminalRatio <= 0.35
        }
    }

    private static func matches(_ text: String, _ pattern: String, caseInsensitive: Bool = true) -> Bool {
        let options: String.CompareOptions = caseInsensitive ? [.regularExpression, .caseInsensitive] : [.regularExpression]
        return text.range(of: pattern, options: options) != nil
    }

    private static func normalizedHeading(_ text: String) -> String {
        text.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\d+(?:\.\d+)*(?:[.)]\s*|\s+)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func technicalTitle(_ title: String) -> Bool {
        let words = title.replacingOccurrences(of: #"[_/\\.\-]"#, with: " ", options: .regularExpression)
        return matches(words, #"(?:\b(?:api|sdk|readme|changelog|programming|developer|software|database|python|javascript|typescript|sql)\b|\bswift\s+(?:language|guide|reference|documentation|docs)\b|\b(?:reference|user) manual\b|技术文档|接口文档|开发指南|编程|程序设计|数据结构|操作手册|使用手册)"#) ||
            matches(title, #"\.(?:swift|py|js|jsx|ts|tsx|java|rb|go|rs|cpp|c|h|sh|bash|yaml|yml|json|sql|xml|toml|ini|ipynb)(?:\.[a-z0-9]+)?$"#)
    }

    private static func isCodeLine(_ text: String) -> Bool {
        matches(text, #"^(?:import\s+[\w.]+|from\s+[\w.]+\s+import\s+|#include\s*[<\"]|(?:public\s+|private\s+|internal\s+)?(?:func|function|def|class|struct|enum|interface)\s+\w+[\w\s:<>,]*(?:\(|\{|:)|(?:let|var|const)\s+\w+\s*(?::[^=]+)?=|(?:if|for|while)\s*\(.*\)\s*\{|return\s+.*;\s*$|(?:\$|%)\s+(?:curl|npm|pip|git|docker|swift|python|node)\s+)"#, caseInsensitive: false) ||
            matches(text, #"^(?:select\s+.+\s+from\s+|create\s+table\s+|insert\s+into\s+|update\s+\w+\s+set\s+)"#)
    }

    private static func inlineSpeaker(_ text: String) -> String? {
        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
        let name = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
        let dialogue = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !dialogue.isEmpty, validSpeakerName(name) else { return nil }
        return name.lowercased()
    }

    private static func standaloneSpeaker(_ text: String) -> String? {
        guard text != text.lowercased(), text == text.uppercased(), validSpeakerName(text) else { return nil }
        return text.lowercased()
    }

    private static func validSpeakerName(_ name: String) -> Bool {
        guard (1...24).contains(name.count), matches(name, #"^[\p{L}][\p{L}\s.'’\-]*$"#) else { return false }
        let labels: Set<String> = ["abstract", "keywords", "doi", "references", "title", "author", "date", "name", "age", "address", "email", "phone", "status", "type", "note", "notes", "warning", "example", "input", "output", "host", "port", "user", "password", "path", "version", "timeout", "method", "url", "content", "description", "introduction", "conclusion", "summary", "摘要", "关键词", "姓名", "日期", "作者", "标题", "备注", "说明", "地址", "状态", "示例"]
        return !labels.contains(name.lowercased())
    }

    private static func isShortVerseLine(_ text: String) -> Bool {
        guard (3...80).contains(text.count), !matches(text, #"[{}=<>]|^\d+[.)]?\s|^[-*+]\s"#) else { return false }
        let cjk = text.unicodeScalars.filter { (0x3400...0x9FFF).contains($0.value) }.count
        if cjk >= 3 { return text.count <= 30 && Double(cjk) / Double(text.unicodeScalars.count) >= 0.5 }
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return (2...12).contains(words)
    }

    private static func fence(in line: String, closing current: Fence? = nil) -> Fence? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let body = line.dropFirst(indent)
        guard let marker = body.first, marker == "`" || marker == "~" else { return nil }
        let length = body.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        let tail = body.dropFirst(length)
        if let current {
            guard marker == current.character, length >= current.length, tail.allSatisfy({ $0.isWhitespace }) else { return nil }
        } else if marker == "`", tail.contains("`") { return nil }
        return Fence(character: marker, length: length)
    }
}
