import XCTest
@testable import TranslationCore

final class DocumentClassifierTests: XCTestCase {
    func testEnglishAndChineseChaptersIdentifyFiction() {
        XCTAssertEqual(DocumentClassifier.detect(text: "Chapter IV: The Library\nAlice stepped through the doorway."), .fiction)
        XCTAssertEqual(DocumentClassifier.detect(text: "第十二章 夜航\n船沿着河流向前。"), .fiction)
        XCTAssertEqual(DocumentClassifier.detect(text: "We will discuss Chapter 3 during the meeting."), .general)
    }

    func testEnglishChapterNamesBeyondTenIdentifyFictionAndSections() {
        for title in ["Chapter Eleven", "Chapter TWENTY-ONE: The River", "Chapter Twenty‑One — The River", "Chapter Ninety Nine — Home"] {
            let source = title + "\nAlice stepped through the doorway."
            XCTAssertEqual(DocumentClassifier.detect(text: source), .fiction, title)
            XCTAssertEqual(Chunker.plan(text: source, kind: .fiction).sections.map(\.title), [title])
        }
    }

    func testAllEnglishChapterNamesOneThroughNinetyNineAgreeWithChunker() {
        let smallNumbers = ["", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        var titles: [String] = []
        for number in 1...99 {
            let spelling = number < 20 ? smallNumbers[number] :
                tens[number / 10] + (number % 10 == 0 ? "" : "-" + smallNumbers[number % 10])
            for variant in Set([spelling, spelling.replacingOccurrences(of: "-", with: " ")]).sorted() {
                let title = "Chapter \(variant): The River"
                titles.append(title)
                let source = title + "\nAlice reads a letter.\n\n"
                XCTAssertEqual(DocumentClassifier.detect(text: source), .fiction, title)
                XCTAssertEqual(Chunker.plan(text: source, kind: .fiction).sections.map(\.title), [title])
            }
        }
        let book = titles.map { $0 + "\nAlice reads a letter.\n\n" }.joined()
        let plan = Chunker.plan(text: book, kind: .fiction)
        XCTAssertEqual(DocumentClassifier.detect(text: book), .fiction)
        XCTAssertEqual(plan.sections.map(\.title), titles)
        XCTAssertEqual(plan.sections.map(\.text).joined(), book)
    }

    func testEnglishChapterNamesInsideCodeOrBodyProseDoNotBecomeSections() {
        let fenced = "````text\nChapter Eleven\nChapter TWENTY-ONE\n```\nChapter Ninety Nine\n````\nA plain explanation follows."
        XCTAssertEqual(DocumentClassifier.detect(text: fenced), .technical)
        XCTAssertEqual(Chunker.plan(text: fenced, kind: .fiction).sections.map(\.title), ["正文"])
        for prose in ["The notes mention Chapter Eleven and Chapter Twenty-One in one paragraph.",
                      "We will discuss Chapter Ninety Nine during the meeting.",
                      "There are ninety nine reasons to read this general document.",
                      "Chapter elevenfold", "Chapter twenty-ten", "Chapter twenty-one-year-old"] {
            XCTAssertEqual(DocumentClassifier.detect(text: prose), .general)
            XCTAssertEqual(Chunker.plan(text: prose, kind: .fiction).sections.map(\.title), ["正文"])
        }
    }

    func testPoetryTitleRequiresVerseStructure() {
        let english = "The light slips past the willow,\nA silver thread of rain,\nThe river keeps its counsel,\nAnd calls us home again."
        let chinese = "床前明月光，\n疑是地上霜。\n举头望明月，\n低头思故乡。"
        XCTAssertEqual(DocumentClassifier.detect(text: english, title: "Selected Poems.epub"), .poetry)
        XCTAssertEqual(DocumentClassifier.detect(text: english.uppercased(), title: "Jonathan Swift Poems"), .poetry)
        XCTAssertEqual(DocumentClassifier.detect(text: chinese, title: "唐诗选·诗集"), .poetry)
        XCTAssertEqual(DocumentClassifier.detect(text: "Poetry is an art form that uses language to evoke emotion. This essay examines its history in several countries.", title: "Poetry and Society"), .general)
    }

    func testUntitledPoetryRequiresSustainedVerseAndStanzas() {
        let verse = "By the quiet river\nsilver rushes lean,\nstars above the willow\nframe the water's sheen.\n\nAll the night is breathing\nover field and foam,\nand the road remembers\nevery footstep home."
        XCTAssertEqual(DocumentClassifier.detect(text: verse), .poetry)
        XCTAssertEqual(DocumentClassifier.detect(text: "By the quiet river\nsilver rushes lean,\nstars above the willow\nframe the water's sheen."), .general)
    }

    func testOrdinaryShortProseAndListsAreNotPoetry() {
        let prose = "The train was late.\nI called my friend.\nShe was already there.\nWe waited for an hour.\n\nThe rain finally stopped.\nWe walked to the hotel.\nThe room was ready.\nI went to sleep."
        let list = "- Bring a notebook\n- Charge the phone\n- Check the weather\n- Call the driver\n\n- Pack the suitcase\n- Lock the window\n- Feed the cat\n- Leave the keys"
        XCTAssertEqual(DocumentClassifier.detect(text: prose), .general)
        XCTAssertEqual(DocumentClassifier.detect(text: list), .general)
        XCTAssertEqual(DocumentClassifier.detect(text: "Name: Lin\nDate: Monday\nStatus: Ready\nNote: Arrive early"), .general)
        XCTAssertEqual(DocumentClassifier.detect(text: "Open the document\nSave the changes\nCheck the settings\nClose the window\n\nStart the application\nChoose the account\nRead the messages\nUse the menu", title: "README.md"), .technical)
    }

    func testTechnicalTitlesAndSnippetsIdentifyTechnicalDocuments() {
        let code = "import Foundation\nlet count = 3\nprint(count)"
        XCTAssertEqual(DocumentClassifier.detect(text: code), .technical)
        XCTAssertEqual(DocumentClassifier.detect(text: "Set host and port before launching.\nhost: localhost\nport: 8080", title: "README.md"), .technical)
        XCTAssertEqual(DocumentClassifier.detect(text: "Functions are explained below.", title: "title.swift.md"), .technical)
        XCTAssertEqual(DocumentClassifier.detect(text: "Call the endpoint with a token.", title: "REST_API_Guide.md"), .technical)
        XCTAssertEqual(DocumentClassifier.detect(text: "配置接口参数后启动服务。", title: "接口文档"), .technical)
    }

    func testMarkdownTableProvidesTechnicalStructure() {
        let text = "Name | Value\n--- | ---\nport | 8080\nhost | localhost"
        XCTAssertEqual(DocumentClassifier.detect(text: text), .technical)
    }

    func testAcademicAbstractAndKeywordsDoNotRequireReferencesInSample() {
        let text = "# A Controlled Study\n## 1. Abstract\nWe compare two translation methods using a fixed evaluation set.\nKeywords: translation; evaluation\n## 2. Methods\nThe study enrolled 120 participants."
        XCTAssertEqual(DocumentClassifier.detect(text: text), .academic)
    }

    func testAcademicReferencesAndDOIProvideAlternativeEvidence() {
        XCTAssertEqual(DocumentClassifier.detect(text: "Abstract: We estimate treatment effects.\nMethods\nA randomized trial was conducted.\nReferences\n[1] An earlier study."), .academic)
        XCTAssertEqual(DocumentClassifier.detect(text: "Abstract\nWe report a multilingual study.\n1.Introduction\nEarlier work is discussed.\n2.Methods\nWe measure accuracy.\nReferences\n[1] A previous paper."), .academic)
        XCTAssertEqual(DocumentClassifier.detect(text: "1.Abstract\nWe report a multilingual study.\n2.Keywords: translation\n3.Introduction\nEarlier work is discussed."), .academic)
        XCTAssertEqual(DocumentClassifier.detect(text: "摘要\n本文研究机器翻译的质量。\n关键词：机器翻译；评价\n方法\n采用双盲实验。"), .academic)
        XCTAssertEqual(DocumentClassifier.detect(text: "Abstract\nWe present a new estimator.\nhttps://doi.org/10.12345/example.2026"), .academic)
    }

    func testAcademicRequiresCombinedEvidence() {
        XCTAssertEqual(DocumentClassifier.detect(text: "Abstract painting uses colour and shape.\nKeywords: colour, shape"), .general)
        XCTAssertEqual(DocumentClassifier.detect(text: "References\nUse DOI: 10.1234/example to find the article."), .general)
        XCTAssertEqual(DocumentClassifier.detect(text: "Abstract\nThis is a short description of the event."), .general)
    }

    func testAcademicTitleStillRequiresASourceMarker() {
        XCTAssertEqual(DocumentClassifier.detect(text: "摘要\n本文研究机器翻译。", title: "博士论文.pdf"), .academic)
        XCTAssertEqual(DocumentClassifier.detect(text: "Abstract\nWe compare language models.", title: "doctoral_thesis.pdf"), .academic)
        XCTAssertEqual(DocumentClassifier.detect(text: "DOI: 10.12345/translation.2026", title: "Research Paper.pdf"), .academic)
        XCTAssertEqual(DocumentClassifier.detect(text: "写作应当使用清晰的语言。这篇随笔讲述作者的写作经历。", title: "论文写作随笔"), .general)
        XCTAssertEqual(DocumentClassifier.detect(text: "This essay discusses the process of writing.", title: "Dissertation Notes.pdf"), .general)
    }

    func testEnglishAndChinesePlaysNeedScenesAndSpeakerTurns() {
        let english = "ACT I\nSCENE II. A library.\nALICE: Is anybody there?\nBOB: Only the librarian."
        let chinese = "第一幕 雨夜\n李明：你听见敲门声了吗？\n王敏：我听见了。"
        XCTAssertEqual(DocumentClassifier.detect(text: english), .script)
        XCTAssertEqual(DocumentClassifier.detect(text: chinese), .script)
        XCTAssertEqual(DocumentClassifier.detect(text: "Scene 2 describes the garden.\nThere are three trees."), .general)
    }

    func testScreenplaySlugLinesAndStandaloneSpeakers() {
        let screenplay = "INT. LIBRARY - NIGHT\nALICE\nWhere did everybody go?\nBOB\nThey left an hour ago.\n\nEXT. RIVER - DAWN\nThe mist rises."
        XCTAssertEqual(DocumentClassifier.detect(text: screenplay), .script)
        XCTAssertEqual(DocumentClassifier.detect(text: "INT. LIBRARY - NIGHT\nALICE\nWhere did everybody go?\nBOB\nThey left an hour ago."), .script)
    }

    func testRepeatedDialogueCanIdentifyScriptWithoutSceneHeading() {
        XCTAssertEqual(DocumentClassifier.detect(text: "Alice: Good morning.\nBob: Good morning to you.\nAlice: Is the train here?\nBob: It will arrive soon."), .script)
        XCTAssertEqual(DocumentClassifier.detect(text: "Name: Ada\nStatus: Ready\nAuthor: Lin\nDate: October"), .general)
        XCTAssertEqual(DocumentClassifier.detect(text: "NAME\nAda\nSTATUS\nReady\nAUTHOR\nLin\nDATE\nOctober"), .general)
    }

    func testFencedGenreMarkersAreIgnoredIncludingShorterInnerFence() {
        let text = "````markdown\nAbstract\nKeywords: translation\nReferences\nACT I\nALICE: Hello.\nBOB: Goodbye.\n```\nChapter IV\n第十二章\n````\nA plain explanation follows."
        XCTAssertEqual(DocumentClassifier.detect(text: text), .technical)
        XCTAssertEqual(DocumentClassifier.detect(text: "~~~text\nPoems\nBy the river\nunder the moon\nbeyond the willow\nfar from home\n~~~", title: "Poems"), .technical)
    }

    func testAcademicStructureOverridesCodeInAPaper() {
        let text = "Abstract\nWe present a parser.\nKeywords: parsing; syntax\n```swift\nlet token = 1\n```"
        XCTAssertEqual(DocumentClassifier.detect(text: text), .academic)
    }

    func testEPUBIsAFallbackAndStrongerGenresOverrideIt() {
        XCTAssertEqual(DocumentClassifier.detect(text: "A woman arrived in the village before sunrise.", format: "EPUB"), .fiction)
        XCTAssertEqual(DocumentClassifier.detect(text: "A woman arrived in the village before sunrise.", format: "application/epub+zip"), .fiction)
        XCTAssertEqual(DocumentClassifier.detect(text: "A woman arrived in the village before sunrise.", title: "book.EPUB"), .fiction)
        XCTAssertEqual(DocumentClassifier.detect(text: "A woman arrived in the village before sunrise.", title: "Jonathan Swift.epub"), .fiction)
        XCTAssertEqual(DocumentClassifier.detect(text: "import Foundation\nlet item = 1", format: ".EPUB"), .technical)
        XCTAssertEqual(DocumentClassifier.detect(text: "Abstract\nWe evaluate quality.\nKeywords: translation", format: "book.epub"), .academic)
        XCTAssertEqual(DocumentClassifier.detect(text: "ACT I\nALICE: Hello.\nBOB: Goodbye.", format: "epub"), .script)
        XCTAssertEqual(DocumentClassifier.detect(text: "床前明月光，\n疑是地上霜。\n举头望明月，\n低头思故乡。", title: "诗集.epub"), .poetry)
    }

    func testOnlyFirstTwentyThousandCharactersAffectDetection() {
        let prefix = String(repeating: "A ", count: 10_000)
        XCTAssertEqual(DocumentClassifier.detect(text: prefix + "\nAbstract\nKeywords: translation\nReferences"), .general)
        XCTAssertEqual(DocumentClassifier.detect(text: String(repeating: "🙂", count: 19_999) + "\nChapter IV"), .general)
    }

    func testWhitespaceAndUnknownFormatsStayGeneral() {
        XCTAssertEqual(DocumentClassifier.detect(text: " \r\n\t ", title: "Poems.epub", format: "epub"), .general)
        XCTAssertEqual(DocumentClassifier.detect(text: "The meeting begins tomorrow.", format: "pdf"), .general)
        XCTAssertEqual(DocumentClassifier.detect(text: "first line\nsecond line\nthird line\nfourth line", title: "notes.txt"), .general)
    }
}
