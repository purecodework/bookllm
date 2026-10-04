import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PDFKit
import ZIPFoundation
import QuickLookThumbnailing

/// Extract only a declared book cover, or the first document page. All failures
/// are optional: a damaged image must never prevent importing readable text.
enum DocumentCoverExtractor {
    struct EPUBCover { var data: Data?; var pagePaths: Set<String> = [] }
    private static let maximumBytes = 8_000_000
    private static let maximumSide = 1_600

    static func epub(archive: Archive, packagePath: String, packageData: Data) -> EPUBCover {
        guard let metadata = CoverXML(data: packageData, mode: .package) else { return EPUBCover() }
        var references: [String] = [], pages = Set<String>()
        for item in metadata.items where item.properties.contains("cover-image") { references.append(item.href) }
        for id in metadata.coverIDs { if let item = metadata.items.first(where: { $0.id == id }) { references.append(item.href) } }
        references += metadata.guideCovers
        for item in metadata.items {
            let basename = ((item.href.components(separatedBy: "#").first ?? item.href) as NSString).lastPathComponent.lowercased()
            if ["cover", "coverpage", "cover-page"].contains(item.id.lowercased()) || ["cover.xhtml", "cover.html", "cover.htm", "cover.svg"].contains(basename) { references.append(item.href) }
        }
        // EPUB 3 landmarks provide another explicit cover declaration.
        for item in metadata.items where item.properties.contains("nav") {
            guard let path = archivePath(item.href, relativeTo: packagePath), let data = entry(path, archive: archive), let page = CoverXML(data: data, mode: .page) else { continue }
            for href in page.coverLinks { if let target = archivePath(href, relativeTo: path) { references.append("/" + target) } }
        }
        // A spine page may declare epub:type="cover" even without OPF metadata.
        // The first ordinary illustration is deliberately not a fallback.
        if let id = metadata.spine.first, let item = metadata.items.first(where: { $0.id == id }),
           let path = archivePath(item.href, relativeTo: packagePath), let data = entry(path, archive: archive),
           let page = CoverXML(data: data, mode: .page), page.isCover { references.append(item.href) }

        var paths: [String] = []
        for reference in references {
            guard let path = archivePath(reference, relativeTo: packagePath, allowRoot: true), !paths.contains(path) else { continue }
            paths.append(path)
            if isWrapper(path) { pages.insert(path) }
        }
        var result = EPUBCover(pagePaths: pages)
        for path in paths {
            if let data = cover(at: path, archive: archive, depth: 0) { result.data = data; break }
        }
        return result
    }

