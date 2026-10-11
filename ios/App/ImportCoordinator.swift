import Foundation
import Observation
import TranslationCore

struct ImportDraft: Codable, Sendable {
    var id: String; var title: String; var file: String
    var url: URL { ImportFiles.directory(id).appendingPathComponent(file) }
    func url(rootURL: URL) -> URL { ImportFiles.directory(id, rootURL: rootURL).appendingPathComponent(file) }
}
enum ImportFiles {
    static var root: URL {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--paper-ui-testing") { return URL.cachesDirectory.appendingPathComponent("PaperUITests/imports", isDirectory: true) }
        #endif
        return URL.applicationSupportDirectory.appendingPathComponent("BookLLM/imports", isDirectory: true)
    }
    static func directory(_ id: String, rootURL: URL = root) -> URL { rootURL.appendingPathComponent(UUID(uuidString: id)?.uuidString ?? "invalid", isDirectory: true) }
    static func copy(_ url: URL, rootURL: URL = root) throws -> ImportDraft {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let generatedScan = url.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL && url.lastPathComponent.hasPrefix("扫描文稿-") && url.pathExtension == "pdf"
        defer { if generatedScan { try? FileManager.default.removeItem(at: url) } }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 40_000_000 else { throw TranslationError.message("请导入 40 MB 以内的文件。") }
        let id = UUID().uuidString, file = "source." + url.pathExtension.lowercased()
        let draft = ImportDraft(id: id, title: generatedScan ? "扫描文稿" : url.deletingPathExtension().lastPathComponent, file: file)
        try FileManager.default.createDirectory(at: directory(id, rootURL: rootURL), withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: url, to: draft.url(rootURL: rootURL))
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: draft.url(rootURL: rootURL).path)
            try JSONEncoder().encode(draft).write(to: rootURL.appendingPathComponent("pending.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return draft
        } catch { try? FileManager.default.removeItem(at: directory(id, rootURL: rootURL)); throw error }
    }
    static func cached(_ draft: ImportDraft, rootURL: URL = root) -> [Int: OCRPage] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory(draft.id, rootURL: rootURL), includingPropertiesForKeys: nil)) ?? []
        var pages: [Int: OCRPage] = [:], cachedBytes = 0
        for url in files where url.lastPathComponent.hasPrefix("page-") && url.pathExtension == "json" {
            if let attributes = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = attributes.fileSize, size <= 4_000_000, cachedBytes + size <= 64_000_000, let data = try? Data(contentsOf: url), let page = try? JSONDecoder().decode(OCRPage.self, from: data), (1...2000).contains(page.number) { pages[page.number] = page; cachedBytes += data.count }
        }
        return pages
    }
    static func save(_ page: OCRPage, draft: ImportDraft, rootURL: URL = root) throws {
        try JSONEncoder().encode(page).write(to: directory(draft.id, rootURL: rootURL).appendingPathComponent("page-\(page.number).json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func readPending(rootURL: URL = root) throws -> ImportDraft? {
        let index = rootURL.appendingPathComponent("pending.json")
        guard FileManager.default.fileExists(atPath: index.path) else { return nil }
        let data = try Data(contentsOf: index)
        let draft = try JSONDecoder().decode(ImportDraft.self, from: data)
        guard UUID(uuidString: draft.id) != nil, draft.file == "source." + draft.url.pathExtension, !draft.url.pathExtension.isEmpty else {
            throw TranslationError.message("导入恢复记录格式无效。")
        }
        guard FileManager.default.fileExists(atPath: draft.url(rootURL: rootURL).path) else {
            throw TranslationError.message("导入的原文件暂时无法读取。")
        }
        return draft
    }
    static func pending(rootURL: URL = root) -> ImportDraft? { try? readPending(rootURL: rootURL) }
    static func removePending(rootURL: URL = root) throws {
        let index = rootURL.appendingPathComponent("pending.json")
        if FileManager.default.fileExists(atPath: index.path) { try FileManager.default.removeItem(at: index) }
    }
    static func clear(_ draft: ImportDraft?, discard: Bool, rootURL: URL = root) {
        try? FileManager.default.removeItem(at: rootURL.appendingPathComponent("pending.json"))
        if discard, let draft { try? FileManager.default.removeItem(at: directory(draft.id, rootURL: rootURL)) }
    }
}
@MainActor @Observable final class ImportCoordinator {
    enum Phase { case processing, paused, reviewing, failed }
    var draft: ImportDraft?
    var result: ImportedText?
    var phase = Phase.paused
    var progress = OCRProgress(completed: 0, total: 0, recognized: 0)
    var error: String?
    var presented = false
    var jobID: String?
    private(set) var accepting = false
    private(set) var recoveryError: String?
    let rootURL: URL
    @ObservationIgnored private weak var studio: StudioStore?
    private var task: Task<Void, Never>?
    init(rootURL: URL = ImportFiles.root) { self.rootURL = rootURL; loadPending() }
    var hasPending: Bool { draft != nil || recoveryError != nil }
    var needsOCRReview: Bool { result?.ocrPages?.contains(where: { $0.usedOCR || $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) == true }
    private func loadPending() {
        do { draft = try ImportFiles.readPending(rootURL: rootURL); recoveryError = nil }
        catch {
            draft = nil; phase = .failed
            recoveryError = "导入恢复记录读取失败。原文件和已识别页面仍保留；请重试读取，或明确放弃这次导入后再导入新文件。"
        }
    }
    func retryRecovery(studio: StudioStore) {
        guard task == nil, !accepting else { return }
        loadPending()
        if recoveryError == nil {
            error = nil; phase = .paused
            if draft != nil { resume(studio: studio) }
        }
    }
    func reconcile(studio: StudioStore) {
        guard studio.libraryLoadError == nil, let draft, !studio.pendingImportIDs.contains(draft.id),
              studio.job(draft.id)?.sourceDocumentID == draft.id else { return }
        ImportFiles.clear(draft, discard: false, rootURL: rootURL)
        self.draft = nil; result = nil
    }
    func start(_ url: URL, studio: StudioStore) {
        self.studio = studio
        guard task == nil, !accepting else { return }
        if draft == nil { loadPending(); reconcile(studio: studio) }
        guard recoveryError == nil else { presented = true; return }
        guard ["txt", "md", "markdown", "pdf", "epub", "docx"].contains(url.pathExtension.lowercased()) else {
            studio.message = "请选择 EPUB、PDF、DOCX、TXT 或 Markdown 文稿。"
            return
        }
        guard draft == nil else { presented = true; error = "请先完成或放弃当前导入，再导入其他文稿。"; return }
        presented = true; phase = .processing; error = nil; progress = .init(completed: 0, total: 0, recognized: 0)
        task = Task {
            do {
                let root = rootURL
                let prepared = try await Task.detached(priority: .userInitiated) { try ImportFiles.copy(url, rootURL: root) }.value
                draft = prepared; try Task.checkCancellation(); task = nil; run(prepared)
            } catch is CancellationError { phase = .paused; task = nil }
            catch { self.error = error.localizedDescription; phase = .failed; task = nil }
        }
    }
    func resume(studio: StudioStore) {
        self.studio = studio
        guard task == nil, !accepting else { return }
        presented = true
        guard recoveryError == nil, let draft else { return }
        if phase == .reviewing, result != nil { return }
        run(draft)
    }
    private func run(_ draft: ImportDraft) {
        phase = .processing; error = nil
        let root = rootURL
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let cached = ImportFiles.cached(draft, rootURL: root)
                var imported = try await DocumentIO.read(draft.url(rootURL: root), cached: cached) { [weak self] page, progress in
                    try ImportFiles.save(page, draft: draft, rootURL: root)
                    await self?.updateProgress(progress)
                }
                imported.title = draft.title; imported.sourceDocumentID = draft.id
                try Task.checkCancellation()
                await self?.finished(imported)
            } catch is CancellationError { await self?.stopped(nil) }
            catch { await self?.stopped(error.localizedDescription) }
        }
    }
    private func updateProgress(_ value: OCRProgress) { progress = value }
    private func finished(_ imported: ImportedText) async {
        result = imported; phase = .reviewing; task = nil
        if !needsOCRReview, let studio {
            do { try await accept(imported, studio: studio) } catch { self.error = error.localizedDescription; phase = .reviewing }
        }
    }
    private func stopped(_ message: String?) { phase = message == nil ? .paused : .failed; error = message; task = nil }
    func pause() { task?.cancel() }
    @discardableResult func discard() -> Bool {
        guard task == nil, !accepting else { return false }
        do {
            try ImportFiles.removePending(rootURL: rootURL)
            if let draft { try? FileManager.default.removeItem(at: ImportFiles.directory(draft.id, rootURL: rootURL)) }
            draft = nil; result = nil; error = nil; recoveryError = nil; presented = false
            return true
        } catch {
            self.error = "无法放弃这次导入：\(error.localizedDescription) 恢复记录仍保留，请重试。"
            return false
        }
    }
    func accept(_ imported: ImportedText, studio: StudioStore) async throws {
        guard task == nil, !accepting, recoveryError == nil, let draft else { throw TranslationError.message("当前导入尚未准备好，请稍后重试。") }
        accepting = true; error = nil
        defer { accepting = false }
        do {
            jobID = try await studio.addPersisted(imported, id: draft.id)
            ImportFiles.clear(draft, discard: false, rootURL: rootURL)
            self.draft = nil; result = nil; presented = false
        } catch {
            self.error = "加入书库失败：\(error.localizedDescription) 已识别的原稿仍保留，可重试。"
            throw error
        }
    }
}
