#if canImport(Vision) && canImport(PDFKit)
import XCTest
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
@testable import TranslationCore

final class DocumentOCRTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> (URL, CGImage) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let context = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 800, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1600, height: 800))
        let font = CTFontCreateWithName("Helvetica" as CFString, 48, nil)
        let rows = ["BookLLM scanned document", "Alice walked into the garden.", "The total was 42 dollars."]
        for (index, text) in rows.enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.textPosition = CGPoint(x: 100, y: 600 - index * 120); CTLineDraw(line, context)
        }
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(directory.appendingPathComponent("scan.png") as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        return (directory, image)
    }
    func testRealVisionReadsImageAndRetainsNumbers() async throws {
        let (directory, _) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let page = try await DocumentOCR.readImage(url: directory.appendingPathComponent("scan.png"))
        XCTAssertTrue(page.usedOCR)
        XCTAssertTrue(page.text.localizedCaseInsensitiveContains("Alice walked"), page.text)
        XCTAssertTrue(page.text.contains("42"), page.text)
        XCTAssertGreaterThanOrEqual(page.lines.count, 3)
        XCTAssertFalse(try DocumentOCR.preview(url: directory.appendingPathComponent("scan.png"), page: 1).isEmpty)
    }
    func testMixedPDFUsesTextLayerAndOCRPerPageAndResumesCachedPages() async throws {
        let (directory, image) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mixed.pdf")
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        var bounds = CGRect(x: 0, y: 0, width: 800, height: 400)
        let pdf = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        pdf.beginPDFPage(nil)
        let native = "This is selectable text with enough complete sentences to keep the original text layer intact. Alice read the book and checked the total of 42 dollars."
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: native, attributes: [.init(kCTFontAttributeName as String): font]))
        pdf.textPosition = CGPoint(x: 12, y: 300); CTLineDraw(line, pdf); pdf.endPDFPage()
        pdf.beginPDFPage(nil); pdf.draw(image, in: bounds); pdf.endPDFPage(); pdf.closePDF()
        let pages = try await DocumentOCR.readPDF(url: url)
        XCTAssertEqual(pages.count, 2)
        XCTAssertFalse(pages[0].usedOCR)
        XCTAssertTrue(pages[1].usedOCR)
        XCTAssertTrue(pages[1].text.localizedCaseInsensitiveContains("Alice walked"), pages[1].text)
        let cached = [1: OCRPage(number: 1, text: "Reviewed transcription survives resume.", usedOCR: false), 2: pages[1]]
        let resumed = try await DocumentOCR.readPDF(url: url, cached: cached)
        XCTAssertEqual(resumed[0].text, cached[1]?.text)
        XCTAssertEqual(resumed[1], pages[1])
    }
    func testCancelledReadDoesNotContinueRecognition() async throws {
        let (directory, _) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let task = Task { try await DocumentOCR.readImage(url: directory.appendingPathComponent("scan.png")) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
    }
}
#endif
