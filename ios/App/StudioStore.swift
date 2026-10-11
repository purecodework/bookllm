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
    var glossaryStrategyVersion: Int?
    var glossaryQueries: [Int: GlossaryQuery]?
    var glossaryRejected: [Int: [String]]?
    var termDiscoveries: [Int: [Term]]?
    var nameOverrides: [String: String]?
    var readingAnchor: String?
    var readingFontSize: Double?
    var readingMode: Int?
    var readingChapter: Int?
    var pauseReason: String?
    var terms: [Term] = []
    var displayTerms: [Term] { NameOverrides.applying(nameOverrides ?? [:], to: terms) }
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
        switch status { case .draft: "待翻译"; case .extracting: "整理术语"; case .reviewing: "旧任务需要继续"; case .translating: "翻译中"; case .paused: "已暂停"; case .complete: "翻译完成"; case .failed: "需要重试"; case .awaitingCredits: "等待充值"; case .needsReview: "需要补全" }
    }
    var estimate: Int {
        let perChunk: Int = max(1, basePoints / max(1, chunkCount))
        let translation: Int = max(0, basePoints * options.stages.count - checkpoints.count * perChunk)
        let editorial: Int = options.usesCollaborativeEditing ? (editorialContextPoints ?? 0) : 0
        let glossary: Int
        if glossaryMode == .accumulated {
            let remaining = max(0, chunkCount - termBatches.count)
            let proportion: Double = Double(remaining) / Double(max(1, chunkCount))
            let estimatedTerms: Int = Int(ceil(Double(glossaryPoints) * proportion))
            glossary = max(remaining, estimatedTerms)
        } else { glossary = glossaryMode == .custom || glossaryReady ? 0 : glossaryPoints }
        return translation + editorial + glossary
    }

    func estimatedPoints(tokensPerPoint: Int) -> Int { max(1, Int(ceil(Double(estimate) * 1000 / Double(max(1, tokensPerPoint))))) }

    var readableChapters: [ReadingChapter] {
        guard let final = options.stages.last else { return [] }
        let finished = Set(checkpoints.filter { $0.stage == final }.map(\.index))
        return Array(chapters.prefix { !$0.chunks.isEmpty && $0.chunks.allSatisfy { finished.contains($0) } })
    }
    mutating func replan() {
        let plan = Chunker.plan(text: source, kind: options.documentKind, preparationVersion: options.preparationVersion)
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
    var defaultPreferences = TranslationPreferences()
    var activeID: String?
    var message: String?
    var libraryLoadError: String?
    var incomingWorkID: String?
    var ownAPI = UserDefaults.standard.bool(forKey: "ownAPI")
    var endpoint = UserDefaults.standard.string(forKey: "endpoint") ?? "https://api.deepseek.com/v1"
    var model = UserDefaults.standard.string(forKey: "model") ?? "deepseek-flash"
    var apiContextWindowTokens = ModelRequestLimits.standard.contextWindowTokens
    var apiMaximumOutputTokens = ModelRequestLimits.standard.maximumOutputTokens
    var apiRequestLimits: ModelRequestLimits { .init(contextWindowTokens: apiContextWindowTokens, maximumOutputTokens: apiMaximumOutputTokens) }
    var task: Task<Void, Never>?
    var liveChunks: [Int: String] = [:]
    var processing: [String: ProcessingEvent] = [:]
    var pauseRequestedID: String?
    private(set) var pendingImportIDs = Set<String>()
    #if DEBUG
    @ObservationIgnored var testingProvider: (any TranslationProvider)?
    #endif
    @ObservationIgnored private var savingNames = Set<String>()
    @ObservationIgnored private var renamingIDs = Set<String>()
    @ObservationIgnored private var namesBeforeSave: [String: String] = [:]
    private let storage: URL
    @ObservationIgnored private let connectionKeySaver: @MainActor (String) throws -> Void
    @ObservationIgnored private let preferences: UserDefaults
    private struct Snapshot: Codable, Sendable { var jobs: [BookJob]; var styles: [TranslationStyle]; var preferences: TranslationPreferences }
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
    init(storageURL: URL = URL.applicationSupportDirectory.appendingPathComponent("BookLLM/studio.json"),
         connectionKeySaver: @escaping @MainActor (String) throws -> Void = { try Vault.save($0, name: "apiKey") },
         preferences: UserDefaults = .standard) {
        storage = storageURL
        self.connectionKeySaver = connectionKeySaver
        self.preferences = preferences
        ownAPI = preferences.bool(forKey: "ownAPI")
        endpoint = preferences.string(forKey: "endpoint") ?? "https://api.deepseek.com/v1"
        model = preferences.string(forKey: "model") ?? "deepseek-flash"
        apiContextWindowTokens = preferences.object(forKey: "apiContextWindowTokens") == nil ? ModelRequestLimits.standard.contextWindowTokens : preferences.integer(forKey: "apiContextWindowTokens")
        apiMaximumOutputTokens = preferences.object(forKey: "apiMaximumOutputTokens") == nil ? ModelRequestLimits.standard.maximumOutputTokens : preferences.integer(forKey: "apiMaximumOutputTokens")
        do {
            if FileManager.default.fileExists(atPath: storage.path) {
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: storage))
                restore(snapshot)
            }
        } catch {
            libraryLoadError = "本地记录读取失败，请保留文件后重试：\(error.localizedDescription)"
            message = libraryLoadError
        }
    }
    func reloadLibrary() {
        do {
            let restored = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: storage))
            restore(restored)
            libraryLoadError = nil
        } catch { libraryLoadError = "无法读取书库：\(error.localizedDescription)" }
    }
    private func restore(_ snapshot: Snapshot) {
        jobs = snapshot.jobs; customStyles = snapshot.styles; defaultPreferences = snapshot.preferences
        // Only upgrade a draft that has no evidence of prepared or dispatched work.
        // Started books retain their chunk indices, paid request IDs, and snapshots.
        for i in jobs.indices where jobs[i].status == .draft && jobs[i].checkpoints.isEmpty && jobs[i].reviewDraft == nil &&
            jobs[i].termBatches.isEmpty && (jobs[i].glossaryQueries ?? [:]).isEmpty &&
            (jobs[i].termDiscoveries ?? [:]).isEmpty && (jobs[i].glossaryRejected ?? [:]).isEmpty &&
            jobs[i].glossarySeed == nil && !jobs[i].glossaryReady && jobs[i].glossaryBatch == 0 &&
            jobs[i].result.isEmpty && jobs[i].purchasedWorkID == nil {
            var changed = false
            if jobs[i].options.pipelineVersion == nil {
                jobs[i].options.quality = jobs[i].options.effectiveQuality
                jobs[i].options.pipelineVersion = 2; jobs[i].options.preferences.extraLanguageReview = false
                changed = true
            }
            if jobs[i].options.preparationVersion == nil {
                jobs[i].options.preparationVersion = 2
                if !jobs[i].genreWasCorrected {
                    jobs[i].options.documentKind = DocumentClassifier.detect(text: jobs[i].source, title: jobs[i].title, format: jobs[i].format)
                }
                changed = true
            }
            if changed { jobs[i].replan() }
        }
        // Opening or retrying library loading never starts translation.
        for i in jobs.indices where jobs[i].status == .translating || jobs[i].status == .extracting { jobs[i].status = .paused }
    }
    private func snapshot() -> Snapshot { Snapshot(jobs: jobs, styles: customStyles, preferences: defaultPreferences) }
    func save() async throws {
        guard libraryLoadError == nil else { throw TranslationError.message("书库尚未读取成功，不能覆盖原记录。请先重试读取。") }
        revision += 1; try await disk.save(snapshot(), url: storage, revision: revision)
    }
    func persist() {
        guard libraryLoadError == nil else { message = "书库尚未读取成功，不能覆盖原记录。请先重试读取。"; return }
        revision += 1; let version = revision; let value = snapshot()
        Task { do { try await disk.save(value, url: storage, revision: version) } catch { message = "保存失败：\(error.localizedDescription)" } }
    }
    func job(_ id: String) -> BookJob? { jobs.first { $0.id == id } }
    func update(_ id: String, _ action: (inout BookJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }; let oldKind = jobs[index].options.documentKind; action(&jobs[index]); if jobs[index].options.documentKind != oldKind { jobs[index].replan() }; persist()
    }
    private func prepare(_ imported: ImportedText, id: String = UUID().uuidString) throws -> BookJob {
        guard libraryLoadError == nil else { throw TranslationError.message("请先重试读取书库，避免覆盖原记录。") }
        guard !imported.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, imported.text.count <= 2_000_000 else { throw TranslationError.message("请确认原稿有正文且不超过 200 万字符。") }
        var job = BookJob(title: imported.title, source: imported.text, format: imported.format); job.id = id; job.options.preferences = defaultPreferences
        job.ocrPages = imported.ocrPages; job.sourceDocumentID = imported.sourceDocumentID
        job.options.sourceWasOCR = imported.ocrPages?.contains(where: { $0.usedOCR }) == true ? true : nil
        if let data = imported.coverData { job.coverKey = try CoverStorage.save(data) }
        job.options.sourceLanguage = SourceLanguageDetection.code(for: imported.text)
        job.options.documentKind = DocumentClassifier.detect(text: imported.text, title: imported.title, format: imported.format)
        job.replan(); job.glossaryStrategyVersion = 2
        job.glossaryPoints = job.sourceBatches.reduce(0) { $0 + max(1, Int(ceil(Double($1.unicodeScalars.count) / 1000))) }
        return job
    }
    func add(_ imported: ImportedText) throws -> String {
        let job = try prepare(imported)
        jobs.insert(job, at: 0); persist(); return job.id
    }
    /// Import input is retained until the complete library snapshot is on disk.
    /// A stable ID makes recovery after a crash between saving and draft cleanup idempotent.
    func addPersisted(_ imported: ImportedText, id: String) async throws -> String {
        guard !pendingImportIDs.contains(id) else { throw TranslationError.message("文稿正在保存，请稍候。") }
        if let existing = job(id) {
            guard existing.source == imported.text && existing.format == imported.format else {
                throw TranslationError.message("这份草稿已经入库，但内容不同。请保留草稿并查看书库。")
            }
            try await save()
            return id
        }
        let added = try prepare(imported, id: id)
        pendingImportIDs.insert(id)
        jobs.insert(added, at: 0)
        do {
            try await save()
            pendingImportIDs.remove(id)
            return id
        } catch {
            // Only undo this insertion; other books may have changed while awaiting disk I/O.
            jobs.removeAll { $0.id == id }
            pendingImportIDs.remove(id)
            try? await save()
            throw error
        }
    }
    func renameDraft(_ id: String, title: String) async throws {
        guard !renamingIDs.contains(id) else { throw TranslationError.message("名称正在保存，请稍候。") }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw TranslationError.message("请输入文稿名称。") }
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status == .draft else {
            throw TranslationError.message("只能修改尚未开始翻译的文稿名称。")
        }
        renamingIDs.insert(id)
        defer { renamingIDs.remove(id) }
        let previous = jobs[index].title
        jobs[index].title = title
        do { try await save() }
        catch {
            if let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].title == title { jobs[index].title = previous }
            try? await save()
            throw error
        }
    }
    func canUseOwnAPI(account: CloudAccount, purchases: PurchaseStore) -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--byok-testing") { return true }
        #endif
        return purchases.localOwnAPIUnlocked || account.ownAPIUnlocked
    }
    func provider(account: CloudAccount, purchases: PurchaseStore, own: Bool) throws -> any TranslationProvider {
        #if DEBUG
        if let testingProvider { return testingProvider }
        #endif
        if own {
            guard canUseOwnAPI(account: account, purchases: purchases) else { throw TranslationError.message("请先买断解锁自带 API。") }
            guard let url = URL(string: endpoint), url.scheme == "https", url.host != nil else { throw TranslationError.message("请输入有效的 HTTPS API 地址。") }
            let key = Vault.read("apiKey"); guard !key.isEmpty else { throw TranslationError.message("请先在设置中保存 API 密钥。") }
            try Self.validateConnection(endpoint: endpoint, model: model, key: key, limits: apiRequestLimits)
            return APIProvider(connection: .ownKey(baseURL: url, key: key, model: model), limits: apiRequestLimits)
        }
        guard let url = account.baseURL else { throw TranslationError.message("云端服务尚未配置。请配置服务后使用，或买断并使用自己的 API。") }
        guard account.isLoggedIn else { throw TranslationError.message("请先登录账户，再使用翻译点数。") }
        return APIProvider(connection: .cloud(baseURL: url, token: account.session))
    }
    func begin(_ id: String, account: CloudAccount, purchases: PurchaseStore, approved: Bool = false, partial: Bool = false) {
        guard task == nil, !pendingImportIDs.contains(id), !renamingIDs.contains(id), var job = job(id), job.status != .complete else { return }
        if job.status == .draft && job.checkpoints.isEmpty && job.termBatches.isEmpty && job.reviewDraft == nil && (job.glossaryQueries ?? [:]).isEmpty {
            update(id) { $0.glossaryMode = .accumulated }
            job = self.job(id) ?? job
        }
        if job.status == .reviewing && !approved { return }
        if job.reviewDraft != nil { repair(id, account: account, purchases: purchases); return }
        do {
            let own = job.status == .draft ? ownAPI : job.usesOwnAPI
            let provider = try provider(account: account, purchases: purchases, own: own)
            if job.status == .draft { update(id) { $0.usesOwnAPI = own }; job.usesOwnAPI = own }
            // Freeze an empty document-local seed before the first paid request.
            // Previously started jobs keep their original seed on resume.
            if job.glossarySeed == nil && job.status == .draft && job.termBatches.isEmpty && job.checkpoints.isEmpty {
                update(id) { $0.glossaryStrategyVersion = 2; $0.glossarySeed = $0.displayTerms }
                job = self.job(id) ?? job
            }
            if job.glossaryMode == .accumulated && !job.glossaryReady {
                update(id) { $0.glossaryReady = true }
            }
            if job.glossaryMode == .custom && !job.glossaryReady {
                // Legacy jobs may resume only with their own retained terms.
                let retained = job.glossarySeed ?? job.terms
                guard retained.allSatisfy(GlossaryMemory.isValid) else { throw TranslationError.message("已保存的术语格式无效。") }
                update(id) { $0.terms = retained; $0.glossaryReady = true }
            }
            // A partial budget never bypasses the selected full-text scan or
            // confirmation gate. Users may choose accumulated mode beforehand.
            if partial { update(id) { $0.partialApproved = true } }
            if approved {
                guard job.displayTerms.allSatisfy(GlossaryMemory.isValid) else { throw TranslationError.message("请补充空缺译名，或删除该术语后再确认。") }
                update(id) { $0.terms = $0.displayTerms; $0.glossaryReady = true }
            }
            update(id) { $0.status = $0.glossaryReady ? .translating : .extracting; $0.error = nil }
            activeID = id; liveChunks = [:]; processing = [:]; pauseRequestedID = nil
            task = Task { [weak self] in
                guard let self else { return }
                defer { self.task = nil; self.activeID = nil; self.processing = [:]; self.pauseRequestedID = nil }
                do {
                    // Save the seed and mode before starting any billable request.
                    try await self.save()
                    if let current = self.job(id), !current.glossaryReady {
                        self.update(id) { $0.status = .extracting; $0.error = nil }
                        try await self.save()
                        try await GlossaryEngine().run(jobID: id, batches: current.sourceBatches, target: current.options.targetLanguage, provider: provider, completed: Set(current.termBatches.keys), categorized: current.glossaryStrategyVersion == 2) { [weak self] index, terms in
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
                    try await self.save()
                    let translationProvider: any TranslationProvider
                    if current.glossaryMode == .accumulated && current.glossaryStrategyVersion == 2 {
                        let plan = Chunker.plan(text: current.source, kind: current.options.documentKind, preparationVersion: current.options.preparationVersion)
                        translationProvider = EfficientGlossaryProvider(provider: provider, jobID: id, chunks: plan.chunks,
                            sections: plan.sectionForChunk, kind: current.options.documentKind, target: current.options.targetLanguage,
                            seed: current.glossarySeed ?? current.terms, snapshots: current.termBatches,
                            discoveries: current.termDiscoveries ?? [:], queries: current.glossaryQueries ?? [:], rejected: current.glossaryRejected ?? [:],
                            nameOverrides: { [weak self] in await self?.confirmedNameOverrides(id) ?? [:] },
                            onQuery: { [weak self] group, query in try await self?.recordGlossaryQuery(id, group: group, query: query) },
                            onRejected: { [weak self] group, names in try await self?.recordGlossaryRejected(id, group: group, names: names) },
                            onSnapshot: { [weak self] index, terms in try await self?.recordTerms(id, index: index, terms: terms) },
                            onDiscovery: { [weak self] index, terms in try await self?.recordDiscoveries(id, index: index, terms: terms) })
                    } else if current.glossaryMode == .accumulated {
                        translationProvider = IncrementalGlossaryProvider(provider: provider, jobID: id,
                            chunks: Chunker.plan(text: current.source, kind: current.options.documentKind, preparationVersion: current.options.preparationVersion).chunks,
                            target: current.options.targetLanguage, seed: current.glossarySeed ?? current.terms,
                            snapshots: current.termBatches, nameOverrides: { [weak self] in await self?.confirmedNameOverrides(id) ?? [:] }) { [weak self] index, terms in
                                try await self?.recordTerms(id, index: index, terms: terms)
                            }
                    } else { translationProvider = provider }
                    let result = try await TranslationEngine().run(jobID: id, source: current.source, options: current.options, provider: translationProvider, checkpoints: current.checkpoints, onPartial: { [weak self] index, text in await self?.partial(id, index: index, text: text) }, onEvent: { [weak self] event in await self?.observe(id, event: event) }) { [weak self] checkpoint in
                        try await self?.record(id, checkpoint: checkpoint)
                    }
                    self.update(id) { $0.result = result; $0.status = .complete }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } catch is CancellationError { self.update(id) { $0.status = .paused; if $0.pauseReason == nil { $0.pauseReason = "已暂停" } } }
                catch let error as URLError where error.code == .cancelled { self.update(id) { $0.status = .paused; if $0.pauseReason == nil { $0.pauseReason = "已暂停" } } }
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
                var request = failure.request
                if job.glossaryMode == .accumulated, let terms = job.termBatches[index] {
                    let extra = request.stage == .translate ? [] : job.termDiscoveries?[index] ?? []
                    request.options.glossary = Array(GlossaryMemory.merge(terms + extra).prefix(1000))
                }
                job.reviewDraft = ReviewDraft(original: request, output: failure.output, issues: failure.issues, index: index)
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
                request.glossaryCapture = nil // Manual repair returns text, with the retained glossary.
                if request.reviewMode != true { request.draft = review.output }
                request.reviewNotes = String(review.issues.joined(separator: "\n").prefix(1900))
                review.prepared = request
            }
            guard let request = review.prepared else { return }
            update(id) { $0.reviewDraft = review; $0.status = .translating; $0.error = nil }
            activeID = id; processing = [:]; pauseRequestedID = nil
            task = Task { [weak self] in
                guard let self else { return }
                var succeeded = false
                do {
                    // Persist the exact paid retry identity before dispatch; pause/402 resumes it.
                    try await self.save()
                    self.observe(id, event: .init(requestID: request.requestID, chunkIndex: retained.index, stage: request.stage, state: .started))
                    let output = try await provider.complete(request)
                    try Task.checkCancellation()
                    self.observe(id, event: .init(requestID: request.requestID, chunkIndex: retained.index, stage: request.stage, state: .checking))
                    try CoverageValidator.validateCompletion(request: request, output: output)
                    let plan = Chunker.plan(text: job.source, kind: job.options.documentKind, preparationVersion: job.options.preparationVersion)
                    let text = request.reviewMode == true ? output : EditorNotes.filter(output, source: job.source, chunks: plan.chunks, index: retained.index)
                    try await self.record(id, checkpoint: .init(index: retained.index, stage: retained.original.stage, text: text))
                    self.observe(id, event: .init(requestID: request.requestID, chunkIndex: retained.index, stage: request.stage, state: .finished))
                    self.update(id) { $0.reviewDraft = nil; $0.status = .paused; $0.error = nil }
                    try await self.save(); succeeded = true
                } catch is CancellationError { self.update(id) { $0.status = .paused; if $0.pauseReason == nil { $0.pauseReason = "已暂停" } } }
                catch let error as URLError where error.code == .cancelled { self.update(id) { $0.status = .paused; if $0.pauseReason == nil { $0.pauseReason = "已暂停" } } }
                catch let failure as CoverageFailure { self.retainFailure(id, failure: failure) }
                catch TranslationError.insufficientCredits { self.update(id) { $0.status = .awaitingCredits; $0.error = "点数不足，充值后继续补全。" } }
                catch { self.update(id) { $0.status = .needsReview; $0.error = error.localizedDescription } }
                self.task = nil; self.activeID = nil; self.processing = [:]; self.pauseRequestedID = nil
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
        job.checkpoints = Chunker.plan(text: work.text, kind: job.options.documentKind, preparationVersion: job.options.preparationVersion).chunks.map { .init(index: $0.index, stage: .translate, text: $0.text) }
        jobs.insert(job, at: 0); persist(); return job.id
    }
    private func recordTerms(_ id: String, index batch: Int, terms: [Term]) async throws {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].termBatches[batch] = terms
        let seed = jobs[index].glossarySeed ?? []
        let prepared = jobs[index].termBatches.keys.sorted().flatMap { jobs[index].termBatches[$0] ?? [] }
        let discovered = (jobs[index].termDiscoveries ?? [:]).keys.sorted().flatMap { jobs[index].termDiscoveries?[$0] ?? [] }
        jobs[index].terms = Self.mergeTerms(seed + prepared + discovered)
        jobs[index].glossaryBatch = jobs[index].termBatches.count
        try await save()
    }
    private static func mergeTerms(_ candidates: [Term]) -> [Term] { GlossaryMemory.merge(candidates) }
    private func recordGlossaryQuery(_ id: String, group: Int, query: GlossaryQuery) async throws {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[index].glossaryQueries == nil { jobs[index].glossaryQueries = [:] }
        jobs[index].glossaryQueries?[group] = query; try await save()
    }
    private func recordGlossaryRejected(_ id: String, group: Int, names: [String]) async throws {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[index].glossaryRejected == nil { jobs[index].glossaryRejected = [:] }
        jobs[index].glossaryRejected?[group] = names; try await save()
    }
    private func recordDiscoveries(_ id: String, index chunk: Int, terms: [Term]) async throws {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[index].termDiscoveries == nil { jobs[index].termDiscoveries = [:] }
        jobs[index].termDiscoveries?[chunk] = terms
        let seed = jobs[index].glossarySeed ?? []
        let prepared = jobs[index].termBatches.keys.sorted().flatMap { jobs[index].termBatches[$0] ?? [] }
        let discovered = (jobs[index].termDiscoveries ?? [:]).keys.sorted().flatMap { jobs[index].termDiscoveries?[$0] ?? [] }
        jobs[index].terms = GlossaryMemory.merge(seed + prepared + discovered)
        try await save()
    }
    private func record(_ id: String, checkpoint: Checkpoint) async throws {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].checkpoints.removeAll { $0.index == checkpoint.index && $0.stage == checkpoint.stage }
        jobs[index].checkpoints.append(checkpoint); liveChunks[checkpoint.index] = nil; try await save()
    }
    private func partial(_ id: String, index: Int, text: String) { if activeID == id { liveChunks[index] = text } }
    func pause(reason: String = "已暂停") {
        guard let id = activeID, task != nil, pauseRequestedID == nil else { return }
        pauseRequestedID = id
        update(id) { $0.pauseReason = reason }
        task?.cancel()
    }
    func observe(_ id: String, event: ProcessingEvent) {
        guard activeID == id else { return }
        let key = "\(event.chunkIndex)-\(event.stage.rawValue)"
        if event.state == .finished { processing[key] = nil }
        else { processing[key] = event }
    }
    func saveNameOverride(bookID: String, termID: String, target: String) async throws {
        let value = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw TranslationError.message("请输入译名。") }
        guard value.unicodeScalars.count <= 400 else { throw TranslationError.message("译名不能超过 400 字符。") }
        guard let index = jobs.firstIndex(where: { $0.id == bookID }), jobs[index].terms.contains(where: { $0.id == termID }) else { throw TranslationError.message("这个译名已不存在，请返回列表重试。") }
        let key = bookID + "|" + termID
        guard savingNames.insert(key).inserted else { throw TranslationError.message("正在保存，请稍候。") }
        defer { savingNames.remove(key); namesBeforeSave[key] = nil }
        let previous = jobs[index].nameOverrides?[termID]
        namesBeforeSave[key] = previous
        if jobs[index].nameOverrides == nil { jobs[index].nameOverrides = [:] }
        jobs[index].nameOverrides?[termID] = value
        do { try await save() }
        catch {
            if let current = jobs.firstIndex(where: { $0.id == bookID }), jobs[current].nameOverrides?[termID] == value {
                jobs[current].nameOverrides?[termID] = previous
                persist()
            }
            throw error
        }
    }
    /// Providers cannot observe an optimistic preference before its save succeeds.
    func confirmedNameOverrides(_ id: String) -> [String: String] {
        var values = job(id)?.nameOverrides ?? [:]
        for term in Array(values.keys) {
            let key = id + "|" + term
            if savingNames.contains(key) { values[term] = namesBeforeSave[key] }
        }
        return values
    }
    static func validateConnection(endpoint: String, model: String, key: String, limits: ModelRequestLimits? = nil) throws {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw TranslationError.message("请输入有效的 HTTPS API 地址，不要在地址中包含密钥。")
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranslationError.message("请输入模型名称。") }
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranslationError.message("请输入 API 密钥。") }
        if let limits { try limits.validate() }
    }
    var connectionIssue: String? {
        do { try Self.validateConnection(endpoint: endpoint, model: model, key: Vault.read("apiKey"), limits: apiRequestLimits); return nil }
        catch { return error.localizedDescription }
    }
    func setOwnAPI(_ value: Bool) { ownAPI = value; preferences.set(value, forKey: "ownAPI") }
    func saveConnection(endpoint: String, model: String, key: String, limits: ModelRequestLimits? = nil) throws {
        let limits = limits ?? apiRequestLimits
        try Self.validateConnection(endpoint: endpoint, model: model, key: key, limits: limits)
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        try connectionKeySaver(key.trimmingCharacters(in: .whitespacesAndNewlines))
        self.endpoint = endpoint; self.model = model
        apiContextWindowTokens = limits.contextWindowTokens; apiMaximumOutputTokens = limits.maximumOutputTokens
        preferences.set(endpoint, forKey: "endpoint"); preferences.set(model, forKey: "model"); preferences.set(ownAPI, forKey: "ownAPI")
        preferences.set(apiContextWindowTokens, forKey: "apiContextWindowTokens"); preferences.set(apiMaximumOutputTokens, forKey: "apiMaximumOutputTokens")
    }
    func saveConnection(key: String) throws {
        try saveConnection(endpoint: endpoint, model: model, key: key)
    }
}
