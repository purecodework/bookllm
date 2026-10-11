import Foundation
import UIKit
import ZIPFoundation

/// Reflowable EPUB / editable Word exports preserve semantic structure, not the source's pixel layout.
enum DocumentExporter {
    @MainActor static func export(title: String, text: String, ext: String, preserveLayout: Bool, coverData: Data? = nil) throws -> URL {
        let format = ext.lowercased()
        guard ["epub", "docx"].contains(format) else { throw ExportFailure.message("此导出格式暂不支持。") }
        guard validXML(title), validXML(text) else { throw ExportFailure.message("文档含 XML 无法表示的控制字符，请清理后导出。") }
        let cover = try coverData.map { try ExportCover.decode($0) }
        let blocks = ExportMarkdown.parse(text, preserveLayout: preserveLayout)
        let name = title.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(String((name.isEmpty ? "translation" : name).prefix(100)) + "." + format)
        do {
            let entries = format == "epub" ? epub(title: title, blocks: blocks, cover: cover) : docx(title: title, blocks: blocks, cover: cover)
            let archive = try Archive(url: url, accessMode: .create)
            for entry in entries {
                let data = entry.data
                try archive.addEntry(with: entry.path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: entry.stored ? .none : .deflate) { position, size in
                    let start = Int(position), end = min(data.count, Int(position) + size)
                    return data.subdata(in: start..<end)
                }
            }
            return url
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func validXML(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            let c = scalar.value
            return c == 9 || c == 10 || c == 13 || (0x20...0xD7FF).contains(c) || (0xE000...0xFFFD).contains(c) || (0x10000...0x10FFFF).contains(c)
        }
    }
    fileprivate static func xml(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
    private static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    private static func xhtml(title: String, body: String) -> String {
        declaration + "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\" xml:lang=\"und\"><head><title>\(xml(title))</title><link rel=\"stylesheet\" type=\"text/css\" href=\"styles.css\"/></head><body>\(body)</body></html>"
    }
    private static func epub(title: String, blocks: [ExportBlock], cover: ExportCover?) -> [ExportEntry] {
        let renderer = ExportHTML()
        let body = renderer.render(blocks)
        let titleText = title.isEmpty ? "译文" : title
        let identifier = "urn:uuid:" + UUID().uuidString
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        let modified = formatter.string(from: Date())
        var entries: [ExportEntry] = [
            .init(path: "mimetype", text: "application/epub+zip", stored: true),
            .init(path: "META-INF/container.xml", text: declaration + "<container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/package.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>")
        ]
        let coverManifest = cover.map { "<item id=\"cover-image\" href=\"images/cover.\($0.ext)\" media-type=\"\($0.mime)\" properties=\"cover-image\"/><item id=\"cover\" href=\"cover.xhtml\" media-type=\"application/xhtml+xml\"/>" } ?? ""
        let package = declaration + """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book-id">\(identifier)</dc:identifier><dc:title>\(xml(titleText))</dc:title><dc:language>und</dc:language><meta property="dcterms:modified">\(modified)</meta></metadata><manifest>\(coverManifest)<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="content" href="content.xhtml" media-type="application/xhtml+xml"/><item id="css" href="styles.css" media-type="text/css"/></manifest><spine>\(cover == nil ? "" : "<itemref idref=\"cover\"/>")<itemref idref="content"/></spine></package>
        """
        entries.append(.init(path: "OEBPS/package.opf", text: package))
        var links = cover == nil ? "" : "<li><a href=\"cover.xhtml\">封面</a></li>"
        links += "<li><a href=\"content.xhtml\">\(xml(titleText))</a></li>"
        links += renderer.headings.map { "<li class=\"level-\($0.level)\"><a href=\"content.xhtml#\($0.id)\">\(xml($0.title))</a></li>" }.joined()
        entries.append(.init(path: "OEBPS/nav.xhtml", text: xhtml(title: "目录", body: "<nav epub:type=\"toc\" id=\"toc\"><h1>目录</h1><ol>\(links)</ol></nav>")))
        entries.append(.init(path: "OEBPS/content.xhtml", text: xhtml(title: titleText, body: "<main><h1 class=\"book-title\">\(xml(titleText))</h1>\(body)</main>")))
        entries.append(.init(path: "OEBPS/styles.css", text: """
        body{font-family:serif;line-height:1.7;margin:6%;color:#24221f}h1,h2,h3,h4,h5,h6{line-height:1.3;break-after:avoid}p{margin:.7em 0}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#f5f2ed;padding:1em}code{font-family:monospace}table{border-collapse:collapse;width:100%;margin:1em 0}th,td{border:1px solid #d8d2c8;padding:.45em;text-align:left}th{background:#f5f2ed}blockquote{margin:1em;padding-left:1em;border-left:3px solid #d8d2c8}img{max-width:100%;height:auto}.cover{text-align:center;break-after:page}.cover img{max-height:95vh}nav .level-2{margin-left:1em}nav .level-3{margin-left:2em}
        """))
        if let cover {
            entries.append(.init(path: "OEBPS/images/cover.\(cover.ext)", data: cover.data))
            entries.append(.init(path: "OEBPS/cover.xhtml", text: xhtml(title: "封面", body: "<section epub:type=\"cover\" class=\"cover\"><img src=\"images/cover.\(cover.ext)\" alt=\"\(xml(titleText)) 封面\"/></section>")))
        }
        return entries
    }

    private static func docx(title: String, blocks: [ExportBlock], cover: ExportCover?) -> [ExportEntry] {
        let renderer = ExportWord()
        let body = renderer.render(blocks)
        let coverBody = cover.map { renderer.cover($0, title: title) } ?? ""
        let document = declaration + """
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(coverBody)\(renderer.paragraph(title, style: "Title"))\(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1200" w:right="1200" w:bottom="1200" w:left="1200" w:header="600" w:footer="600" w:gutter="0"/></w:sectPr></w:body></w:document>
        """
        let imageType = cover.map { "<Default Extension=\"\($0.ext)\" ContentType=\"\($0.mime)\"/>" } ?? ""
        let types = declaration + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>\(imageType)<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>
        """
        let rootRelationships = declaration + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rIdDocument" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rIdCore" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>
        """
        let imageRelationship = cover.map { "<Relationship Id=\"rIdCover\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/cover.\($0.ext)\"/>" } ?? ""
        let relationships = declaration + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/><Relationship Id="rIdNumbering" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>\(imageRelationship)</Relationships>
        """
        let metadata = declaration + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>\(xml(title))</dc:title><dc:creator>BookLLM</dc:creator></cp:coreProperties>"
        var entries: [ExportEntry] = [
            .init(path: "[Content_Types].xml", text: types), .init(path: "_rels/.rels", text: rootRelationships),
            .init(path: "word/document.xml", text: document), .init(path: "word/_rels/document.xml.rels", text: relationships),
            .init(path: "word/styles.xml", text: declaration + renderer.styles), .init(path: "word/numbering.xml", text: declaration + renderer.numbering),
            .init(path: "docProps/core.xml", text: metadata)
        ]
        if let cover { entries.append(.init(path: "word/media/cover.\(cover.ext)", data: cover.data)) }
        return entries
    }
}

private enum ExportFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { value } else { nil } }
}
private struct ExportEntry {
    let path: String
    let data: Data
    var stored = false
    init(path: String, data: Data, stored: Bool = false) { self.path = path; self.data = data; self.stored = stored }
    init(path: String, text: String, stored: Bool = false) { self.init(path: path, data: Data(text.utf8), stored: stored) }
}
private struct ExportCover {
    var data: Data
    var ext: String
    var mime: String
    var width: Double
    var height: Double
    @MainActor static func decode(_ data: Data) throws -> Self {
        guard data.count <= 40_000_000, let image = UIImage(data: data), image.size.width > 0, image.size.height > 0, image.size.width.isFinite, image.size.height.isFinite else { throw ExportFailure.message("封面图片无效或超过 40 MB。") }
        let png = data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let jpeg = data.starts(with: [0xFF, 0xD8, 0xFF])
        if image.imageOrientation == .up, png || jpeg {
            return .init(data: data, ext: png ? "png" : "jpg", mime: png ? "image/png" : "image/jpeg", width: Double(image.size.width), height: Double(image.size.height))
        }
        // Normalize EXIF orientation and unsupported input encodings without generating new artwork.
        let normalized = UIGraphicsImageRenderer(size: image.size).image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
        guard let encoded = normalized.pngData() else { throw ExportFailure.message("无法转换封面图片。") }
        return .init(data: encoded, ext: "png", mime: "image/png", width: Double(image.size.width), height: Double(image.size.height))
    }
}

private indirect enum ExportBlock {
    case heading(Int, String), paragraph(String), code(String), list(Bool, Int, [[ExportBlock]]), quote([ExportBlock]), table([String], [[String]]), rule
}
private struct ExportListMarker { var indent: Int; var contentIndent: Int; var ordered: Bool; var start: Int; var text: String }
private enum ExportMarkdown {
    static func capture(_ pattern: String, _ value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (1..<match.numberOfRanges).map { index in Range(match.range(at: index), in: value).map { String(value[$0]) } ?? "" }
    }
    private static func indent(_ line: String) -> Int { line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } }
    private static func unindent(_ line: String, columns: Int) -> String {
        var width = 0, index = line.startIndex
        while index < line.endIndex, width < columns, line[index] == " " || line[index] == "\t" { width += line[index] == "\t" ? 4 : 1; index = line.index(after: index) }
        return String(line[index...])
    }
    private static func marker(_ line: String) -> ExportListMarker? {
        guard let pieces = capture("^([ \\t]*)([-+*]|[0-9]{1,9}[.)])([ \\t]+)(.*)$", line) else { return nil }
        let ordered = pieces[1].first?.isNumber == true
        return .init(indent: indent(pieces[0]), contentIndent: indent(pieces[0]) + pieces[1].count + indent(pieces[2]), ordered: ordered, start: ordered ? Int(pieces[1].dropLast()) ?? 1 : 1, text: pieces[3])
    }
    private static func fence(_ line: String) -> (Character, Int)? {
        guard indent(line) <= 3 else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let char = trimmed.first, char == "`" || char == "~" else { return nil }
        let count = trimmed.prefix { $0 == char }.count
        return count >= 3 ? (char, count) : nil
    }
    static func cells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|"), !value.hasSuffix("\\|") { value.removeLast() }
        var cells: [String] = [], current = "", index = value.startIndex, ticks = 0
        while index < value.endIndex {
            let char = value[index]
            if char == "\\" {
                let next = value.index(after: index)
                if next < value.endIndex { current.append(char); current.append(value[next]); index = value.index(after: next); continue }
            }
            if char == "`" {
                let run = value[index...].prefix { $0 == "`" }.count
                if ticks == 0 { ticks = run } else if ticks == run { ticks = 0 }
                current += String(repeating: "`", count: run); index = value.index(index, offsetBy: run); continue
            }
            if char == "|", ticks == 0 { cells.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
            else { current.append(char) }
            index = value.index(after: index)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces)); return cells
    }
    private static func tableSeparator(_ line: String) -> Bool {
        let columns = cells(line)
        return !columns.isEmpty && columns.allSatisfy { $0.range(of: "^:?-{3,}:?$", options: .regularExpression) != nil }
    }
    private static func startsBlock(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return fence(line) != nil || marker(line) != nil || trimmed.hasPrefix(">") || capture("^ {0,3}(#{1,6})[ \\t]+(.+?)(?:[ \\t]+#+[ \\t]*)?$", line) != nil || trimmed.range(of: "^(?:\\*\\s*){3,}$|^(?:-\\s*){3,}$|^(?:_\\s*){3,}$", options: .regularExpression) != nil
    }
    static func parse(_ source: String, preserveLayout: Bool, depth: Int = 0) -> [ExportBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        guard depth < 24 else { return [.paragraph(lines.joined(separator: "\n"))] }
        var output: [ExportBlock] = [], index = 0
        while index < lines.count {
            let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }
            if let opening = fence(line) {
                index += 1; var code: [String] = []; var closed = false
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if indent(lines[index]) <= 3, candidate.count >= opening.1, candidate.allSatisfy({ $0 == opening.0 }) { index += 1; closed = true; break }
                    code.append(lines[index]); index += 1
                }
                output.append(.code(code.joined(separator: "\n") + (closed && !code.isEmpty ? "\n" : ""))); continue
            }
            if let heading = capture("^ {0,3}(#{1,6})[ \\t]+(.+?)(?:[ \\t]+#+[ \\t]*)?$", line) { output.append(.heading(heading[0].count, heading[1])); index += 1; continue }
            if index + 1 < lines.count, let underline = capture("^ {0,3}(={3,}|-{3,})[ \\t]*$", lines[index + 1]), marker(line) == nil { output.append(.heading(underline[0].first == "=" ? 1 : 2, trimmed)); index += 2; continue }
            if trimmed.range(of: "^(?:\\*\\s*){3,}$|^(?:-\\s*){3,}$|^(?:_\\s*){3,}$", options: .regularExpression) != nil { output.append(.rule); index += 1; continue }
            if index + 1 < lines.count, line.contains("|"), tableSeparator(lines[index + 1]) {
                let header = cells(line); index += 2; var rows: [[String]] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty, lines[index].contains("|") { rows.append(cells(lines[index])); index += 1 }
                output.append(.table(header, rows)); continue
            }
            if trimmed.hasPrefix(">") {
                var quote: [String] = []
                while index < lines.count, let value = capture("^ {0,3}>[ \\t]?(.*)$", lines[index]) { quote.append(value[0]); index += 1 }
                if quote.isEmpty { output.append(.paragraph(line)); index += 1 }
                else { output.append(.quote(parse(quote.joined(separator: "\n"), preserveLayout: preserveLayout, depth: depth + 1))) }
                continue
            }
            if let first = marker(line) {
                var items: [[ExportBlock]] = []
                while index < lines.count, let item = marker(lines[index]), item.indent == first.indent, item.ordered == first.ordered {
                    var content = [item.text]; index += 1
                    while index < lines.count {
                        let next = lines[index]
                        if let peer = marker(next), peer.indent <= first.indent { break }
                        if next.trimmingCharacters(in: .whitespaces).isEmpty {
                            if index + 1 < lines.count, indent(lines[index + 1]) > first.indent { content.append(""); index += 1; continue }
                            break
                        }
                        guard indent(next) >= item.contentIndent else { break }
                        content.append(unindent(next, columns: item.contentIndent)); index += 1
                    }
                    items.append(parse(content.joined(separator: "\n"), preserveLayout: preserveLayout, depth: depth + 1))
                    if index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty, index + 1 < lines.count, let next = marker(lines[index + 1]), next.indent == first.indent, next.ordered == first.ordered { index += 1 }
                }
                output.append(.list(first.ordered, first.start, items)); continue
            }
            var paragraph = [line]; index += 1
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty, !startsBlock(lines[index]) {
                if index + 1 < lines.count, lines[index].contains("|"), tableSeparator(lines[index + 1]) { break }
                paragraph.append(lines[index]); index += 1
            }
            var joined = ""
            for (position, part) in paragraph.enumerated() {
                let hardBreak = part.hasSuffix("  ") || part.hasSuffix("\\")
                let clean = part.hasSuffix("  ") ? String(part.dropLast(2)) : part.hasSuffix("\\") ? String(part.dropLast()) : part
                joined += clean
                if position < paragraph.count - 1 { joined += preserveLayout || hardBreak ? "\n" : " " }
            }
            output.append(.paragraph(joined))
        }
        return output
    }
}

private struct ExportRun { var text: String; var bold = false; var italic = false; var code = false }
private enum ExportInline {
    static func parse(_ value: String, bold: Bool = false, italic: Bool = false, depth: Int = 0) -> [ExportRun] {
        guard depth < 20 else { return [.init(text: value, bold: bold, italic: italic)] }
        var runs: [ExportRun] = [], plain = "", index = value.startIndex
        func flush() { if !plain.isEmpty { runs.append(.init(text: plain, bold: bold, italic: italic)); plain = "" } }
        while index < value.endIndex {
            if value[index] == "\\" {
                let next = value.index(after: index)
                if next < value.endIndex, "\\`*_[]#<>|".contains(value[next]) { plain.append(value[next]); index = value.index(after: next); continue }
            }
            if value[index] == "`" {
                let length = value[index...].prefix { $0 == "`" }.count, delimiter = String(repeating: "`", count: value[index...].prefix { $0 == "`" }.count)
                let start = value.index(index, offsetBy: length)
                if let end = value.range(of: delimiter, range: start..<value.endIndex) {
                    var code = String(value[start..<end.lowerBound])
                    if code.hasPrefix(" "), code.hasSuffix(" "), !code.allSatisfy({ $0 == " " }) { code.removeFirst(); code.removeLast() }
                    flush(); runs.append(.init(text: code, bold: bold, italic: italic, code: true)); index = end.upperBound; continue
                }
            }
            if value[index...].hasPrefix("<br>") || value[index...].hasPrefix("<br/>") || value[index...].hasPrefix("<br />") {
                let length = value[index...].hasPrefix("<br>") ? 4 : value[index...].hasPrefix("<br/>") ? 5 : 6
                plain.append("\n"); index = value.index(index, offsetBy: length); continue
            }
            var matched = false
            for marker in ["***", "___", "**", "__", "*", "_"] where value[index...].hasPrefix(marker) {
                if marker.first == "_", index > value.startIndex { let previous = value[value.index(before: index)]; if previous.isLetter || previous.isNumber { continue } }
                let start = value.index(index, offsetBy: marker.count)
                if let end = value.range(of: marker, range: start..<value.endIndex), end.lowerBound > start {
                    flush(); runs += parse(String(value[start..<end.lowerBound]), bold: bold || marker.count >= 2, italic: italic || marker.count != 2, depth: depth + 1); index = end.upperBound; matched = true; break
                }
            }
            if matched { continue }
            plain.append(value[index]); index = value.index(after: index)
        }
        flush(); return runs
    }
    static func plain(_ value: String) -> String { parse(value).map(\.text).joined() }
    static func html(_ value: String) -> String {
        parse(value).map { run in
            var body = DocumentExporter.xml(run.text).replacingOccurrences(of: "\n", with: "<br/>")
            if run.code { body = "<code>\(body)</code>" }
            if run.italic { body = "<em>\(body)</em>" }
            if run.bold { body = "<strong>\(body)</strong>" }
            return body
        }.joined()
    }
}
private final class ExportHTML {
    struct Heading { var id: String; var level: Int; var title: String }
    var headings: [Heading] = []
    func render(_ blocks: [ExportBlock]) -> String {
        blocks.map { block in
            switch block {
            case .heading(let level, let text): let id = "heading-\(headings.count + 1)"; headings.append(.init(id: id, level: level, title: ExportInline.plain(text))); return "<h\(level) id=\"\(id)\">\(ExportInline.html(text))</h\(level)>"
            case .paragraph(let text): return "<p>\(ExportInline.html(text))</p>"
            case .code(let text): return "<pre><code>\(DocumentExporter.xml(text))</code></pre>"
            case .list(let ordered, let start, let items): let tag = ordered ? "ol" : "ul", attribute = ordered ? " start=\"\(start)\"" : ""; return "<\(tag)\(attribute)>" + items.map { "<li>\(render($0))</li>" }.joined() + "</\(tag)>"
            case .quote(let blocks): return "<blockquote>\(render(blocks))</blockquote>"
            case .rule: return "<hr/>"
            case .table(let header, let rows):
                let count = max(header.count, rows.map(\.count).max() ?? 0)
                func cells(_ values: [String], tag: String) -> String { (values + Array(repeating: "", count: max(0, count - values.count))).map { "<\(tag)\(tag == "th" ? " scope=\"col\"" : "")>\(ExportInline.html($0))</\(tag)>" }.joined() }
                return "<table><thead><tr>\(cells(header, tag: "th"))</tr></thead><tbody>" + rows.map { "<tr>\(cells($0, tag: "td"))</tr>" }.joined() + "</tbody></table>"
            }
        }.joined(separator: "\n")
    }
}

private final class ExportWord {
    private var definitions: [(id: Int, ordered: Bool, start: Int, depth: Int)] = []
    private static let namespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    func runs(_ text: String, literal: Bool = false, bold: Bool = false) -> String {
        let runs = literal ? [ExportRun(text: text)] : ExportInline.parse(text, bold: bold)
        return runs.map { run in
            let properties = (run.bold ? "<w:b/>" : "") + (run.italic ? "<w:i/>" : "") + (run.code || literal ? "<w:rFonts w:ascii=\"Consolas\" w:hAnsi=\"Consolas\"/>" : "")
            var content = "", plain = ""
            func flush() { if !plain.isEmpty { content += "<w:t xml:space=\"preserve\">\(DocumentExporter.xml(plain))</w:t>"; plain = "" } }
            for char in run.text {
                if char == "\n" { flush(); content += "<w:br/>" }
                else if char == "\t" { flush(); content += "<w:tab/>" }
                else { plain.append(char) }
            }
            flush()
            return "<w:r>\(properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>")\(content)</w:r>"
        }.joined()
    }
    func paragraph(_ text: String, style: String = "Normal", properties: String = "", literal: Bool = false, bold: Bool = false) -> String {
        "<w:p><w:pPr><w:pStyle w:val=\"\(style)\"/>\(properties)</w:pPr>\(runs(text, literal: literal, bold: bold))</w:p>"
    }
    private func number(_ id: Int, depth: Int) -> String { "<w:numPr><w:ilvl w:val=\"\(depth)\"/><w:numId w:val=\"\(id)\"/></w:numPr>" }
    func render(_ blocks: [ExportBlock], depth: Int = 0, leadingNumber: Int? = nil) -> String {
        var leading = leadingNumber, output = ""
        for block in blocks {
            let listProperties = leading.map { number($0, depth: min(depth, 8)) } ?? ""
            switch block {
            case .heading(let level, let text): output += paragraph(text, style: "Heading\(level)", properties: listProperties); leading = nil
            case .paragraph(let text): output += paragraph(text, style: leading == nil ? "Normal" : "ListParagraph", properties: listProperties); leading = nil
            case .code(let text):
                for line in text.components(separatedBy: "\n") { output += paragraph(line, style: "CodeBlock", properties: leading.map { number($0, depth: min(depth, 8)) } ?? "", literal: true); leading = nil }
            case .quote(let blocks): output += render(blocks, depth: depth, leadingNumber: leading); leading = nil
            case .rule: output += "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:color=\"D8D2C8\"/></w:pBdr>\(listProperties)</w:pPr></w:p>"; leading = nil
            case .list(let ordered, let start, let items):
                if leading != nil { output += paragraph("", style: "ListParagraph", properties: listProperties); leading = nil }
                let id = definitions.count + 1, level = min(depth + (leadingNumber == nil ? 0 : 1), 8)
                definitions.append((id, ordered, max(0, start), level))
                for item in items { output += item.isEmpty ? paragraph("", style: "ListParagraph", properties: number(id, depth: level)) : render(item, depth: level, leadingNumber: id) }
            case .table(let header, let rows):
                if leading != nil { output += paragraph("", style: "ListParagraph", properties: listProperties); leading = nil }
                output += table(header, rows: rows)
            }
        }
        return output
    }
    private func table(_ header: [String], rows: [[String]]) -> String {
        let count = max(header.count, rows.map(\.count).max() ?? 0), width = max(1, 9506 / max(1, count))
        let grid = String(repeating: "<w:gridCol w:w=\"\(width)\"/>", count: count)
        var output = "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblBorders>" + ["top", "left", "bottom", "right", "insideH", "insideV"].map { "<w:\($0) w:val=\"single\" w:sz=\"4\" w:color=\"D8D2C8\"/>" }.joined() + "</w:tblBorders></w:tblPr><w:tblGrid>\(grid)</w:tblGrid>"
        for (index, row) in ([header] + rows).enumerated() {
            output += "<w:tr>\(index == 0 ? "<w:trPr><w:tblHeader/></w:trPr>" : "")"
            for cell in row + Array(repeating: "", count: max(0, count - row.count)) { output += "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/>\(index == 0 ? "<w:shd w:fill=\"F5F2ED\"/>" : "")</w:tcPr>\(paragraph(cell, bold: index == 0))</w:tc>" }
            output += "</w:tr>"
        }
        return output + "</w:tbl>"
    }
    var numbering: String {
        var abstract = ""
        for ordered in [false, true] {
            let id = ordered ? 1 : 0
            abstract += "<w:abstractNum w:abstractNumId=\"\(id)\"><w:multiLevelType w:val=\"multilevel\"/>"
            for depth in 0...8 { abstract += "<w:lvl w:ilvl=\"\(depth)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(ordered ? "decimal" : "bullet")\"/><w:lvlText w:val=\"\(ordered ? "%\(depth + 1)." : "•")\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:tabs><w:tab w:val=\"num\" w:pos=\"\((depth + 1) * 720)\"/></w:tabs><w:ind w:left=\"\((depth + 1) * 720)\" w:hanging=\"360\"/></w:pPr></w:lvl>" }
            abstract += "</w:abstractNum>"
        }
        let instances = definitions.map { "<w:num w:numId=\"\($0.id)\"><w:abstractNumId w:val=\"\($0.ordered ? 1 : 0)\"/><w:lvlOverride w:ilvl=\"\($0.depth)\"><w:startOverride w:val=\"\($0.start)\"/></w:lvlOverride></w:num>" }.joined()
        return "<w:numbering xmlns:w=\"\(Self.namespace)\">\(abstract)\(instances)</w:numbering>"
    }
    var styles: String {
        var headings = ""
        for level in 1...6 { headings += "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(level)\"><w:name w:val=\"heading \(level)\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:pPr><w:keepNext/><w:spacing w:before=\"260\" w:after=\"120\"/><w:outlineLvl w:val=\"\(level - 1)\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"\([36, 32, 28, 26, 24, 24][level - 1])\"/></w:rPr></w:style>" }
        return """
        <w:styles xmlns:w="\(Self.namespace)"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Georgia" w:hAnsi="Georgia" w:eastAsia="宋体"/><w:sz w:val="24"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="140" w:line="360" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style><w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="360"/><w:keepNext/></w:pPr><w:rPr><w:b/><w:sz w:val="48"/></w:rPr></w:style>\(headings)<w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/></w:style><w:style w:type="paragraph" w:styleId="CodeBlock"><w:name w:val="Code Block"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:before="0" w:after="0" w:line="240"/><w:shd w:fill="F5F2ED"/></w:pPr><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/><w:sz w:val="20"/></w:rPr></w:style></w:styles>
        """
    }
    func cover(_ cover: ExportCover, title: String) -> String {
        let scale = min(5.8 * 914400 / cover.width, 8.2 * 914400 / cover.height)
        let width = max(1, Int(cover.width * scale)), height = max(1, Int(cover.height * scale))
        return """
        <w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(width)" cy="\(height)"/><wp:docPr id="1" name="Cover" descr="\(DocumentExporter.xml(title)) 封面"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="cover.\(cover.ext)"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="rIdCover"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(width)" cy="\(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p><w:p><w:r><w:br w:type="page"/></w:r></w:p>
        """
    }
}