    static func image(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }; return raster(data)
    }
    static func pdf(_ document: PDFDocument) -> Data? {
        guard let page = document.page(at: 0), let reference = page.pageRef else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = CGFloat(maximumSide) / max(bounds.width, bounds.height)
        let width = max(1, Int((bounds.width * scale).rounded())), height = max(1, Int((bounds.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rectangle = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rectangle)
        context.concatenate(reference.getDrawingTransform(.mediaBox, rect: rectangle, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(reference)
        guard let image = context.makeImage() else { return nil }
        return encode(image, png: false)
    }

    static func docx(archive: Archive, documentData: Data) -> Data? {
        guard let document = CoverXML(data: documentData, mode: .word),
              let data = entry("word/_rels/document.xml.rels", archive: archive),
              let relationships = CoverXML(data: data, mode: .relationships) else { return nil }
        for id in document.firstPageImages {
            guard let target = relationships.images[id], let path = archivePath(target, relativeTo: "word/document.xml", allowRoot: true) else { continue }
            if let data = cover(at: path, archive: archive, depth: 0) { return data }
        }
        return nil
    }

    /// Resolve archive-relative IRIs without extracting files or following URLs.
    static func archivePath(_ reference: String, relativeTo document: String, allowRoot: Bool = false) -> String? {
        let raw = reference.components(separatedBy: "#").first?.components(separatedBy: "?").first ?? ""
        guard let decoded = raw.removingPercentEncoding, !decoded.isEmpty, !decoded.contains("\\"), !decoded.contains("\0"),
              !decoded.hasPrefix("//"), URLComponents(string: decoded)?.scheme == nil else { return nil }
        var components: [String]
        if decoded.hasPrefix("/") { guard allowRoot else { return nil }; components = [] }
        else { components = document.split(separator: "/").dropLast().map(String.init) }
        for part in decoded.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { guard !components.isEmpty else { return nil }; components.removeLast() }
            else { components.append(String(part)) }
        }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    private static func isWrapper(_ path: String) -> Bool { ["xhtml", "html", "htm", "svg", "xml"].contains((path as NSString).pathExtension.lowercased()) }
    private static func entry(_ path: String, archive: Archive) -> Data? {
        guard let item = archive[path], item.uncompressedSize > 0, item.uncompressedSize <= maximumBytes else { return nil }
        var result = Data()
        do {
            _ = try archive.extract(item) { part in
                guard result.count + part.count <= maximumBytes else { throw CoverFailure.oversized }
                result.append(part)
            }
            return result
        } catch { return nil }
    }
    private enum CoverFailure: Error { case oversized }
    private static func cover(at path: String, archive: Archive, depth: Int) -> Data? {
        guard depth < 4, let data = entry(path, archive: archive) else { return nil }
        if let image = raster(data) { return image }
        guard isWrapper(path), let page = CoverXML(data: data, mode: .page) else { return nil }
        for reference in page.pageImages {
            if reference.hasPrefix("data:image/"), let comma = reference.firstIndex(of: ","), reference[..<comma].hasSuffix(";base64"),
               let embedded = Data(base64Encoded: String(reference[reference.index(after: comma)...])), let image = raster(embedded) { return image }
            if let next = archivePath(reference, relativeTo: path), let image = cover(at: next, archive: archive, depth: depth + 1) { return image }
        }
        if (path as NSString).pathExtension.lowercased() == "svg" { return vectorThumbnail(data) }
        return nil
    }
    private static func raster(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber, let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        let w = width.doubleValue, h = height.doubleValue
        guard w > 0, h > 0, w <= 32_000, h <= 32_000, w * h <= 64_000_000 else { return nil }
        for side in [maximumSide, 1_200] {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: side, kCGImageSourceShouldCacheImmediately: true]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            // A validated, already bounded PNG/JPEG can retain its exact original
            // bytes; only oversized or other formats need a display-size copy.
            if side == maximumSide, w <= Double(maximumSide), h <= Double(maximumSide), CGImageSourceGetCount(source) == 1,
               data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) || data.starts(with: [255, 216, 255]) { return data }
            let alpha = [CGImageAlphaInfo.first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo)
            if let result = encode(image, png: alpha) { return result }
        }
        return nil
    }
    private static func encode(_ image: CGImage, png: Bool) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer as CFMutableData, (png ? UTType.png.identifier : UTType.jpeg.identifier) as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination), buffer.length <= maximumBytes else { return nil }
        return buffer as Data
    }
    private static func vectorThumbnail(_ data: Data) -> Data? {
        // Quick Look can render a self-contained vector cover on supported iOS
        // versions. External resources and DTDs are excluded; unsupported SVGs
        // simply leave the cover optional, while the book text still imports.
        guard !Thread.isMainThread, data.count <= 2_000_000, let source = String(data: data, encoding: .utf8),
              !source.localizedCaseInsensitiveContains("<!DOCTYPE"),
              source.range(of: "(?:<(?:[A-Za-z_][\\w.-]*:)?(?:script|foreignObject)\\b|xml:base\\s*=)", options: [.regularExpression, .caseInsensitive]) == nil,
              let references = try? NSRegularExpression(pattern: "(?:href\\s*=\\s*['\"]([^'\"]+)['\"]|url\\s*\\(\\s*['\"]?([^)'\"\\s]+))", options: .caseInsensitive) else { return nil }
        for match in references.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            for index in 1..<match.numberOfRanges {
                if let range = Range(match.range(at: index), in: source), !source[range].hasPrefix("#") { return nil }
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("cover.svg")
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try data.write(to: url) } catch { return nil }
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 1_200, height: 1_600), scale: 1, representationTypes: .thumbnail)
        let box = ThumbnailResult(), semaphore = DispatchSemaphore(value: 0)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            if let representation { box.set(encode(representation.cgImage, png: true)) }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 4) == .timedOut { QLThumbnailGenerator.shared.cancel(request); return nil }
        return box.get()
    }
    private final class ThumbnailResult: @unchecked Sendable {
        private let lock = NSLock(); private var data: Data?
        func set(_ value: Data?) { lock.lock(); defer { lock.unlock() }; data = value }
        func get() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    }
}

