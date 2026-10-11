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
                if let recoveryError = importer.recoveryError {
                    recoveryView(recoveryError)
                } else if importer.phase == .reviewing, let result = importer.result, !importer.needsOCRReview {
                    libraryRetry(result)
                } else if importer.phase == .reviewing, let result = importer.result {
                    VStack(spacing: 0) {
                        if let error = importer.error { Text(error).font(.subheadline).foregroundStyle(Ink.error).padding(24).fixedSize(horizontal: false, vertical: true) }
                        OCRReviewView(imported: result, saveTitle: importer.accepting ? "正在加入书库…" : "确认原稿，加入书库") { reviewed in
                            Task { do { try await importer.accept(reviewed, studio: studio) } catch { } }
                        }.disabled(importer.accepting)
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
                            Button("放弃导入", role: .destructive) { discarding = true }.font(.system(size: 13)).frame(minHeight: 44)
                            Button("稍后继续") { importer.presented = false }.font(.system(size: 13))
                        }
                        Spacer()
                    }.padding(26)
                }
            }.background(Ink.paper).navigationTitle(importer.phase == .reviewing ? importer.needsOCRReview ? "核对识别原稿" : "加入书库" : "导入").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if importer.phase == .reviewing {
                        PaperToolbarItem(placement: .topBarLeading) { Button("放弃", role: .destructive) { discarding = true }.disabled(importer.accepting) }
                        PaperToolbarItem(placement: .topBarTrailing) { Button(importer.needsOCRReview ? "稍后核对" : "稍后继续") { importer.presented = false }.disabled(importer.accepting) }
                    }
                }
                .confirmationDialog("放弃这次导入？", isPresented: $discarding, titleVisibility: .visible) { Button("放弃导入", role: .destructive) { importer.discard() } } message: {
                    Text(importer.recoveryError == nil ? "识别稿将删除，您选择的原始文件不会改动。" : "将移除无法读取的恢复记录。保留的原文件和已识别页面不会删除；您可重新选择文件导入。")
                }
        }.interactiveDismissDisabled()
    }
    private func recoveryView(_ message: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("无法恢复这次导入").font(.title3)
                Text(message).font(.subheadline).foregroundStyle(Ink.error).fixedSize(horizontal: false, vertical: true)
                if let error = importer.error { Text(error).font(.caption).foregroundStyle(Ink.error) }
                PrimaryButton(title: "重试读取恢复记录", icon: "arrow.clockwise") { importer.retryRecovery(studio: studio) }
                Button("放弃这次导入", role: .destructive) { discarding = true }.frame(minHeight: 44)
                Button("稍后处理") { importer.presented = false }.frame(minHeight: 44)
            }.padding(24).frame(maxWidth: PaperLayout.formWidth).frame(maxWidth: .infinity)
        }
    }
    private func libraryRetry(_ imported: ImportedText) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(imported.title).font(.title3)
                Text("原稿已读取，尚未加入书库").font(.subheadline)
                Text("\(imported.format) · \(imported.text.count.formatted()) 字符。原文件仍保留，重试会保存完整原稿。").font(.caption).foregroundStyle(Ink.muted)
                if let error = importer.error { Text(error).font(.subheadline).foregroundStyle(Ink.error).fixedSize(horizontal: false, vertical: true) }
                PrimaryButton(title: importer.accepting ? "正在加入书库…" : "重试加入书库", icon: "arrow.clockwise") {
                    Task { do { try await importer.accept(imported, studio: studio) } catch { } }
                }.disabled(importer.accepting)
                PaperRule()
                Text(imported.text.count > 1200 ? "原稿预览（前 1,200 字符）" : "原稿预览").font(.caption).foregroundStyle(Ink.muted)
                Text(String(imported.text.prefix(1200))).font(PaperType.reading(17)).lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(24).frame(maxWidth: PaperLayout.formWidth).frame(maxWidth: .infinity)
        }
    }
}
struct OCRReviewView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ImportCoordinator.self) private var importer
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
    init(imported: ImportedText, readOnly: Bool = false, saveTitle: String = "确认原稿，加入书库", onSave: @escaping (ImportedText) -> Void) {
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
                    let root = importer.rootURL
                    do { let data = try await Task.detached(priority: .utility) { try DocumentOCR.preview(url: draft.url(rootURL: root), page: page.number) }.value; if !Task.isCancelled { preview = data } }
                    catch { if !Task.isCancelled { originalError = error.localizedDescription } }
                }
        }
    }
    private func reread(_ page: OCRPage) {
        guard let id = imported.sourceDocumentID, let draft = sourceDraft(id) else { return }
        let root = importer.rootURL
        rereading = page.number; rereadError = nil
        rereadTask = Task {
            do {
                let worker = Task.detached(priority: .userInitiated) { try await DocumentOCR.reread(url: draft.url(rootURL: root), page: page.number) }
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
        guard let draft = ImportFiles.pending(rootURL: importer.rootURL), draft.id == imported.sourceDocumentID else { pendingEdits.removeAll(); return true }
        do {
            for page in pendingEdits.values { try ImportFiles.save(page, draft: draft, rootURL: importer.rootURL) }
            pendingEdits.removeAll(); saveError = nil; return true
        } catch { saveError = "修改未保存：\(error.localizedDescription)"; return false }
    }
    private func sourceDraft(_ id: String) -> ImportDraft? {
        let extensions = ["pdf", "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff"]
        return extensions.first { FileManager.default.fileExists(atPath: ImportFiles.directory(id, rootURL: importer.rootURL).appendingPathComponent("source." + $0).path) }.map { .init(id: id, title: imported.title, file: "source." + $0) }
    }
}
