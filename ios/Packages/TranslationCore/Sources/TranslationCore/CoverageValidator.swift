import Foundation

public struct CoverageIssue: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case emptyOutput, extremeSummary, codeBlocks, changedCode, tables, tableRows, tableColumns
        case headings, paragraphs, verseLines, stanzas, dialogueTurns
    }
    public let kind: Kind
    public let expected: Int
    public let actual: Int
    public init(kind: Kind, expected: Int, actual: Int) { self.kind = kind; self.expected = expected; self.actual = actual }
    public var message: String {
        switch kind {
        case .emptyOutput: "模型未返回译文"
        case .extremeSummary: "长篇多段原文仅返回极短内容，可能只翻译了摘要"
        case .codeBlocks: "代码块缺失（原文 \(expected)，译文 \(actual)）"
        case .changedCode: "代码内容未完整保留（原文 \(expected) 块，仅 \(actual) 块一致）"
        case .tables: "表格缺失（原文 \(expected)，译文 \(actual)）"
        case .tableRows: "表格行缺失（原文 \(expected)，译文 \(actual)）"
        case .tableColumns: "表格列缺失（原文 \(expected)，译文 \(actual)）"
        case .headings: "标题结构缺失（原文 \(expected)，译文 \(actual)）"
        case .paragraphs: "原文段落结构明显缺失（原文 \(expected) 段，译文 \(actual) 段）"
        case .verseLines: "诗行缺失（原文 \(expected)，译文 \(actual)）"
        case .stanzas: "诗节缺失（原文 \(expected)，译文 \(actual)）"
        case .dialogueTurns: "角色台词段缺失（原文 \(expected)，译文 \(actual)）"
        }
    }
}

/// Carries the returned, potentially paid output so the app can retain it for an
/// explicit repair. This error must not silently retry a changed request payload.
public struct CoverageFailure: LocalizedError, Sendable {
    public let request: TranslationRequest
    public let output: String
    public let issues: [String]
    public init(request: TranslationRequest, output: String, issues: [String]) {
        self.request = request; self.output = output; self.issues = issues
    }
    public var errorDescription: String? {
        "译文完整性检查未通过，请核对并补全。"
    }
}

/// Deterministic checks for clear structural loss. This is not a semantic proof
/// of completeness, and deliberately does not compare source/target length ratios.
public enum CoverageValidator {
    public static func inspect(source: String, output: String, options: TranslationOptions) -> [CoverageIssue] {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [.init(kind: .emptyOutput, expected: 1, actual: 0)] }
        let original = Structure(source), translated = Structure(output)
        var issues: [CoverageIssue] = []

