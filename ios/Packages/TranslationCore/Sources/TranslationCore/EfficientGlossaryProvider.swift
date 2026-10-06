import Foundation

/// New jobs use compact candidate queries for at most two neighboring chunks.
/// Older paid jobs keep IncrementalGlossaryProvider and its exact request identities.
public struct EfficientGlossaryProvider: TranslationProvider {
    private let provider: any TranslationProvider
    private let memory: EfficientGlossaryMemory
    public init(provider: any TranslationProvider, jobID: String, chunks: [TextChunk], sections: [Int] = [],
                kind: DocumentKind, target: String, seed: [Term], snapshots: [Int: [Term]] = [:],
                discoveries: [Int: [Term]] = [:], queries: [Int: GlossaryQuery] = [:], rejected: [Int: [String]] = [:],
                onQuery: @escaping @Sendable (Int, GlossaryQuery) async throws -> Void,
                onRejected: @escaping @Sendable (Int, [String]) async throws -> Void,
                onSnapshot: @escaping @Sendable (Int, [Term]) async throws -> Void,
                onDiscovery: @escaping @Sendable (Int, [Term]) async throws -> Void) {
        self.provider = provider
        memory = EfficientGlossaryMemory(provider: provider, jobID: jobID, chunks: chunks, sections: sections,
            kind: kind, target: target, seed: seed, snapshots: snapshots, discoveries: discoveries, queries: queries,
            rejected: rejected, onQuery: onQuery, onRejected: onRejected, onSnapshot: onSnapshot, onDiscovery: onDiscovery)
    }
    public func complete(_ request: TranslationRequest) async throws -> String {
        let prepared = try await memory.prepare(request)
        let raw = try await provider.complete(prepared)
        return try await memory.finish(prepared, raw: raw)
    }
    public func stream(_ request: TranslationRequest, onPartial: @escaping @Sendable (String) async -> Void) async throws -> String {
        let prepared = try await memory.prepare(request)
        let capture = prepared.glossaryCapture == true
        let raw = try await provider.stream(prepared) { partial in await onPartial(capture ? GlossaryCapture.partial(partial) : partial) }
        return try await memory.finish(prepared, raw: raw)
    }
    public func extractTerms(source: String, target: String, requestID: String) async throws -> [Term] {
        try await provider.extractTerms(source: source, target: target, requestID: requestID)
    }
    public func resolveTerms(_ query: GlossaryQuery) async throws -> [Term] { try await provider.resolveTerms(query) }
}

