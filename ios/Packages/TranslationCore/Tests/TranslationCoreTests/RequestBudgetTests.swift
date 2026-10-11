import XCTest
@testable import TranslationCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class BudgetTransport: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { var status: Int; var text: String }
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var replies: [Reply] = []
        var bodies: [Data] = []
        func reset(_ values: [Reply]) { lock.withLock { replies = values; bodies = [] } }
        func receive(_ data: Data) -> Reply {
            lock.withLock {
                bodies.append(data)
                return replies.isEmpty ? Reply(status: 500, text: "unexpected call") : replies.removeFirst()
            }
        }
        func recorded() -> [Data] { lock.withLock { bodies } }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool {
        ["budget.invalid", "api.deepseek.com"].contains(request.url?.host ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let size = stream.read(&bytes, maxLength: bytes.count)
                if size <= 0 { break }
                data.append(contentsOf: bytes.prefix(size))
            }
        }
        let reply = Self.state.receive(data)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
            headerFields: ["Content-Type": request.value(forHTTPHeaderField: "Accept") == "text/event-stream" ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class RequestBudgetTests: XCTestCase, @unchecked Sendable {
    private let url = URL(string: "https://budget.invalid/v1")!
    private func request() -> TranslationRequest {
        .init(requestID: "stable-p2-0-editor", source: "Alice arrives.\n\nBob waits.", context: "Neighbor background.",
              draft: "爱丽丝到达。\n\n鲍勃等待。", stage: .editor,
              options: .init(quality: .publication, glossary: [.init(source: "Alice", target: "爱丽丝")]),
              reviewNotes: "Preserve both paragraphs.", reviews: [
                .init(role: .proofread, report: .init(findings: [])),
                .init(role: .linguist, report: .init(findings: []))
              ], chapterContext: "Chapter I. Background.", chunkIndex: 0)
    }
    private func provider(limits: ModelRequestLimits = .standard, cloud: Bool = false,
                          baseURL: URL? = nil, model: String = "test-model") -> APIProvider {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BudgetTransport.self]
        return APIProvider(connection: cloud ? .cloud(baseURL: url, token: "test-session") : .ownKey(baseURL: baseURL ?? url, key: "test-key", model: model),
                           limits: limits, session: URLSession(configuration: config))
    }
    private func ownSuccess(stream: Bool = false) -> BudgetTransport.Reply {
        .init(status: 200, text: stream
              ? "data: {\"choices\":[{\"delta\":{\"content\":\"爱丽丝到达。\\n\\n鲍勃等待。\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
              : "{\"choices\":[{\"message\":{\"content\":\"爱丽丝到达。\\n\\n鲍勃等待。\"},\"finish_reason\":\"stop\"}]}")
    }
    private func bodies() throws -> [[String: Any]] {
        try BudgetTransport.state.recorded().map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
    }

    func testDeepSeekFlashCompletionDisablesThinkingWithoutChangingBudgetOrMessages() async throws {
        for model in ["deepseek-flash", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp"] {
            BudgetTransport.state.reset([ownSuccess()])
            _ = try await provider(baseURL: URL(string: "https://api.deepseek.com/v1")!, model: model).complete(request())
            let body = try XCTUnwrap(try bodies().first)
            XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
            XCTAssertEqual(body["max_tokens"] as? Int, try RequestBudget.prepare(request(), limits: .standard).maxTokens)
            XCTAssertEqual((body["messages"] as? [[String: String]])?[1]["content"], request().budgetedInput)
        }
    }

    func testDeepSeekFlashStreamDisablesThinking() async throws {
        #if canImport(FoundationNetworking)
        BudgetTransport.state.reset([ownSuccess()])
        #else
        BudgetTransport.state.reset([ownSuccess(stream: true)])
        #endif
        _ = try await provider(baseURL: URL(string: "https://api.deepseek.com/v1")!, model: "deepseek-flash").stream(request()) { _ in }
        let body = try XCTUnwrap(try bodies().first)
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
    }

    func testDeepSeekFieldsDoNotChangeCustomEndpointsOrLegacyReasoningModels() async throws {
        BudgetTransport.state.reset([ownSuccess()])
        _ = try await provider(model: "deepseek-flash").complete(request())
        XCTAssertNil(try bodies().first?["thinking"])
        BudgetTransport.state.reset([ownSuccess()])
        _ = try await provider(baseURL: URL(string: "https://api.deepseek.com/v1")!, model: "deepseek-reasoner").complete(request())
        XCTAssertNil(try bodies().first?["thinking"])
    }

    func testCompleteMessagesIncludePromptGlossaryDraftReportsAndTokenHeadroom() throws {
        var original = request()
        original.context = String(repeating: "邻近背景。", count: 2000)
        original.chapterContext = String(repeating: "章级原文和初稿。", count: 3200)
        let limits = ModelRequestLimits(contextWindowTokens: 8192, maximumOutputTokens: 2048)
        let prepared = try RequestBudget.prepare(original, limits: limits)
        XCTAssertLessThanOrEqual(prepared.estimatedInputTokens + prepared.maxTokens + 819, 8192)
        XCTAssertEqual(prepared.estimatedInputTokens, RequestBudget.inputTokens(system: prepared.system, input: prepared.input))
        XCTAssertTrue(prepared.system.contains("Alice → 爱丽丝") || prepared.system.contains("Alice"))
        XCTAssertTrue(prepared.input.contains("<source>" + original.source + "</source>"))
        XCTAssertTrue(prepared.input.contains("<draft>" + original.draft + "</draft>"))
        XCTAssertTrue(prepared.input.contains(CollaborationPrompts.json(original.reviews!)))
        XCTAssertTrue(prepared.input.contains("Preserve both paragraphs."))
        XCTAssertLessThan(prepared.input.utf8.count, original.input.utf8.count)
        XCTAssertTrue(prepared.input.contains("omitted"))
        XCTAssertEqual(original.requestID, "stable-p2-0-editor")
        XCTAssertEqual(original.chapterContext, String(repeating: "章级原文和初稿。", count: 3200))
    }

    func testOutputCapAdaptsToSmallModelWithoutRequesting8192() throws {
        var original = request(); original.source = String(repeating: "word ", count: 600)
        let prepared = try RequestBudget.prepare(original, limits: .init(contextWindowTokens: 8192, maximumOutputTokens: 2048))
        XCTAssertEqual(prepared.maxTokens, 2048)
        XCTAssertThrowsError(try RequestBudget.prepare(original, limits: .init(contextWindowTokens: 8192, maximumOutputTokens: 512)))
    }

    func testNecessaryDataIsNeverTrimmedToMakeARequestFit() {
        var original = request()
        original.options.style.instruction = String(repeating: "User style instruction. ", count: 1600)
        original.chapterContext = String(repeating: "Background.", count: 3000)
        original.context = String(repeating: "Neighbors.", count: 1000)
        XCTAssertThrowsError(try RequestBudget.prepare(original, limits: .init(contextWindowTokens: 4096, maximumOutputTokens: 1024))) { error in
            XCTAssertTrue(error.localizedDescription.contains("背景已自动收缩"))
        }
        XCTAssertTrue(original.options.style.instruction.hasSuffix("User style instruction. "))
        XCTAssertEqual(original.source, "Alice arrives.\n\nBob waits.")
    }

    func testByteEstimateDoesNotTreatUnicodeScalarsAsTokens() {
        XCTAssertEqual(RequestBudget.estimatedTokens("abc"), 1)
        XCTAssertEqual(RequestBudget.estimatedTokens("译间"), 2)
        XCTAssertGreaterThan(RequestBudget.estimatedTokens("🧑🏽‍💻"), RequestBudget.estimatedTokens("abcd"))
    }

    func testNewOwnInputContainsOneSourceCopyAndLegacyInputRemainsIdentical() throws {
        var original = request()
        XCTAssertEqual(original.budgetedInput.components(separatedBy: original.source).count - 1, 1)
        XCTAssertFalse(original.budgetedInput.contains("\"text\""))
        XCTAssertTrue(original.budgetedInput.contains("[\"p1\",\"p2\"]"))
        original.options.preparationVersion = nil
        XCTAssertEqual(original.budgetedInput, original.input)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var options = try XCTUnwrap(object["options"] as? [String: Any]); options.removeValue(forKey: "preparationVersion"); object["options"] = options
        let decoded = try JSONDecoder().decode(TranslationRequest.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.options.preparationVersion)
        XCTAssertEqual(decoded.input, original.input)
    }

    func testPreparationIsDeterministicAndDoesNotAlterFrozenRequest() throws {
        var original = request(); original.chapterContext = String(repeating: "Chapter background. ", count: 1600)
        let encoded = try JSONEncoder().encode(original)
        let first = try RequestBudget.prepare(original, limits: .init(contextWindowTokens: 8192, maximumOutputTokens: 2048))
        let second = try RequestBudget.prepare(original, limits: .init(contextWindowTokens: 8192, maximumOutputTokens: 2048))
        XCTAssertEqual(first.input, second.input); XCTAssertEqual(first.maxTokens, second.maxTokens)
        XCTAssertEqual(try JSONDecoder().decode(TranslationRequest.self, from: encoded).input, original.input)
    }

    func testExplicitContextRejectionShrinksAndRetriesWithCompleteMandatoryData() async throws {
        var original = request(); original.chapterContext = String(repeating: "Chapter background. ", count: 1600)
        BudgetTransport.state.reset([
            .init(status: 400, text: "{\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"Maximum context length is 4096 tokens.\"}}"), ownSuccess()
        ])
        let output = try await provider().complete(original)
        XCTAssertEqual(output, "爱丽丝到达。\n\n鲍勃等待。")
        let sent = try bodies(); XCTAssertEqual(sent.count, 2)
        let first = try XCTUnwrap(sent[0]["messages"] as? [[String: String]])
        let second = try XCTUnwrap(sent[1]["messages"] as? [[String: String]])
        XCTAssertLessThan(second[1]["content"]!.count, first[1]["content"]!.count)
        XCTAssertTrue(second[1]["content"]!.contains(original.source))
        XCTAssertTrue(second[1]["content"]!.contains(original.draft))
        XCTAssertLessThanOrEqual(RequestBudget.inputTokens(system: second[0]["content"]!, input: second[1]["content"]!) + (sent[1]["max_tokens"] as! Int) + 409, 4096)
    }

    func testOutputLimitRejectionCapsReportsAndPreservesReviewDraft() async throws {
        var original = request(); original.reviewMode = true; original.stage = .proofread; original.reviews = nil
        BudgetTransport.state.reset([
            .init(status: 400, text: "{\"error\":{\"message\":\"max_tokens must be less than or equal to 1024\"}}"),
            .init(status: 200, text: "{\"choices\":[{\"message\":{\"content\":\"{\\\"findings\\\":[]}\"},\"finish_reason\":\"stop\"}]}")
        ])
        let output = try await provider().complete(original)
        XCTAssertEqual(output, "{\"findings\":[]}")
        let sent = try bodies(); XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[1]["max_tokens"] as? Int, 1024)
        XCTAssertEqual((sent[1]["messages"] as? [[String: String]])?[1]["content"], original.budgetedInput)
    }

    func testUnrelatedBadRequestIsNotRetriedAndInfeasibleRequestNeverDispatches() async throws {
        BudgetTransport.state.reset([.init(status: 400, text: "{\"error\":{\"message\":\"Unknown model\"}}")])
        do { _ = try await provider().complete(request()); XCTFail("Expected failure") } catch { }
        XCTAssertEqual(BudgetTransport.state.recorded().count, 1)
        var original = request(); original.draft = String(repeating: "required draft ", count: 2000)
        BudgetTransport.state.reset([])
        do { _ = try await provider(limits: .init(contextWindowTokens: 4096, maximumOutputTokens: 1024)).complete(original); XCTFail("Expected local failure") } catch { }
        XCTAssertTrue(BudgetTransport.state.recorded().isEmpty)
    }

    func testCloudKeepsWireSchemaAndDoesNotRetryOrRewriteLimitErrors() async throws {
        BudgetTransport.state.reset([.init(status: 200, text: "{\"text\":\"爱丽丝到达。\\n\\n鲍勃等待。\"}")])
        _ = try await provider(cloud: true).complete(request())
        let body = try XCTUnwrap(try bodies().first), options = try XCTUnwrap(body["options"] as? [String: Any])
        XCTAssertNil(options["preparationVersion"]); XCTAssertEqual(options["pipelineVersion"] as? Int, 2)
        XCTAssertEqual(body["requestID"] as? String, request().requestID)
        XCTAssertEqual(body["source"] as? String, request().source)
        BudgetTransport.state.reset([.init(status: 400, text: "{\"error\":{\"code\":\"context_length_exceeded\"}}")])
        do { _ = try await provider(cloud: true).complete(request()); XCTFail("Expected failure") } catch { }
        XCTAssertEqual(BudgetTransport.state.recorded().count, 1)
    }

    func testStreamUsesSameBudgetAndAdaptsBeforeEmittingAcceptedOutput() async throws {
        var original = request(); original.chapterContext = String(repeating: "Chapter background. ", count: 1600)
        #if canImport(FoundationNetworking)
        let success = ownSuccess()
        #else
        let success = ownSuccess(stream: true)
        #endif
        BudgetTransport.state.reset([
            .init(status: 400, text: "{\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"Maximum context length is 4096 tokens.\"}}"), success
        ])
        let output = try await provider().stream(original) { _ in }
        XCTAssertEqual(output, "爱丽丝到达。\n\n鲍勃等待。")
        let sent = try bodies(); XCTAssertEqual(sent.count, 2)
        let expected = try RequestBudget.prepare(original, limits: .init(contextWindowTokens: 4096, maximumOutputTokens: 3840), backgroundReduction: 1)
        XCTAssertEqual(sent[1]["max_tokens"] as? Int, expected.maxTokens)
        XCTAssertEqual((sent[1]["messages"] as? [[String: String]])?[1]["content"], expected.input)
    }

    func testCapacityRetriesAreBoundedAndReportSizeRemainsValidated() async throws {
        BudgetTransport.state.reset(Array(repeating: .init(status: 400, text: "{\"error\":{\"code\":\"context_length_exceeded\"}}"), count: 3))
        do { _ = try await provider().complete(request()); XCTFail("Expected capacity failure") } catch {
            XCTAssertTrue(error.localizedDescription.contains("自动收缩后"))
        }
        XCTAssertLessThanOrEqual(BudgetTransport.state.recorded().count, 3)
        XCTAssertNil(ModelLimitRejection.decode(Data("{\"error\":{\"message\":\"max_tokens must be positive\"}}".utf8)))
    }

    func testShortOutputLimitsAndCombinedProviderLimitsHaveSafeFallbacks() throws {
        let small = try RequestBudget.prepare(request(), limits: .init(contextWindowTokens: 4096, maximumOutputTokens: 256))
        XCTAssertEqual(small.maxTokens, 256)
        let abbreviated = try XCTUnwrap(ModelLimitRejection.decode(Data("{\"error\":{\"message\":\"max_tokens must be <= 4096\"}}".utf8)))
        XCTAssertEqual(try abbreviated.reduced(.standard).maximumOutputTokens, 4096)
        let strict = try XCTUnwrap(ModelLimitRejection.decode(Data("{\"error\":{\"message\":\"max_tokens must be less than 2048\"}}".utf8)))
        XCTAssertEqual(try strict.reduced(.standard).maximumOutputTokens, 2047)
        let strictSymbol = try XCTUnwrap(ModelLimitRejection.decode(Data("{\"error\":{\"message\":\"max_tokens must be < 2048\"}}".utf8)))
        XCTAssertEqual(try strictSymbol.reduced(.standard).maximumOutputTokens, 2047)
        let underestimated = ModelLimitRejection(contextWindow: 8192, maximumOutput: nil, contextExceeded: true, outputExceeded: false)
        XCTAssertEqual(try underestimated.reduced(.init(contextWindowTokens: 8192, maximumOutputTokens: 2048)).contextWindowTokens, 6144)
        let combined = ModelLimitRejection(contextWindow: 4096, maximumOutput: 4096, contextExceeded: true, outputExceeded: true)
        let limits = try combined.reduced(.standard)
        XCTAssertEqual(limits.contextWindowTokens, 4096)
        XCTAssertLessThan(limits.maximumOutputTokens, limits.contextWindowTokens)
    }

    func testTokenizerUnderestimateForcesBackgroundShrinkEvenBelowEstimatedBudget() async throws {
        var original = request(); original.chapterContext = String(repeating: "!", count: 32000)
        BudgetTransport.state.reset([
            .init(status: 400, text: "{\"error\":{\"message\":\"Maximum context length is 32768 tokens.\"}}"), ownSuccess()
        ])
        _ = try await provider().complete(original)
        let sent = try bodies(), first = try XCTUnwrap(sent[0]["messages"] as? [[String: String]]), second = try XCTUnwrap(sent[1]["messages"] as? [[String: String]])
        XCTAssertEqual(sent.count, 2)
        XCTAssertLessThan(second[1]["content"]!.utf8.count, first[1]["content"]!.utf8.count)
        XCTAssertTrue(second[1]["content"]!.contains(original.source)); XCTAssertTrue(second[1]["content"]!.contains(original.draft))
    }

    func testProviderRejectionShrinksPastAlreadyAppliedPreflightReductions() async throws {
        var original = request(); original.chapterContext = String(repeating: "!", count: 32000)
        let limits = ModelRequestLimits(contextWindowTokens: 8192, maximumOutputTokens: 2048)
        let initial = try RequestBudget.prepare(original, limits: limits)
        XCTAssertGreaterThan(initial.backgroundReduction, 0)
        BudgetTransport.state.reset([
            .init(status: 400, text: "{\"error\":{\"message\":\"Maximum context length is 8192 tokens.\"}}"), ownSuccess()
        ])
        _ = try await provider(limits: limits).complete(original)
        let sent = try bodies(), first = try XCTUnwrap(sent[0]["messages"] as? [[String: String]]), second = try XCTUnwrap(sent[1]["messages"] as? [[String: String]])
        XCTAssertEqual(sent.count, 2)
        XCTAssertLessThan(second[1]["content"]!.utf8.count, first[1]["content"]!.utf8.count)
        XCTAssertTrue(second[1]["content"]!.contains(original.source)); XCTAssertTrue(second[1]["content"]!.contains(original.draft))
    }
}
