import SwiftUI
import TranslationCore

enum ExportScope: String, CaseIterable, Identifiable {
    case all, current, selected
    var id: String { rawValue }
    var title: String {
        switch self { case .all: "全书已完成内容"; case .current: "当前章"; case .selected: "选择章节" }
    }
}

/// A read-only selection of checked final content. Reading position and live output are never inputs.
struct BookExportSelection {
    let scope: ExportScope
    let chapters: [ReadingChapter]
    let chunks: [TextChunk]
    let finalText: [Int: String]
    let completeChapterCount: Int
    let partialChapterCount: Int

    init(job: BookJob, chunks: [TextChunk], scope: ExportScope, currentChapterID: Int?, selectedChapterIDs: Set<Int>) {
        self.scope = scope
        chapters = job.chapters.filter { chapter in
            switch scope {
            case .all: true
            case .current: chapter.id == currentChapterID
            case .selected: selectedChapterIDs.contains(chapter.id)
            }
        }
        let indices = Set(chapters.flatMap(\.chunks))
        self.chunks = chunks.filter { indices.contains($0.index) }
        var finalText: [Int: String] = [:]
        if let stage = job.options.stages.last {
            for checkpoint in job.checkpoints where checkpoint.stage == stage && indices.contains(checkpoint.index) {
                let text = EditorNotes.display(checkpoint.text)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { finalText[checkpoint.index] = text }
            }
        }
        self.finalText = finalText
        let completed = Set(finalText.keys)
        completeChapterCount = chapters.filter { !$0.chunks.isEmpty && Set($0.chunks).isSubset(of: completed) }.count
        partialChapterCount = chapters.filter { !Set($0.chunks).isDisjoint(with: completed) && !Set($0.chunks).isSubset(of: completed) }.count
    }
    var canGenerate: Bool { chunks.contains { finalText[$0.index] != nil } }
    var summary: String {
        guard !chapters.isEmpty else { return "请选择要导出的章节。" }
        var text = "已完成 \(completeChapterCount) / \(chapters.count) 章"
        if partialChapterCount > 0 { text += "，另有 \(partialChapterCount) 章的已完成部分可导出" }
        return text
    }
    var rangeDescription: String {
        if scope == .all { return "全书已完成内容" }
        return chapters.map { "第 \($0.id + 1) 章 · \($0.title)" }.joined(separator: "、")
    }
    func snapshot(job: BookJob, bilingual: Bool) -> BookExportSnapshot {
        let includeOriginal = bilingual && job.purchasedWorkID == nil
        let text = chunks.compactMap { chunk -> String? in
            guard let translated = finalText[chunk.index] else { return nil }
            return includeOriginal ? "原文\n\(chunk.text)\n\n译文\n\(translated)" : translated
        }.joined(separator: "\n\n")
        let suffix = scope == .all ? "" : chapters.count == 1 ? "-" + (chapters.first?.title ?? "章节") : "-所选章节"
        return .init(title: job.title + suffix, text: text, rangeDescription: rangeDescription, summary: summary)
    }
}

struct BookExportSnapshot: Equatable {
    let title: String
    let text: String
    let rangeDescription: String
    let summary: String
}

struct ExportView: View {
    let id: String
    let currentChapterID: Int?
    @Environment(StudioStore.self) private var studio
    @Environment(\.dismiss) private var dismiss
    @State private var scope: ExportScope
    @State private var selectedChapterIDs: Set<Int> = []
    @State private var chunks: [TextChunk] = []
    @State private var format = "md"
    @State private var bilingual = false
    @State private var exportURL: URL?
    @State private var generated: BookExportSnapshot?
    @State private var error: String?
    @State private var preparing = false