private actor EfficientGlossaryMemory {
    let provider: any TranslationProvider
    let jobID: String
    let chunks: [TextChunk]
    let kind: DocumentKind
    let target: String
    let groups: [[TextChunk]]
    let onQuery: @Sendable (Int, GlossaryQuery) async throws -> Void
    let onRejected: @Sendable (Int, [String]) async throws -> Void
    let onSnapshot: @Sendable (Int, [Term]) async throws -> Void
    let onDiscovery: @Sendable (Int, [Term]) async throws -> Void
    var terms: [Term]
    var snapshots: [Int: [Term]]
    var discoveries: [Int: [Term]]
    var queries: [Int: GlossaryQuery]
    var ignored: Set<String>
    var pending: [Int: Task<Void, Error>] = [:]

    init(provider: any TranslationProvider, jobID: String, chunks: [TextChunk], sections: [Int],
         kind: DocumentKind, target: String, seed: [Term], snapshots: [Int: [Term]], discoveries: [Int: [Term]],
         queries: [Int: GlossaryQuery], rejected: [Int: [String]],
         onQuery: @escaping @Sendable (Int, GlossaryQuery) async throws -> Void,
         onRejected: @escaping @Sendable (Int, [String]) async throws -> Void,
         onSnapshot: @escaping @Sendable (Int, [Term]) async throws -> Void,
         onDiscovery: @escaping @Sendable (Int, [Term]) async throws -> Void) {
        let sortedChunks = chunks.sorted { $0.index < $1.index }
        self.provider = provider; self.jobID = jobID; self.chunks = sortedChunks
        self.kind = kind; self.target = target; self.snapshots = snapshots; self.discoveries = discoveries
        self.queries = queries; self.onQuery = onQuery; self.onRejected = onRejected
        self.onSnapshot = onSnapshot; self.onDiscovery = onDiscovery
        terms = GlossaryMemory.merge(seed + snapshots.keys.sorted().flatMap { snapshots[$0] ?? [] } + discoveries.keys.sorted().flatMap { discoveries[$0] ?? [] })
        ignored = Set(rejected.values.flatMap { $0 })
        var batches: [[TextChunk]] = []
        for chunk in sortedChunks {
            let lastIndex = batches.last?.last?.index
            let sameSection = lastIndex.map { previous in
                sections.isEmpty || (previous < sections.count && chunk.index < sections.count && sections[previous] == sections[chunk.index])
            } ?? false
            if let last = batches.last, last.count < 2 && sameSection { batches[batches.count - 1].append(chunk) }
            else { batches.append([chunk]) }
        }
        groups = batches
    }
    func prepare(_ original: TranslationRequest) async throws -> TranslationRequest {
        try Task.checkCancellation()
        let prefix = jobID + "-"
        let encoded = original.requestID.hasPrefix(prefix) ? Int(original.requestID.dropFirst(prefix.count).split(separator: "-").first ?? "") : nil
        guard let index = original.chunkIndex ?? encoded, let chunk = chunks.first(where: { $0.index == index }), chunk.text == original.source,
              let groupIndex = groups.firstIndex(where: { $0.contains(where: { $0.index == index }) }) else { return original }
        if snapshots[index] == nil {
            var previous: Task<Void, Error>?
            for group in 0...groupIndex {
                let members = groups[group]
                if members.allSatisfy({ snapshots[$0.index] != nil }) { continue }
                if let existing = pending[group] { previous = existing; continue }
                let dependency = previous
                let work = Task {
                    defer { self.pending[group] = nil }
                    if let dependency { try await dependency.value }
                    try Task.checkCancellation()
                    try await self.prepareGroup(group, members: members)
                }
                pending[group] = work; previous = work
            }
            guard let work = pending[groupIndex] else { throw TranslationError.message("术语准备未完成，请继续翻译。") }
            try await withTaskCancellationHandler { try await work.value } onCancel: {
                work.cancel(); Task { await self.cancelPending() }
            }
        }
        try Task.checkCancellation()
        var request = original
        request.chunkIndex = index
        let supplement = request.stage == .translate ? [] : discoveries[index] ?? []
        request.options.glossary = Array(GlossaryMemory.merge((snapshots[index] ?? []) + supplement).prefix(1000))
        request.glossaryCapture = request.stage == .translate && !request.source.contains(GlossaryCapture.start) && !request.source.contains(GlossaryCapture.end) ? true : nil
        return request
    }
    private func prepareGroup(_ group: Int, members: [TextChunk]) async throws {
        var query = queries[group]
        if query == nil {
            var candidates: [GlossaryCandidate] = [], names = Set<String>(), quotes = Set<String>(), source = ""
            let found = members.flatMap { GlossaryCandidates.find(in: $0, kind: kind) }.enumerated().sorted {
                $0.element.priority != $1.element.priority ? $0.element.priority < $1.element.priority : $0.offset < $1.offset
            }.map(\.element)
            for candidate in found {
                if let chunk = members.first(where: { $0.index == candidate.chunk }) {
                    let key = GlossaryMemory.fold(candidate.source)
                    guard !ignored.contains(key), !terms.contains(where: { ($0.source.caseInsensitiveCompare(candidate.source) == .orderedSame || ($0.category == .specialist && GlossaryMemory.matches($0, text: candidate.source))) && GlossaryMemory.matches($0, text: chunk.text) }),
                          names.insert(key).inserted, candidates.count < 24 else { continue }
                    let quote = "[chunk \(candidate.chunk)] " + candidate.context
                    let addition = quotes.contains(candidate.context) ? "" : quote + "\n"
                    guard (source + addition).unicodeScalars.count <= 4500 else { continue }
                    quotes.insert(candidate.context); source += addition; candidates.append(candidate)
                }
            }
            if !candidates.isEmpty {
                let related = terms.filter { term in candidates.contains { GlossaryMemory.contains(term.source, in: $0.context) || (term.aliases ?? []).contains($0.source) } }
                let recentPeople = terms.suffix(16).filter { $0.category == .person && $0.ambiguous != true }
                let known = Array(GlossaryMemory.merge(related + recentPeople).prefix(16)).map { term in
                    var compact = term
                    if term.ambiguous != true { compact.evidence = nil }
                    compact.firstChunk = nil; return compact
                }
                let prepared = GlossaryQuery(requestID: "\(jobID)-g2-terms-\(group)", source: source, target: target,
                    candidates: candidates.map(\.source), known: known.isEmpty ? nil : known)
                // Persist the exact compact payload before billable dispatch. Resume
                // cannot rebuild it from newer entity memory and change its hash.
                try await onQuery(group, prepared); queries[group] = prepared; query = prepared
            }
        }
        if let query {
            let proposals = try await TranslationEngine.retry(throughput: Throughput(maximum: 1)) { try await self.provider.resolveTerms(query) }
            try Task.checkCancellation()
            let original = members.map(\.text).joined(separator: "\n\n")
            let observed = GlossaryMemory.normalize(proposals, source: original, known: terms, chunk: members[0].index, allowed: query.candidates).map { term in
                var located = term
                located.firstChunk = members.first { GlossaryMemory.matches(term, text: $0.text) }?.index
                return located
            }
            terms = GlossaryMemory.merge(terms + observed)
            let contextualWords = Set(["may", "march", "rose", "brown", "orange"])
            let rejected = (query.candidates ?? []).map(GlossaryMemory.fold).filter { word in
                !contextualWords.contains(word) && !observed.contains { GlossaryMemory.fold($0.source) == word }
            }
            try await onRejected(group, rejected); ignored.formUnion(rejected)
        }
        for chunk in members where snapshots[chunk.index] == nil {
            try Task.checkCancellation()
            let snapshot = GlossaryMemory.relevant(terms, to: chunk.text)
            guard snapshot.count <= 1000 else { throw TranslationError.message("本段匹配术语超过服务限制，请检查本文术语后重新导入。") }
            try await onSnapshot(chunk.index, snapshot); snapshots[chunk.index] = snapshot
        }
    }
    func finish(_ request: TranslationRequest, raw: String) async throws -> String {
        guard request.glossaryCapture == true, let index = request.chunkIndex else { return raw }
        try Task.checkCancellation()
        let text = GlossaryCapture.text(raw)
        let proposals = GlossaryCapture.proposals(raw)
        let observed = GlossaryMemory.normalize(proposals, source: request.source, known: terms, chunk: index, translated: text)
        let keys = Set((snapshots[index] ?? []).map(GlossaryMemory.key))
        let additions = observed.filter { !keys.contains(GlossaryMemory.key($0)) }.map { term in
            var canonical = term
            if let existing = terms.first(where: {
                $0.source.caseInsensitiveCompare(term.source) == .orderedSame &&
                (GlossaryMemory.key($0) == GlossaryMemory.key(term) || ($0.entityID != nil && $0.entityID == term.entityID))
            }) { canonical.target = existing.target }
            return canonical
        }
        let merged = GlossaryMemory.merge((discoveries[index] ?? []) + additions)
        if merged != (discoveries[index] ?? []), !merged.isEmpty {
            try await onDiscovery(index, merged); discoveries[index] = merged
            terms = GlossaryMemory.merge(terms + merged)
        }
        return text
    }
    private func cancelPending() { for work in pending.values { work.cancel() } }
}
