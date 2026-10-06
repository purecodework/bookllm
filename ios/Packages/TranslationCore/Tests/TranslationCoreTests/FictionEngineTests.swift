import XCTest
@testable import TranslationCore

private func fictionTag(index: Int, stage: Stage) -> String { "[DRAFT-\(stage.rawValue)-\(index)]" }
private func fictionIndex(_ request: TranslationRequest) -> Int {
    Int(request.requestID.split(separator: "-").dropLast().last ?? "") ?? -1
}
private func scalarHead(_ text: String, _ count: Int) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.prefix(count)))
}
private func scalarTail(_ text: String, _ count: Int) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.suffix(count)))
}

private actor FictionTrace {
    var events: [String] = []
    var checkpoints: [Checkpoint] = []
    func event(_ value: String) { events.append(value) }
    func save(_ checkpoint: Checkpoint) {
        checkpoints.append(checkpoint)
        events.append("save:\(checkpoint.index)-\(checkpoint.stage.rawValue)")
    }
}

private actor FictionRecordingProvider: TranslationProvider {
    var requests: [TranslationRequest] = []
    var streamCalls = 0
    var live = 0
    var peak = 0
    private let trace: FictionTrace
    private let delays: [String: Duration]
    private let defaultDelay: Duration
    private let failingID: String?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(trace: FictionTrace, delays: [String: Duration] = [:], defaultDelay: Duration = .milliseconds(3), failingID: String? = nil) {
        self.trace = trace; self.delays = delays; self.defaultDelay = defaultDelay; self.failingID = failingID
    }
    func complete(_ request: TranslationRequest) async throws -> String {
        requests.append(request)
        live += 1; peak = max(peak, live)
        defer { live -= 1 }
        let started = waiters; waiters = []; started.forEach { $0.resume() }
        await trace.event("start:" + request.requestID)
        if request.requestID == failingID { throw TranslationError.message("Provider failed") }
        try await Task.sleep(for: delays[request.requestID] ?? defaultDelay)
        await trace.event("done:" + request.requestID)
        return fictionTag(index: fictionIndex(request), stage: request.stage)
    }
    func stream(_ request: TranslationRequest, onPartial: @escaping @Sendable (String) async -> Void) async throws -> String {
        streamCalls += 1
        throw TranslationError.message("FictionEngine must use complete")
    }
    func extractTerms(source: String, target: String, requestID: String) async throws -> [Term] { [] }
    func waitUntilStarted() async {
        if requests.isEmpty { await withCheckedContinuation { waiters.append($0) } }
    }
}

final class FictionEngineTests: XCTestCase, @unchecked Sendable {
    /// Each paragraph fits by itself and two exceed the default fiction budget.
    /// This exercises the engine's actual import-time plan without a test-only budget.
    private func source(firstChapterChunks: Int = 3, secondChapterChunks: Int = 2) -> String {
        func chapter(_ title: String, number: Int, count: Int, character: String) -> String {
            title + "\n\n" + (0..<count).map { index in
                "[SOURCE-\(number)-\(index)-BEGIN]" + String(repeating: character, count: 1_000) + "[SOURCE-\(number)-\(index)-END]。\n\n"
            }.joined()
        }
        return chapter("Chapter I: The River", number: 1, count: firstChapterChunks, character: "甲") +
            chapter("Chapter II: The Mountain", number: 2, count: secondChapterChunks, character: "乙")
    }

