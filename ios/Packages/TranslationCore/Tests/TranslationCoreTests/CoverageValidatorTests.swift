import XCTest
@testable import TranslationCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class CoverageMockURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "coverage.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let own = request.url?.path.hasSuffix("chat/completions") == true
        let streaming = request.value(forHTTPHeaderField: "Accept") == "text/event-stream" || request.url?.path.hasSuffix("translate/stream") == true || body?["stream"] as? Bool == true
        let payload: String
        if streaming {
            payload = own ? "data: {\"choices\":[{\"delta\":{\"content\":\"片段\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n" : "data: {\"delta\":\"片段\"}\n\ndata: {\"done\":true}\n\n"
        } else {
            payload = own ? "{\"choices\":[{\"message\":{\"content\":\"片段\"},\"finish_reason\":\"stop\"}]}" : "{\"text\":\"片段\"}"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": streaming ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class CoverageValidatorTests: XCTestCase, @unchecked Sendable {
    private func issues(_ source: String, _ output: String, kind: DocumentKind = .general, layout: LayoutPolicy = .preserve) -> [CoverageIssue] {
        CoverageValidator.inspect(source: source, output: output, options: .init(documentKind: kind, layout: layout))
    }

    func testEmptyOutputAndExtremeSummaryAreDetectedWithoutLanguageRatioRules() {
        XCTAssertEqual(issues("A source paragraph.", "  \n ").map(\.kind), [.emptyOutput])
        let source = (0..<4).map { "Paragraph \($0). " + String(repeating: "A source sentence with facts. ", count: 15) }.joined(separator: "\n\n")
        XCTAssertTrue(issues(source, "摘要", layout: .reading).contains { $0.kind == .extremeSummary })
        XCTAssertTrue(issues("A long, meaningful translated sentence.", "意译完成。").isEmpty)
        XCTAssertTrue(issues("", "").isEmpty)
    }

    func testParagraphLossDependsOnPreserveLayoutNotReadingReflow() {
        let source = "Alice arrives.\n\nBob waits.\n\nRain falls.\n\nThey leave."
        XCTAssertTrue(issues(source, "爱丽丝到达。鲍勃等待。雨落下。他们离开。", layout: .preserve).contains { $0.kind == .paragraphs })
        XCTAssertTrue(issues(source, "爱丽丝到达。鲍勃等待。雨落下。他们离开。", layout: .reading).isEmpty)
        XCTAssertTrue(issues(source, "到达。\n\n等待。\n\n下雨。\n\n离开。").isEmpty)
    }

    func testMissingAndAlteredCompleteCodeBlocksAreDetected() {
        let source = "An example.\n\n```swift\nlet value = 1\n  print(value)\n```\n"
        XCTAssertTrue(issues(source, "一个示例。", kind: .technical).contains { $0.kind == .codeBlocks })
        XCTAssertTrue(issues(source, "一个示例。\n\n```swift\nlet value = 2\n  print(value)\n```\n", kind: .technical).contains { $0.kind == .changedCode })
        XCTAssertTrue(issues(source.replacingOccurrences(of: "\n", with: "\r\n"), "一个示例。\n\n```swift\nlet value = 1\n  print(value)\n```\n", kind: .technical).isEmpty)
    }

    func testLongFencesShortInnerFenceAndPartialChunkDoNotProduceFalseCodeMatches() {
        let source = "````markdown\n# inner\n```\nretained\n````\n"
        XCTAssertTrue(issues(source, source, kind: .technical).isEmpty)
        XCTAssertTrue(issues(source, "```markdown\n# inner\n```\nretained\n", kind: .technical).contains { $0.kind == .changedCode })
        XCTAssertTrue(issues("```swift\nlet value = 1", "```swift\nlet value = 1", kind: .technical).isEmpty)
    }

    func testMissingTableRowsAndColumnsAreDetected() {
        let source = "| Name | Value |\n| --- | --- |\n| API | 1 |\n| SDK | 2 |\n"
        XCTAssertTrue(issues(source, "接口为一，工具为二。", kind: .technical).contains { $0.kind == .tables })
        let rowLost = "| 名称 | 数值 |\n| --- | --- |\n| 接口 | 1 |\n"
        XCTAssertTrue(issues(source, rowLost, kind: .technical).contains { $0.kind == .tableRows })
        let columnLost = "| 名称 |\n| --- |\n| 接口 |\n| 工具 |\n"
        XCTAssertTrue(issues(source, columnLost, kind: .technical).contains { $0.kind == .tableColumns })
        XCTAssertTrue(issues(source, "| 名称 | 数值 |\n| --- | --- |\n| 接口 | 1 |\n| 工具 | 2 |\n", kind: .technical).isEmpty)
    }

    func testEscapedPipesStayWithinCells() {
        let source = "Name | Meaning\n--- | ---\nA | literal \\|\nB | A\\|B\n"
        let output = "名称 | 意义\n--- | ---\nA | 字面符号 \\|\nB | A\\|B\n"
        XCTAssertTrue(issues(source, output, kind: .technical).isEmpty)
    }

    func testPoetryChecksVerseAndStanzaCoverageEvenInReadingLayout() {
        let source = "The moon rises\nOver the water\nThrough the willow\n\nA bird listens\nThe wind carries\nOur quiet song"
        let complete = "月升\n临水\n穿柳\n\n鸟听\n风送\n低吟"
        XCTAssertTrue(issues(source, complete, kind: .poetry, layout: .reading).isEmpty)
        XCTAssertTrue(issues(source, "月升\n临水\n穿柳\n鸟听\n风送\n低吟", kind: .poetry, layout: .reading).contains { $0.kind == .stanzas })
        XCTAssertTrue(issues(source, "月升\n临水\n穿柳\n\n鸟听\n风送", kind: .poetry).contains { $0.kind == .verseLines })
    }

    func testPoetryCompressionAndEditorNotesCannotMaskMissingVerse() {
        let source = "The silver moon across the distant valley\nThe quiet river under evening branches\nThe faintest song beyond the sleeping village\nThe final star above the empty harbour"
        XCTAssertTrue(issues(source, "月\n河\n歌\n星", kind: .poetry).isEmpty)
        XCTAssertTrue(issues(source, "月\n河\n歌\n[编者注：这里保留原作意象。]", kind: .poetry).contains { $0.kind == .verseLines })
    }

    func testScriptDetectsLostTurnsAndAcceptsTranslatedSpeakerLabels() {
        let source = "ACT I\nALICE: Is anybody there?\nBOB: Only me.\n"
        XCTAssertTrue(issues(source, "第一幕\n爱丽丝：有人吗？", kind: .script).contains { $0.kind == .dialogueTurns })
        XCTAssertTrue(issues(source, "第一幕\n爱丽丝：有人吗？\n鲍勃：只有我。", kind: .script).isEmpty)
        let standalone = "ALICE\nIs anybody there?\nBOB\nOnly me.\n"
        XCTAssertTrue(issues(standalone, "爱丽丝\n有人吗？\n鲍勃\n只有我。\n", kind: .script).isEmpty)
    }

    func testHeadingsAreCheckedWhenMarkdownLayoutMustBePreserved() {
        XCTAssertTrue(issues("# Arrival\nAlice arrived.", "爱丽丝到达了。").contains { $0.kind == .headings })
        XCTAssertTrue(issues("# Arrival\nAlice arrived.", "# 到达\n爱丽丝到达了。").isEmpty)
    }

    func testIntermediatePassMayRepairAndFinalFailureCarriesExactRequestAndPaidOutput() throws {
        let source = "```swift\nlet value = 1\n```"
        let options = TranslationOptions(quality: .refined, documentKind: .technical)
        let initial = TranslationRequest(requestID: "book-0-translate", source: source, context: "voice", draft: "", stage: .translate, options: options)
        XCTAssertNoThrow(try CoverageValidator.validateCompletion(request: initial, output: "片段"))
        let final = TranslationRequest(requestID: "book-0-proofread", source: source, context: "voice", draft: "片段", stage: .proofread, options: options)
        do {
            try CoverageValidator.validateCompletion(request: final, output: "本次已付费输出")
            XCTFail("Expected coverage failure")
        } catch let failure as CoverageFailure {
            XCTAssertEqual(failure.request.requestID, final.requestID)
            XCTAssertEqual(failure.request.source, source)
            XCTAssertEqual(failure.request.draft, "片段")
            XCTAssertEqual(failure.output, "本次已付费输出")
            XCTAssertTrue(failure.issues.contains { $0.contains("代码块缺失") })
        }
    }

    func testDiagnosticsAreDeterministicForStableRepairPayloads() {
        let source = "| A | B |\n| --- | --- |\n| 1 | 2 |\n\n| A | B | C |\n| --- | --- | --- |\n| 1 | 2 | 3 |"
        let output = "| A |\n| --- |\n| 1 |\n\n| A |\n| --- |\n| 1 |"
        let expected = issues(source, output, kind: .technical)
        for _ in 0..<10 { XCTAssertEqual(issues(source, output, kind: .technical), expected) }
        XCTAssertEqual(expected.filter { $0.kind == .tableColumns }.map(\.expected), [2, 3])
    }

    func testProductionProviderChecksBothCloudAndOwnKeyFinalOutputsOnly() async throws {
        _ = URLProtocol.registerClass(CoverageMockURLProtocol.self)
        defer { URLProtocol.unregisterClass(CoverageMockURLProtocol.self) }
        let url = URL(string: "https://coverage.invalid/v1")!
        let providers = [APIProvider(connection: .ownKey(baseURL: url, key: "unit-test-key", model: "unit-test-model")), APIProvider(connection: .cloud(baseURL: url, token: "unit-test-session"))]
        let options = TranslationOptions(quality: .refined, documentKind: .technical)
        for provider in providers {
            let first = TranslationRequest(requestID: "book-0-translate", source: "```swift\nlet value = 1\n```", context: "", draft: "", stage: .translate, options: options)
            let intermediate = try await provider.complete(first)
            XCTAssertEqual(intermediate, "片段")
            let final = TranslationRequest(requestID: "book-0-proofread", source: first.source, context: "", draft: intermediate, stage: .proofread, options: options)
            do { _ = try await provider.complete(final); XCTFail("Final missing code must fail") }
            catch let error as CoverageFailure { XCTAssertEqual(error.output, "片段"); XCTAssertEqual(error.request.requestID, final.requestID) }
        }
    }

    func testProductionProviderStreamValidatesFinalAfterStop() async throws {
        _ = URLProtocol.registerClass(CoverageMockURLProtocol.self)
        defer { URLProtocol.unregisterClass(CoverageMockURLProtocol.self) }
        let url = URL(string: "https://coverage.invalid/v1")!
        for provider in [APIProvider(connection: .ownKey(baseURL: url, key: "unit-test-key", model: "unit-test-model")), APIProvider(connection: .cloud(baseURL: url, token: "unit-test-session"))] {
            let request = TranslationRequest(requestID: "fast-0-translate", source: "```swift\nlet value = 1\n```", context: "", draft: "", stage: .translate, options: .init(quality: .fast, documentKind: .technical))
            do { _ = try await provider.stream(request) { _ in }; XCTFail("Stop alone does not prove structural coverage") }
            catch let error as CoverageFailure { XCTAssertEqual(error.output, "片段"); XCTAssertEqual(error.request.requestID, request.requestID) }
        }
    }
}
