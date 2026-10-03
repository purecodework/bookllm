import XCTest
@testable import TranslationCore

actor FakeProvider: TranslationProvider {
    var calls = 0
    var live = 0
    var peak = 0
    var glossarySizes: [Int] = []
    func complete(_ request: TranslationRequest) async throws -> String {
        glossarySizes.append(request.options.glossary.count)
        calls += 1; live += 1; peak = max(peak, live)
        defer { live -= 1 }
        try await Task.sleep(for: .milliseconds(request.source.hasPrefix("A") ? 30 : 2))
        return request.stage == .translate ? request.source : request.draft
    }
    func extractTerms(source: String, target: String, requestID: String) async throws -> [Term] { [] }
}
actor Collector {
    var values: [Checkpoint] = []
    func add(_ value: Checkpoint) { values.append(value) }
}
actor StreamingFake: TranslationProvider {
    func complete(_ request: TranslationRequest) async throws -> String { "final" }
    func stream(_ request: TranslationRequest, onPartial: @escaping @Sendable (String) async -> Void) async throws -> String {
        await onPartial("fir"); try await Task.sleep(for: .milliseconds(5)); await onPartial("first"); return "first"
    }
    func extractTerms(source: String, target: String, requestID: String) async throws -> [Term] { [] }
}
actor StreamEvents { var events: [String] = []; func add(_ text: String) { events.append(text) } }
final class EngineTests: XCTestCase, @unchecked Sendable {
    func testLosslessUnicodeAndBudget() {
        let source = String(repeating: "Alice 👨‍👩‍👧‍👦 walked. 她走向图书馆。\n\n", count: 500)
        let chunks = Chunker.split(source, budget: 120)
        XCTAssertEqual(chunks.map(\.text).joined(), source)
        XCTAssertTrue(chunks.allSatisfy { $0.text.reduce(0) { $0 + Chunker.tokenCost($1) } <= 120.01 })
        XCTAssertEqual(chunks[1].context, String(chunks[0].text.suffix(350)))
    }
    func testLongUnbrokenInput() {
        let source = String(repeating: "漢", count: 12001)
        XCTAssertEqual(Chunker.split(source).map(\.text).joined(), source)
        XCTAssertEqual(Chunker.split(" \n ").count, 0)
    }
    func testParallelOrderingAndStageCheckpointResume() async throws {
        let source = "A" + String(repeating: "x", count: 18000)
        let chunks = Chunker.split(source)
        let provider = FakeProvider(), collector = Collector()
        let options = TranslationOptions(quality: .publication)
        let result = try await TranslationEngine().run(jobID: "one", source: source, options: options, provider: provider) { await collector.add($0) }
        XCTAssertEqual(result, chunks.map(\.text).joined(separator: "\n\n"))
        let calls = await provider.calls, peak = await provider.peak
        XCTAssertEqual(calls, chunks.count * 4)
        XCTAssertGreaterThan(peak, 1); XCTAssertLessThanOrEqual(peak, 3)
        let saved = await collector.values
        _ = try await TranslationEngine().run(jobID: "one", source: source, options: options, provider: provider, checkpoints: saved) { _ in XCTFail("Resume should reuse results") }
        let resumedCalls = await provider.calls
        XCTAssertEqual(resumedCalls, calls)
    }
    func testCancellationStopsPipeline() async throws {
        let task = Task { try await TranslationEngine().run(jobID: "cancel", source: String(repeating: "a", count: 20000), options: .init(), provider: FakeProvider()) { _ in } }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { } catch { XCTFail("Unexpected \(error)") }
    }
    func testPointEstimateIncludesEveryPass() {
        let source = "hello"
        XCTAssertEqual(Chunker.points(source: source, quality: .publication, glossary: true), 5)
        XCTAssertEqual(Chunker.points(source: source, quality: .fast, glossary: false), 1)
    }
    func testAdaptiveWindow() async {
        let throughput = Throughput(maximum: 4)
        for _ in 0..<6 { await throughput.succeeded() }
        let high = await throughput.current(); XCTAssertEqual(high, 4)
        await throughput.throttled()
        let low = await throughput.current(); XCTAssertEqual(low, 2)
    }
    func testPreferencesReachLanguageExpertAndPrompt() {
        var preferences = TranslationPreferences()
        preferences.extraLanguageReview = true; preferences.foreignText = .preserve
        preferences.annotations = .cultural; preferences.sparseNotes = false
        let options = TranslationOptions(quality: .refined, preferences: preferences)
        XCTAssertEqual(options.stages, [.translate, .proofread, .linguist])
        let request = TranslationRequest(requestID: "p", source: "bonjour", context: "", draft: "你好", stage: .linguist, options: options)
        XCTAssertTrue(request.prompt.contains("Preserve passages"))
        XCTAssertTrue(request.prompt.contains("at most 3"))
        XCTAssertTrue(request.prompt.contains("[编者注"))
        XCTAssertTrue(request.prompt.contains("remove uncertain claims"))
        XCTAssertEqual(TranslationOptions(quality: .publication).stages.last, .editor)
    }
    func testOnlyRelevantGlossaryTravelsWithChunk() async throws {
        let provider = FakeProvider()
        let options = TranslationOptions(quality: .fast, glossary: [.init(source: "Alice", target: "爱丽丝"), .init(source: "Bob", target: "鲍勃")])
        _ = try await TranslationEngine().run(jobID: "glossary", source: "Alice reads.", options: options, provider: provider) { _ in }
        let sizes = await provider.glossarySizes
        XCTAssertEqual(sizes, [1])
    }

    func testFastStreamsBeforeFinalCheckpoint() async throws {
        let events = StreamEvents()
        let result = try await TranslationEngine().run(jobID: "live", source: "source", options: .init(quality: .fast), provider: StreamingFake(), onPartial: { _, text in await events.add("partial:" + text) }) { checkpoint in await events.add("saved:" + checkpoint.text) }
        XCTAssertEqual(result, "first")
        let seen = await events.events
        XCTAssertEqual(seen, ["partial:", "partial:fir", "partial:first", "saved:first"])
    }
    func testRefinedNeverPublishesIntermediateDraftPartials() async throws {
        let events = StreamEvents()
        _ = try await TranslationEngine().run(jobID: "review", source: "source", options: .init(quality: .refined), provider: StreamingFake(), onPartial: { _, text in await events.add(text) }) { _ in }
        let seen = await events.events
        XCTAssertTrue(seen.isEmpty)
    }

}
