import XCTest
@testable import TranslationCore

final class StructuredChunkerTests: XCTestCase, @unchecked Sendable {
    private func assertLossless(_ plan: ChunkPlan, source: String, budget: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(plan.sections.map(\.text).joined(), source, file: file, line: line)
        XCTAssertEqual(plan.chunks.map(\.text).joined(), source, file: file, line: line)
        XCTAssertEqual(plan.chunks.map(\.index), Array(plan.chunks.indices), file: file, line: line)
        XCTAssertEqual(plan.sectionForChunk.count, plan.chunks.count, file: file, line: line)
        for (index, chunk) in plan.chunks.enumerated() {
            XCTAssertLessThanOrEqual(chunk.text.reduce(0) { $0 + Chunker.tokenCost($1) }, budget + 0.001, file: file, line: line)
            XCTAssertEqual(chunk.context, index == 0 ? "" : String(plan.chunks[index - 1].text.suffix(350)), file: file, line: line)
        }
        for section in plan.sections {
            let text = zip(plan.chunks, plan.sectionForChunk).filter { $0.1 == section.index }.map { $0.0.text }.joined()
            XCTAssertEqual(text, section.text, file: file, line: line)
        }
    }

    func testFictionRecognizesChineseEnglishAndMarkdownChapters() {
        let source = "序言。\n\n第一章 初见\n她来了。\n\nChapter IV: The Library\nAlice reads.\n\n# 尾声\n再见。\n"
        let plan = Chunker.plan(text: source, kind: .fiction, budget: 80)
        XCTAssertEqual(plan.sections.map(\.title), ["正文", "第一章 初见", "Chapter IV: The Library", "尾声"])
        XCTAssertEqual(plan.sections.map(\.index), [0, 1, 2, 3])
        assertLossless(plan, source: source, budget: 80)
    }

    func testSpelledEnglishChaptersDrivePublicationPipelineAsTwoChapters() async throws {
        let source = "CHAPTER ONE\nAlice arrived by the river.\n\nCHAPTER TWO\nThe mountain was quiet.\n"
        let plan = Chunker.plan(text: source, kind: .fiction)
        XCTAssertEqual(DocumentClassifier.detect(text: source), .fiction)
        XCTAssertEqual(plan.sections.map(\.title), ["CHAPTER ONE", "CHAPTER TWO"])
        XCTAssertEqual(plan.sectionForChunk, [0, 1])
        assertLossless(plan, source: source, budget: DocumentKind.fiction.defaultBudget)

        let provider = FakeProvider(), collector = Collector()
        let result = try await TranslationEngine().run(jobID: "spelled-chapters", source: source, options: .init(quality: .publication, pipelineVersion: nil), provider: provider) { await collector.add($0) }
        let checkpoints = await collector.values, calls = await provider.calls
        XCTAssertEqual(result, plan.chunks.map(\.text).joined(separator: "\n\n"))
        XCTAssertEqual(checkpoints.map(\.index), [0, 0, 0, 0, 1, 1, 1, 1])
        XCTAssertEqual(checkpoints.map(\.stage), Quality.publication.stages + Quality.publication.stages)
        XCTAssertEqual(calls, 8)
    }

