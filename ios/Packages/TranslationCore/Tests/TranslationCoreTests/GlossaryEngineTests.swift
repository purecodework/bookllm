import XCTest
@testable import TranslationCore

private actor GlossaryTestProvider: TranslationProvider {
    struct Call: Sendable {
        let source: String
        let target: String
        let requestID: String
    }
    var calls: [Call] = []
    var live = 0
    var peak = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let delays: [String: Duration]
    private let defaultDelay: Duration
    private let failingSource: String?
    private let retryOnce: Bool

    init(delays: [String: Duration] = [:], defaultDelay: Duration = .milliseconds(15), failingSource: String? = nil, retryOnce: Bool = false) {
        self.delays = delays; self.defaultDelay = defaultDelay
        self.failingSource = failingSource; self.retryOnce = retryOnce
    }
    func complete(_ request: TranslationRequest) async throws -> String { request.source }
    func extractTerms(source: String, target: String, requestID: String) async throws -> [Term] {
        calls.append(Call(source: source, target: target, requestID: requestID))
        live += 1; peak = max(peak, live)
        defer { live -= 1 }
        let started = waiters; waiters = []; started.forEach { $0.resume() }
        let attempt = calls.filter { $0.source == source }.count
        if source == failingSource {
            if !retryOnce { throw TranslationError.message("Extraction failed") }
            if attempt == 1 { throw TranslationError.rateLimited(0) }
        }
        try await Task.sleep(for: delays[source] ?? defaultDelay)
        return [.init(source: source, target: "译：\(source)")]
    }
    func waitUntilStarted() async {
        if calls.isEmpty { await withCheckedContinuation { waiters.append($0) } }
    }
}

private actor GlossaryBatchCollector {
    var batches: [(Int, [Term])] = []
    func add(_ index: Int, _ terms: [Term]) { batches.append((index, terms)) }
}

final class GlossaryEngineTests: XCTestCase, @unchecked Sendable {
    func testParallelCompletionKeepsOriginalBatchIndicesAndRequestIDs() async throws {
        let provider = GlossaryTestProvider(delays: ["zero": .milliseconds(100), "one": .milliseconds(5), "two": .milliseconds(5)])
        let collector = GlossaryBatchCollector()
        let batches = ["zero", "one", "two", "three", "four", "five"]
        try await GlossaryEngine().run(jobID: "book", batches: batches, target: "简体中文", provider: provider) { index, terms in
            await collector.add(index, terms)
        }
        let results = await collector.batches
        XCTAssertEqual(results.first?.0, 1)
        XCTAssertEqual(Set(results.map { $0.0 }), Set(batches.indices))
        XCTAssertEqual(results.count, batches.count)
        for (index, terms) in results { XCTAssertEqual(terms, [.init(source: batches[index], target: "译：\(batches[index])")]) }
        let calls = await provider.calls
        XCTAssertEqual(Set(calls.map(\.requestID)), Set(batches.indices.map { "book-terms-\($0)" }))
        XCTAssertTrue(calls.allSatisfy { $0.target == "简体中文" })
        let peak = await provider.peak
        XCTAssertGreaterThanOrEqual(peak, 2)
        XCTAssertLessThanOrEqual(peak, 4)
    }

    func testAdaptiveWindowGrowsButRemainsBounded() async throws {
        let provider = GlossaryTestProvider(defaultDelay: .milliseconds(25))
        let collector = GlossaryBatchCollector()
        let batches = (0..<24).map { "batch-\($0)" }
        try await GlossaryEngine().run(jobID: "long", batches: batches, target: "中文", provider: provider) { index, terms in
            await collector.add(index, terms)
        }
        let peak = await provider.peak, calls = await provider.calls, results = await collector.batches
        XCTAssertEqual(peak, 4)
        XCTAssertEqual(calls.count, batches.count)
        XCTAssertEqual(results.count, batches.count)
    }

