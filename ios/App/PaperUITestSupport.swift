#if DEBUG
import Foundation
import TranslationCore

/// Isolated native test harness. Never compiled into Release or enabled in normal launches.
enum PaperUITestSupport {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--paper-ui-testing") }
    @MainActor static func store() -> StudioStore {
        guard enabled else { return StudioStore() }
        let url = URL.cachesDirectory.appendingPathComponent("PaperUITests/studio.json")
        let preferences = UserDefaults(suiteName: "app.bookllm.paper-ui-tests")!
        if ProcessInfo.processInfo.arguments.contains("--paper-ui-reset") { preferences.removePersistentDomain(forName: "app.bookllm.paper-ui-tests") }
        let store = StudioStore(storageURL: url, preferences: preferences)
        if ProcessInfo.processInfo.arguments.contains("--paper-ui-reset") || store.jobs.isEmpty {
            var draft = BookJob(title: "远山来信", source: "Chapter I\n\nElizabeth opened a letter.\n\nThe garden was quiet.", format: "TXT")
            draft.options.sourceLanguage = "en"; draft.id = "paper-draft"; draft.options.quality = .publication; draft.replan()
            var complete = BookJob(title: "午后的花园", source: "Chapter I\n\nElizabeth opened a letter.\n\nShe read by the window.\n\nChapter II\n\nThe rain stopped.", format: "TXT")
            complete.options.sourceLanguage = "en"; complete.id = "paper-complete"; complete.replan(); complete.status = .complete
            let plan = Chunker.plan(text: complete.source, kind: complete.options.documentKind, preparationVersion: complete.options.preparationVersion)
            let text = ["# 风起时\n\n午后的光越过窗沿，落在那封刚刚拆开的信上。\n\n她把信拿近了一些，纸页很薄，像是要轻轻一碰，就会碎成一段旧时光。\n\n窗外，雨刚停。街道尽头有人收起伞，一只鸟掠过屋檐。", "# 雨停之后\n\n花园渐渐安静下来。她放下那封信，走到窗前。"]
            complete.checkpoints = plan.chunks.flatMap { chunk in complete.options.stages.map { .init(index: chunk.index, stage: $0, text: text[min(chunk.index, text.count - 1)]) } }
            complete.result = text.joined(separator: "\n\n")
            complete.terms = [.init(source: "Elizabeth", target: "伊丽莎白", category: .person, evidence: "Elizabeth opened a letter."), .init(source: "Nell", target: "内尔", category: .person)]
            var progress = complete
            progress.id = "paper-progress"; progress.title = "旧城手记"; progress.options.quality = .publication; progress.replan()
            progress.status = .paused; progress.result = ""
            progress.checkpoints = [.init(index: 0, stage: .translate, text: text[0]), .init(index: 0, stage: .proofread, text: "{\"findings\":[]}"), .init(index: 0, stage: .linguist, text: "{\"findings\":[]}"), .init(index: 0, stage: .editor, text: text[0])]
            store.jobs = [draft, progress, complete]
            store.persist()
        }
        if ProcessInfo.processInfo.arguments.contains("--paper-ui-reset") { store.setOwnAPI(false) }
        if ProcessInfo.processInfo.arguments.contains("--paper-ui-parallel") { startParallel(store) }
        return store
    }
    @MainActor private static func startParallel(_ store: StudioStore) {
        guard let job = store.job("paper-progress") else { return }
        store.activeID = job.id
        store.update(job.id) { $0.status = .translating }
        let provider = HeldReviewProvider()
        store.task = Task { [weak store] in
            guard let store else { return }
            defer { store.task = nil; store.activeID = nil; store.processing = [:]; store.pauseRequestedID = nil }
            do {
                _ = try await TranslationEngine().run(jobID: job.id, source: job.source, options: job.options, provider: provider, checkpoints: job.checkpoints, onEvent: { [weak store] event in await store?.observe(job.id, event: event) }) { [weak store] point in
                    await store?.update(job.id) { $0.checkpoints.append(point) }
                }
            } catch { store.update(job.id) { $0.status = .paused } }
        }
    }
}
private struct HeldReviewProvider: TranslationProvider {
    private let gate = ReviewGate()
    func complete(_ request: TranslationRequest) async throws -> String {
        if request.reviewMode == true { try await withTaskCancellationHandler { try await gate.wait(request.requestID) } onCancel: { Task { await gate.cancel(request.requestID) } } }
        return request.source
    }
    func extractTerms(source: String, target: String, requestID: String) async throws -> [Term] { [] }
}
private actor ReviewGate {
    var pending: [String: CheckedContinuation<Void, Error>] = [:]
    var cancelled = Set<String>()
    func wait(_ id: String) async throws {
        if cancelled.contains(id) { throw CancellationError() }
        try await withCheckedThrowingContinuation { pending[id] = $0 }
    }
    func cancel(_ id: String) { cancelled.insert(id); pending.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
}
#endif

import SwiftUI
struct PaperUITestLayout: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        if PaperUITestSupport.enabled && ProcessInfo.processInfo.arguments.contains("--paper-ui-largest-type") {
            content.environment(\.dynamicTypeSize, .accessibility5)
        } else if PaperUITestSupport.enabled && ProcessInfo.processInfo.arguments.contains("--paper-ui-large-type") {
            content.environment(\.dynamicTypeSize, .accessibility3)
        } else { content }
        #else
        content
        #endif
    }
}
