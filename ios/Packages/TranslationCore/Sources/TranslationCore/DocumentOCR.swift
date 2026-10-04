#if canImport(Vision) && canImport(PDFKit)
import Foundation
import Vision
import PDFKit
import CoreGraphics
import ImageIO

/// On-device OCR; no document upload, model call or point consumption.
public enum DocumentOCR {
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var active: VNRequest?
        private var cancelled = false
        func install(_ request: VNRequest) { lock.lock(); defer { lock.unlock() }; active = request; if cancelled { request.cancel() } }
        func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true; active?.cancel() }
    }
    public static func readPDF(url: URL, cached: [Int: OCRPage] = [:],
        onPage: @escaping @Sendable (OCRPage, OCRProgress) async throws -> Void = { _, _ in }) async throws -> [OCRPage] {
        guard let document = PDFDocument(url: url), !document.isLocked else { throw TranslationError.message("无法读取或 PDF 已加密。") }
        guard document.pageCount > 0, document.pageCount <= 2000 else { throw TranslationError.message("请导入 2000 页以内的 PDF，或按卷拆分。") }
        var pages: [OCRPage] = [], recognized = 0, length = 0
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let result: OCRPage
            if let saved = cached[index + 1] { result = saved }
            else {
                guard let page = document.page(at: index) else { throw TranslationError.message("第 \(index + 1) 页无法读取，请重新导出 PDF。") }
                let native = page.string ?? ""
                if OCRLayout.usableTextLayer(native) { result = .init(number: index + 1, text: native, usedOCR: false) }
                else {
                    let cancellation = Cancellation()
                    result = try await withTaskCancellationHandler {
                        try autoreleasepool {
                            let image = try render(page: page, maximum: 3000)
                            var scanned = try recognize(image: image, orientation: .up, number: index + 1, cancellation: cancellation)
                            if !scanned.uncertainLines.isEmpty || scanned.text.isEmpty {
                                let retry = try recognize(image: render(page: page, maximum: 4096), orientation: .up, number: index + 1, cancellation: cancellation)
                                if score(retry) > score(scanned) { scanned = retry }
                            }
                            // Sparse real text pages retain their selectable text if OCR adds nothing useful.
                            let nativeCount = native.filter { $0.isLetter || $0.isNumber }.count
                            let scannedCount = scanned.text.filter { $0.isLetter || $0.isNumber }.count
                            if nativeCount > 0, scannedCount <= nativeCount, !native.unicodeScalars.contains(where: { $0.value == 0xfffd || (0xe000...0xf8ff).contains($0.value) }) {
                                return OCRPage(number: index + 1, text: native, usedOCR: false)
                            }
                            return scanned
                        }
                    } onCancel: { cancellation.cancel() }
                }
            }
            try Task.checkCancellation()
            length += result.text.count
            guard length <= 2_000_000 else { throw TranslationError.message("识别后的文档过长，请按卷拆分。") }
            if result.usedOCR { recognized += 1 }; pages.append(result)
            try await onPage(result, .init(completed: index + 1, total: document.pageCount, recognized: recognized))
        }
        return pages
    }
    public static func readImage(url: URL) async throws -> OCRPage {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) == 1,
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 4096, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                    throw TranslationError.message("请使用可读取的 JPEG、PNG、HEIC 或单页 TIFF；多帧图片请先转换成 PDF。")
                }
                var result = try recognize(image: image, orientation: .up, number: 1, cancellation: cancellation)
                if result.text.isEmpty {
                    for orientation in [CGImagePropertyOrientation.right, .left, .down] {
                        try Task.checkCancellation()
                        let rotated = try recognize(image: image, orientation: orientation, number: 1, cancellation: cancellation)
                        if score(rotated) > score(result) { result = rotated }
                        if !result.text.isEmpty && result.uncertainLines.isEmpty { break }
                    }
                }
                return result
            }
        } onCancel: { cancellation.cancel() }
    }
    /// Explicit reread for mixed pages whose text layer covers only a heading or caption.
    public static func reread(url: URL, page number: Int) async throws -> OCRPage {
        guard url.pathExtension.lowercased() == "pdf" else { return try await readImage(url: url) }
        guard let document = PDFDocument(url: url), !document.isLocked, let page = document.page(at: number - 1) else { throw TranslationError.message("原页无法读取。") }
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try autoreleasepool { try recognize(image: render(page: page, maximum: 4096), orientation: .up, number: number, cancellation: cancellation) }
        } onCancel: { cancellation.cancel() }
    }
    public static func preview(url: URL, page number: Int) throws -> Data {
        let image: CGImage
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url), let page = document.page(at: number - 1) else { throw TranslationError.message("原页无法读取。") }
            image = try render(page: page, maximum: 1200)
        } else {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1200, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw TranslationError.message("原图无法读取。") }
            image = thumbnail
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw TranslationError.message("原页无法显示。") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TranslationError.message("原页无法显示。") }
        return data as Data
    }
    private static func score(_ page: OCRPage) -> Double {
        page.lines.reduce(0) { $0 + Double(min(80, $1.text.count)) * $1.confidence }
    }
    private static func recognize(image: CGImage, orientation: CGImagePropertyOrientation, number: Int, cancellation: Cancellation) throws -> OCRPage {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = false // Avoid silently replacing names, numbers and verse.
        let supported = try request.supportedRecognitionLanguages()
        let wanted = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es", "ru"]
        let languages = supported.filter { language in wanted.contains { language == $0 || language.hasPrefix($0 + "-") } }
        if !languages.isEmpty { request.recognitionLanguages = languages }
        request.minimumTextHeight = 0.004
        cancellation.install(request)
        do { try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request]) }
        catch { try Task.checkCancellation(); throw error }
        try Task.checkCancellation()
        let lines = (request.results ?? []).enumerated().compactMap { index, observation -> OCRLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return .init(id: index, text: candidate.string, confidence: Double(candidate.confidence), x: Double(box.minX), y: Double(1 - box.maxY), width: Double(box.width), height: Double(box.height))
        }
        let layout = OCRLayout.assemble(lines)
        var warnings: [String] = []
        if layout.text.isEmpty { warnings.append("未识别到正文；请核对是否为空白或插图页。") }
        if lines.contains(where: { $0.confidence < 0.8 }) { warnings.append("部分文字识别不确定，请核对人名、数字与标点。") }
        if layout.complex { warnings.append("可能包含多栏或表格，请核对阅读顺序和单元格。") }
        return .init(number: number, text: layout.text, usedOCR: true, lines: lines, warnings: warnings)
    }
    private static func render(page: PDFPage, maximum: Int) throws -> CGImage {
        guard let reference = page.pageRef else { throw TranslationError.message("PDF 页面无法绘制。") }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width >= 1, bounds.height >= 1 else { throw TranslationError.message("PDF 页面尺寸无效。") }
        let scale = CGFloat(maximum) / max(bounds.width, bounds.height)
        let width = max(1, Int((bounds.width * scale).rounded())), height = max(1, Int((bounds.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw TranslationError.message("OCR 内存不足，请稍后重试。") }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
        context.concatenate(reference.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true)); context.drawPDFPage(reference)
        guard let image = context.makeImage() else { throw TranslationError.message("PDF 页面无法绘制。") }
        return image
    }
}
#endif