    func testAllChunksFinishAndPersistBeforeNextStageAndChapter() async throws {
        let source = self.source(), plan = Chunker.plan(text: source, kind: .fiction)
        XCTAssertEqual(plan.sections.count, 2)
        XCTAssertEqual(plan.sectionForChunk.filter { $0 == 0 }.count, 3)
        XCTAssertEqual(plan.sectionForChunk.filter { $0 == 1 }.count, 2)
        let trace = FictionTrace()
        let provider = FictionRecordingProvider(trace: trace, delays: ["barrier-0-translate": .milliseconds(70), "barrier-1-translate": .milliseconds(5)])
        let result = try await FictionEngine().run(jobID: "barrier", source: source, options: .init(quality: .publication, pipelineVersion: nil), provider: provider) {
            await trace.save($0)
        }
        let events = await trace.events, checkpoints = await trace.checkpoints
        let requests = await provider.requests, peak = await provider.peak
        XCTAssertEqual(result, plan.chunks.map { fictionTag(index: $0.index, stage: .editor) }.joined(separator: "\n\n"))
        XCTAssertEqual(requests.count, plan.chunks.count * 4)
        XCTAssertEqual(checkpoints.count, requests.count)
        XCTAssertGreaterThan(peak, 1)
        XCTAssertLessThanOrEqual(peak, Quality.publication.maxConcurrency)
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "done:barrier-1-translate")), try XCTUnwrap(events.firstIndex(of: "done:barrier-0-translate")))

        for chapter in plan.sections {
            let indices = plan.chunks.indices.filter { plan.sectionForChunk[$0] == chapter.index }
            for (previous, next) in zip(Quality.publication.stages, Quality.publication.stages.dropFirst()) {
                let persisted = try indices.map { try XCTUnwrap(events.firstIndex(of: "save:\($0)-\(previous.rawValue)")) }
                let started = try indices.map { try XCTUnwrap(events.firstIndex(of: "start:barrier-\($0)-\(next.rawValue)")) }
                XCTAssertLessThan(try XCTUnwrap(persisted.max()), try XCTUnwrap(started.min()))
            }
        }
        let firstChapter = plan.chunks.indices.filter { plan.sectionForChunk[$0] == 0 }
        let secondChapter = plan.chunks.indices.filter { plan.sectionForChunk[$0] == 1 }
        let chapterOneFinished = try firstChapter.map { try XCTUnwrap(events.firstIndex(of: "save:\($0)-editor")) }.max()
        let chapterTwoStarted = try secondChapter.map { try XCTUnwrap(events.firstIndex(of: "start:barrier-\($0)-translate")) }.min()
        XCTAssertLessThan(try XCTUnwrap(chapterOneFinished), try XCTUnwrap(chapterTwoStarted))
    }

    func testEveryStageUsesImmutableCompletePreviousStageNeighborDrafts() async throws {
        let source = self.source(firstChapterChunks: 6), plan = Chunker.plan(text: source, kind: .fiction)
        let trace = FictionTrace()
        let provider = FictionRecordingProvider(trace: trace, delays: [
            "snapshot-0-proofread": .milliseconds(90),
            "snapshot-1-proofread": .milliseconds(60),
            "snapshot-2-proofread": .milliseconds(5)
        ])
        let options = TranslationOptions(quality: .publication, pipelineVersion: nil)
        _ = try await FictionEngine().run(jobID: "snapshot", source: source, options: options, provider: provider) { await trace.save($0) }
        let requests = await provider.requests, events = await trace.events
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "save:2-proofread")), try XCTUnwrap(events.firstIndex(of: "start:snapshot-3-proofread")))

        for request in requests {
            let index = fictionIndex(request), stagePosition = try XCTUnwrap(options.stages.firstIndex(of: request.stage))
            XCTAssertEqual(request.source, plan.chunks[index].text)
            XCTAssertEqual(request.draft, stagePosition == 0 ? "" : fictionTag(index: index, stage: options.stages[stagePosition - 1]))
            XCTAssertTrue(request.context.contains(scalarHead(source, 1_000)))
            XCTAssertTrue(request.context.contains(plan.sections[plan.sectionForChunk[index]].title))
            XCTAssertLessThanOrEqual(request.context.unicodeScalars.count, 3_900)
            for neighbor in [index - 1, index + 1] where plan.chunks.indices.contains(neighbor) {
                let sameChapter = plan.sectionForChunk[neighbor] == plan.sectionForChunk[index]
                for stage in Quality.publication.stages {
                    let precedingChapterFinal = !sameChapter && neighbor == index - 1 && stage == options.stages.last
                    let shouldContain = precedingChapterFinal || (sameChapter && stagePosition > 0 && stage == options.stages[stagePosition - 1])
                    XCTAssertEqual(request.context.contains(fictionTag(index: neighbor, stage: stage)), shouldContain,
                                   "Unexpected \(stage.rawValue) neighbor \(neighbor) in \(request.requestID)")
                }
                if sameChapter {
                    let passage = neighbor < index ? scalarTail(plan.chunks[neighbor].text, 650) : scalarHead(plan.chunks[neighbor].text, 300)
                    XCTAssertTrue(request.context.contains(passage))
                }
            }
        }
        let afterNeighborFinished = try XCTUnwrap(requests.first { $0.requestID == "snapshot-3-proofread" })
        XCTAssertTrue(afterNeighborFinished.context.contains(fictionTag(index: 2, stage: .translate)))
        XCTAssertFalse(afterNeighborFinished.context.contains(fictionTag(index: 2, stage: .proofread)))
    }

    func testPartialResumeReusesLastCheckpointAndIdenticalPendingRequests() async throws {
        let source = self.source(), plan = Chunker.plan(text: source, kind: .fiction)
        let options = TranslationOptions(quality: .publication, pipelineVersion: nil)
        let originalTrace = FictionTrace(), originalProvider = FictionRecordingProvider(trace: originalTrace)
        let originalResult = try await FictionEngine().run(jobID: "resume", source: source, options: options, provider: originalProvider) { await originalTrace.save($0) }
        let originalRequests = await originalProvider.requests, saved = await originalTrace.checkpoints
        let reusable = saved.filter { $0.stage == .translate || ($0.stage == .proofread && [0, 2].contains($0.index)) }
        let cache = [Checkpoint(index: 0, stage: .translate, text: "STALE CHECKPOINT")] + reusable
        let resumedTrace = FictionTrace(), resumedProvider = FictionRecordingProvider(trace: resumedTrace)
        let resumedResult = try await FictionEngine().run(jobID: "resume", source: source, options: options, provider: resumedProvider, checkpoints: cache) { await resumedTrace.save($0) }
        let resumedRequests = await resumedProvider.requests, emitted = await resumedTrace.checkpoints

        XCTAssertEqual(resumedResult, originalResult)
        XCTAssertEqual(resumedResult, plan.chunks.map { fictionTag(index: $0.index, stage: .editor) }.joined(separator: "\n\n"))
        XCTAssertEqual(resumedRequests.count, originalRequests.count - reusable.count)
        XCTAssertEqual(emitted.count, resumedRequests.count)
        for checkpoint in emitted {
            XCTAssertFalse(reusable.contains { $0.index == checkpoint.index && $0.stage == checkpoint.stage })
        }
        for request in resumedRequests {
            let original = try XCTUnwrap(originalRequests.first { $0.requestID == request.requestID })
            XCTAssertEqual(request.source, original.source)
            XCTAssertEqual(request.stage, original.stage)
            XCTAssertEqual(request.context, original.context)
            XCTAssertEqual(request.draft, original.draft)
            XCTAssertEqual(request.options, original.options)
            XCTAssertFalse(request.context.contains("STALE CHECKPOINT"))
        }
    }

    func testFullResumeDoesNotRequestOrRepublishCachedResults() async throws {
        let source = self.source(), plan = Chunker.plan(text: source, kind: .fiction)
        let trace = FictionTrace(), provider = FictionRecordingProvider(trace: trace)
        let checkpoints = plan.chunks.flatMap { chunk in
            Quality.publication.stages.map { Checkpoint(index: chunk.index, stage: $0, text: fictionTag(index: chunk.index, stage: $0)) }
        }
        let result = try await FictionEngine().run(jobID: "cached", source: source, options: .init(quality: .publication, pipelineVersion: nil), provider: provider, checkpoints: checkpoints) { await trace.save($0) }
        let requests = await provider.requests, emitted = await trace.checkpoints
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(emitted.isEmpty)
        XCTAssertEqual(result, plan.chunks.map { fictionTag(index: $0.index, stage: .editor) }.joined(separator: "\n\n"))
    }

    func testContextUsesScalarBoundsAndSourceOnlyBackgroundAcrossChapters() {
        let unicode = "👨‍👩‍👧‍👦e\u{301}"
        let passages = [
            "Chapter I\n" + String(repeating: unicode, count: 400) + "OPENING-END",
            String(repeating: "界", count: 400) + "NOT-A-SAME-CHAPTER-650-NEIGHBOR" + String(repeating: "界", count: 380) + "PREVIOUS-CHAPTER-TAIL",
            "Chapter II\nCURRENT-SOURCE",
            "NEXT-SOURCE-HEAD" + String(repeating: unicode, count: 600)
        ]
        let source = passages.joined()
        let chunks = passages.enumerated().map { TextChunk(index: $0.offset, text: $0.element, context: "") }
        let sections = [DocumentSection(index: 0, title: "Chapter I", text: passages[0] + passages[1]),
                        DocumentSection(index: 1, title: "Chapter II", text: passages[2] + passages[3])]
        let plan = ChunkPlan(sections: sections, chunks: chunks, sectionForChunk: [0, 0, 1, 1])
        let nextDraft = "NEXT-TRANSLATED-DRAFT" + String(repeating: unicode, count: 300)
        let priorDrafts = [1: "PREVIOUS-CHAPTER-DRAFT", 2: "CURRENT-CHAPTER-DRAFT", 3: nextDraft]
        let context = FictionContext.make(source: source, plan: plan, index: 2, priorDrafts: priorDrafts)

        XCTAssertLessThanOrEqual(context.unicodeScalars.count, 3_900)
        XCTAssertTrue(context.contains(scalarHead(source, 1_000)))
        XCTAssertFalse(context.contains("OPENING-END"))
        XCTAssertTrue(context.contains("Chapter II"))
        XCTAssertTrue(context.contains("PREVIOUS CHAPTER END"))
        XCTAssertTrue(context.contains("do not inject prior events"))
        XCTAssertTrue(context.contains(scalarTail(passages[1], 350)))
        XCTAssertFalse(context.contains("NOT-A-SAME-CHAPTER-650-NEIGHBOR"))
        XCTAssertFalse(context.contains("PREVIOUS-CHAPTER-DRAFT"))
        XCTAssertTrue(context.contains(scalarHead(passages[3], 300)))
        XCTAssertTrue(context.contains(scalarHead(nextDraft, 350)))

        let chapterOneEnd = FictionContext.make(source: source, plan: plan, index: 1, priorDrafts: priorDrafts)
        XCTAssertTrue(chapterOneEnd.contains(scalarTail(passages[0], 650)))
        XCTAssertFalse(chapterOneEnd.contains("CURRENT-SOURCE"))
        XCTAssertFalse(chapterOneEnd.contains("CURRENT-CHAPTER-DRAFT"))
        XCTAssertFalse(chapterOneEnd.contains("NEXT-TRANSLATED-DRAFT"))
    }

    func testContextCapsLongUnicodeTitlesAndUnknownIndexIsEmpty() {
        let text = String(repeating: "🧑🏽‍💻e\u{301}", count: 700)
        let passages = [text, text, text]
        let chunks = passages.enumerated().map { TextChunk(index: $0.offset, text: $0.element, context: "") }
        let plan = ChunkPlan(sections: [.init(index: 0, title: text, text: passages.joined())], chunks: chunks, sectionForChunk: [0, 0, 0])
        let context = FictionContext.make(source: passages.joined(), plan: plan, index: 1, priorDrafts: [0: text, 2: text])
        XCTAssertLessThanOrEqual(context.unicodeScalars.count, 3_900)
        XCTAssertTrue(context.contains("Author-voice"))
        XCTAssertTrue(context.contains("background"))
        XCTAssertEqual(FictionContext.make(source: text, plan: plan, index: 99), "")
    }

    func testRefinedRespectsOptionalLanguageReviewWithoutAddingEditorPass() async throws {
        let source = "Chapter I\nAlice walked towards the river."
        for includeLinguist in [false, true] {
            var preferences = TranslationPreferences()
            preferences.extraLanguageReview = includeLinguist
            let options = TranslationOptions(quality: .refined, preferences: preferences, pipelineVersion: nil)
            let trace = FictionTrace(), provider = FictionRecordingProvider(trace: trace)
            let result = try await FictionEngine().run(jobID: "passes", source: source, options: options, provider: provider) { await trace.save($0) }
            let requests = await provider.requests
            XCTAssertEqual(requests.map(\.stage), includeLinguist ? [.translate, .proofread, .linguist] : [.translate, .proofread])
            XCTAssertEqual(result, fictionTag(index: 0, stage: includeLinguist ? .linguist : .proofread))
        }
    }

    func testNewChapterUsesCompletedFinalTranslationForEachEditorialQuality() async throws {
        let source = self.source(firstChapterChunks: 2), plan = Chunker.plan(text: source, kind: .fiction)
        let boundary = try XCTUnwrap(plan.sectionForChunk.firstIndex(of: 1))
        var reviewedPreferences = TranslationPreferences(); reviewedPreferences.extraLanguageReview = true
        let configurations: [TranslationOptions] = [.init(quality: .refined, pipelineVersion: nil), .init(quality: .refined, preferences: reviewedPreferences, pipelineVersion: nil), .init(quality: .publication, pipelineVersion: nil)]
        for options in configurations {
            let trace = FictionTrace(), provider = FictionRecordingProvider(trace: trace)
            _ = try await FictionEngine().run(jobID: "finalvoice", source: source, options: options, provider: provider) { await trace.save($0) }
            let requests = await provider.requests, last = try XCTUnwrap(options.stages.last)
            let finalChapter = plan.chunks.prefix(boundary).map { fictionTag(index: $0.index, stage: last) }.joined(separator: "\n\n")
            XCTAssertEqual(requests.count, plan.chunks.count * options.stages.count)
            for request in requests where fictionIndex(request) == boundary {
                XCTAssertTrue(request.context.contains("PREVIOUS CHAPTER FINAL TRANSLATION"))
                XCTAssertTrue(request.context.contains("never copy its text or introduce its facts or events"))
                XCTAssertTrue(request.context.contains(scalarTail(finalChapter, 350)))
                // Both final chunks fit the sample, so the preceding chunk is
                // represented even when the chapter's final chunk is very short.
                XCTAssertTrue(request.context.contains(fictionTag(index: 0, stage: last)))
                for earlier in options.stages.dropLast() {
                    XCTAssertFalse(request.context.contains(fictionTag(index: boundary - 1, stage: earlier)))
                }
                XCTAssertLessThanOrEqual(request.context.unicodeScalars.count, 3_900)
            }
            for request in requests where fictionIndex(request) != boundary {
                XCTAssertFalse(request.context.contains("PREVIOUS CHAPTER FINAL TRANSLATION"))
            }
        }
    }

    func testBoundaryResumeUsesIdenticalFinalVoiceAndRequestIdentity() async throws {
        let source = self.source(), plan = Chunker.plan(text: source, kind: .fiction)
        let boundary = try XCTUnwrap(plan.sectionForChunk.firstIndex(of: 1)), options = TranslationOptions(quality: .publication, pipelineVersion: nil)
        let originalTrace = FictionTrace(), originalProvider = FictionRecordingProvider(trace: originalTrace)
        let originalResult = try await FictionEngine().run(jobID: "boundaryresume", source: source, options: options, provider: originalProvider) { await originalTrace.save($0) }
        let originalRequests = await originalProvider.requests, saved = await originalTrace.checkpoints
        let reusable = saved.filter { $0.index < boundary || ($0.index == boundary && $0.stage == .translate) }
        let resumedTrace = FictionTrace(), resumedProvider = FictionRecordingProvider(trace: resumedTrace)
        let resumedResult = try await FictionEngine().run(jobID: "boundaryresume", source: source, options: options, provider: resumedProvider, checkpoints: reusable) { await resumedTrace.save($0) }
        let resumedRequests = await resumedProvider.requests
        XCTAssertEqual(resumedResult, originalResult)
        XCTAssertEqual(resumedRequests.count, originalRequests.count - reusable.count)
        for request in resumedRequests {
            let original = try XCTUnwrap(originalRequests.first { $0.requestID == request.requestID })
            XCTAssertEqual(request.context, original.context)
            XCTAssertEqual(request.draft, original.draft)
            XCTAssertEqual(request.options, original.options)
            XCTAssertEqual(request.source, original.source)
        }
        let boundaryRequest = try XCTUnwrap(resumedRequests.first { fictionIndex($0) == boundary })
        XCTAssertTrue(boundaryRequest.context.contains(fictionTag(index: boundary - 1, stage: .editor)))
    }

    func testFutureIncompleteChapterCacheNeverProvidesPreviousChapterBackground() async throws {
        let source = self.source(firstChapterChunks: 2, secondChapterChunks: 1) + "Chapter III: Tomorrow\n\n" + String(repeating: "丙", count: 1_000)
        let plan = Chunker.plan(text: source, kind: .fiction), options = TranslationOptions(quality: .publication, pipelineVersion: nil)
        XCTAssertEqual(plan.sections.count, 3)
        let secondBoundary = try XCTUnwrap(plan.sectionForChunk.firstIndex(of: 1)), thirdBoundary = try XCTUnwrap(plan.sectionForChunk.firstIndex(of: 2))
        // A later chapter's final checkpoint alone does not mean the chapter is
        // complete. The current chapter's cached early pass is also not final.
        let cache = [Checkpoint(index: thirdBoundary, stage: .editor, text: "UNFINISHED-FUTURE-FINAL"),
                     Checkpoint(index: secondBoundary, stage: .translate, text: "EARLY-SECOND-CHAPTER-DRAFT")]
        let trace = FictionTrace(), provider = FictionRecordingProvider(trace: trace)
        _ = try await FictionEngine().run(jobID: "futurecache", source: source, options: options, provider: provider, checkpoints: cache) { await trace.save($0) }
        let requests = await provider.requests
        for request in requests where fictionIndex(request) < thirdBoundary {
            XCTAssertFalse(request.context.contains("UNFINISHED-FUTURE-FINAL"))
        }
        for request in requests where fictionIndex(request) == secondBoundary {
            XCTAssertTrue(request.context.contains(fictionTag(index: secondBoundary - 1, stage: .editor)))
            XCTAssertFalse(request.context.contains("EARLY-SECOND-CHAPTER-DRAFT"))
        }
        for request in requests where fictionIndex(request) == thirdBoundary {
            XCTAssertTrue(request.context.contains(fictionTag(index: secondBoundary, stage: .editor)))
            XCTAssertFalse(request.context.contains("EARLY-SECOND-CHAPTER-DRAFT"))
            XCTAssertFalse(request.context.contains("UNFINISHED-FUTURE-FINAL"))
        }
    }

    func testOptionalPreviousFinalIsScalarBoundedAndFastChapterContextIsUnchanged() async throws {
        let source = self.source(firstChapterChunks: 1, secondChapterChunks: 1), plan = Chunker.plan(text: source, kind: .fiction)
        let boundary = try XCTUnwrap(plan.sectionForChunk.firstIndex(of: 1)), sample = String(repeating: "👨‍👩‍👧‍👦e\u{301}", count: 100) + "FINAL-VOICE-END"
        let context = FictionContext.make(source: source, plan: plan, index: boundary, previousChapterFinal: sample)
        XCTAssertTrue(context.contains(scalarTail(sample, 350)))
        XCTAssertLessThanOrEqual(context.unicodeScalars.count, 3_900)
        XCTAssertFalse(FictionContext.make(source: source, plan: plan, index: 0, previousChapterFinal: sample).contains("FINAL-VOICE-END"))
        let trace = FictionTrace(), provider = FictionRecordingProvider(trace: trace)
        _ = try await FictionEngine().run(jobID: "fastboundary", source: source, options: .init(quality: .fast, pipelineVersion: nil), provider: provider) { await trace.save($0) }
        let requests = await provider.requests
        XCTAssertEqual(requests.count, plan.chunks.count)
        for request in requests {
            XCTAssertEqual(request.context, FictionContext.make(source: source, plan: plan, index: fictionIndex(request)))
            XCTAssertFalse(request.context.contains("PREVIOUS CHAPTER FINAL TRANSLATION"))
        }
    }

    func testFastFictionUsesCompleteAndEmptySourceDoesNoWork() async throws {
        let trace = FictionTrace(), provider = FictionRecordingProvider(trace: trace)
        let result = try await FictionEngine().run(jobID: "fast", source: "A short novel opening.", options: .init(quality: .fast, pipelineVersion: nil), provider: provider) { await trace.save($0) }
        XCTAssertEqual(result, fictionTag(index: 0, stage: .translate))
        let streamed = await provider.streamCalls
        XCTAssertEqual(streamed, 0)
        let emptyTrace = FictionTrace(), emptyProvider = FictionRecordingProvider(trace: emptyTrace)
        let empty = try await FictionEngine().run(jobID: "empty", source: "", options: .init(), provider: emptyProvider) { await emptyTrace.save($0) }
        let requests = await emptyProvider.requests, checkpoints = await emptyTrace.checkpoints
        XCTAssertEqual(empty, "")
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(checkpoints.isEmpty)
    }

    func testCancellationStopsInFlightWorkAndLaterChapters() async throws {
        let source = self.source(), trace = FictionTrace()
        let provider = FictionRecordingProvider(trace: trace, defaultDelay: .seconds(10))
        let task = Task {
            try await FictionEngine().run(jobID: "cancel", source: source, options: .init(quality: .publication, pipelineVersion: nil), provider: provider) { await trace.save($0) }
        }
        await provider.waitUntilStarted()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        let requests = await provider.requests, checkpoints = await trace.checkpoints, live = await provider.live
        XCTAssertLessThanOrEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.stage == .translate && fictionIndex($0) < 2 })
        XCTAssertTrue(checkpoints.isEmpty)
        XCTAssertEqual(live, 0)
    }

    func testProviderFailurePropagatesAndCancelsSiblings() async throws {
        let trace = FictionTrace(), provider = FictionRecordingProvider(trace: trace, defaultDelay: .seconds(10), failingID: "failure-0-translate")
        do {
            _ = try await FictionEngine().run(jobID: "failure", source: source(), options: .init(quality: .publication, pipelineVersion: nil), provider: provider) { await trace.save($0) }
            XCTFail("Expected provider failure")
        } catch TranslationError.message(let message) { XCTAssertEqual(message, "Provider failed") }
        catch { XCTFail("Unexpected error: \(error)") }
        let requests = await provider.requests, checkpoints = await trace.checkpoints, live = await provider.live
        XCTAssertLessThanOrEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.stage == .translate && fictionIndex($0) < 2 })
        XCTAssertTrue(checkpoints.isEmpty)
        XCTAssertEqual(live, 0)
    }

    func testCheckpointFailureStopsTheChapterBeforeFurtherStages() async throws {
        let trace = FictionTrace()
        let provider = FictionRecordingProvider(trace: trace, delays: ["storage-1-translate": .milliseconds(3)], defaultDelay: .seconds(10))
        do {
            _ = try await FictionEngine().run(jobID: "storage", source: source(), options: .init(quality: .publication, pipelineVersion: nil), provider: provider) { _ in
                throw TranslationError.message("Disk full")
            }
            XCTFail("Expected checkpoint failure")
        } catch TranslationError.message(let message) { XCTAssertEqual(message, "Disk full") }
        catch { XCTFail("Unexpected error: \(error)") }
        let requests = await provider.requests, live = await provider.live
        XCTAssertLessThanOrEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.stage == .translate && fictionIndex($0) < 2 })
        XCTAssertEqual(live, 0)
    }
}
