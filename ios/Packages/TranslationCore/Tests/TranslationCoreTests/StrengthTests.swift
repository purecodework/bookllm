import XCTest
@testable import TranslationCore

private actor CollaborationProvider: TranslationProvider {
    var requests: [TranslationRequest] = []
    var streams = 0
    var payloads: [String: String] = [:]
    var reviewed = Set<Stage>()
    var waitForBothReviewers = false
    var breakTranslation = false
    var failLanguageOnce = false
    var permanentlyBroken = false
    func configure(wait: Bool = false, broken: Bool = false, failLanguage: Bool = false, permanent: Bool = false) { waitForBothReviewers = wait; breakTranslation = broken; failLanguageOnce = failLanguage; permanentlyBroken = permanent }
    func complete(_ request: TranslationRequest) async throws -> String {
        requests.append(request)
        let payload = request.prompt + request.input
        if let old = payloads[request.requestID], old != payload { throw TranslationError.message("Resume changed a paid request payload") }
        payloads[request.requestID] = payload
        if request.reviewMode == true {
            reviewed.insert(request.stage)
            if waitForBothReviewers {
                let deadline = ContinuousClock.now + .seconds(2)
                while !reviewed.contains(.proofread) || !reviewed.contains(.linguist) {
                    if ContinuousClock.now > deadline { throw TranslationError.message("Reviewers did not run concurrently") }
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
            if request.stage == .linguist && failLanguageOnce { failLanguageOnce = false; throw TranslationError.message("Paused review") }
            let unit = SourceUnit.make(request.source)[0]
            let finding = ReviewFinding(paragraphID: unit.id, kind: request.stage == .proofread ? .fact : .language, severity: .major, sourceQuote: String(unit.text.prefix(20)), explanation: "Evidence from the source", suggestedTranslation: "Preserve the chosen voice")
            return CollaborationPrompts.json(ReviewReport(findings: [finding]))
        }
        if permanentlyBroken || (breakTranslation && request.stage == .translate && request.reviewNotes == nil) { return "Missing code" }
        return request.source
    }
    func stream(_ request: TranslationRequest, onPartial: @escaping @Sendable (String) async -> Void) async throws -> String { streams += 1; let text = try await complete(request); await onPartial(text); return text }
    func extractTerms(source: String, target: String, requestID: String) async throws -> [Term] { [] }
}
final class StrengthTests: XCTestCase, @unchecked Sendable {
    func testFourSelectableLevelsAndNoNewFinalVerifier() throws {
        XCTAssertEqual(Quality.allCases.map(\.title), ["速读", "精译", "深校", "精修"])
        XCTAssertEqual(TranslationOptions().pipelineVersion, 2)
        for quality in Quality.allCases { XCTAssertFalse(TranslationOptions(quality: quality).stages.contains(.verify)) }
        XCTAssertEqual(TranslationOptions(quality: .definitive).stages.last, .editor)
    }
    func testHistoricalFivePassOptionsDecodeWithoutMigratingPaidCheckpoints() throws {
        let encoder = JSONEncoder()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(TranslationOptions(quality: .definitive))) as? [String: Any])
        object.removeValue(forKey: "pipelineVersion")
        let old = try JSONDecoder().decode(TranslationOptions.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.pipelineVersion); XCTAssertFalse(old.usesCollaborativeEditing)
        XCTAssertEqual(old.stages, Stage.allCases); XCTAssertEqual(old.effectiveQuality, .publication)
        let request = TranslationRequest(requestID: "old-0-editor", source: "Alice.", context: "", draft: "Alice.", stage: .editor, options: old)
        let decoded = try JSONDecoder().decode(TranslationRequest.self, from: encoder.encode(request))
        XCTAssertNil(decoded.reviews); XCTAssertNil(decoded.chapterContext); XCTAssertNil(decoded.reviewMode)
    }
    func testLegacyExtraLanguageReviewMapsToDeep() {
        var preferences = TranslationPreferences(); preferences.extraLanguageReview = true
        let old = TranslationOptions(quality: .refined, preferences: preferences, pipelineVersion: nil)
        XCTAssertEqual(old.effectiveQuality, .deep); XCTAssertEqual(old.stages, Quality.deep.stages)
    }
    func testFourLevelsExecuteAndOnlyFastStreams() async throws {
        for quality in Quality.allCases {
            let provider = CollaborationProvider(), options = TranslationOptions(quality: quality, documentKind: .general, sourceWasOCR: true)
            _ = try await TranslationEngine().run(jobID: quality.rawValue, source: "Alice paid 42 dollars.\n\nShe kept the receipt.", options: options, provider: provider) { _ in }
            let requests = await provider.requests, streams = await provider.streams
            XCTAssertEqual(Set(requests.map(\.stage)), Set(options.stages)); XCTAssertEqual(requests.count, options.stages.count)
            XCTAssertEqual(streams, quality == .fast ? 1 : 0)
            XCTAssertTrue(requests.allSatisfy { $0.prompt.contains(options.style.instruction) && $0.prompt.contains("OCR source") })
        }
    }
    func testReviewersRunConcurrentlyOnSameDraftAndChiefReceivesBothReports() async throws {
        let provider = CollaborationProvider(); await provider.configure(wait: true)
        let source = "Henry held his violin case.\n\nClara hid the telegram.", options = TranslationOptions(quality: .publication, style: TranslationStyle.presets.last!)
        let result = try await TranslationEngine().run(jobID: "parallel", source: source, options: options, provider: provider) { _ in }
        XCTAssertEqual(result, source)
        let requests = await provider.requests, reviews = requests.filter { $0.reviewMode == true }
        XCTAssertEqual(reviews.count, 2); XCTAssertTrue(reviews.allSatisfy { $0.draft == source })
        let chief = try XCTUnwrap(requests.last); XCTAssertEqual(chief.stage, .editor); XCTAssertEqual(chief.draft, source)
        XCTAssertEqual(Set(chief.reviews?.map(\.role) ?? []), [.proofread, .linguist])
        XCTAssertTrue(chief.chapterContext?.contains("FULL CURRENT CHAPTER") == true)
        XCTAssertTrue(chief.chapterContext?.contains("CHAPTER REVIEW OVERVIEW") == true)
        XCTAssertTrue(chief.prompt.contains("reject preference-only rewrites"))
        XCTAssertFalse(requests.contains { $0.stage == .verify })
    }
    func testChapterBarrierAndCompleteInitialChapterContext() async throws {
        let source = "Chapter I\n\n" + String(repeating: "甲", count: 2200) + "\n\nLast clue.\n\nChapter II\n\nThe telegram was opened."
        let provider = CollaborationProvider(), collector = Collector(), options = TranslationOptions(quality: .publication)
        _ = try await TranslationEngine().run(jobID: "chapters", source: source, options: options, provider: provider) { await collector.add($0) }
        let plan = Chunker.plan(text: source, kind: .fiction), requests = await provider.requests
        let firstIndices = Set(plan.chunks.indices.filter { plan.sectionForChunk[$0] == 0 })
        let firstChiefs = requests.filter { $0.stage == .editor && firstIndices.contains($0.chunkIndex ?? -1) }
        XCTAssertTrue(firstChiefs.allSatisfy { $0.chapterContext?.contains("Last clue.") == true })
        let firstChiefLast = try XCTUnwrap(requests.lastIndex { $0.stage == .editor && firstIndices.contains($0.chunkIndex ?? -1) })
        let secondStart = try XCTUnwrap(requests.firstIndex { $0.stage == .translate && !firstIndices.contains($0.chunkIndex ?? -1) })
        XCTAssertLessThan(firstChiefLast, secondStart)
        XCTAssertTrue(requests.filter { $0.stage == .editor && !firstIndices.contains($0.chunkIndex ?? -1) }.allSatisfy { $0.chapterContext?.contains("Previously completed chapter") == true })
    }
    func testLongChapterContextCoversAllChunksWithinBound() {
        let chunks = (0..<40).map { TextChunk(index: $0, text: "SOURCE-\($0)-" + String(repeating: "甲", count: 3000), context: "") }
        let drafts = Dictionary(uniqueKeysWithValues: chunks.map { ($0.index, "DRAFT-\($0.index)-" + String(repeating: "乙", count: 3000)) })
        let context = ChapterEditorialContext.make(title: "Long chapter", chunks: chunks, drafts: drafts, previousChapters: [])
        XCTAssertLessThanOrEqual(context.unicodeScalars.count, 32000); XCTAssertTrue(context.contains("not a full chapter"))
        for chunk in chunks { XCTAssertTrue(context.contains("Chunk \(chunk.index) SOURCE EXCERPTS")) }
    }
    func testPartialResumeReusesReviewerCheckpointAndSameChiefPayload() async throws {
        let provider = CollaborationProvider(), collector = Collector(); await provider.configure(failLanguage: true)
        let options = TranslationOptions(quality: .publication), source = "The train left at 8:15."
        do { _ = try await TranslationEngine().run(jobID: "resume", source: source, options: options, provider: provider) { await collector.add($0) }; XCTFail("Expected pause") } catch { }
        let saved = await collector.values
        XCTAssertTrue(saved.contains { $0.stage == .translate })
        _ = try await TranslationEngine().run(jobID: "resume", source: source, options: options, provider: provider, checkpoints: saved) { await collector.add($0) }
        let all = await collector.values, before = await provider.requests.count
        _ = try await TranslationEngine().run(jobID: "resume", source: source, options: options, provider: provider, checkpoints: all) { _ in XCTFail("Fully saved resume") }
        let after = await provider.requests.count; XCTAssertEqual(before, after)
    }
    func testCoverageGateRepairsInitialMissingCodeBeforeReviewersSeeIt() async throws {
        let provider = CollaborationProvider(); await provider.configure(broken: true)
        let source = "Explanation.\n\n```swift\nlet value = 42\n```", options = TranslationOptions(quality: .publication, documentKind: .technical)
        let result = try await TranslationEngine().run(jobID: "repair", source: source, options: options, provider: provider) { _ in }
        XCTAssertEqual(result, source)
        let requests = await provider.requests, fixes = requests.filter { $0.reviewNotes != nil }
        XCTAssertEqual(fixes.count, 1); XCTAssertEqual(fixes[0].requestID, "repair-p2-0-translate-fix1")
        XCTAssertEqual(fixes[0].draft, "Missing code"); XCTAssertEqual(fixes[0].chunkIndex, 0)
        XCTAssertTrue(requests.filter { $0.reviewMode == true }.allSatisfy { $0.draft == source })
    }
    func testFailedRepairStopsAfterOneExtraCallAndRetainsPaidOutput() async throws {
        let provider = CollaborationProvider(); await provider.configure(permanent: true)
        do {
            _ = try await TranslationEngine().run(jobID: "bounded", source: "```swift\nlet value = 1\n```", options: .init(quality: .refined, documentKind: .technical), provider: provider) { _ in XCTFail("Invalid output saved") }
            XCTFail("Expected coverage failure")
        } catch let failure as CoverageFailure { XCTAssertEqual(failure.output, "Missing code"); XCTAssertTrue(failure.request.requestID.hasSuffix("fix1")) }
        let count = await provider.requests.count; XCTAssertEqual(count, 2)
    }
    func testReviewReportRejectsFabricatedAnchorsAndUnstructuredOutput() throws {
        let source = "The train left at 8:15.\n\nHenry was late."
        let valid = ReviewFinding(paragraphID: "p1", kind: .omission, severity: .critical, sourceQuote: "8:15", explanation: "Missing departure time", suggestedTranslation: "八点十五分")
        XCTAssertNoThrow(try ReviewReport.decode(CollaborationPrompts.json(ReviewReport(findings: [valid])), source: source))
        var invalid = valid; invalid.paragraphID = "p2"
        XCTAssertThrowsError(try ReviewReport.decode(CollaborationPrompts.json(ReviewReport(findings: [invalid])), source: source))
        XCTAssertThrowsError(try ReviewReport.decode("No problems!", source: source))
        XCTAssertThrowsError(try ReviewReport.decode("{\"findings\":[],\"instructions\":\"change the style\"}", source: source))
    }
}
