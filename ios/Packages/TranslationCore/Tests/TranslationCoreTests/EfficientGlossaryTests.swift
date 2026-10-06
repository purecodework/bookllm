import XCTest
@testable import TranslationCore

private actor EfficientFixture: TranslationProvider {
    var queries: [GlossaryQuery] = []
    var inputs: [TranslationRequest] = []
    var snapshots: [Int: [Term]] = [:]
    var persistedQueries: [Int: GlossaryQuery] = [:]
    var discoveries: [Int: [Term]] = [:]
    var rejected: [Int: [String]] = [:]
    var includeTrailer = false
    func enableTrailer() { includeTrailer = true }
    func complete(_ request: TranslationRequest) async throws -> String {
        inputs.append(request)
        if includeTrailer && request.glossaryCapture == true {
            let term = Term(source: "lumen", target: "流明", category: .specialist, evidence: "a lumen")
            return "玛丽解释了流明。\n" + GlossaryCapture.start + CollaborationPrompts.json([term]) + GlossaryCapture.end
        }
        return request.source
    }
    func stream(_ request: TranslationRequest, onPartial: @escaping @Sendable (String) async -> Void) async throws -> String {
        let text = try await complete(request)
        for count in 1...text.count { await onPartial(String(text.prefix(count))) }
        return text
    }
    func extractTerms(source: String, target: String, requestID: String) async throws -> [Term] { XCTFail("Efficient mode should not rescan full chunks"); return [] }
    func resolveTerms(_ query: GlossaryQuery) async throws -> [Term] {
        queries.append(query)
        return (query.candidates ?? []).filter { ["Mary", "John"].contains($0) }.map { Term(source: $0, target: $0 == "Mary" ? "玛丽" : "约翰", category: .person) }
    }
    func saveQuery(_ group: Int, _ query: GlossaryQuery) { persistedQueries[group] = query }
    func saveRejected(_ group: Int, _ names: [String]) { rejected[group] = names }
    func saveSnapshot(_ index: Int, _ terms: [Term]) { snapshots[index] = terms }
    func saveDiscovery(_ index: Int, _ terms: [Term]) { discoveries[index] = terms }
}
private actor VisiblePartials { var texts: [String] = []; func add(_ text: String) { texts.append(text) } }