/// Small bounded metadata reader; it never resolves an external XML entity.
private final class CoverXML: NSObject, XMLParserDelegate {
    enum Mode { case package, page, word, relationships }
    struct Item { var id: String; var href: String; var properties: Set<String> }
    var items: [Item] = [], coverIDs: [String] = [], guideCovers: [String] = [], spine: [String] = []
    var pageImages: [String] = [], coverLinks: [String] = [], isCover = false
    var firstPageImages: [String] = [], images: [String: String] = [:]
    private let mode: Mode
    private var firstPageEnded = false, inText = false, visibleCharacters = 0
    private var inSectionProperties = false, sectionBreak = "nextPage"
    init?(data: Data, mode: Mode) {
        guard data.count <= 8_000_000 else { return nil }
        self.mode = mode; super.init()
        var prepared = data
        if mode == .page, var source = String(data: data, encoding: .utf8) {
            let entities = ["nbsp": 160, "copy": 169, "reg": 174, "hellip": 8230, "mdash": 8212, "ndash": 8211, "lsquo": 8216, "rsquo": 8217, "ldquo": 8220, "rdquo": 8221]
            if let regex = try? NSRegularExpression(pattern: "(?s)<!\\[CDATA\\[.*?\\]\\]>|<!--.*?-->|&(?:\(entities.keys.sorted().joined(separator: "|")));" ) {
                for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
                    guard let range = Range(match.range, in: source) else { continue }
                    let token = String(source[range])
                    if token.hasPrefix("&"), let scalar = entities[String(token.dropFirst().dropLast())] { source.replaceSubrange(range, with: "&#\(scalar);") }
                }
            }
            prepared = Data(source.utf8)
        }
        let parser = XMLParser(data: prepared); parser.delegate = self; parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return nil }
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let name = String(name.split(separator: ":").last ?? Substring(name))
        func value(_ key: String) -> String? { attributes[key] ?? attributes.first { $0.key.split(separator: ":").last == Substring(key) }?.value }
        func tokens(_ key: String) -> Set<String> { Set((value(key) ?? "").split(whereSeparator: \.isWhitespace).map(String.init)) }
        switch mode {
        case .package:
            if name == "item", let id = value("id"), let href = value("href") { items.append(.init(id: id, href: href, properties: tokens("properties"))) }
            if name == "meta", value("name")?.lowercased() == "cover", let id = value("content") { coverIDs.append(id) }
            if name == "reference", tokens("type").contains("cover"), let href = value("href") { guideCovers.append(href) }
            if name == "itemref", let id = value("idref") { spine.append(id) }
        case .page:
            if tokens("type").contains("cover") || value("role") == "doc-cover" { isCover = true }
            if name == "img", let src = value("src") { pageImages.append(src) }
            if name == "image", let href = value("href") { pageImages.append(href) }
            if name == "object", let data = value("data") { pageImages.append(data) }
            if name == "a", tokens("type").contains("cover"), let href = value("href") { coverLinks.append(href) }
        case .relationships:
            if name == "Relationship", value("TargetMode")?.lowercased() != "external", value("Type")?.hasSuffix("/image") == true,
               let id = value("Id"), let target = value("Target") { images[id] = target }
        case .word:
            if name == "lastRenderedPageBreak" || (name == "br" && value("type") == "page") { firstPageEnded = true }
            if name == "pageBreakBefore", !["0", "false", "off"].contains(value("val")?.lowercased() ?? "1") { firstPageEnded = true }
            if name == "sectPr" { inSectionProperties = true; sectionBreak = "nextPage" }
            if inSectionProperties, name == "type" { sectionBreak = value("val") ?? "nextPage" }
            if name == "t" { inText = true }
            guard !firstPageEnded else { return }
            if name == "blip", let id = value("embed") { firstPageImages.append(id) }
            if name == "imagedata", let id = value("id") { firstPageImages.append(id) }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if mode == .word && inText {
            visibleCharacters += string.count
            // DOCX has no portable pagination engine. Explicit rendered/page
            // breaks are authoritative; this conservative guard avoids choosing
            // a much later body illustration when those markers are absent.
            if visibleCharacters > 4_500 { firstPageEnded = true }
        }
    }
    func parser(_ parser: XMLParser, foundCDATA block: Data) { self.parser(parser, foundCharacters: String(decoding: block, as: UTF8.self)) }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = name.split(separator: ":").last
        if local == "t" { inText = false }
        if mode == .word, local == "sectPr" { inSectionProperties = false; if !["continuous", "nextColumn"].contains(sectionBreak) { firstPageEnded = true } }
    }
}
