import Foundation

/// Observations only: checkpoints remain the authority for completed content.
public struct ProcessingEvent: Sendable, Equatable {
    public enum State: String, Sendable { case started, retrying, checking, finished, failed }
    public var requestID: String
    public var chunkIndex: Int
    public var stage: Stage
    public var state: State
    public init(requestID: String, chunkIndex: Int, stage: Stage, state: State) {
        self.requestID = requestID; self.chunkIndex = chunkIndex; self.stage = stage; self.state = state
    }
}
public typealias ProcessingObserver = @Sendable (ProcessingEvent) async -> Void

struct ObservedProvider: TranslationProvider {
    let provider: any TranslationProvider
    let onEvent: ProcessingObserver
    private let attempts = RequestAttempts()
    init(provider: any TranslationProvider, onEvent: @escaping ProcessingObserver) { self.provider = provider; self.onEvent = onEvent }
    func complete(_ request: TranslationRequest) async throws -> String {
        await started(request)
        do {
            let result = try await provider.complete(request)
            await emit(request, .checking)
            return result
        } catch { await emit(request, retryState(error)); throw error }
    }
    func stream(_ request: TranslationRequest, onPartial: @escaping @Sendable (String) async -> Void) async throws -> String {
        await started(request)
        do {
            let result = try await provider.stream(request, onPartial: onPartial)
            await emit(request, .checking)
            return result
        } catch { await emit(request, retryState(error)); throw error }
    }
    func extractTerms(source: String, target: String, requestID: String) async throws -> [Term] { try await provider.extractTerms(source: source, target: target, requestID: requestID) }
    func resolveTerms(_ query: GlossaryQuery) async throws -> [Term] { try await provider.resolveTerms(query) }
    private func retryState(_ error: Error) -> ProcessingEvent.State {
        if let error = error as? TranslationError {
            switch error { case .rateLimited, .transient, .pending: return .retrying; default: return .failed }
        }
        if let error = error as? URLError, [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code) { return .retrying }
        return .failed
    }
    private func started(_ request: TranslationRequest) async { await emit(request, await attempts.next(request.requestID) ? .retrying : .started) }
    private func emit(_ request: TranslationRequest, _ state: ProcessingEvent.State) async {
        let index = request.chunkIndex ?? request.requestID.split(separator: "-").dropLast().last.flatMap { Int($0) } ?? 0
        await onEvent(.init(requestID: request.requestID, chunkIndex: index, stage: request.stage, state: state))
    }
}
private actor RequestAttempts {
    private var seen = Set<String>()
    func next(_ id: String) -> Bool { !seen.insert(id).inserted }
}

/// An override changes only wording, retaining identity, aliases and evidence.
public enum NameOverrides {
    public static func applying(_ overrides: [String: String], to terms: [Term]) -> [Term] {
        terms.map { original in
            var term = original
            if let target = overrides[term.id], !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                term.target = target
            }
            return term
        }
    }
}