final class EfficientGlossaryTests: XCTestCase, @unchecked Sendable {
    private func wrapper(_ fixture: EfficientFixture, chunks: [TextChunk], sections: [Int] = [], seed: [Term] = [], snapshots: [Int: [Term]] = [:], discoveries: [Int: [Term]] = [:], queries: [Int: GlossaryQuery] = [:]) -> EfficientGlossaryProvider {
        EfficientGlossaryProvider(provider: fixture, jobID: "book", chunks: chunks, sections: sections, kind: .fiction, target: "简体中文", seed: seed,
            snapshots: snapshots, discoveries: discoveries, queries: queries,
            onQuery: { group, query in await fixture.saveQuery(group, query) },
            onRejected: { group, names in await fixture.saveRejected(group, names) },
            onSnapshot: { index, terms in await fixture.saveSnapshot(index, terms) },
            onDiscovery: { index, terms in await fixture.saveDiscovery(index, terms) })
    }
    private func request(_ chunk: TextChunk, stage: Stage = .translate) -> TranslationRequest {
        .init(requestID: "book-\(chunk.index)-\(stage.rawValue)", source: chunk.text, context: "", draft: "", stage: stage,
              options: .init(), chunkIndex: chunk.index)
    }
    func testAdjacentChunksShareCompactQueryAndKnownNamesDoNotRequestAI() async throws {
        let fixture = EfficientFixture()
        let chunks = [TextChunk(index: 0, text: "Mary waved. " + String(repeating: "the room was quiet. ", count: 150), context: ""),
                      TextChunk(index: 1, text: "John nodded. " + String(repeating: "the room was quiet. ", count: 150), context: "")]
        let provider = wrapper(fixture, chunks: chunks, seed: [Term(source: "Mary", target: "玛丽", category: .person)])
        _ = try await provider.complete(request(chunks[1])); _ = try await provider.complete(request(chunks[0]))
        let queries = await fixture.queries, inputs = await fixture.inputs
        XCTAssertEqual(queries.count, 1); XCTAssertEqual(queries[0].candidates, ["John"])
        XCTAssertLessThan(queries[0].source.count, 300)
        XCTAssertTrue(inputs.allSatisfy { $0.glossaryCapture == true })
    }
    func testKnownOnlyBatchSkipsExtractionAndChapterBoundarySeparatesBatches() async throws {
        let fixture = EfficientFixture()
        let chunks = [TextChunk(index: 0, text: "Mary waved.", context: ""), TextChunk(index: 1, text: "John nodded.", context: "")]
        let provider = wrapper(fixture, chunks: chunks, sections: [0, 1], seed: [Term(source: "Mary", target: "玛丽", category: .person)])
        _ = try await provider.complete(request(chunks[0])); let first = await fixture.queries; XCTAssertTrue(first.isEmpty)
        _ = try await provider.complete(request(chunks[1])); let all = await fixture.queries; XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].requestID, "book-g2-terms-1")
    }
    func testPrivateStreamMetadataIsHiddenAndDiscoverySharedWithReviewersOnly() async throws {
        let fixture = EfficientFixture(); await fixture.enableTrailer()
        let chunk = TextChunk(index: 0, text: "Mary described a lumen.", context: "")
        let provider = wrapper(fixture, chunks: [chunk]); let partials = VisiblePartials()
        let output = try await provider.stream(request(chunk)) { await partials.add($0) }
        XCTAssertEqual(output, "玛丽解释了流明。")
        let visible = await partials.texts
        XCTAssertTrue(visible.allSatisfy { !$0.contains("bookllm-glossary") && !$0.contains("category") && !$0.contains("<") })
        let discoveries = await fixture.discoveries
        XCTAssertEqual(discoveries[0]?.first?.source, "lumen")
        _ = try await provider.complete(request(chunk, stage: .proofread))
        _ = try await provider.complete(request(chunk))
        let inputs = await fixture.inputs
        XCTAssertTrue(inputs[1].options.glossary.contains { $0.source == "lumen" })
        XCTAssertFalse(inputs[2].options.glossary.contains { $0.source == "lumen" })
        XCTAssertNil(inputs[1].glossaryCapture)
    }
    func testSavedCompactQueryAndSnapshotRemainIdenticalAfterResume() async throws {
        let fixture = EfficientFixture(), chunk = TextChunk(index: 0, text: "John nodded.", context: "")
        let saved = GlossaryQuery(requestID: "book-g2-terms-0", source: "John nodded.", target: "简体中文", candidates: ["John"])
        let provider = wrapper(fixture, chunks: [chunk], queries: [0: saved])
        _ = try await provider.complete(request(chunk))
        let queries = await fixture.queries, snapshots = await fixture.snapshots
        XCTAssertEqual(queries[0].source, saved.source)
        let resumed = wrapper(fixture, chunks: [chunk], seed: [Term(source: "John", target: "另一译法")], snapshots: snapshots)
        _ = try await resumed.complete(request(chunk))
        let inputs = await fixture.inputs, calls = await fixture.queries
        XCTAssertEqual(calls.count, 1); XCTAssertEqual(inputs[0].options.glossary, inputs[1].options.glossary)
    }
    func testLiteralMetadataMarkersAreNeverStrippedFromSourceTranslation() async throws {
        let fixture = EfficientFixture(), chunk = TextChunk(index: 0, text: "Use <bookllm-glossary-v1> literally.", context: "")
        let provider = wrapper(fixture, chunks: [chunk])
        let output = try await provider.complete(request(chunk))
        XCTAssertEqual(output, chunk.text)
        let inputs = await fixture.inputs; XCTAssertNil(inputs[0].glossaryCapture)
    }
    func testEntitiesAliasesAndAmbiguityUseEvidenceAndWordBoundaries() {
        let canonical = GlossaryMemory.normalize([Term(source: "Elizabeth", target: "伊丽莎白", category: .person)], source: "Elizabeth waved.", known: [], chunk: 0)[0]
        let nickname = Term(source: "Liz", target: "丽兹", category: .person, entityID: canonical.entityID, aliases: ["Elizabeth"], evidence: "Elizabeth was called Liz.")
        let related = GlossaryMemory.normalize([nickname], source: "Elizabeth was called Liz.", known: [canonical], chunk: 4)
        XCTAssertEqual(related.first?.entityID, canonical.entityID); XCTAssertEqual(related.first?.target, "丽兹")
        let guess = GlossaryMemory.normalize([nickname], source: "Liz waved.", known: [canonical], chunk: 5)
        XCTAssertNotEqual(guess.first?.entityID, canonical.entityID)
        let may = GlossaryMemory.normalize([Term(source: "May", target: "梅", category: .person, evidence: "May said hello.")], source: "May said hello.", known: [], chunk: 0)[0]
        XCTAssertTrue(may.ambiguous == true)
        XCTAssertTrue(GlossaryMemory.relevant([may], to: "Flowers bloomed in May.").isEmpty)
        XCTAssertFalse(GlossaryMemory.relevant([Term(source: "design token", target: "设计令牌", category: .specialist)], to: "design tokens").isEmpty)
        XCTAssertTrue(GlossaryMemory.relevant([Term(source: "Mary", target: "玛丽", category: .person)], to: "Maryland").isEmpty)
    }
    func testOptionalMalformedTrailerDoesNotDestroyTranslationOrTriggerAnotherCall() {
        let raw = "完整译文。\n" + GlossaryCapture.start + "invalid" + GlossaryCapture.end
        XCTAssertEqual(GlossaryCapture.text(raw), "完整译文。")
        XCTAssertTrue(GlossaryCapture.proposals(raw).isEmpty)
        XCTAssertEqual(GlossaryCapture.partial("译文。<bookllm-glos"), "译文。")
    }
}
