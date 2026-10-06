import Foundation
import Observation
import TranslationCore

struct ImportDraft: Codable, Sendable {
    var id: String; var title: String; var file: String
    var url: URL { ImportFiles.directory(id).appendingPathComponent(file) }
}
enum ImportFiles {
    static let root = URL.applicationSupportDirectory.appendingPathComponent("BookLLM/imports", isDirectory: true)
    static func directory(_ id: String) -> URL { root.appendingPathComponent(UUID(uuidString: id)?.uuidString ?? "invalid", isDirectory: true) }
    static func copy(_ url: URL) throws -> ImportDraft {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let generatedScan = url.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL && url.lastPathComponent.hasPrefix("扫描文稿-") && url.pathExtension == "pdf"
        defer { if generatedScan { try? FileManager.default.removeItem(at: url) } }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 40_000_000 else { throw TranslationError.message("请导入 40 MB 以内的文件。") }
        let id = UUID().uuidString, file = "source." + url.pathExtension.lowercased()
        let draft = ImportDraft(id: id, title: generatedScan ? "扫描文稿" : url.deletingPathExtension().lastPathComponent, file: file)
        try FileManager.default.createDirectory(at: directory(id), withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: url, to: draft.url)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: draft.url.path)
            try JSONEncoder().encode(draft).write(to: root.appendingPathComponent("pending.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return draft
        } catch { try? FileManager.default.removeItem(at: directory(id)); throw error }
    }
    static func cached(_ draft: ImportDraft) -> [Int: OCRPage] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory(draft.id), includingPropertiesForKeys: nil)) ?? []
        var pages: [Int: OCRPage] = [:], cachedBytes = 0
        for url in files where url.lastPathComponent.hasPrefix("page-") && url.pathExtension == "json" {
            if let attributes = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = attributes.fileSize, size <= 4_000_000, cachedBytes + size <= 64_000_000, let data = try? Data(contentsOf: url), let page = try? JSONDecoder().decode(OCRPage.self, from: data), (1...2000).contains(page.number) { pages[page.number] = page; cachedBytes += data.count }
        }
        return pages
    }
    static func save(_ page: OCRPage, draft: ImportDraft) throws {
        try JSONEncoder().encode(page).write(to: directory(draft.id).appendingPathComponent("page-\(page.number).json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func pending() -> ImportDraft? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("pending.json")), let draft = try? JSONDecoder().decode(ImportDraft.self, from: data), UUID(uuidString: draft.id) != nil, draft.file == "source." + draft.url.pathExtension else { return nil }
        return FileManager.default.fileExists(atPath: draft.url.path) ? draft : nil
    }
    static func clear(_ draft: ImportDraft?, discard: Bool) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent("pending.json"))
        if discard, let draft { try? FileManager.default.removeItem(at: directory(draft.id)) }
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
    @ObservationIgnored private weak var studio: StudioStore?
    private var task: Task<Void, Never>?
    init() { draft = ImportFiles.pending() }
    var hasPending: Bool { draft != nil }
    func start(_ url: URL, studio: StudioStore) {
        self.studio = studio
        guard task == nil else { return }
        guard draft == nil else { presented = true; error = "请先完成或放弃当前导入，再导入其他文稿。"; return }
        presented = true; phase = .processing; error = nil; progress = .init(completed: 0, total: 0, recognized: 0)
        task = Task {
            do {
                let prepared = try await Task.detached(priority: .userInitiated) { try ImportFiles.copy(url) }.value
                draft = prepared; try Task.checkCancellation(); task = nil; run(prepared)
            } catch is CancellationError { phase = .paused; task = nil }
            catch { self.error = error.localizedDescription; phase = .failed; task = nil }
        }
    }
    func resume(studio: StudioStore) { self.studio = studio; guard task == nil, let draft else { return }; presented = true; run(draft) }
    private func run(_ draft: ImportDraft) {
        phase = .processing; error = nil
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let cached = ImportFiles.cached(draft)
                var imported = try await DocumentIO.read(draft.url, cached: cached) { [weak self] page, progress in
                    try ImportFiles.save(page, draft: draft)
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
    private func finished(_ imported: ImportedText) {
        result = imported; phase = .reviewing; task = nil
        if imported.ocrPages?.contains(where: { $0.usedOCR || $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) != true, let studio {
            do { try accept(imported, studio: studio) } catch { self.error = error.localizedDescription; phase = .failed }
        }
    }
    private func stopped(_ message: String?) { phase = message == nil ? .paused : .failed; error = message; task = nil }
    func pause() { task?.cancel() }
    func discard() {
        guard task == nil else { return }
        ImportFiles.clear(draft, discard: true); draft = nil; result = nil; error = nil; presented = false
    }
    func accept(_ imported: ImportedText, studio: StudioStore) throws {
        guard task == nil else { return }
        jobID = try studio.add(imported); ImportFiles.clear(draft, discard: false)
        draft = nil; result = nil; presented = false
    }
}
