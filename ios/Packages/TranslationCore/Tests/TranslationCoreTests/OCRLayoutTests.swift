import XCTest
@testable import TranslationCore

final class OCRLayoutTests: XCTestCase {
    private func line(_ id: Int, _ text: String, x: Double = 0.1, y: Double, width: Double = 0.8, confidence: Double = 0.99) -> OCRLine {
        .init(id: id, text: text, confidence: confidence, x: x, y: y, width: width, height: 0.025)
    }
    func testPoetryLineBoundariesAndParagraphGapsArePreserved() {
        let result = OCRLayout.assemble([line(2, "第三行", y: 0.3), line(0, "第一行", y: 0.1), line(1, "第二行", y: 0.135)])
        XCTAssertEqual(result.text, "第一行\n第二行\n\n第三行")
        XCTAssertFalse(result.complex)
    }
    func testColumnsReadDownLeftThenDownRightWithFullWidthHeading() {
        let lines = [line(0, "Heading", y: 0.05)] + (0..<6).flatMap { index in
            [line(index * 2 + 1, "L\(index)", x: 0.08, y: 0.2 + Double(index) * 0.04, width: 0.37),
             line(index * 2 + 2, "R\(index)", x: 0.56, y: 0.205 + Double(index) * 0.04, width: 0.36)]
        }
        let result = OCRLayout.assemble(lines.reversed())
        XCTAssertTrue(result.complex)
        XCTAssertTrue(result.text.hasPrefix("Heading\n\nL0"))
        XCTAssertTrue(result.text.contains("L5\n\nR0"))
        XCTAssertTrue(result.text.hasSuffix("R5"))
    }
    func testSmallAlignedCellsStayOnSameRowAndRequireReview() {
        let lines = (0..<6).flatMap { index in
            [line(index * 2, "Name\(index)", x: 0.1, y: 0.2 + Double(index) * 0.04, width: 0.12),
             line(index * 2 + 1, "42", x: 0.65, y: 0.2 + Double(index) * 0.04, width: 0.06)]
        }
        let result = OCRLayout.assemble(lines)
        XCTAssertTrue(result.complex)
        XCTAssertTrue(result.text.contains("Name0\t42\nName1\t42"))
    }
    func testThreeColumnTableIsFlaggedWithoutInventingCells() {
        let lines = (0..<4).flatMap { row in (0..<3).map { col in
            line(row * 3 + col, "\(row)-\(col)", x: 0.1 + Double(col) * 0.3, y: 0.2 + Double(row) * 0.04, width: 0.1)
        } }
        let result = OCRLayout.assemble(lines)
        XCTAssertTrue(result.complex)
        XCTAssertEqual(result.text.components(separatedBy: "\n").count, 4)
        XCTAssertTrue(result.text.contains("0-0\t0-1\t0-2"))
    }
    func testPageOrderIgnoresCompletionOrderAndDoesNotRepeatPageText() {
        let pages = [OCRPage(number: 2, text: "扫描正文", usedOCR: true), OCRPage(number: 1, text: "原文字层", usedOCR: false)]
        XCTAssertEqual(OCRLayout.joined(pages), "原文字层\n\n扫描正文")
    }
    func testTextLayerOnlyAcceptedWhenSubstantialAndNotBrokenGlyphs() {
        XCTAssertTrue(OCRLayout.usableTextLayer(String(repeating: "A reliable selectable text layer. ", count: 4)))
        XCTAssertFalse(OCRLayout.usableTextLayer("Page 27"))
        XCTAssertFalse(OCRLayout.usableTextLayer(String(repeating: "\u{fffd}", count: 200)))
        XCTAssertFalse(OCRLayout.usableTextLayer(String(repeating: "\u{e000}", count: 200)))
    }
    func testInvalidGeometryAndBlankObservationsCannotCorruptOrdering() {
        let result = OCRLayout.assemble([line(0, "", y: 0.1), line(1, "bad", y: .nan), line(2, "正文", y: 0.2)])
        XCTAssertEqual(result.text, "正文")
    }
    func testUncertaintyIsCarriedToReviewAndPipelineAvoidsSpeculativeRepairs() throws {
        let page = OCRPage(number: 1, text: "A1ice paid 8.00", usedOCR: true, lines: [line(0, "A1ice paid 8.00", y: 0.1, confidence: 0.5)])
        let restored = try JSONDecoder().decode(OCRPage.self, from: JSONEncoder().encode(page))
        XCTAssertEqual(restored.uncertainLines.count, 1)
        let blank = OCRPage(number: 2, text: "", usedOCR: true, confirmedEmpty: true)
        XCTAssertEqual(try JSONDecoder().decode(OCRPage.self, from: JSONEncoder().encode(blank)).confirmedEmpty, true)
        XCTAssertNil(try JSONDecoder().decode(OCRPage.self, from: JSONEncoder().encode(page)).confirmedEmpty)
        let options = TranslationOptions(quality: .publication, sourceWasOCR: true)
        for stage in options.stages {
            let request = TranslationRequest(requestID: "ocr-\(stage)", source: page.text, context: "", draft: "", stage: stage, options: options)
            XCTAssertTrue(request.prompt.contains("OCR source"))
            XCTAssertTrue(request.prompt.contains("Never invent missing text"))
            XCTAssertTrue(request.prompt.contains(options.style.instruction))
        }
    }
}
