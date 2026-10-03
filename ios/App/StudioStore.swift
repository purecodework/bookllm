import Foundation
import Observation
import TranslationCore
import UIKit

enum JobStatus: String, Codable, Sendable { case draft, extracting, reviewing, translating, paused, complete, failed }
struct ReadingChapter: Codable, Identifiable, Sendable { var id: Int; var title: String; var chunks: [Int] }
struct BookJob: Codable, Identifiable, Sendable {
    var id = UUID().uuidString
    var title: String
    var source: String
    var format: String
    var created = Date()
    var options = TranslationOptions()
    var glossaryMode = GlossaryMode.automatic
    var terms: [Term] = []
    var checkpoints: [Checkpoint] = []
    var status = JobStatus.draft
    var glossaryReady = false
    var glossaryBatch = 0
    var termBatches: [Int: [Term]] = [:]
    var result = ""
    var error: String?
    var usesOwnAPI = false
    var chapters: [ReadingChapter] = []
    var chunkCount = 0
    var basePoints = 0
    var glossaryPoints = 0
    var progress: Double { Double(checkpoints.count) / Double(max(1, chunkCount * options.stages.count)) }
    var statusText: String {
        switch status { case .draft: "待翻译"; case .extracting: "整理术语"; case .reviewing: "等待术语校对"; case .translating: "翻译中"; case .paused: "已暂停"; case .complete: "翻译完成"; case .failed: "需要重试" }
    }
    var estimate: Int {
        basePoints * options.stages.count + (glossaryMode == .custom || glossaryReady ? 0 : glossaryPoints)
    }

    var readableChapters: [ReadingChapter] {
        guard let final = options.stages.last else { return [] }
        let finished = Set(checkpoints.filter { $0.stage == final }.map(\.index))
        return Array(chapters.prefix { !$0.chunks.isEmpty && $0.chunks.allSatisfy { finished.contains($0) } })
    }
    mutating func replan() {
        let plan = Chunker.plan(text: source, kind: options.documentKind)
        chunkCount = plan.chunks.count
        basePoints = plan.chunks.reduce(0) { $0 + max(1, Int(ceil(Double($1.text.unicodeScalars.count) / 1000))) }
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
    func add(_ imported: ImportedText) -> String {
        var job = BookJob(title: imported.title, source: imported.text, format: imported.format); job.options.preferences = defaultPreferences
        job.options.documentKind = imported.format == "EPUB" || imported.format == "TXT" ? .fiction : imported.format == "MD" || imported.format == "MARKDOWN" ? .technical : .general
        job.replan()
        job.glossaryPoints = job.sourceBatches.reduce(0) { $0 + max(1, Int(ceil(Double($1.unicodeScalars.count) / 1000))) }
        jobs.insert(job, at: 0); persist(); return job.id
    }
    func provider(account: CloudAccount, purchases: PurchaseStore, own: Bool) throws -> APIProvider {
        if own {
            #if DEBUG
            let debugUnlocked = ProcessInfo.processInfo.arguments.contains("--byok-testing")
            #else
            let debugUnlocked = false
            #endif
            guard purchases.localOwnAPIUnlocked || account.ownAPIUnlocked || debugUnlocked else { throw TranslationError.message("请先买断解锁自带 API。") }
            guard let url = URL(string: endpoint), url.scheme == "https", url.host != nil else { throw TranslationError.message("请输入有效的 HTTPS API 地址。") }
            let key = Vault.read("apiKey"); guard !key.isEmpty else { throw TranslationError.message("请先在设置中保存 API 密钥。") }
            return APIProvider(connection: .ownKey(baseURL: url, key: key, model: model))
        }
        guard let url = account.baseURL else { throw TranslationError.message("云端服务尚未配置。请配置服务后使用，或买断并使用自己的 API。") }
        guard account.isLoggedIn else { throw TranslationError.message("请先登录账户，再使用翻译点数。") }
        return APIProvider(connection: .cloud(baseURL: url, token: account.session))
    }
    func begin(_ id: String, account: CloudAccount, purchases: PurchaseStore, approved: Bool = false) {
        guard task == nil, var job = job(id), job.status != .complete else { return }
        if job.status == .reviewing && !approved { return }
        do {
            let own = job.status == .draft ? ownAPI : job.usesOwnAPI
            let provider = try provider(account: account, purchases: purchases, own: own)
            if job.status == .draft { update(id) { $0.usesOwnAPI = own }; job.usesOwnAPI = own }
            if job.glossaryMode == .custom && !job.glossaryReady {
                guard !libraryTerms.isEmpty, libraryTerms.allSatisfy({ !$0.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw TranslationError.message("请先在术语库中添加或导入术语。") }
                update(id) { $0.terms = libraryTerms; $0.glossaryReady = true }
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
                    let result = try await TranslationEngine().run(jobID: id, source: current.source, options: current.options, provider: provider, checkpoints: current.checkpoints, onPartial: { [weak self] index, text in await self?.partial(id, index: index, text: text) }) { [weak self] checkpoint in
                        try await self?.record(id, checkpoint: checkpoint)
                    }
                    self.update(id) { $0.result = result; $0.status = .complete }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } catch is CancellationError { self.update(id) { $0.status = .paused } }
                catch let error as URLError where error.code == .cancelled { self.update(id) { $0.status = .paused } }
                catch { self.update(id) { $0.status = .failed; $0.error = error.localizedDescription } }
                if account.isLoggedIn { try? await account.refresh() }
            }
        } catch { message = error.localizedDescription }
    }
    private func recordTerms(_ id: String, index batch: Int, terms: [Term]) async throws {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].termBatches[batch] = terms
        var known = Set<String>()
        jobs[index].terms = jobs[index].termBatches.keys.sorted().flatMap { jobs[index].termBatches[$0] ?? [] }.filter { !$0.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.source.count <= 200 && $0.target.count <= 400 && known.insert($0.source.lowercased()).inserted }
        jobs[index].glossaryBatch = jobs[index].termBatches.count
        try await save()
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
