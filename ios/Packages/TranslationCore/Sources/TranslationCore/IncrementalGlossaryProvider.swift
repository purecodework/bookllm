import Foundation

/// Freeze a glossary per source chunk before dispatch. Serial term preparation
/// prevents simultaneous chunks from choosing different translations of a name;
/// translation itself remains concurrent. Persist snapshots before paid requests.
public struct IncrementalGlossaryProvider: TranslationProvider {
    private let provider: any TranslationProvider
    private let ledger: IncrementalGlossaryLedger

    public init(provider: any TranslationProvider, jobID: String, chunks: [TextChunk], target: String,
                seed: [Term], snapshots: [Int: [Term]] = [:],
                onSnapshot: @escaping @Sendable (Int, [Term]) async throws -> Void) {
        self.provider = provider
        ledger = IncrementalGlossaryLedger(provider: provider, jobID: jobID, chunks: chunks,
            target: target, seed: seed, snapshots: snapshots, onSnapshot: onSnapshot)
    }

    public func complete(_ request: TranslationRequest) async throws -> String {
        let prepared = try await ledger.prepare(request)
        return try await provider.complete(prepared)
    }
    public func stream(_ request: TranslationRequest, onPartial: @escaping @Sendable (String) async -> Void) async throws -> String {
        let prepared = try await ledger.prepare(request)
        return try await provider.stream(prepared, onPartial: onPartial)
    }
    public func extractTerms(source: String, target: String, requestID: String) async throws -> [Term] {
        try await provider.extractTerms(source: source, target: target, requestID: requestID)
    }
}

private actor IncrementalGlossaryLedger {
    let provider: any TranslationProvider
    let jobID: String
    let chunks: [TextChunk]
    let target: String
    let onSnapshot: @Sendable (Int, [Term]) async throws -> Void
    var terms: [Term]
    var snapshots: [Int: [Term]]
    var pending: [Int: Task<[Term], Error>] = [:]

    init(provider: any TranslationProvider, jobID: String, chunks: [TextChunk], target: String,
         seed: [Term], snapshots: [Int: [Term]],
         onSnapshot: @escaping @Sendable (Int, [Term]) async throws -> Void) {
        self.provider = provider; self.jobID = jobID; self.chunks = chunks.sorted { $0.index < $1.index }
        self.target = target; self.onSnapshot = onSnapshot; self.snapshots = snapshots
        terms = Self.merge(seed + snapshots.keys.sorted().flatMap { snapshots[$0] ?? [] })
    }

    func prepare(_ original: TranslationRequest) async throws -> TranslationRequest {
        try Task.checkCancellation()
        // Explicit indices disambiguate identical source passages. Older engines
        // identify the chunk in the request ID; repair suffixes are also allowed.
        let prefix = jobID + "-"
        let encodedIndex = original.requestID.hasPrefix(prefix)
            ? Int(original.requestID.dropFirst(prefix.count).split(separator: "-").first ?? "") : nil
        guard let index = original.chunkIndex ?? encodedIndex,
              let chunk = chunks.first(where: { $0.index == index }), chunk.text == original.source else {
            return original
        }
        var request = original
        if let snapshot = snapshots[index] { request.options.glossary = snapshot; return request }
        // Concurrent translation workers can arrive out of source order. Prepare
        // only the requested prefix, always in source order, sharing pending work.
        var previous: Task<[Term], Error>?
        for chunk in chunks where chunk.index <= index {
            if snapshots[chunk.index] != nil { continue }
            if let existing = pending[chunk.index] { previous = existing; continue }
            let dependency = previous
            let work = Task {
                defer { self.pending[chunk.index] = nil }
                if let dependency { _ = try await dependency.value }
                try Task.checkCancellation()
                let existing = self.terms
                let extracted = try await TranslationEngine.retry(throughput: Throughput(maximum: 1)) {
                    try await self.provider.extractTerms(source: chunk.text, target: self.target,
                        requestID: "\(self.jobID)-incremental-terms-\(chunk.index)")
                }
                try Task.checkCancellation()
                // Unanchored suggestions must not silently seed future chunks;
                // only observed terms can be reconstructed from saved snapshots.
                let observed = extracted.filter { chunk.text.localizedCaseInsensitiveContains($0.source) }
                let merged = Self.merge(existing + observed)
                let snapshot = merged.filter { chunk.text.localizedCaseInsensitiveContains($0.source) }
                guard snapshot.count <= 1000 else { throw TranslationError.message("本段匹配术语超过 1000 个，请减少个人词表后重新导入文稿。") }
                try await self.onSnapshot(chunk.index, snapshot)
                try Task.checkCancellation()
                self.terms = merged; self.snapshots[chunk.index] = snapshot
                return snapshot
            }
            pending[chunk.index] = work; previous = work
        }
        guard let work = pending[index] else { throw TranslationError.message("术语准备未完成，请继续翻译。") }
        request.options.glossary = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
            Task { await self.cancelPending() }
        }
        try Task.checkCancellation()
        return request
    }

    private func cancelPending() { for work in pending.values { work.cancel() } }

    static func merge(_ candidates: [Term]) -> [Term] {
        var seen = Set<String>()
        return candidates.filter {
            !$0.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            $0.source.count <= 200 && $0.target.count <= 400 &&
            seen.insert($0.source.lowercased()).inserted
        }
    }
}