    init(id: String, currentChapterID: Int? = nil, initialScope: ExportScope = .all) {
        self.id = id
        self.currentChapterID = currentChapterID
        _scope = State(initialValue: initialScope == .current && currentChapterID == nil ? .all : initialScope)
    }
    var body: some View {
        NavigationStack {
            Group {
                if let job = studio.job(id) {
                    let selection = BookExportSelection(job: job, chunks: chunks, scope: scope, currentChapterID: currentChapterID, selectedChapterIDs: selectedChapterIDs)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text(job.title).font(PaperType.reading(23, relativeTo: .title2)).fixedSize(horizontal: false, vertical: true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("导出范围").font(.caption).foregroundStyle(Ink.muted)
                                Picker("导出范围", selection: $scope) {
                                    ForEach(ExportScope.allCases) { value in
                                        if value != .current || currentChapterID != nil { Text(value.title).tag(value) }
                                    }
                                }.labelsHidden().frame(minHeight: 44).accessibilityIdentifier("export-scope")
                            }
                            if scope == .selected { chapterChoices(job) }
                            else if scope == .current { Text(selection.rangeDescription).font(.subheadline).fixedSize(horizontal: false, vertical: true) }
                            Text(selection.summary).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                            Text("只导出已完成检查的译文；尚未完成的文字不会导出。")
                                .font(.caption).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
                            PaperRule()
                            VStack(alignment: .leading, spacing: 4) {
                                Text("文件格式").font(.caption).foregroundStyle(Ink.muted)
                                Picker("文件格式", selection: $format) {
                                    Text("Markdown").tag("md"); Text("TXT").tag("txt"); Text("PDF").tag("pdf"); Text("EPUB").tag("epub"); Text("DOCX").tag("docx")
                                }.labelsHidden().frame(minHeight: 44)
                            }
                            if job.purchasedWorkID == nil { Toggle("导出双语对照", isOn: $bilingual).frame(minHeight: 44) }
                            else { Text("已购译本仅包含译文。").font(.caption).foregroundStyle(Ink.muted) }
                            if let error { Text(error).foregroundStyle(Ink.error).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("导出错误") }
                            if let exportURL, let generated {
                                Label("文件已生成", systemImage: "checkmark.circle").foregroundStyle(Ink.accent)
                                Text(generated.rangeDescription + " · " + format.uppercased()).font(.caption).fixedSize(horizontal: false, vertical: true)
                                Text("本次文件：" + generated.summary).font(.caption).fixedSize(horizontal: false, vertical: true)
                                Text("文件包含生成时的已完成内容。新增译文后可重新生成。")
                                    .font(.caption).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
                                ShareLink(item: exportURL) {
                                    Label("分享或保存", systemImage: "square.and.arrow.up")
                                        .frame(maxWidth: .infinity).frame(minHeight: 48).foregroundStyle(.white)
                                        .background(Ink.accent, in: RoundedRectangle(cornerRadius: 7))
                                }.buttonStyle(.plain)
                            }
                            PrimaryButton(title: preparing ? "正在生成…" : exportURL == nil ? "生成导出文件" : "重新生成", icon: "doc", secondary: exportURL != nil) {
                                generate(job, selection: selection)
                            }.disabled(!selection.canGenerate || preparing)
                            if !selection.canGenerate && scope != .selected {
                                Text("此范围还没有已完成的译文，完成后即可导出。").font(.caption).foregroundStyle(Ink.muted)
                            }
                        }.font(.subheadline).padding(24).frame(maxWidth: PaperLayout.formWidth, alignment: .leading).frame(maxWidth: .infinity)
                    }.background { PaperBackground(textured: false) }
                        .task(id: job.options.documentKind) {
                            chunks = Chunker.plan(text: job.source, kind: job.options.documentKind, preparationVersion: job.options.preparationVersion).chunks
                        }
                } else { ContentUnavailableView("文稿不存在", systemImage: "book.closed") }
            }
            .navigationTitle("导出与分享").navigationBarTitleDisplayMode(.inline)
            .toolbar { PaperToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .presentationDetents([.large]).presentationDragIndicator(.visible).presentationCornerRadius(18)
        .onChange(of: scope) { _, _ in invalidate() }
        .onChange(of: selectedChapterIDs) { _, _ in invalidate() }
        .onChange(of: format) { _, _ in invalidate() }
        .onChange(of: bilingual) { _, _ in invalidate() }
    }
    private func chapterChoices(_ job: BookJob) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(job.chapters) { chapter in
                let available = !Set(chapter.chunks).isDisjoint(with: job.finalChunkIndices)
                Button {
                    if selectedChapterIDs.contains(chapter.id) { selectedChapterIDs.remove(chapter.id) }
                    else { selectedChapterIDs.insert(chapter.id) }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: selectedChapterIDs.contains(chapter.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(Ink.accent).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("第 \(chapter.id + 1) 章 · " + chapter.title).foregroundStyle(Ink.text)
                            if !available { Text("尚无可导出内容").font(.caption).foregroundStyle(Ink.muted) }
                        }
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!available).accessibilityAddTraits(selectedChapterIDs.contains(chapter.id) ? .isSelected : [])
                PaperRule()
            }
        }
    }
    private func invalidate() { exportURL = nil; generated = nil; error = nil }
    private func generate(_ job: BookJob, selection: BookExportSelection) {
        guard !preparing, selection.canGenerate else { return }
        preparing = true; error = nil
        defer { preparing = false }
        let snapshot = selection.snapshot(job: job, bilingual: bilingual)
        do {
            let url = try DocumentIO.export(title: snapshot.title, text: snapshot.text, ext: format, preserveLayout: job.options.layout == .preserve, coverData: CoverStorage.data(for: job.coverKey))
            generated = snapshot; exportURL = url
        } catch { self.error = error.localizedDescription }
    }
}