        if translated.code.count < original.code.count {
            issues.append(.init(kind: .codeBlocks, expected: original.code.count, actual: translated.code.count))
        } else if !original.code.isEmpty {
            var remaining = translated.code
            var matched = 0
            for block in original.code {
                if let index = remaining.firstIndex(of: block) { remaining.remove(at: index); matched += 1 }
            }
            if matched < original.code.count { issues.append(.init(kind: .changedCode, expected: original.code.count, actual: matched)) }
        }
        if translated.tables.count < original.tables.count {
            issues.append(.init(kind: .tables, expected: original.tables.count, actual: translated.tables.count))
        } else {
            for (originalTable, translatedTable) in zip(original.tables, translated.tables) {
                if translatedTable.count < originalTable.count { issues.append(.init(kind: .tableRows, expected: originalTable.count, actual: translatedTable.count)) }
                for (expected, actual) in zip(originalTable, translatedTable) where actual < expected {
                    issues.append(.init(kind: .tableColumns, expected: expected, actual: actual)); break
                }
            }
        }
        if options.layout == .preserve, translated.headings < original.headings {
            issues.append(.init(kind: .headings, expected: original.headings, actual: translated.headings))
        }
        switch options.documentKind {
        case .poetry:
            if translated.verseLines < original.verseLines { issues.append(.init(kind: .verseLines, expected: original.verseLines, actual: translated.verseLines)) }
            if translated.stanzas < original.stanzas { issues.append(.init(kind: .stanzas, expected: original.stanzas, actual: translated.stanzas)) }
        case .script:
            let sourceTurns = original.dialogueTurns
            if sourceTurns >= 2, translated.dialogueTurns < sourceTurns { issues.append(.init(kind: .dialogueTurns, expected: sourceTurns, actual: translated.dialogueTurns)) }
        case .fiction, .general, .technical, .academic:
            // A large multilingual text can legitimately become much shorter.
            // Only flag a few letters for a long, multi-paragraph prose source.
            if original.paragraphs >= 4, original.meaningfulScalars >= 1000, translated.meaningfulScalars <= 8 {
                issues.append(.init(kind: .extremeSummary, expected: original.paragraphs, actual: translated.paragraphs))
            }
            if options.layout == .preserve, original.paragraphs >= 4, translated.paragraphs + 1 < original.paragraphs {
                issues.append(.init(kind: .paragraphs, expected: original.paragraphs, actual: translated.paragraphs))
            }
        }
        return Array(Set(issues)).sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            if $0.expected != $1.expected { return $0.expected < $1.expected }
            return $0.actual < $1.actual
        }
    }

    public static func requireComplete(request: TranslationRequest, output: String) throws {
        let issues = inspect(source: request.source, output: output, options: request.options)
        if !issues.isEmpty { throw CoverageFailure(request: request, output: output, issues: issues.map(\.message)) }
    }

    /// Intermediate passes may repair omissions using the already selected next
    /// pass. Final passes must pass checks before a final checkpoint is saved.
    public static func validateCompletion(request: TranslationRequest, output: String) throws {
        guard request.stage == request.options.stages.last else { return }
        try requireComplete(request: request, output: output)
    }

    private struct Fence { let marker: Character; let length: Int }
    private struct Structure {
        var code: [String] = []
        var tables: [[Int]] = []
        var headings = 0
        var paragraphs = 0
        var verseLines = 0
        var stanzas = 0
        var dialogueTurns = 0
        var meaningfulScalars = 0

        init(_ text: String) {
            let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
            var prose = lines, index = 0
            while index < lines.count {
                let line = lines[index]
                if let opening = CoverageValidator.fence(line) {
                    var body: [String] = [], end = index + 1, closed = false
                    while end < lines.count {
                        if CoverageValidator.fence(lines[end], closing: opening) != nil { closed = true; break }
                        body.append(lines[end]); end += 1
                    }
                    if closed { code.append(body.joined(separator: "\n")) }
                    for row in index..<min(end + 1, prose.count) { prose[row] = "" }
                    index = min(end + 1, lines.count); continue
                }
                if index + 1 < lines.count, let header = CoverageValidator.cells(line), CoverageValidator.tableDelimiter(lines[index + 1]) {
                    var rows = [header.count], end = index + 2
                    while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).isEmpty,
                          let row = CoverageValidator.cells(lines[end]), !CoverageValidator.isHeading(lines[end]) {
                        rows.append(row.count); end += 1
                    }
                    tables.append(rows)
                    for row in index..<end { prose[row] = "" }
                    index = end; continue
                }
                index += 1
            }
            var inParagraph = false, inStanza = false
            for (index, line) in prose.enumerated() {
                let value = line.trimmingCharacters(in: .whitespaces)
                if value.isEmpty || value.hasPrefix("⟦编者注:") || CoverageValidator.isEditorialNote(value) {
                    inParagraph = false; inStanza = false; continue
                }
                if CoverageValidator.isHeading(value) { headings += 1; inParagraph = false; inStanza = false; continue }
                if !inParagraph { paragraphs += 1; inParagraph = true }
                if !inStanza { stanzas += 1; inStanza = true }
                verseLines += 1
                meaningfulScalars += value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
                if CoverageValidator.isInlineSpeaker(value) { dialogueTurns += 1 }
                else if index + 1 < prose.count, !prose[index + 1].trimmingCharacters(in: .whitespaces).isEmpty,
                        CoverageValidator.isStandaloneSpeaker(value) { dialogueTurns += 1 }
            }
        }
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
    private static func isHeading(_ line: String) -> Bool { matches(line, #"^ {0,3}#{1,6}(?:[ \t]+|$)"#) }
    private static func isEditorialNote(_ line: String) -> Bool { matches(line, #"^\[(?:编者注|译者注|Editor's note|Translator's note|Note)[：:]"#) }
    private static func isInlineSpeaker(_ line: String) -> Bool {
        matches(line, #"^[\p{L}][\p{L} ._'’\-]{0,35}[：:][ \t]*\S"#) && !matches(line, #"^(?:ACT|SCENE|INT\.|EXT\.|第.{1,10}[幕场])"#)
    }
    private static func isStandaloneSpeaker(_ line: String) -> Bool {
        guard !matches(line, #"^(?:ACT|SCENE|INT\.|EXT\.|第.{1,10}[幕场])"#), (1...24).contains(line.count) else { return false }
        let english = matches(line, #"^[A-Z][A-Z ._'’\-]{0,23}(?: \((?:V\.O\.|O\.S\.)\))?$"#)
        // Translated Chinese labels have no upper/lowercase distinction. This
        // permissive candidate avoids rejecting correctly localized speaker names.
        let chinese = matches(line, #"^[\p{Han}·]{1,8}$"#)
        return english || chinese
    }
    private static func fence(_ line: String, closing existing: Fence? = nil) -> Fence? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let body = line.dropFirst(indent)
        guard let marker = body.first, marker == "`" || marker == "~" else { return nil }
        let length = body.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        let rest = body.dropFirst(length)
        if let existing {
            guard marker == existing.marker, length >= existing.length, rest.allSatisfy({ $0.isWhitespace }) else { return nil }
        } else if marker == "`", rest.contains("`") { return nil }
        return Fence(marker: marker, length: length)
    }
    private static func cells(_ line: String) -> [String]? {
        let value = line.trimmingCharacters(in: .whitespaces)
        var cells = [""], slashes = 0, separators = 0, lastWasSeparator = false
        for character in value {
            if character == "|", slashes % 2 == 0 { cells.append(""); separators += 1; lastWasSeparator = true }
            else { cells[cells.count - 1].append(character); lastWasSeparator = false }
            slashes = character == "\\" ? slashes + 1 : 0
        }
        guard separators > 0 else { return nil }
        if value.first == "|" { cells.removeFirst() }
        if lastWasSeparator { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }
    private static func tableDelimiter(_ line: String) -> Bool {
        guard let cells = cells(line), !cells.isEmpty else { return false }
        return cells.allSatisfy { matches($0, #"^:?-{3,}:?$"#) }
    }
}
