import Foundation

/// Extract a whole document's glossary before translation, with bounded parallel
/// requests and per-batch checkpoints that can resume in any completion order.
public struct GlossaryEngine: Sendable {
    public init() {}

    public func run(
        jobID: String,
        batches: [String],
        target: String,
        provider: any TranslationProvider,
        completed: Set<Int> = [],
        categorized: Bool = false,
        onBatch: @escaping @Sendable (Int, [Term]) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let pending = batches.indices.filter { !completed.contains($0) }
        let throughput = Throughput(maximum: 4)

        try await withThrowingTaskGroup(of: (Int, [Term]).self) { group in
            var next = 0, active = 0
            while next < pending.count || active > 0 {
                try Task.checkCancellation()
                let limit = await throughput.current()
                while next < pending.count && active < limit {
                    let index = pending[next]
                    let source = batches[index]
                    group.addTask {
                        let terms = try await TranslationEngine.retry(throughput: throughput) {
                            if categorized {
                                let query = GlossaryQuery(requestID: "\(jobID)-g2-full-\(index)", source: source, target: target)
                                let terms = try await provider.resolveTerms(query)
                                return GlossaryMemory.normalize(terms, source: source, known: [], chunk: index).map { term in
                                    var located = term; located.firstChunk = nil; return located
                                }
                            }
                            return try await provider.extractTerms(source: source, target: target, requestID: "\(jobID)-terms-\(index)")
                        }
                        return (index, terms)
                    }
                    next += 1; active += 1
                }
                if let (index, terms) = try await group.next() {
                    active -= 1
                    await throughput.succeeded()
                    try Task.checkCancellation()
                    // Serial callbacks let the caller persist each original index
                    // safely; extraction itself continues concurrently.
                    try await onBatch(index, terms)
                }
            }
        }
        try Task.checkCancellation()
    }
}
