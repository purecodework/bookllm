import Foundation
import Observation
import TranslationCore
import UIKit

enum JobStatus: String, Codable, Sendable { case draft, extracting, reviewing, translating, paused, complete, failed, awaitingCredits, needsReview }
struct ReadingChapter: Codable, Identifiable, Sendable { var id: Int; var title: String; var chunks: [Int] }
struct ReviewDraft: Codable, Sendable { var original: TranslationRequest; var output: String; var issues: [String]; var index: Int; var attempt = 0; var prepared: TranslationRequest? }
struct BookJob: Codable, Identifiable, Sendable {
    var id = UUID().uuidString
    var title: String
    var source: String
    var format: String
    var coverKey: String? = nil
    var ocrPages: [OCRPage]?
    var sourceDocumentID: String?
    var partialApproved: Bool?
    var reviewDraft: ReviewDraft?
    var purchasedWorkID: String?
    var publishedWorkID: String?
    var publicationPrice: Int?
    var created = Date()
    var options = TranslationOptions()
    var glossaryMode = GlossaryMode.accumulated
    var glossarySeed: [Term]?
    var terms: [Term] = []
    var checkpoints: [Checkpoint] = []
    var status = JobStatus.draft
    var glossaryReady = false
    var glossaryBatch = 0
    var termBatches: [Int: [Term]] = [:]
    var result = ""
    var error: String?
    var usesOwnAPI = false
    var genreWasCorrected = false
    var chapters: [ReadingChapter] = []
    var chunkCount = 0
    var basePoints = 0
    var glossaryPoints = 0
    var editorialContextPoints: Int?
    var sourceLanguage: String? { TranslationLanguage.sourceTitle(options.sourceLanguage) }
    var progress: Double { Double(checkpoints.count) / Double(max(1, chunkCount * options.stages.count)) }
    var statusText: String {
        switch status { case .draft: "待翻译"; case .extracting: "整理术语"; case .reviewing: "等待术语校对"; case .translating: "翻译中"; case .paused: "已暂停"; case .complete: "翻译完成"; case .failed: "需要重试"; case .awaitingCredits: "等待充值"; case .needsReview: "需要补全" }
    }
    var estimate: Int {
        max(0, basePoints * options.stages.count - checkpoints.count * max(1, basePoints / max(1, chunkCount))) + (options.usesCollaborativeEditing ? (editorialContextPoints ?? 0) : 0) + (glossaryMode == .custom || glossaryReady ? 0 : glossaryPoints)
    }

    func estimatedPoints(tokensPerPoint: Int) -> Int { max(1, Int(ceil(Double(estimate) * 1000 / Double(max(1, tokensPerPoint))))) }

