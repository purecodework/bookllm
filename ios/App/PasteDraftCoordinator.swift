import Foundation
import Observation
import TranslationCore

struct PasteDraft: Codable, Equatable, Sendable {
    var id = UUID().uuidString
    var title = ""
    var text = ""
    var hasContent: Bool { !title.isEmpty || !text.isEmpty }
}

/// Owns only text that has not yet been added to the library.
@MainActor @Observable final class PasteDraftCoordinator {
    private(set) var draft: PasteDraft?
    private(set) var loadError: String?
    private(set) var saveError: String?
    private(set) var savingToLibrary = false
    private(set) var isSaved = false
    let storageURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    static var defaultStorageURL: URL {
        #if DEBUG
        if PaperUITestSupport.enabled {
            return URL.cachesDirectory.appendingPathComponent("PaperUITests/paste-draft.json")
        }
        #endif
        return URL.applicationSupportDirectory.appendingPathComponent("BookLLM/paste-draft.json")
    }
    init(storageURL: URL = PasteDraftCoordinator.defaultStorageURL) {
        self.storageURL = storageURL
        #if DEBUG
        if PaperUITestSupport.enabled && ProcessInfo.processInfo.arguments.contains("--paper-ui-reset") && storageURL == Self.defaultStorageURL {
            try? FileManager.default.removeItem(at: storageURL)
        }
        #endif
        reload()
    }
    var hasDraft: Bool { draft?.hasContent == true || loadError != nil }
    func open() { if draft == nil && loadError == nil { draft = PasteDraft() } }
    func reconcile(studio: StudioStore) {
        guard studio.libraryLoadError == nil, let draft, !studio.pendingImportIDs.contains(draft.id),
              let book = studio.job(draft.id), book.source == draft.text, book.format == "TXT" else { return }
        // The book is durable. A crash during cleanup must not display it twice.
        try? FileManager.default.removeItem(at: storageURL)
        self.draft = nil; saveError = nil; isSaved = false
    }
    func reload() {
        saveTask?.cancel()
        guard FileManager.default.fileExists(atPath: storageURL.path) else { draft = nil; loadError = nil; saveError = nil; isSaved = false; return }
        do {
            let value = try JSONDecoder().decode(PasteDraft.self, from: Data(contentsOf: storageURL))
            guard UUID(uuidString: value.id) != nil else { throw TranslationError.message("草稿编号无效。") }
            draft = value; loadError = nil; saveError = nil; isSaved = true
        } catch {
            draft = nil
            isSaved = false
            loadError = "粘贴草稿读取失败，原文件已保留。可重试读取，或明确放弃后重新粘贴。"
        }
    }
    func setTitle(_ value: String) { change { $0.title = value } }
    func setText(_ value: String) { change { $0.text = value } }
    private func change(_ action: (inout PasteDraft) -> Void) {
        guard loadError == nil, !savingToLibrary else { return }
        if draft == nil { draft = PasteDraft() }
        action(&draft!)
        isSaved = false
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)); _ = self?.flush() } catch { }
        }
    }
    @discardableResult func flush() -> Bool {
        saveTask?.cancel(); saveTask = nil
        guard loadError == nil else { return false }
        guard let draft else { return true }
        do {
            if draft.hasContent {
                try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(draft).write(to: storageURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } else if FileManager.default.fileExists(atPath: storageURL.path) {
                try FileManager.default.removeItem(at: storageURL)
            }
            saveError = nil; isSaved = draft.hasContent; return true
        } catch {
            saveError = "草稿未保存：\(error.localizedDescription) 输入仍保留，请重试。"
            return false
        }
    }
    @discardableResult func discard() -> Bool {
        guard !savingToLibrary else { return false }
        saveTask?.cancel(); saveTask = nil
        do {
            if FileManager.default.fileExists(atPath: storageURL.path) { try FileManager.default.removeItem(at: storageURL) }
            draft = nil; loadError = nil; saveError = nil; isSaved = false; return true
        } catch {
            saveError = "无法放弃草稿：\(error.localizedDescription) 请重试。"
            return false
        }
    }
    func addToLibrary(studio: StudioStore) async throws -> String {
        guard !savingToLibrary else { throw TranslationError.message("正在加入书库，请稍候。") }
        guard loadError == nil, let draft else { throw TranslationError.message("请先恢复或重新粘贴草稿。") }
        guard flush() else { throw TranslationError.message(saveError ?? "草稿尚未保存，请重试。") }
        savingToLibrary = true
        defer { savingToLibrary = false }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = try await studio.addPersisted(.init(title: title.isEmpty ? "未命名" : title, text: draft.text, format: "TXT"), id: draft.id)
        // A retained file after a cleanup failure is safe: the stable ID makes retry idempotent.
        do {
            if FileManager.default.fileExists(atPath: storageURL.path) { try FileManager.default.removeItem(at: storageURL) }
            saveError = nil
        } catch {
            saveError = "文稿已入库，临时草稿尚未清除。再次添加不会生成重复文稿。"
        }
        self.draft = nil; isSaved = false
        return id
    }
}
