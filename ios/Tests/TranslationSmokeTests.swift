import XCTest
import TranslationCore
@testable import BookLLM

private let smokeSource = "The room was quiet.\n\nThe window was open."
private let smokeTranslation = "房间里很安静。\n\n窗户开着。"

private actor SmokeModel: TranslationProvider {
    var requests: [TranslationRequest] = []
    var termRequests = 0
    func complete(_ request: TranslationRequest) async throws -> String {
        requests.append(request)
        if request.reviewMode == true { return "{\"findings\":[]}" }
        return smokeTranslation
    }
    func stream(_ request: TranslationRequest, onPartial: @escaping @Sendable (String) async -> Void) async throws -> String {
        requests.append(request)
        await onPartial("房间里")
        let text = smokeTranslation + (request.glossaryCapture == true ? "\n" + GlossaryCapture.start + "[]" + GlossaryCapture.end : "")
        await onPartial(text)
        return text
    }
    func extractTerms(source: String, target: String, requestID: String) async throws -> [Term] {
        termRequests += 1
        return []
    }
}

/// Test-only forwarding transport: preserve incremental SSE delivery, observe
/// usage, and refuse a second dispatch even if the engine wants to retry.
private final class SingleLiveRequest: URLProtocol, URLSessionDataDelegate, @unchecked Sendable {
    final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private var dispatched = 0
        private var response = Data()
        func reset() { lock.withLock { dispatched = 0; response = Data() } }
        func reserve() -> Bool { lock.withLock { guard dispatched == 0 else { return false }; dispatched += 1; return true } }
        func append(_ data: Data) { lock.withLock { response.append(data) } }
        func report() -> (Int, [String: Int]?) {
            lock.withLock {
                let lines = String(decoding: response, as: UTF8.self).components(separatedBy: "\n")
                let usage = lines.compactMap { line -> [String: Int]? in
                    guard line.hasPrefix("data:"), let data = String(line.dropFirst(5)).data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                    // Providers can include nested token details and null fields.
                    return (object["usage"] as? [String: Any])?.compactMapValues { $0 as? Int }
                }.last
                return (dispatched, usage)
            }
        }
    }
    static let meter = Meter()
    private var forwarding: URLSession?
    private var networkTask: URLSessionDataTask?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard request.url?.scheme == "https", request.url?.host == "api.deepseek.com",
                  request.url?.path == "/v1/chat/completions", request.httpMethod == "POST" else {
                throw TranslationError.message("Live smoke test permits only the DeepSeek translation endpoint.")
            }
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    guard count > 0 else { break }
                    body.append(contentsOf: bytes.prefix(count))
                }
            }
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            guard object["max_tokens"] as? Int == 128, object["stream"] as? Bool == true,
                  body.count < 20_000, Self.meter.reserve() else {
                throw TranslationError.message("Live smoke test exhausted its one-request / 128-output-token budget.")
            }
            object["stream_options"] = ["include_usage": true]
            var outgoing = request
            outgoing.httpBodyStream = nil
            outgoing.httpBody = try JSONSerialization.data(withJSONObject: object)
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = []
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            forwarding = session
            networkTask = session.dataTask(with: outgoing)
            networkTask?.resume()
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { networkTask?.cancel(); forwarding?.invalidateAndCancel() }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        Self.meter.append(data)
        client?.urlProtocol(self, didLoad: data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { client?.urlProtocol(self, didFailWithError: error) }
        else { client?.urlProtocolDidFinishLoading(self) }
        session.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class TranslationSmokeTests: XCTestCase {
    func testUsageMeterAcceptsNestedDetailsAndRefusesSecondDispatch() {
        let meter = SingleLiveRequest.Meter()
        XCTAssertTrue(meter.reserve())
        XCTAssertFalse(meter.reserve())
        meter.append(Data("data: {\"usage\":null}\n\ndata: {\"usage\":{\"prompt_tokens\":42,\"completion_tokens\":12,\"total_tokens\":54,\"completion_tokens_details\":{\"reasoning_tokens\":0}}}\n\ndata: [DONE]\n\n".utf8))
        let (count, usage) = meter.report()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(usage?["prompt_tokens"], 42)
        XCTAssertEqual(usage?["completion_tokens"], 12)
        XCTAssertEqual(usage?["total_tokens"], 54)
    }
    @MainActor private func store() throws -> (StudioStore, URL, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "BookLLM.TranslationSmoke." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        let url = root.appendingPathComponent("studio.json")
        let store = StudioStore(storageURL: url, connectionKeySaver: { _ in }, preferences: preferences)
        store.ownAPI = true
        return (store, url, preferences)
    }
    @MainActor private func book(quality: Quality) -> BookJob {
        var job = BookJob(title: "翻译冒烟测试", source: smokeSource, format: "TXT")
        job.options = .init(quality: quality, documentKind: .general, sourceLanguage: "en")
        job.replan()
        return job
    }
    @MainActor private func translate(_ store: StudioStore, book: BookJob) async throws -> BookJob {
        store.jobs = [book]
        store.begin(book.id, account: CloudAccount(), purchases: PurchaseStore())
        let task = try XCTUnwrap(store.task, store.message ?? "Translation did not start")
        await task.value
        let result = try XCTUnwrap(store.job(book.id))
        XCTAssertEqual(result.status, .complete, result.error ?? "No error detail")
        XCTAssertNil(result.reviewDraft)
        XCTAssertEqual(result.completedChapterCount, 1)
        XCTAssertTrue(result.canRead)
        XCTAssertEqual(result.termBatches.count, 1)
        XCTAssertEqual(result.checkpoints.count, book.options.stages.count)
        // Wait for the final debounced update through an explicit persistence barrier.
        try await store.save()
        return result
    }
    @MainActor func testMockAllFourQualitiesPersistReadableResultsAndResumeWithoutCalls() async throws {
        for quality in Quality.allCases {
            let (store, url, preferences) = try store()
            let provider = SmokeModel()
            store.testingProvider = provider
            let result = try await translate(store, book: book(quality: quality))
            XCTAssertEqual(result.result, smokeTranslation)
            XCTAssertFalse(result.result.contains(GlossaryCapture.start))
            let requests = await provider.requests
            XCTAssertEqual(requests.count, quality.stages.count)
            XCTAssertEqual(Set(requests.map(\.requestID)).count, requests.count)
            let terms = await provider.termRequests
            XCTAssertEqual(terms, 0, "Ordinary prose should skip standalone glossary calls")
            let restored = StudioStore(storageURL: url, connectionKeySaver: { _ in }, preferences: preferences)
            restored.testingProvider = provider
            XCTAssertEqual(restored.job(result.id)?.result, smokeTranslation)
            XCTAssertEqual(restored.job(result.id)?.checkpoints, result.checkpoints)
            restored.begin(result.id, account: CloudAccount(), purchases: PurchaseStore())
            XCTAssertNil(restored.task)
            let afterResume = await provider.requests.count
            XCTAssertEqual(afterResume, requests.count)
        }
    }
    @MainActor func testLiveDeepSeekSingleStreamPersistsAndRestoresWithoutAnotherRequest() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["BOOKLLM_DEEPSEEK_KEY_FILE"], !path.isEmpty else {
            throw XCTSkip("Opt-in only: provide BOOKLLM_DEEPSEEK_KEY_FILE to authorize one real request.")
        }
        let key = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TranslationError.message("The local API key file is empty.") }
        SingleLiveRequest.meter.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SingleLiveRequest.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (store, url, preferences) = try store()
        store.testingProvider = APIProvider(connection: .ownKey(baseURL: URL(string: "https://api.deepseek.com/v1")!,
            key: key, model: env["BOOKLLM_DEEPSEEK_MODEL"] ?? "deepseek-flash"),
            limits: .init(contextWindowTokens: 8192, maximumOutputTokens: 128), session: session)
        let result = try await translate(store, book: book(quality: .fast))
        XCTAssertTrue(result.result.contains("窗"), "The translation should preserve the open window.")
        XCTAssertTrue(result.result.contains("静"), "The translation should preserve the quiet room.")
        XCTAssertFalse(result.result.contains(GlossaryCapture.start))
        let restored = StudioStore(storageURL: url, connectionKeySaver: { _ in }, preferences: preferences)
        restored.testingProvider = store.testingProvider
        XCTAssertEqual(restored.job(result.id)?.status, .complete)
        XCTAssertEqual(restored.job(result.id)?.result, result.result)
        XCTAssertEqual(restored.job(result.id)?.checkpoints, result.checkpoints)
        restored.begin(result.id, account: CloudAccount(), purchases: PurchaseStore())
        XCTAssertNil(restored.task)
        let (count, usage) = SingleLiveRequest.meter.report()
        XCTAssertEqual(count, 1)
        if let usage {
            XCTAssertLessThanOrEqual(usage["completion_tokens"] ?? Int.max, 128)
            print("DEEPSEEK_SMOKE_USAGE: input=\(usage["prompt_tokens"] ?? -1) output=\(usage["completion_tokens"] ?? -1) total=\(usage["total_tokens"] ?? -1) requests=\(count)")
        }
        print("DEEPSEEK_SMOKE_TRANSLATION: \(result.result)")
    }
}
