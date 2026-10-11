import XCTest
@testable import TranslationCore

private actor IncrementalTermsFixture: TranslationProvider {
    var events: [String] = []
    var requests: [TranslationRequest] = []
    var extractionIDs: [String] = []
    var failFirst = false
    func failNextExtraction() { failFirst = true }
    func persisted(_ index: Int) { events.append("saved-\(index)") }
    func complete(_ request: TranslationRequest) async throws -> String {
        events.append("translated-\(request.chunkIndex ?? -1)")
        requests.append(request)
        return request.source
    }
    func stream(_ request: TranslationRequest, onPartial: @escaping @Sendable (String) async -> Void) async throws -> String {
        let result = try await complete(request); await onPartial(result); return result
    }
    func extractTerms(source: String, target: String, requestID: String) async throws -> [Term] {
        extractionIDs.append(requestID)
        if failFirst { failFirst = false; throw TranslationError.message("Extraction interrupted") }
        try await Task.sleep(for: .milliseconds(10))
        return [Term(source: "Mary", target: source.contains("FIRST") ? "玛丽" : "玛莉"),
                Term(source: "Ghost", target: source.contains("FIRST") ? "猜译" : "幽灵")]
    }
}

final class IncrementalGlossaryTests: XCTestCase, @unchecked Sendable {
    private let chunks = [TextChunk(index: 0, text: "FIRST Mary", context: ""), TextChunk(index: 1, text: "SECOND Mary", context: "")]
    private func request(_ index: Int, stage: Stage = .translate) -> TranslationRequest {
        TranslationRequest(requestID: "book-p2-\(index)-\(stage.rawValue)", source: chunks[index].text,
            context: "", draft: "", stage: stage, options: TranslationOptions(), chunkIndex: index)
    }
    private func wrapper(_ provider: IncrementalTermsFixture, seed: [Term] = [], snapshots: [Int: [Term]] = [:]) -> IncrementalGlossaryProvider {
        IncrementalGlossaryProvider(provider: provider, jobID: "book", chunks: chunks, target: "简体中文",
            seed: seed, snapshots: snapshots) { index, _ in await provider.persisted(index) }
    }
    func testOutOfOrderWorkersUseFirstSourceTranslationAndPersistBeforeDispatch() async throws {
        let fixture = IncrementalTermsFixture(), provider = wrapper(fixture)
        _ = try await provider.complete(request(1))
        _ = try await provider.complete(request(0, stage: .proofread))
        let calls = await fixture.requests, events = await fixture.events, ids = await fixture.extractionIDs
        XCTAssertEqual(ids, ["book-incremental-terms-0", "book-incremental-terms-1"])
        XCTAssertEqual(calls.map { $0.options.glossary }, [[Term(source: "Mary", target: "玛丽")], [Term(source: "Mary", target: "玛丽")]])
        XCTAssertEqual(events, ["saved-0", "saved-1", "translated-1", "translated-0"])
    }
    func testConcurrentReviewersSharePreparationAndPersonalTranslationWins() async throws {
        let fixture = IncrementalTermsFixture(), provider = wrapper(fixture, seed: [Term(source: "Mary", target: "玛利")])
        async let proof = provider.complete(request(0, stage: .proofread))
        async let language = provider.complete(request(0, stage: .linguist))
        _ = try await (proof, language)
        let calls = await fixture.requests, ids = await fixture.extractionIDs
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(Set(calls.map(\.stage)), [.proofread, .linguist])
        XCTAssertTrue(calls.allSatisfy { $0.options.glossary == [Term(source: "Mary", target: "玛利")] })
    }
    func testResumeAndStreamReuseExactSnapshotWithoutExtraction() async throws {
        let fixture = IncrementalTermsFixture()
        let snapshot = [Term(source: "Mary", target: "玛丽")]
        let provider = wrapper(fixture, seed: [Term(source: "Mary", target: "另一个译名")], snapshots: [0: snapshot])
        _ = try await provider.stream(request(0)) { _ in }
        _ = try await provider.complete(request(0, stage: .editor))
        let calls = await fixture.requests, ids = await fixture.extractionIDs
        XCTAssertTrue(ids.isEmpty)
        XCTAssertTrue(calls.allSatisfy { $0.options.glossary == snapshot })
    }
    func testFailedPredecessorBlocksLaterTranslationAndAllowsRetry() async throws {
        let fixture = IncrementalTermsFixture(), provider = wrapper(fixture)
        await fixture.failNextExtraction()
        do { _ = try await provider.complete(request(1)); XCTFail("Should stop before translation") }
        catch { }
        let before = await fixture.requests
        XCTAssertTrue(before.isEmpty)
        _ = try await provider.complete(request(1))
        let after = await fixture.requests
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].options.glossary, [Term(source: "Mary", target: "玛丽")])
    }
    func testOnlyThreeModesAreOfferedAndLegacyModeStillDecodes() throws {
        XCTAssertEqual(GlossaryMode.allCases, [.accumulated, .automatic, .review])
        XCTAssertEqual(try JSONDecoder().decode(GlossaryMode.self, from: Data("\"custom\"".utf8)), .custom)
    }
    func testSuggestionsAbsentFromSourceCannotSeedFutureChunks() async throws {
        let fixture = IncrementalTermsFixture()
        let later = TextChunk(index: 1, text: "SECOND Mary Ghost", context: "")
        let provider = IncrementalGlossaryProvider(provider: fixture, jobID: "book", chunks: [chunks[0], later],
            target: "简体中文", seed: []) { index, _ in await fixture.persisted(index) }
        _ = try await provider.complete(request(0))
        var second = request(1); second.source = later.text
        _ = try await provider.complete(second)
        let calls = await fixture.requests
        XCTAssertEqual(calls[1].options.glossary.first { $0.source == "Ghost" }?.target, "幽灵")
    }
}
