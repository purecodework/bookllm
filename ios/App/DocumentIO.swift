import Foundation
import PDFKit
import UIKit
import CoreText
import ZIPFoundation
import TranslationCore

struct ImportedText: Sendable { var title: String; var text: String; var format: String; var coverData: Data? = nil }
enum DocumentIO {
    static func read(_ url: URL) throws -> ImportedText {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard ((attrs[.size] as? NSNumber)?.intValue ?? 0) <= 40_000_000 else { throw TranslationError.message("请导入 40 MB 以内的文件。") }
        let ext = url.pathExtension.lowercased(), text: String
        var coverData: Data?
        switch ext {
        case "txt", "md", "markdown":
            let data = try Data(contentsOf: url)
            guard let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw TranslationError.message("文本编码暂不支持，请转换为 UTF-8。") }; text = decoded
        case "pdf":
            guard let pdf = PDFDocument(url: url), !pdf.isLocked else { throw TranslationError.message("无法读取或 PDF 已加密。") }
            text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n\n")
            coverData = DocumentCoverExtractor.pdf(pdf)
        case "epub": let imported = try epub(url); text = imported.text; coverData = imported.cover
        case "docx": let imported = try docx(url); text = imported.text; coverData = imported.cover
        default: throw TranslationError.message("支持 TXT、Markdown、EPUB、PDF 和 DOCX。")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranslationError.message("未提取到文本。扫描版 PDF 需要先进行 OCR。") }
        guard text.count <= 2_000_000 else { throw TranslationError.message("文档过长，请按卷或章节拆分后导入。") }
        return .init(title: url.deletingPathExtension().lastPathComponent, text: text, format: ext.uppercased(), coverData: coverData)
    }
    private static func entry(_ path: String, archive: Archive) throws -> Data {
        guard let entry = archive[path], entry.uncompressedSize <= 20_000_000 else { throw TranslationError.message("文档内容缺失或超过安全解压限制。") }
        var data = Data(); _ = try archive.extract(entry) { data.append($0) }; return data
    }
    private static func epub(_ url: URL) throws -> (text: String, cover: Data?) {
        let archive = try Archive(url: url, accessMode: .read)
        let container = try XMLIndex(data: try entry("META-INF/container.xml", archive: archive))
        guard let path = container.rootfile else { throw TranslationError.message("EPUB 缺少目录。") }
        let packageData = try entry(path, archive: archive)
        let index = try XMLIndex(data: packageData)
        let cover = DocumentCoverExtractor.epub(archive: archive, packagePath: path, packageData: packageData)
        let directory = (path as NSString).deletingLastPathComponent
        var texts: [String] = [], size = 0
        for id in index.spine {
            guard let href = index.manifest[id] else { continue }
            let clean = href.removingPercentEncoding ?? href
            let resource = directory.isEmpty ? clean : directory + "/" + clean
            let normalized = (resource as NSString).standardizingPath
            guard !normalized.hasPrefix("../"), !normalized.hasPrefix("/") else { throw TranslationError.message("EPUB 路径无效。") }
            do {
                let data = try entry(normalized, archive: archive); size += data.count
                guard size <= 40_000_000 else { throw TranslationError.message("EPUB 解压后过大。") }
                let collector = try XMLText(data: data)
                texts.append(collector.text)
            } catch {
                // Cover resources are optional; a missing or malformed cover
                // wrapper must not hide otherwise readable chapters.
                if !cover.pagePaths.contains(normalized) { throw error }
            }
        }
        return (texts.joined(separator: "\n\n"), cover.data)
    }
    private static func docx(_ url: URL) throws -> (text: String, cover: Data?) {
        let archive = try Archive(url: url, accessMode: .read)
        let numbering = archive["word/numbering.xml"] == nil ? [:] : try XMLText.numbering(from: entry("word/numbering.xml", archive: archive))
        let documentData = try entry("word/document.xml", archive: archive)
        return (try XMLText(data: documentData, word: true, numbering: numbering).text, DocumentCoverExtractor.docx(archive: archive, documentData: documentData))
    }
    @MainActor static func export(title: String, text: String, ext: String, preserveLayout: Bool = true, coverData: Data? = nil) throws -> URL {
        if ext == "epub" || ext == "docx" { return try DocumentExporter.export(title: title, text: text, ext: ext, preserveLayout: preserveLayout, coverData: coverData) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = title.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        let url = directory.appendingPathComponent(String((safe.isEmpty ? "translation" : safe).prefix(100)) + "." + ext)
        if ext == "pdf" {
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
            let attributed = MarkdownPDF.attributed(title: title, text: text, preserveLayout: preserveLayout)
            let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
            var position = 0, stalled = false
            let data = renderer.pdfData { context in
                if let coverData, let image = UIImage(data: coverData), image.size.width > 0, image.size.height > 0 {
                    context.beginPage()
                    let scale = min(507 / image.size.width, 754 / image.size.height)
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    image.draw(in: CGRect(x: (595 - size.width) / 2, y: (842 - size.height) / 2, width: size.width, height: size.height))
                }
                while position < attributed.length {
                    context.beginPage()
                    let cg = context.cgContext; cg.saveGState(); cg.translateBy(x: 0, y: 842); cg.scaleBy(x: 1, y: -1); cg.textMatrix = .identity
                    let path = CGPath(rect: CGRect(x: 44, y: 44, width: 507, height: 754), transform: nil)
                    let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: position, length: 0), path, nil)
                    CTFrameDraw(frame, cg); cg.restoreGState()
                    let visible = CTFrameGetVisibleStringRange(frame); guard visible.length > 0 else { stalled = true; break }; position += visible.length
                }
            }
            guard !stalled else { throw TranslationError.message("PDF 排版无法继续，请改用 Markdown 或 TXT 导出。") }
            try data.write(to: url, options: .atomic)
        } else { try text.write(to: url, atomically: true, encoding: .utf8) }
        return url
    }
}
private final class XMLIndex: NSObject, XMLParserDelegate {
    var rootfile: String?; var manifest: [String: String] = [:]; var spine: [String] = []
    init(data: Data) throws { super.init(); let parser = XMLParser(data: data); parser.delegate = self; parser.shouldResolveExternalEntities = false; guard parser.parse() else { throw TranslationError.message("文档目录损坏或 XML 无效。") } }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if elementName == "rootfile" { rootfile = attributes["full-path"] }
        if elementName == "item", let id = attributes["id"], let href = attributes["href"] { manifest[id] = href }
        if elementName == "itemref", let id = attributes["idref"] { spine.append(id) }
    }
}
private enum XMLContent { case text(String), element(XMLNode) }
private final class XMLNode {
    let name: String
    let attributes: [String: String]
    var content: [XMLContent] = []
    init(name: String, attributes: [String: String] = [:]) { self.name = name; self.attributes = attributes }
    var elements: [XMLNode] { content.compactMap { if case .element(let node) = $0 { node } else { nil } } }
    func child(_ name: String) -> XMLNode? { elements.first { $0.name == name } }
    func value(_ key: String) -> String? { attributes[key] ?? attributes.first { $0.key.split(separator: ":").last == Substring(key) }?.value }
    var rawText: String { content.map { part in switch part { case .text(let value): value; case .element(let node): node.name == "br" || node.name == "cr" ? "\n" : node.name == "tab" ? "\t" : node.rawText } }.joined() }
}
private final class XMLTree: NSObject, XMLParserDelegate {
    let root = XMLNode(name: "root")
    private var stack: [XMLNode] = []
    init(data: Data, htmlEntities: Bool = false) throws {
        super.init(); stack = [root]
        var prepared = data
        // XHTML often uses these DTD-defined entities. Resolve known characters locally;
        // unknown entities remain a parse error rather than fetching an external DTD.
        if htmlEntities, var source = String(data: data, encoding: .utf8) {
            let entities = ["nbsp": 160, "copy": 169, "reg": 174, "hellip": 8230, "mdash": 8212, "ndash": 8211, "lsquo": 8216, "rsquo": 8217, "ldquo": 8220, "rdquo": 8221, "thinsp": 8201, "ensp": 8194, "emsp": 8195]
            let names = entities.keys.sorted().joined(separator: "|")
            let pattern = "(?s)<!\\[CDATA\\[.*?\\]\\]>|<!--.*?-->|&(?:\(names));"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
                    guard let range = Range(match.range, in: source) else { continue }
                    let token = String(source[range])
                    if token.hasPrefix("&"), let scalar = entities[String(token.dropFirst().dropLast())] { source.replaceSubrange(range, with: "&#\(scalar);") }
                }
            }
            prepared = Data(source.utf8)
        }
        let parser = XMLParser(data: prepared); parser.delegate = self; parser.shouldResolveExternalEntities = false
        guard parser.parse(), stack.count == 1 else { throw TranslationError.message("文档 XML 损坏或含无法解析的实体，请重新导出为有效 XHTML / DOCX 后导入。") }
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let local = String(name.split(separator: ":").last ?? Substring(name))
        let node = XMLNode(name: local, attributes: attributes); stack.last?.content.append(.element(node)); stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { append(string) }
    func parser(_ parser: XMLParser, foundCDATA block: Data) { append(String(decoding: block, as: UTF8.self)) }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) { if stack.count > 1 { stack.removeLast() } }
    private func append(_ value: String) {
        guard let node = stack.last, !value.isEmpty else { return }
        if case .text(let previous) = node.content.last { node.content[node.content.count - 1] = .text(previous + value) }
        else { node.content.append(.text(value)) }
    }
}
private struct WordNumberLevel { var format: String; var start: Int }
private final class XMLText {
    let text: String
    init(data: Data, word: Bool = false, numbering: [String: [Int: WordNumberLevel]] = [:]) throws {
        let tree = try XMLTree(data: data, htmlEntities: !word)
        let renderer = MarkdownImport(numbering: numbering)
        text = MarkdownImport.tidy(word ? renderer.wordBlocks(tree.root) : renderer.html(tree.root))
    }
    static func numbering(from data: Data) throws -> [String: [Int: WordNumberLevel]] {
        let tree = try XMLTree(data: data)
        guard let root = tree.root.child("numbering") else { return [:] }
        var abstracts: [String: [Int: WordNumberLevel]] = [:], result: [String: [Int: WordNumberLevel]] = [:]
        for item in root.elements where item.name == "abstractNum" {
            guard let id = item.value("abstractNumId") else { continue }
            var levels: [Int: WordNumberLevel] = [:]
            for level in item.elements where level.name == "lvl" {
                let depth = Int(level.value("ilvl") ?? "0") ?? 0
                levels[depth] = .init(format: level.child("numFmt")?.value("val") ?? "bullet", start: Int(level.child("start")?.value("val") ?? "1") ?? 1)
            }
            abstracts[id] = levels
        }
        for item in root.elements where item.name == "num" {
            guard let id = item.value("numId"), let abstract = item.child("abstractNumId")?.value("val") else { continue }
            var levels = abstracts[abstract] ?? [:]
            for override in item.elements where override.name == "lvlOverride" {
                let depth = Int(override.value("ilvl") ?? "0") ?? 0
                if let start = override.child("startOverride")?.value("val"), let number = Int(start) {
                    var level = levels[depth] ?? .init(format: "decimal", start: 1); level.start = number; levels[depth] = level
                }
            }
            result[id] = levels
        }
        return result
    }
}
private final class MarkdownImport {
    let numbering: [String: [Int: WordNumberLevel]]
    private var counters: [String: Int] = [:]
    init(numbering: [String: [Int: WordNumberLevel]]) { self.numbering = numbering }
    static func fence(_ value: String) -> String {
        let runs = value.split(whereSeparator: { $0 != "`" }).map(\.count)
        return String(repeating: "`", count: max(3, (runs.max() ?? 0) + 1))
    }
    static func code(_ value: String) -> String { let delimiter = fence(value); return "\n\n\(delimiter)\n\(value)\(value.hasSuffix("\n") ? "" : "\n")\(delimiter)\n\n" }
    static func inlineCode(_ value: String) -> String {
        let delimiter = String(repeating: "`", count: max(1, (value.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0) + 1))
        let pad = value.hasPrefix("`") || value.hasSuffix("`") || (value.hasPrefix(" ") && value.hasSuffix(" ") && !value.allSatisfy({ $0 == " " })) ? " " : ""
        return delimiter + pad + value + pad + delimiter
    }
    static func escape(_ value: String) -> String {
        var result = ""
        for character in value {
            if "\\`*_[]#<>".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
    static func wrap(_ value: String, marker: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return value }
        let prefix = String(value.prefix { $0.isWhitespace }), suffix = String(value.reversed().prefix { $0.isWhitespace }.reversed())
        return prefix + marker + trimmed + marker + suffix
    }
    static func tidy(_ value: String) -> String {
        var lines: [String] = [], fence: Character?, fenceLength = 0, previousBlank = true
        for line in value.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fence {
                lines.append(line)
                if trimmed.allSatisfy({ $0 == marker }), trimmed.count >= fenceLength { fence = nil; previousBlank = false }
                continue
            }
            if let first = trimmed.first, first == "`" || first == "~" {
                let length = trimmed.prefix { $0 == first }.count
                if length >= 3 { fence = first; fenceLength = length; lines.append(line); previousBlank = false; continue }
            }
            if trimmed.isEmpty { if !previousBlank { lines.append("") }; previousBlank = true }
            else { lines.append(line); previousBlank = false }
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
    private func htmlContent(_ node: XMLNode) -> String {
        node.content.map { part in switch part { case .text(let value): Self.escape(value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)); case .element(let child): html(child) } }.joined()
    }
    func html(_ node: XMLNode) -> String {
        switch node.name {
        case "head", "style", "script": return ""
        case "pre": return Self.code(node.rawText)
        case "code", "kbd", "samp": return Self.inlineCode(node.rawText)
        case "strong", "b": return Self.wrap(htmlContent(node), marker: "**")
        case "em", "i": return Self.wrap(htmlContent(node), marker: "*")
        case "br": return "  \n"
        case "hr": return "\n\n---\n\n"
        case "h1", "h2", "h3", "h4", "h5", "h6": return "\n\n" + String(repeating: "#", count: Int(node.name.dropFirst()) ?? 1) + " " + htmlContent(node).trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        case "p", "div", "section", "article": return "\n\n" + htmlContent(node).trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        case "blockquote":
            let body = Self.tidy(htmlContent(node))
            return "\n\n" + body.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n") + "\n\n"
        case "ul", "ol":
            var number = Int(node.value("start") ?? "1") ?? 1, items: [String] = []
            for item in node.elements where item.name == "li" {
                if let override = item.value("value"), let value = Int(override) { number = value }
                let marker = node.name == "ol" ? "\(number). " : "- "
                let lines = Self.tidy(htmlContent(item)).components(separatedBy: "\n")
                items.append(lines.enumerated().map { index, line in (index == 0 ? marker : String(repeating: " ", count: marker.count)) + line }.joined(separator: "\n")); number += 1
            }
            return "\n\n" + items.joined(separator: "\n") + "\n\n"
        case "table":
            let rows = tableRows(node, word: false)
            let caption = node.child("caption").map { htmlContent($0) } ?? ""
            return "\n\n" + (caption.isEmpty ? "" : caption + "\n\n") + table(rows, header: rows.first?.1 ?? false) + "\n\n"
        case "a":
            let label = htmlContent(node)
            guard let href = node.value("href"), !href.isEmpty else { return label }
            return "[\(label)](\(href.replacingOccurrences(of: ")", with: "%29")))"
        case "img": return Self.escape(node.value("alt") ?? "")
        default: return htmlContent(node)
        }
    }
    private func tableRows(_ node: XMLNode, word: Bool) -> [([String], Bool)] {
        var result: [([String], Bool)] = []
        for child in node.elements {
            if child.name == "tr" {
                let cells = child.elements.filter { word ? $0.name == "tc" : ["td", "th"].contains($0.name) }
                result.append((cells.map { word ? Self.tidy(wordBlocks($0)) : Self.tidy(htmlContent($0)) }, word ? enabled(child.child("trPr")?.child("tblHeader")) : cells.contains { $0.name == "th" }))
            } else if child.name != "table" && child.name != "tbl" { result += tableRows(child, word: word) }
        }
        return result
    }
    private func table(_ rows: [([String], Bool)], header: Bool) -> String {
        let count = rows.map { $0.0.count }.max() ?? 0
        guard count > 0 else { return "" }
        func line(_ values: [String]) -> String {
            let cells = (values + Array(repeating: "", count: max(0, count - values.count))).map { $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>") }
            return "| " + cells.joined(separator: " | ") + " |"
        }
        var output = [header ? line(rows[0].0) : line(Array(repeating: "", count: count)), line(Array(repeating: "---", count: count))]
        output += rows.dropFirst(header ? 1 : 0).map { line($0.0) }
        return output.joined(separator: "\n")
    }
    private func enabled(_ node: XMLNode?) -> Bool { guard let node else { return false }; return !["0", "false", "off"].contains(node.value("val")?.lowercased() ?? "1") }
    private func codeParagraph(_ node: XMLNode) -> Bool {
        let style = (node.child("pPr")?.child("pStyle")?.value("val")?.lowercased() ?? "").filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
        return ["code", "codeblock", "sourcecode", "preformatted", "htmlpreformatted"].contains(style)
    }
    private func wordInline(_ node: XMLNode, raw: Bool = false) -> String {
        switch node.name {
        case "pPr", "rPr", "del", "instrText", "delText": return ""
        case "t": return raw ? node.rawText : Self.escape(node.rawText)
        case "tab": return "\t"
        case "br", "cr": return "\n"
        case "noBreakHyphen": return "‑"
        case "softHyphen": return "\u{00AD}"
        case "r":
            let body = node.elements.filter { $0.name != "rPr" }.map { wordInline($0, raw: raw) }.joined()
            guard !raw else { return body }
            let properties = node.child("rPr"), fonts = properties?.child("rFonts")
            let font = (fonts?.value("ascii") ?? fonts?.value("hAnsi") ?? "").lowercased()
            if ["consolas", "courier", "courier new", "menlo", "monaco"].contains(font), !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return Self.inlineCode(node.elements.filter { $0.name != "rPr" }.map { wordInline($0, raw: true) }.joined())
            }
            let bold = enabled(properties?.child("b")), italic = enabled(properties?.child("i"))
            return Self.wrap(body, marker: bold && italic ? "***" : bold ? "**" : italic ? "*" : "")
        default: return node.elements.map { wordInline($0, raw: raw) }.joined()
        }
    }
    func wordBlocks(_ node: XMLNode) -> String {
        if node.name == "p" {
            if codeParagraph(node) { return Self.code(wordInline(node, raw: true)) }
            let body = wordInline(node), properties = node.child("pPr")
            let style = properties?.child("pStyle")?.value("val") ?? ""
            if let match = style.range(of: "^(?:Heading|标题)[ _-]?([1-6])$", options: [.regularExpression, .caseInsensitive]), match == style.startIndex..<style.endIndex, let level = Int(String(style.suffix(1))) {
                return "\n\n" + String(repeating: "#", count: level) + " " + body + "\n\n"
            }
            if let list = properties?.child("numPr"), let id = list.child("numId")?.value("val"), id != "0" {
                let depth = min(12, max(0, Int(list.child("ilvl")?.value("val") ?? "0") ?? 0))
                let level = numbering[id]?[depth] ?? .init(format: "bullet", start: 1), key = "\(id):\(depth)"
                let number = counters[key] ?? level.start; counters[key] = number + 1
                for nested in Array(counters.keys) where nested.hasPrefix(id + ":") && (Int(nested.split(separator: ":").last ?? "0") ?? 0) > depth { counters.removeValue(forKey: nested) }
                let prefix = level.format == "none" ? "" : level.format == "bullet" ? "- " : "\(number). "
                let indentation = String(repeating: " ", count: depth * 4)
                let lines = body.components(separatedBy: "\n").enumerated().map { index, line in indentation + (index == 0 ? prefix : String(repeating: " ", count: prefix.count)) + line }
                return "\n" + lines.joined(separator: "\n") + "\n"
            }
            return "\n\n" + body + "\n\n"
        }
        if node.name == "tbl" { let rows = tableRows(node, word: true); return "\n\n" + table(rows, header: rows.first?.1 ?? false) + "\n\n" }
        var pieces: [String] = [], codeLines: [String] = []
        func flushCode() { if !codeLines.isEmpty { pieces.append(Self.code(codeLines.joined(separator: "\n"))); codeLines = [] } }
        for child in node.elements {
            if child.name == "p", codeParagraph(child) { codeLines.append(wordInline(child, raw: true)) }
            else { flushCode(); pieces.append(wordBlocks(child)) }
        }
        flushCode(); return pieces.joined()
    }
}

