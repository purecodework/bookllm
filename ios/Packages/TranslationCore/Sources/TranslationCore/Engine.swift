import Foundation

public actor Throughput {
    private var limit = 2
    private var successes = 0
    private let maximum: Int
    public init(maximum: Int) { self.maximum = maximum; limit = min(2, maximum) }
    public func current() -> Int { limit }
    public func succeeded() { successes += 1; if successes >= 3 { limit = min(maximum, limit + 1); successes = 0 } }
    public func throttled() { limit = max(1, limit / 2); successes = 0 }
}
public struct TranslationEngine: Sendable {
    public init() {}
    public func run(jobID: String, source: String, options: TranslationOptions, provider: any TranslationProvider, checkpoints: [Checkpoint] = [], onPartial: @escaping @Sendable (Int, String) async -> Void = { _, _ in }, onUpdate: @escaping @Sendable (Checkpoint) async throws -> Void) async throws -> String {
        let chunks = Chunker.plan(text: source, kind: options.documentKind).chunks
        let throughput = Throughput(maximum: options.quality.maxConcurrency)
        var output = Array(repeating: "", count: chunks.count)
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var next = 0, active = 0
            while next < chunks.count || active > 0 {
                let limit = await throughput.current()
                while next < chunks.count && active < limit {
                    let chunk = chunks[next]
                    group.addTask {
                        var draft = ""
                        for stage in options.stages {
                            try Task.checkCancellation()
                            if let cached = checkpoints.last(where: { $0.index == chunk.index && $0.stage == stage }) { draft = cached.text; continue }
                            var chunkOptions = options
                            chunkOptions.glossary = options.glossary.filter { chunk.text.localizedCaseInsensitiveContains($0.source) }
                            let request = TranslationRequest(requestID: "\(jobID)-\(chunk.index)-\(stage.rawValue)", source: chunk.text, context: chunk.context, draft: draft, stage: stage, options: chunkOptions)
                            draft = try await Self.retry(throughput: throughput) {
                                if options.quality == .fast {
                                    await onPartial(chunk.index, "")
                                    return try await provider.stream(request) { text in await onPartial(chunk.index, text) }
                                }
                                return try await provider.complete(request)
                            }
                            guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranslationError.message("模型返回了空译文，请重试。") }
                            try await onUpdate(Checkpoint(index: chunk.index, stage: stage, text: draft))
                        }
                        return (chunk.index, draft)
                    }
                    next += 1; active += 1
                }
                if let result = try await group.next() { output[result.0] = result.1; active -= 1; await throughput.succeeded() }
            }
        }
        return output.joined(separator: "\n\n")
    }
    static func retry<T: Sendable>(throughput: Throughput, operation: @Sendable () async throws -> T) async throws -> T {
        for attempt in 0..<4 {
            try Task.checkCancellation()
            do { return try await operation() }
            catch let error as TranslationError {
                let delay: Double
                switch error {
                case .rateLimited(let seconds): await throughput.throttled(); delay = min(60, max(seconds, pow(2, Double(attempt))))
                case .transient: delay = pow(2, Double(attempt))
                case .message: throw error
                }
                guard attempt < 3 else { throw error }
                try await Task.sleep(for: .seconds(delay + Double.random(in: 0...0.25)))
            } catch let error as URLError where [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code) {
                guard attempt < 3 else { throw error }
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
            }
        }
        throw TranslationError.message("重试失败。")
    }
}
