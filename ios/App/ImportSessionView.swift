import SwiftUI
import UIKit
import TranslationCore

struct ImportSessionView: View {
    @Environment(ImportCoordinator.self) private var importer
    @Environment(StudioStore.self) private var studio
    @State private var discarding = false
    var body: some View {
        NavigationStack {
            Group {
                if importer.phase == .reviewing, let result = importer.result {
                    OCRReviewView(imported: result) { reviewed in
                        do { try importer.accept(reviewed, studio: studio) } catch { studio.message = error.localizedDescription }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(importer.draft?.title ?? "读取文稿").font(.system(size: 25, weight: .medium, design: .serif))
                        HStack { Text(importer.phase == .processing ? "读取与识别" : importer.phase == .paused ? "已暂停" : "未完成导入"); Spacer(); if importer.phase == .processing { ThinkingDots() } }
                        if importer.progress.total > 0 {
                            ProgressView(value: Double(importer.progress.completed), total: Double(importer.progress.total)).tint(Ink.orange)
                            Text("\(importer.progress.completed) / \(importer.progress.total) 页 · OCR \(importer.progress.recognized) 页").font(.system(size: 12)).foregroundStyle(Ink.muted)
                        } else if importer.phase == .processing { ProgressView() }
                        Text("本机处理，不扣翻译点数。已完成页面会保存。").font(.system(size: 13)).foregroundStyle(Ink.muted)
                        if let error = importer.error { Text(error).font(.system(size: 13)).foregroundStyle(Ink.orange) }
                        if importer.phase == .processing { PrimaryButton(title: "暂停识别", icon: "pause") { importer.pause() } }
                        else {
                            if importer.draft != nil { PrimaryButton(title: "继续识别", icon: "play") { importer.resume(studio: studio) } }
                            Button("放弃导入", role: .destructive) { importer.discard() }.font(.system(size: 13))
                            Button("稍后继续") { importer.presented = false }.font(.system(size: 13))
                        }
                        Spacer()
                    }.padding(26)
                }
            }.background(Ink.paper).navigationTitle(importer.phase == .reviewing ? "核对识别原稿" : "导入").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if importer.phase == .reviewing {
                        ToolbarItem(placement: .topBarLeading) { Button("放弃", role: .destructive) { discarding = true } }
                        ToolbarItem(placement: .topBarTrailing) { Button("稍后核对") { importer.presented = false } }
                    }
                }
                .confirmationDialog("放弃这次导入？", isPresented: $discarding, titleVisibility: .visible) { Button("放弃导入", role: .destructive) { importer.discard() } } message: { Text("识别稿将删除，原始文件不会改动。") }
        }.interactiveDismissDisabled()
    }
}
struct OCRReviewView: View {
    @Environment(\.scenePhase) private var scenePhase
    let imported: ImportedText
    var readOnly = false
    var saveTitle: String
    let onSave: (ImportedText) -> Void
    @State private var pages: [OCRPage]
    @State private var selected = 0
    @State private var skipped = Set<Int>()
    @State private var preview: Data?
    @State private var showOriginal = false
    @State private var originalError: String?
    @State private var pendingEdits: [Int: OCRPage] = [:]
    @State private var saveTask: Task<Void, Never>?
    @State private var saveError: String?
    @State private var rereading: Int?
    @State private var rereadTask: Task<Void, Never>?
    @State private var rereadError: String?
    init(imported: ImportedText, readOnly: Bool = false, saveTitle: String = "确认原稿，加入书架", onSave: @escaping (ImportedText) -> Void) {
        self.imported = imported; self.readOnly = readOnly; self.saveTitle = saveTitle; self.onSave = onSave
        let initial = imported.ocrPages ?? [.init(number: 1, text: imported.text, usedOCR: false)]
        _pages = State(initialValue: initial)
        _skipped = State(initialValue: Set(initial.filter { $0.confirmedEmpty == true }.map(\.number)))
    }
    private var emptyPages: Set<Int> { Set(pages.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.number)) }
    private var canSave: Bool { rereading == nil && emptyPages.isSubset(of: skipped) && pages.reduce(0, { $0 + $1.text.count + 2 }) <= 2_000_000 && pages.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    var body: some View {
        if pages.indices.contains(selected) {
            let page = pages[selected]
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack { Text(imported.title).font(.system(size: 20, weight: .medium, design: .serif)); Spacer(); Picker("页面", selection: $selected) { ForEach(pages.indices, id: \.self) { index in Text("第 \(pages[index].number) 页\(pages[index].warnings.isEmpty ? "" : " · 核对")").tag(index) } }.pickerStyle(.menu).tint(Ink.text) }
                    HStack { Text(page.usedOCR ? "OCR 原稿" : "PDF 文字层").font(.system(size: 12)).foregroundStyle(Ink.muted); Spacer(); Button(showOriginal ? "收起原页" : "查看原页") { showOriginal.toggle() }.font(.system(size: 13)) }
                    if !readOnly, !page.usedOCR { Button(rereading == page.number ? "正在识别本页…" : "原稿缺字？识别本页") { reread(page) }.font(.system(size: 12)).disabled(rereading != nil) }
                    if let rereadError { Text(rereadError).font(.system(size: 12)).foregroundStyle(Ink.orange) }
                    if showOriginal {
                        if let preview, let image = UIImage(data: preview) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 440).clipShape(RoundedRectangle(cornerRadius: 10)) }
                        else if let originalError { Text(originalError).font(.system(size: 12)).foregroundStyle(Ink.muted) }
                        else { ProgressView() }
                    }
                    if !page.warnings.isEmpty { Text(page.warnings.joined(separator: "\n")).font(.system(size: 12)).foregroundStyle(Ink.orange) }
                    if !page.uncertainLines.isEmpty {
                        DisclosureGroup("\(page.uncertainLines.count) 行需留意") { ForEach(page.uncertainLines) { line in Text(line.text).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) } }.font(.system(size: 13))
                    }
                    if readOnly { Text(page.text).font(.system(size: 17, design: .serif)).lineSpacing(7).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    else { TextEditor(text: Binding(get: { pages[selected].text }, set: { pages[selected].text = $0; scheduleSave(pages[selected]) })).font(.system(size: 16, design: .serif)).frame(minHeight: 320).scrollContentBackground(.hidden).padding(12).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 14)) }
                    if emptyPages.contains(page.number), !readOnly {
                        Toggle("确认这页无正文，跳过", isOn: Binding(get: { skipped.contains(page.number) }, set: { if $0 { skipped.insert(page.number) } else { skipped.remove(page.number) }; pages[selected].confirmedEmpty = $0; scheduleSave(pages[selected]) })).font(.system(size: 13))
                    }
                    if !readOnly {
                        Text("先核对人名、数字、诗行与多栏顺序，翻译会以此原稿为准。OCR 置信度不代表内容一定正确。").font(.system(size: 12)).foregroundStyle(Ink.muted)
                        if !emptyPages.isSubset(of: skipped) { Text("还有 \(emptyPages.subtracting(skipped).count) 页没有正文，需逐页确认。").font(.system(size: 12)).foregroundStyle(Ink.orange) }
                        if let saveError { Text(saveError).font(.system(size: 12)).foregroundStyle(Ink.orange) }
                        PrimaryButton(title: saveTitle, icon: "checkmark") {
                            guard flushEdits() else { return }
                            var reviewed = imported; reviewed.ocrPages = pages; reviewed.text = OCRLayout.joined(pages)
                            onSave(reviewed)
                        }.disabled(!canSave)
                    }
                }.padding(24)
            }.background(Ink.paper)
                .onDisappear { rereadTask?.cancel(); saveTask?.cancel(); _ = flushEdits() }
                .onChange(of: scenePhase) { _, phase in if phase != .active { saveTask?.cancel(); _ = flushEdits() } }
                .task(id: page.number) {
                    preview = nil; originalError = nil
                    guard let id = imported.sourceDocumentID, let draft = sourceDraft(id) else { originalError = "没有保留原文件。"; return }
                    do { let data = try await Task.detached(priority: .utility) { try DocumentOCR.preview(url: draft.url, page: page.number) }.value; if !Task.isCancelled { preview = data } }
                    catch { if !Task.isCancelled { originalError = error.localizedDescription } }
                }
        }
    }
    private func reread(_ page: OCRPage) {
        guard let id = imported.sourceDocumentID, let draft = sourceDraft(id) else { return }
        rereading = page.number; rereadError = nil
        rereadTask = Task {
            do {
                let worker = Task.detached(priority: .userInitiated) { try await DocumentOCR.reread(url: draft.url, page: page.number) }
                let revised = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                if revised.text.isEmpty { rereadError = "未识别到更多文字，保留当前原稿。" }
                else if let index = pages.firstIndex(where: { $0.number == revised.number }) { pages[index] = revised; skipped.remove(revised.number); scheduleSave(revised) }
            } catch is CancellationError { }
            catch { rereadError = error.localizedDescription }
            rereading = nil
        }
    }
    private func scheduleSave(_ page: OCRPage) {
        pendingEdits[page.number] = page
        saveTask?.cancel()
        saveTask = Task { do { try await Task.sleep(for: .milliseconds(300)); _ = flushEdits() } catch { } }
    }
    @discardableResult private func flushEdits() -> Bool {
        // Only the unfinished import owns this cache. A book edit is saved by its explicit Save action.
        guard let draft = ImportFiles.pending(), draft.id == imported.sourceDocumentID else { pendingEdits.removeAll(); return true }
        do {
            for page in pendingEdits.values { try ImportFiles.save(page, draft: draft) }
            pendingEdits.removeAll(); saveError = nil; return true
        } catch { saveError = "修改未保存：\(error.localizedDescription)"; return false }
    }
    private func sourceDraft(_ id: String) -> ImportDraft? {
        let extensions = ["pdf", "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff"]
        return extensions.first { FileManager.default.fileExists(atPath: ImportFiles.directory(id).appendingPathComponent("source." + $0).path) }.map { .init(id: id, title: imported.title, file: "source." + $0) }
    }
}