@MainActor private enum MarkdownPDF {
    static func attributed(title: String, text: String, preserveLayout: Bool) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        let titleStyle = NSMutableParagraphStyle(); titleStyle.paragraphSpacing = 18
        output.append(NSAttributedString(string: title + "\n", attributes: [.font: UIFont.systemFont(ofSize: 26, weight: .bold), .paragraphStyle: titleStyle, .foregroundColor: UIColor.black]))
        guard preserveLayout else {
            let style = NSMutableParagraphStyle(); style.lineSpacing = 3
            output.append(NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 13), .paragraphStyle: style, .foregroundColor: UIColor.black])); return output
        }
        var fence: Character?, fenceLength = 0
        for original in text.components(separatedBy: "\n") {
            let trimmed = original.trimmingCharacters(in: .whitespaces), style = NSMutableParagraphStyle()
            style.lineSpacing = 3; style.paragraphSpacing = 3
            var line = original, size: CGFloat = 13, bold = false, italic = false, code = false
            if let marker = fence {
                if trimmed.allSatisfy({ $0 == marker }), trimmed.count >= fenceLength { fence = nil; output.append(NSAttributedString(string: "\n")); continue }
                code = true; size = 11; style.firstLineHeadIndent = 10; style.headIndent = 10; style.lineSpacing = 1; style.paragraphSpacing = 0
            } else if let marker = trimmed.first, marker == "`" || marker == "~", trimmed.prefix(while: { $0 == marker }).count >= 3 {
                fence = marker; fenceLength = trimmed.prefix { $0 == marker }.count; continue
            } else if let heading = capture("^(#{1,6})[ \\t]+(.+?)(?:[ \\t]+#+[ \\t]*)?$", line) {
                size = [22, 19, 17, 15, 14, 13][heading[0].count - 1]; bold = true; line = heading[1]; style.paragraphSpacingBefore = 12; style.paragraphSpacing = 8
            } else if let list = capture("^([ \\t]*)([-+*]|[0-9]+[.)])[ \\t]+(.+)$", line) {
                let marker = ["-", "+", "*"].contains(list[1]) ? "•" : list[1]
                line = marker + "  " + list[2]; style.firstLineHeadIndent = CGFloat(list[0].count) * 5; style.headIndent = style.firstLineHeadIndent + 18
            } else if trimmed.hasPrefix(">") {
                line = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces); italic = true; style.firstLineHeadIndent = 14; style.headIndent = 14
            } else if trimmed.hasPrefix("|"), trimmed.hasSuffix("|") {
                if trimmed.replacingOccurrences(of: "[| :\\-]", with: "", options: .regularExpression).isEmpty { continue }
                code = true; size = 10
                line = line.replacingOccurrences(of: "<br>", with: " / ").replacingOccurrences(of: "\\|", with: "|")
            }
            let rendered = code ? NSAttributedString(string: line, attributes: [.font: UIFont.monospacedSystemFont(ofSize: size, weight: .regular)]) : inline(line, size: size, bold: bold, italic: italic)
            let paragraph = NSMutableAttributedString(attributedString: rendered); paragraph.append(NSAttributedString(string: "\n"))
            paragraph.addAttributes([.paragraphStyle: style, .foregroundColor: UIColor.black], range: NSRange(location: 0, length: paragraph.length))
            output.append(paragraph)
        }
        return output
    }
    private static func capture(_ pattern: String, _ value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (1..<match.numberOfRanges).map { index in Range(match.range(at: index), in: value).map { String(value[$0]) } ?? "" }
    }
    private static func font(size: CGFloat, bold: Bool, italic: Bool) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        guard italic else { return base }
        let traits = base.fontDescriptor.symbolicTraits.union(.traitItalic)
        return base.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: size) } ?? base
    }
    private static func inline(_ value: String, size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString(string: ""), base = font(size: size, bold: bold, italic: italic)
        var index = value.startIndex, plain = ""
        func flush() { if !plain.isEmpty { result.append(NSAttributedString(string: plain, attributes: [.font: base])); plain = "" } }
        while index < value.endIndex {
            if value[index] == "\\" {
                let next = value.index(after: index)
                if next < value.endIndex, "\\*_`[]|#<>".contains(value[next]) { plain.append(value[next]); index = value.index(after: next); continue }
            }
            if value[index] == "`" {
                let marker = String(value[index...].prefix { $0 == "`" }), start = value.index(index, offsetBy: value[index...].prefix { $0 == "`" }.count)
                if let end = value.range(of: marker, range: start..<value.endIndex) {
                    var content = String(value[start..<end.lowerBound])
                    if content.hasPrefix(" "), content.hasSuffix(" "), !content.allSatisfy({ $0 == " " }) { content.removeFirst(); content.removeLast() }
                    flush(); result.append(NSAttributedString(string: content, attributes: [.font: UIFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)])); index = end.upperBound; continue
                }
            }
            var matched = false
            for marker in ["***", "___", "**", "__", "*", "_"] where value[index...].hasPrefix(marker) {
                if marker.first == "_", index > value.startIndex, value[value.index(before: index)].isLetter || value[value.index(before: index)].isNumber { continue }
                let start = value.index(index, offsetBy: marker.count)
                if let end = value.range(of: marker, range: start..<value.endIndex), end.lowerBound > start {
                    flush(); result.append(inline(String(value[start..<end.lowerBound]), size: size, bold: bold || marker.count >= 2, italic: italic || marker.count != 2)); index = end.upperBound; matched = true; break
                }
            }
            if matched { continue }
            plain.append(value[index]); index = value.index(after: index)
        }
        flush(); return result
    }
}