    func testResumeSkipsNoncontiguousCompletedBatches() async throws {
        let provider = GlossaryTestProvider(), collector = GlossaryBatchCollector()
        let batches = (0..<7).map { "batch-\($0)" }
        try await GlossaryEngine().run(jobID: "resume", batches: batches, target: "中文", provider: provider, completed: [0, 2, 5, 99]) { index, terms in
            await collector.add(index, terms)
        }
        let calls = await provider.calls, results = await collector.batches
        XCTAssertEqual(Set(calls.map(\.source)), ["batch-1", "batch-3", "batch-4", "batch-6"])
        XCTAssertEqual(Set(results.map { $0.0 }), [1, 3, 4, 6])
        XCTAssertEqual(Set(calls.map(\.requestID)), ["resume-terms-1", "resume-terms-3", "resume-terms-4", "resume-terms-6"])
    }

    func testAlreadyCompletedOrEmptyRunDoesNotCallProvider() async throws {
        let provider = GlossaryTestProvider()
        try await GlossaryEngine().run(jobID: "cached", batches: ["a", "b"], target: "中文", provider: provider, completed: [0, 1]) { _, _ in XCTFail("Cached batches must not emit callbacks") }
        try await GlossaryEngine().run(jobID: "empty", batches: [], target: "中文", provider: provider) { _, _ in XCTFail("Empty input must not emit callbacks") }
        let calls = await provider.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testRateLimitRetriesSameBatchAndEmitsOneCheckpoint() async throws {
        let provider = GlossaryTestProvider(failingSource: "retry", retryOnce: true), collector = GlossaryBatchCollector()
        try await GlossaryEngine().run(jobID: "retry", batches: ["retry", "normal", "last"], target: "中文", provider: provider) { index, terms in
            await collector.add(index, terms)
        }
        let calls = await provider.calls, results = await collector.batches, peak = await provider.peak
        XCTAssertEqual(calls.filter { $0.source == "retry" }.count, 2)
        XCTAssertTrue(calls.filter { $0.source == "retry" }.allSatisfy { $0.requestID == "retry-terms-0" })
        XCTAssertEqual(results.filter { $0.0 == 0 }.count, 1)
        XCTAssertEqual(Set(results.map { $0.0 }), [0, 1, 2])
        XCTAssertLessThanOrEqual(peak, 4)
    }

    func testCancellationStopsInFlightExtraction() async throws {
        let provider = GlossaryTestProvider(defaultDelay: .seconds(10)), collector = GlossaryBatchCollector()
        let task = Task {
            try await GlossaryEngine().run(jobID: "cancel", batches: (0..<20).map { "batch-\($0)" }, target: "中文", provider: provider) { index, terms in
                await collector.add(index, terms)
            }
        }
        await provider.waitUntilStarted()
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        let calls = await provider.calls, results = await collector.batches, live = await provider.live
        XCTAssertLessThanOrEqual(calls.count, 2)
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(live, 0)
    }

    func testProviderFailurePropagatesAndCancelsOtherWork() async throws {
        let provider = GlossaryTestProvider(defaultDelay: .seconds(10), failingSource: "fail")
        do {
            try await GlossaryEngine().run(jobID: "fail", batches: ["fail", "waiting", "never"], target: "中文", provider: provider) { _, _ in XCTFail("No successful batch expected") }
            XCTFail("Expected failure")
        } catch TranslationError.message(let message) { XCTAssertEqual(message, "Extraction failed") }
        catch { XCTFail("Unexpected error: \(error)") }
        let calls = await provider.calls, live = await provider.live
        XCTAssertFalse(calls.contains { $0.source == "never" })
        XCTAssertEqual(live, 0)
    }

    func testCheckpointFailurePropagatesAndCancelsOtherWork() async throws {
        let provider = GlossaryTestProvider()
        do {
            try await GlossaryEngine().run(jobID: "storage", batches: (0..<20).map { "batch-\($0)" }, target: "中文", provider: provider) { _, _ in
                throw TranslationError.message("Storage failed")
            }
            XCTFail("Expected checkpoint failure")
        } catch TranslationError.message(let message) { XCTAssertEqual(message, "Storage failed") }
        catch { XCTFail("Unexpected error: \(error)") }
        let calls = await provider.calls, live = await provider.live
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(live, 0)
    }
}