    func testSpelledChapterNumbersMatchClassifierAndDoNotCaptureProse() {
        for number in ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"] {
            let source = "Chapter \(number): The library\nAlice opened the door.\n"
            XCTAssertEqual(DocumentClassifier.detect(text: source), .fiction)
            XCTAssertEqual(Chunker.plan(text: source, kind: .fiction).sections.first?.title, "Chapter \(number): The library")
        }
        let prose = "Alice remembered chapter one of the story.\nChapter oneiric was an unusual phrase.\n"
        XCTAssertEqual(Chunker.plan(text: prose, kind: .fiction).sections.map(\.title), ["正文"])
    }

    func testLargerEnglishWordNumbersRemainSeparatePublicationChapters() async throws {
        let titles = ["CHAPTER ELEVEN: The River", "CHAPTER TWENTY-ONE: The Road", "CHAPTER NINETY NINE: Return"]
        let source = titles.enumerated().map { "\($0.element)\nAlice continued on day \($0.offset + 1).\n\n" }.joined()
        let plan = Chunker.plan(text: source, kind: .fiction)
        XCTAssertEqual(DocumentClassifier.detect(text: source), .fiction)
        XCTAssertEqual(plan.sections.map(\.title), titles)
        XCTAssertEqual(plan.sectionForChunk, [0, 1, 2])
        assertLossless(plan, source: source, budget: DocumentKind.fiction.defaultBudget)

        let provider = FakeProvider(), collector = Collector()
        let result = try await TranslationEngine().run(jobID: "larger-word-chapters", source: source, options: .init(quality: .publication, pipelineVersion: nil), provider: provider) { await collector.add($0) }
        let checkpoints = await collector.values, calls = await provider.calls
        XCTAssertEqual(result, plan.chunks.map(\.text).joined(separator: "\n\n"))
        XCTAssertEqual(checkpoints.map(\.index), [0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2])
        XCTAssertEqual(checkpoints.map(\.stage), Quality.publication.stages + Quality.publication.stages + Quality.publication.stages)
        XCTAssertEqual(calls, 12)
    }

    func testSharedChapterPredicatePreservesExistingMarkersWithoutCapturingNumberProse() {
        for title in ["Chapter 12-After the storm", "Chapter XCIX: Return", "第十二回 往事", "第二卷", "Chapter Eighty‑Seven"] {
            XCTAssertTrue(FictionChapterHeading.matches(title), title)
            XCTAssertEqual(Chunker.plan(text: title + "\nText.\n", kind: .fiction).sections.first?.title, title)
        }
        for text in ["Chapter twentytwo", "Chapter twenty-ten", "Chapter twenty-one-year-old", "Chapter oneiric", "The chapter ninety-nine was missing.", "At ninety-nine, she still read every day.", "ninety-nine"] {
            XCTAssertFalse(FictionChapterHeading.matches(text), text)
            XCTAssertEqual(Chunker.plan(text: text + "\n", kind: .fiction).sections.map(\.title), ["正文"])
        }
    }

    func testGeneralDocumentsUseHeadingsWithoutTreatingChapterProseAsHeading() {
        let source = "Chapter 2\nIntroduction.\n\n# Installation #\nRun the installer.\n## Configuration\nSet values.\n"
        let plan = Chunker.plan(text: source, kind: .general)
        XCTAssertEqual(plan.sections.map(\.title), ["正文", "Installation", "Configuration"])
        assertLossless(plan, source: source, budget: DocumentKind.general.defaultBudget)
    }

    func testHeadingsInsideFencesNeverCreateSections() {
        let source = "# Guide\n````markdown\n# Hidden\nChapter IX\n第十章\n```\n## Still hidden\n````\n## Actual end\nEnd.\n"
        for kind in DocumentKind.allCases {
            let plan = Chunker.plan(text: source, kind: kind, budget: 100)
            XCTAssertEqual(plan.sections.map(\.title), ["Guide", "Actual end"])
            assertLossless(plan, source: source, budget: 100)
        }
    }

    func testIndentedCodeHeadingsDoNotCreateSections() {
        let source = "# Start\n    # Code heading\n    Chapter IV\n\t第一章\n# End\n"
        for kind in DocumentKind.allCases {
            let plan = Chunker.plan(text: source, kind: kind)
            XCTAssertEqual(plan.sections.map(\.title), ["Start", "End"])
            assertLossless(plan, source: source, budget: kind.defaultBudget)
        }
    }

    func testCodeFenceStaysWholeWhenPrecedingHeadingWouldOverflow() {
        let heading = "# Long API document heading to test boundary\n\n"
        let code = "```swift\n" + String(repeating: "let value = 1\n", count: 16) + "```\n"
        let source = heading + code + "\nExplanation.\n"
        let plan = Chunker.plan(text: source, kind: .technical, budget: 80)
        XCTAssertLessThanOrEqual(code.reduce(0) { $0 + Chunker.tokenCost($1) }, 80)
        XCTAssertTrue(plan.chunks.contains { $0.text.contains(code) })
        XCTAssertEqual(plan.chunks.first?.text, heading)
        assertLossless(plan, source: source, budget: 80)
    }

    func testMarkdownTableStaysWholeWhenItFitsBudget() {
        let table = "| Name | Meaning |\n| :--- | ---: |\n| API | 接口 |\n| SDK | 工具 |\n"
        let source = "# Reference\n\n" + String(repeating: "P", count: 180) + "\n\n" + table + "\nDone.\n"
        let plan = Chunker.plan(text: source, kind: .technical, budget: 80)
        XCTAssertTrue(plan.chunks.contains { $0.text.contains(table) })
        assertLossless(plan, source: source, budget: 80)
    }

    func testOversizedCodeAndTableFallbackAddsNoSyntheticWrappers() {
        let code = "~~~swift\n" + String(repeating: "let 汉字 = 1\n", count: 80) + "~~~\n"
        let table = "Name | Value\n--- | ---\n" + String(repeating: "键 | 值👨‍👩‍👧‍👦\n", count: 80)
        let source = "# Large assets\n" + code + "\n" + table
        let plan = Chunker.plan(text: source, kind: .technical, budget: 64)
        XCTAssertGreaterThan(plan.chunks.count, 3)
        assertLossless(plan, source: source, budget: 64)
        XCTAssertEqual(plan.chunks.map(\.text).joined().components(separatedBy: "~~~").count, 3)
    }

    func testUnicodeNewlinesWhitespaceAndSectionOrderingAreLossless() {
        let source = " \r\n# 第一部分\r\n" + String(repeating: "她读着 cafe\u{301} 👨‍👩‍👧‍👦。\r\n\r\n", count: 80) + "## 第二部分\r\n  内容。\r\n"
        let plan = Chunker.plan(text: source, kind: .general, budget: 100)
        XCTAssertEqual(plan.sections.map(\.title), ["第一部分", "第二部分"])
        XCTAssertEqual(plan.sectionForChunk, plan.sectionForChunk.sorted())
        XCTAssertTrue(plan.sections[0].text.hasPrefix(" \r\n#"))
        assertLossless(plan, source: source, budget: 100)
    }

    func testWithoutHeadingsHasOneSectionAndWhitespaceIsRetained() {
        for source in ["A paragraph.\n\nAnother paragraph.\n", " \r\n\t ", "第一个故事，没有章节标题。"] {
            let plan = Chunker.plan(text: source, kind: .fiction)
            XCTAssertEqual(plan.sections.count, 1)
            assertLossless(plan, source: source, budget: DocumentKind.fiction.defaultBudget)
        }
        XCTAssertTrue(Chunker.plan(text: "", kind: .fiction).sections.isEmpty)
        XCTAssertTrue(Chunker.split(" \r\n\t ").isEmpty)
    }

    func testDocumentKindsUseDifferentConservativeBudgets() {
        let source = String(repeating: "汉", count: 8000)
        let fiction = Chunker.plan(text: source, kind: .fiction)
        let general = Chunker.plan(text: source, kind: .general)
        let technical = Chunker.plan(text: source, kind: .technical)
        XCTAssertLessThan(fiction.chunks.count, general.chunks.count)
        XCTAssertLessThan(general.chunks.count, technical.chunks.count)
        assertLossless(fiction, source: source, budget: 1800)
        assertLossless(general, source: source, budget: 1400)
        assertLossless(technical, source: source, budget: 1100)
    }

    func testEarlyPunctuationCannotLeaveAnOverBudgetUnicodeChunk() {
        let source = "." + String(repeating: "x", count: 199) + "汉"
        let chunks = Chunker.split(source, budget: 64)
        XCTAssertEqual(chunks.map(\.text).joined(), source)
        XCTAssertTrue(chunks.allSatisfy { $0.text.reduce(0) { $0 + Chunker.tokenCost($1) } <= 64.001 })
    }

    func testPoetryKeepsFittingStanzasAndPoemSectionsTogether() {
        let stanza = "月亮照着远山也照着长路\n露珠落在窗前也落在手心\n夜风经过河岸又经过桥头\n\n"
        let source = "# 夜曲\n\n" + stanza + stanza + "# 晨歌\n\n清晨来到树梢\n星光渐渐隐去\n"
        let plan = Chunker.plan(text: source, kind: .poetry, budget: 80)
        XCTAssertEqual(plan.sections.map(\.title), ["夜曲", "晨歌"])
        XCTAssertEqual(plan.chunks.filter { $0.text.contains(stanza) }.count, 2)
        assertLossless(plan, source: source, budget: 80)
    }

    func testOversizedStanzaKeepsEachFittingVerseLineWhole() {
        let verses = (1...6).map { "Verse \($0). " + String(repeating: "夜", count: 32) + "\n" }
        let source = verses.joined()
        let plan = Chunker.plan(text: source, kind: .poetry, budget: 64)
        for verse in verses { XCTAssertTrue(plan.chunks.contains { $0.text.contains(verse) }) }
        XCTAssertTrue(plan.chunks.allSatisfy { $0.text.hasSuffix("\n") })
        assertLossless(plan, source: source, budget: 64)
    }

    func testScriptRecognizesActsScenesAndKeepsSpeakerTurnsTogether() {
        let firstTurn = "ALICE\n(quietly)\n" + String(repeating: "夜", count: 37) + "\n"
        let secondTurn = "BOB: " + String(repeating: "灯", count: 37) + "\n"
        let source = "ACT I\nSCENE 1\n" + firstTurn + secondTurn + "第二幕\n第一场 窗边\n林：我们回家吧。\nINT. LIBRARY - NIGHT\nALICE: Wait.\n"
        let plan = Chunker.plan(text: source, kind: .script, budget: 80)
        XCTAssertEqual(plan.sections.map(\.title), ["ACT I", "SCENE 1", "第二幕", "第一场 窗边", "INT. LIBRARY - NIGHT"])
        XCTAssertTrue(plan.chunks.contains { $0.text.contains(firstTurn) })
        XCTAssertTrue(plan.chunks.contains { $0.text.contains(secondTurn) })
        assertLossless(plan, source: source, budget: 80)
    }

    func testAcademicRecognizesPlainPDFHeadingsAndProtectsCitationEntries() {
        let firstCitation = "[1] Smith, J. (2020). " + String(repeating: "结果", count: 16) + ".\n"
        let secondCitation = "2. Doe, A. (2022). " + String(repeating: "方法", count: 16) + ".\n"
        let source = "Paper title\n\nAbstract\nWe evaluate a model.\n\n1.Introduction\nContext [1, 2].\n1.1 Methods\nMeasurements.\nReferences\n" + firstCitation + secondCitation
        let plan = Chunker.plan(text: source, kind: .academic, budget: 80)
        XCTAssertEqual(plan.sections.map(\.title), ["正文", "Abstract", "1.Introduction", "1.1 Methods", "References"])
        XCTAssertTrue(plan.chunks.contains { $0.text.contains(firstCitation) })
        XCTAssertTrue(plan.chunks.contains { $0.text.contains(secondCitation) })
        assertLossless(plan, source: source, budget: 80)
    }

    func testAcademicKeepsFittingCodeAndTablesWhole() {
        let code = "```python\nprint('result')\n# not a heading\n```\n"
        let table = "| Trial | Score |\n| --- | --- |\n| 1 | 0.8 |\n| 2 | 0.9 |\n"
        let source = "Abstract\nFindings.\n\n2.Methods\n" + String(repeating: "P", count: 150) + "\n\n" + code + "\n" + table
        let plan = Chunker.plan(text: source, kind: .academic, budget: 80)
        XCTAssertTrue(plan.chunks.contains { $0.text.contains(code) })
        XCTAssertTrue(plan.chunks.contains { $0.text.contains(table) })
        assertLossless(plan, source: source, budget: 80)
    }

    func testEveryDocumentKindIsOrderedBoundedAndLossless() {
        let source = "# 第一部分\r\n" + String(repeating: "ALICE: 她读着 cafe\u{301} 👨‍👩‍👧‍👦。\r\n\r\n", count: 40) + "## 第二部分\r\n结束。\r\n"
        for kind in DocumentKind.allCases {
            let plan = Chunker.plan(text: source, kind: kind, budget: 100)
            XCTAssertEqual(plan.sectionForChunk, plan.sectionForChunk.sorted())
            assertLossless(plan, source: source, budget: 100)
        }
        XCTAssertEqual(DocumentKind.poetry.defaultBudget, 900)
        XCTAssertEqual(DocumentKind.script.defaultBudget, 1300)
        XCTAssertEqual(DocumentKind.academic.defaultBudget, 1400)
    }
}