    var readableChapters: [ReadingChapter] {
        guard let final = options.stages.last else { return [] }
        let finished = Set(checkpoints.filter { $0.stage == final }.map(\.index))
        return Array(chapters.prefix { !$0.chunks.isEmpty && $0.chunks.allSatisfy { finished.contains($0) } })
    }
    mutating func replan() {
        let plan = Chunker.plan(text: source, kind: options.documentKind)
        chunkCount = plan.chunks.count
        var estimated = 0
        for chunk in plan.chunks {
            let bytes: Int = chunk.text.utf8.count + chunk.context.utf8.count
            let units: Double = Double(bytes) / 1500.0 + 2.0
            estimated += max(1, Int(ceil(units)))
        }
        basePoints = estimated
        editorialContextPoints = plan.sections.reduce(0) { sum, section in
            let count = plan.sectionForChunk.filter { $0 == section.index }.count
            let scalars = min(32_000, section.text.unicodeScalars.count * 2 + 3_000)
            return sum + count * 3 * max(1, Int(ceil(Double(scalars) * 2 / 1500)))
        }
        chapters = plan.sections.map { section in ReadingChapter(id: section.index, title: section.title, chunks: plan.sectionForChunk.enumerated().filter { $0.element == section.index }.map(\.offset)) }
    }
    var sourceBatches: [String] {
        let scalars = source.unicodeScalars
        var batches: [String] = [], index = scalars.startIndex
        while index < scalars.endIndex { let end = scalars.index(index, offsetBy: 12000, limitedBy: scalars.endIndex) ?? scalars.endIndex; batches.append(String(scalars[index..<end])); index = end }
        return batches
    }
}
@MainActor @Observable final class StudioStore {
    var jobs: [BookJob] = []
    var customStyles: [TranslationStyle] = []
    var libraryTerms: [Term] = []
    var defaultPreferences = TranslationPreferences()
    var activeID: String?
    var message: String?
    var incomingWorkID: String?
    var ownAPI = UserDefaults.standard.bool(forKey: "ownAPI")
    var endpoint = UserDefaults.standard.string(forKey: "endpoint") ?? "https://api.deepseek.com/v1"
    var model = UserDefaults.standard.string(forKey: "model") ?? "deepseek-chat"
    var task: Task<Void, Never>?
    var liveChunks: [Int: String] = [:]
    private let storage = URL.applicationSupportDirectory.appendingPathComponent("BookLLM/studio.json")
    private struct Snapshot: Codable, Sendable { var jobs: [BookJob]; var styles: [TranslationStyle]; var terms: [Term]; var preferences: TranslationPreferences }
    private actor Disk {
        private var written = 0
        func save(_ snapshot: Snapshot, url: URL, revision: Int) throws {
            guard revision > written else { return }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            written = revision
        }
    }
    private let disk = Disk()
    private var revision = 0
    init() {
        do {
            if FileManager.default.fileExists(atPath: storage.path) {
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: storage))
                jobs = snapshot.jobs; customStyles = snapshot.styles; libraryTerms = snapshot.terms; defaultPreferences = snapshot.preferences
                for i in jobs.indices where jobs[i].status == .draft && jobs[i].checkpoints.isEmpty && jobs[i].reviewDraft == nil && jobs[i].options.pipelineVersion == nil {
                    jobs[i].options.quality = jobs[i].options.effectiveQuality
                    jobs[i].options.pipelineVersion = 2; jobs[i].options.preferences.extraLanguageReview = false
                    jobs[i].replan()
                }
                for i in jobs.indices where jobs[i].status == .translating || jobs[i].status == .extracting { jobs[i].status = .paused }
            }
        } catch { message = "本地记录读取失败，请保留文件后重试：\(error.localizedDescription)" }
    }
    private func snapshot() -> Snapshot { Snapshot(jobs: jobs, styles: customStyles, terms: libraryTerms, preferences: defaultPreferences) }
    func save() async throws { revision += 1; try await disk.save(snapshot(), url: storage, revision: revision) }
    func persist() {
        revision += 1; let version = revision; let value = snapshot()
        Task { do { try await disk.save(value, url: storage, revision: version) } catch { message = "保存失败：\(error.localizedDescription)" } }
    }
    func job(_ id: String) -> BookJob? { jobs.first { $0.id == id } }
    func update(_ id: String, _ action: (inout BookJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }; let oldKind = jobs[index].options.documentKind; action(&jobs[index]); if jobs[index].options.documentKind != oldKind { jobs[index].replan() }; persist()
    }
    func add(_ imported: ImportedText) throws -> String {
        guard !imported.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, imported.text.count <= 2_000_000 else { throw TranslationError.message("请确认原稿有正文且不超过 200 万字符。") }
        var job = BookJob(title: imported.title, source: imported.text, format: imported.format); job.options.preferences = defaultPreferences
        job.ocrPages = imported.ocrPages; job.sourceDocumentID = imported.sourceDocumentID
        job.options.sourceWasOCR = imported.ocrPages?.contains(where: { $0.usedOCR }) == true ? true : nil
        if let data = imported.coverData { job.coverKey = try CoverStorage.save(data) }
        job.options.sourceLanguage = SourceLanguageDetection.code(for: imported.text)
        job.options.documentKind = DocumentClassifier.detect(text: imported.text, title: imported.title, format: imported.format)
        job.replan()
        job.glossaryPoints = job.sourceBatches.reduce(0) { $0 + max(1, Int(ceil(Double($1.unicodeScalars.count) / 1000))) }
        jobs.insert(job, at: 0); persist(); return job.id
    }
    func canUseOwnAPI(account: CloudAccount, purchases: PurchaseStore) -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--byok-testing") { return true }
        #endif
        return purchases.localOwnAPIUnlocked || account.ownAPIUnlocked
    }
    func provider(account: CloudAccount, purchases: PurchaseStore, own: Bool) throws -> APIProvider {
        if own {
            guard canUseOwnAPI(account: account, purchases: purchases) else { throw TranslationError.message("请先买断解锁自带 API。") }
            guard let url = URL(string: endpoint), url.scheme == "https", url.host != nil else { throw TranslationError.message("请输入有效的 HTTPS API 地址。") }
            let key = Vault.read("apiKey"); guard !key.isEmpty else { throw TranslationError.message("请先在设置中保存 API 密钥。") }
            return APIProvider(connection: .ownKey(baseURL: url, key: key, model: model))
        }
        guard let url = account.baseURL else { throw TranslationError.message("云端服务尚未配置。请配置服务后使用，或买断并使用自己的 API。") }
        guard account.isLoggedIn else { throw TranslationError.message("请先登录账户，再使用翻译点数。") }
        return APIProvider(connection: .cloud(baseURL: url, token: account.session))
    }
    func begin(_ id: String, account: CloudAccount, purchases: PurchaseStore, approved: Bool = false, partial: Bool = false) {
        guard task == nil, var job = job(id), job.status != .complete else { return }
        if job.status == .reviewing && !approved { return }
        if job.reviewDraft != nil { repair(id, account: account, purchases: purchases); return }
        do {
            let own = job.status == .draft ? ownAPI : job.usesOwnAPI
            let provider = try provider(account: account, purchases: purchases, own: own)
            if job.status == .draft { update(id) { $0.usesOwnAPI = own }; job.usesOwnAPI = own }
            if job.glossarySeed == nil {
                update(id) { $0.glossarySeed = libraryTerms; $0.terms = Self.mergeTerms(libraryTerms + $0.terms) }
                job = self.job(id) ?? job
            }
            if job.glossaryMode == .accumulated && !job.glossaryReady {
                update(id) { $0.glossaryReady = true }
            }
            if job.glossaryMode == .custom && !job.glossaryReady {
                guard !libraryTerms.isEmpty, libraryTerms.allSatisfy({ !$0.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw TranslationError.message("请先在术语库中添加或导入术语。") }
                update(id) { $0.terms = libraryTerms; $0.glossaryReady = true }
            }
            if partial && !job.glossaryReady && job.glossaryMode != .custom {
                // The budget choice explicitly uses existing terms, leaving funds for readable text.
                update(id) { $0.partialApproved = true; $0.terms = libraryTerms; $0.glossaryReady = $0.glossaryMode != .review }
                if job.glossaryMode == .review { update(id) { $0.status = .reviewing }; return }
            }
            if approved {
                guard job.terms.allSatisfy({ !$0.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw TranslationError.message("请补充空缺译名，或删除该术语后再确认。") }
                update(id) { $0.glossaryReady = true }
            }
            activeID = id; liveChunks = [:]
            task = Task { [weak self] in
                guard let self else { return }
                defer { self.task = nil; self.activeID = nil }
                do {
                    if let current = self.job(id), !current.glossaryReady {
                        self.update(id) { $0.status = .extracting; $0.error = nil }
                        try await GlossaryEngine().run(jobID: id, batches: current.sourceBatches, target: current.options.targetLanguage, provider: provider, completed: Set(current.termBatches.keys)) { [weak self] index, terms in
                            try await self?.recordTerms(id, index: index, terms: terms)
                        }
                        if current.glossaryMode == .review {
                            self.update(id) { $0.status = .reviewing }; return
                        }
                        self.update(id) { $0.glossaryReady = true }
                    }
                    guard var current = self.job(id) else { return }
                    current.options.glossary = current.terms
                    self.update(id) { $0.options.glossary = current.terms; $0.status = .translating; $0.error = nil }
                    let translationProvider: any TranslationProvider
                    if current.glossaryMode == .accumulated {
                        translationProvider = IncrementalGlossaryProvider(provider: provider, jobID: id,
                            chunks: Chunker.plan(text: current.source, kind: current.options.documentKind).chunks,
                            target: current.options.targetLanguage, seed: current.glossarySeed ?? current.terms,
                            snapshots: current.termBatches) { [weak self] index, terms in
                                try await self?.recordTerms(id, index: index, terms: terms)
                            }
                    } else { translationProvider = provider }
                    let result = try await TranslationEngine().run(jobID: id, source: current.source, options: current.options, provider: translationProvider, checkpoints: current.checkpoints, onPartial: { [weak self] index, text in await self?.partial(id, index: index, text: text) }) { [weak self] checkpoint in
                        try await self?.record(id, checkpoint: checkpoint)
                    }
                    self.update(id) { $0.result = result; $0.status = .complete }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } catch is CancellationError { self.update(id) { $0.status = .paused } }
                catch let error as URLError where error.code == .cancelled { self.update(id) { $0.status = .paused } }
                catch let failure as CoverageFailure { self.retainFailure(id, failure: failure) }
                catch TranslationError.insufficientCredits { self.update(id) { $0.status = .awaitingCredits; $0.error = "点数不足以完整处理下一段。已完成内容已保存，充值后继续。" } }
                catch { self.update(id) { $0.status = .failed; $0.error = error.localizedDescription } }
                if account.isLoggedIn { try? await account.refresh() }
            }
        } catch { message = error.localizedDescription }
    }
    private func retainFailure(_ id: String, failure: CoverageFailure) {
        update(id) { job in
            if var retained = job.reviewDraft {
                retained.output = failure.output; retained.issues = failure.issues; retained.prepared = nil; job.reviewDraft = retained
            } else {
                let index = failure.request.chunkIndex ?? Int(failure.request.requestID.split(separator: "-").dropLast().last ?? "0") ?? 0
                job.reviewDraft = ReviewDraft(original: failure.request, output: failure.output, issues: failure.issues, index: index)
            }
            job.status = .needsReview; job.error = failure.localizedDescription
        }
    }
    func repair(_ id: String, account: CloudAccount, purchases: PurchaseStore) {
        guard task == nil, let job = job(id), let retained = job.reviewDraft else { return }
        do {
            let provider = try provider(account: account, purchases: purchases, own: job.usesOwnAPI)
            var review = retained
            if review.prepared == nil {
                review.attempt += 1
                var request = review.original
                request.requestID += "-review-\(review.attempt)"
                if request.reviewMode != true { request.draft = review.output }
                request.reviewNotes = String(review.issues.joined(separator: "\n").prefix(1900))
                review.prepared = request
            }
            guard let request = review.prepared else { return }
            update(id) { $0.reviewDraft = review; $0.status = .translating; $0.error = nil }
            activeID = id
            task = Task { [weak self] in
                guard let self else { return }
                var succeeded = false
                do {
                    // Persist the exact paid retry identity before dispatch; pause/402 resumes it.
                    try await self.save()
                    let output = try await provider.complete(request)
                    try Task.checkCancellation()
                    let plan = Chunker.plan(text: job.source, kind: job.options.documentKind)
                    let text = request.reviewMode == true ? output : EditorNotes.filter(output, source: job.source, chunks: plan.chunks, index: retained.index)
                    try await self.record(id, checkpoint: .init(index: retained.index, stage: retained.original.stage, text: text))
                    self.update(id) { $0.reviewDraft = nil; $0.status = .paused; $0.error = nil }
                    try await self.save(); succeeded = true
                } catch is CancellationError { self.update(id) { $0.status = .paused } }
                catch let error as URLError where error.code == .cancelled { self.update(id) { $0.status = .paused } }
                catch let failure as CoverageFailure { self.retainFailure(id, failure: failure) }
                catch TranslationError.insufficientCredits { self.update(id) { $0.status = .awaitingCredits; $0.error = "点数不足，充值后继续补全。" } }
                catch { self.update(id) { $0.status = .needsReview; $0.error = error.localizedDescription } }
                self.task = nil; self.activeID = nil
                if account.isLoggedIn { try? await account.refresh() }
                if succeeded { self.begin(id, account: account, purchases: purchases) }
            }
        } catch { message = error.localizedDescription }
    }
    func addPurchased(_ work: WorkContent) throws -> String {
        if let existing = jobs.first(where: { $0.purchasedWorkID == work.id }) { return existing.id }
        var job = BookJob(title: work.title, source: work.text, format: "EPUB")
        job.purchasedWorkID = work.id; job.options.targetLanguage = work.targetLanguage
        job.options.quality = .fast; job.options.documentKind = DocumentClassifier.detect(text: work.text, title: work.title, format: "EPUB")
        if let encoded = work.coverBase64, let data = Data(base64Encoded: encoded) { job.coverKey = try CoverStorage.save(data) }
        job.replan(); job.glossaryReady = true; job.result = work.text; job.status = .complete
        job.checkpoints = Chunker.plan(text: work.text, kind: job.options.documentKind).chunks.map { .init(index: $0.index, stage: .translate, text: $0.text) }
        jobs.insert(job, at: 0); persist(); return job.id
    }
    private func recordTerms(_ id: String, index batch: Int, terms: [Term]) async throws {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].termBatches[batch] = terms
        jobs[index].terms = Self.mergeTerms((jobs[index].glossarySeed ?? []) + jobs[index].termBatches.keys.sorted().flatMap { jobs[index].termBatches[$0] ?? [] })
        jobs[index].glossaryBatch = jobs[index].termBatches.count
        try await save()
    }
    private static func mergeTerms(_ candidates: [Term]) -> [Term] {
        var known = Set<String>()
        return candidates.filter { !$0.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.source.count <= 200 && $0.target.count <= 400 && known.insert($0.source.lowercased()).inserted }
    }
    private func record(_ id: String, checkpoint: Checkpoint) async throws {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].checkpoints.removeAll { $0.index == checkpoint.index && $0.stage == checkpoint.stage }
        jobs[index].checkpoints.append(checkpoint); liveChunks[checkpoint.index] = nil; try await save()
    }
    private func partial(_ id: String, index: Int, text: String) { if activeID == id { liveChunks[index] = text } }
    func pause() { task?.cancel() }
    func saveConnection(key: String) throws {
        try Vault.save(key, name: "apiKey")
        UserDefaults.standard.set(endpoint, forKey: "endpoint"); UserDefaults.standard.set(model, forKey: "model"); UserDefaults.standard.set(ownAPI, forKey: "ownAPI")
    }
}
