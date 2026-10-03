import SwiftUI
import TranslationCore

struct ReaderView: View {
    let id: String
    @Environment(StudioStore.self) private var studio
    @State private var mode = 0
    @State private var fontSize = 18.0
    @State private var chapter = -1
    @State private var chunks: [TextChunk] = []
    @State private var exportURL: URL?
    @State private var exportFormat = "md"
    @State private var bilingualExport = false
    var body: some View {
        if let job = studio.job(id) {
            let fast = job.options.quality == .fast
            let selected = readableChunks(job)
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    Eyebrow(text: job.status == .complete ? "THE FINISHED EDITION" : fast ? "READ AS WORDS ARRIVE" : "ONE FINISHED CHAPTER AT A TIME")
                    Text(job.title).font(.system(size: 31, weight: .regular, design: .serif)).lineSpacing(5)
                    HStack { Text(job.options.style.name); Text("·"); Text(job.options.quality.title); Spacer(); if job.status == .complete { Image(systemName: "checkmark.seal.fill").foregroundStyle(Ink.green) } else if job.status == .translating { ThinkingDots() } else { Text(job.statusText) } }.font(.system(size: 11)).foregroundStyle(Ink.muted)
                    if job.chapters.count > 1 {
                        Picker("阅读章节", selection: $chapter) {
                            if fast || job.status == .complete { Text("全部章节").tag(-1) }
                            ForEach(fast ? job.chapters : job.readableChapters) { item in Text(item.title).tag(item.id) }
                        }.tint(Ink.text)
                    }
                    if job.status != .complete { Text(fast ? "译文会实时出现，当前正在生成的段落尚未完成。" : "已完成 \(job.readableChapters.count) / \(job.chapters.count) 章，当前展示的章节已完成全部审校。") .font(.system(size: 11)).foregroundStyle(Ink.muted).lineSpacing(4) }
                    Picker("阅读模式", selection: $mode) { Text("译文").tag(0); Text("双语对照").tag(1); Text("原文").tag(2) }.pickerStyle(.segmented)
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(selected, id: \.index) { chunk in
                            let translated = translation(job, chunk: chunk.index, includeLive: true)
                            VStack(alignment: .leading, spacing: 14) {
                                if mode == 1 { Eyebrow(text: "\(String(format: "%02d", chunk.index + 1)) · ORIGINAL") }
                                if mode != 0 { readingText(chunk.text, secondary: mode == 1, preserve: job.options.layout == .preserve) }
                                if mode == 1 { Rectangle().fill(Ink.line).frame(height: 1) }
                                if mode != 2 {
                                    if translated.isEmpty { HStack(spacing: 8) { ThinkingDots(); Text(job.status == .translating ? "这一段还在翻译中…" : "这一段尚未翻译完成").font(.system(size: 12)).foregroundStyle(Ink.muted) } }
                                    else { readingText(translated, secondary: false, preserve: job.options.layout == .preserve) }
                                }
                            }
                        }
                    }
                    if selected.isEmpty { Text("这一章的审校尚未完成，完成后会自动开放阅读。") .font(.system(size: 13)).foregroundStyle(Ink.muted) }
                    if !selected.isEmpty && selected.allSatisfy({ hasFinal(job, index: $0.index) }) { exportPanel(job, selected: selected) }
                }.padding(26)
            }.background(Ink.paper).navigationTitle("译本").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Menu { Button("更大字号") { fontSize = min(28, fontSize + 2) }; Button("更小字号") { fontSize = max(14, fontSize - 2) } } label: { Image(systemName: "textformat.size") } } }
                .task(id: job.options.documentKind) { chunks = Chunker.plan(text: job.source, kind: job.options.documentKind).chunks; if !fast && job.status != .complete { chapter = job.readableChapters.first?.id ?? -2 } }
                .onChange(of: job.readableChapters.count) { _, _ in if chapter == -2 { chapter = job.readableChapters.first?.id ?? -2 } }
                .onChange(of: exportFormat) { _, _ in exportURL = nil }.onChange(of: bilingualExport) { _, _ in exportURL = nil }.onChange(of: chapter) { _, _ in exportURL = nil }
        }
    }
    private func readableChunks(_ job: BookJob) -> [TextChunk] {
        if chapter >= 0 { let indices = Set(job.chapters.first { $0.id == chapter }?.chunks ?? []); return chunks.filter { indices.contains($0.index) } }
        if job.options.quality == .fast || job.status == .complete { return chunks }
        let indices = Set(job.readableChapters.flatMap(\.chunks)); return chunks.filter { indices.contains($0.index) }
    }
    private func hasFinal(_ job: BookJob, index: Int) -> Bool { job.checkpoints.contains { $0.index == index && $0.stage == job.options.stages.last } }
    private func translation(_ job: BookJob, chunk: Int, includeLive: Bool) -> String {
        if let result = job.checkpoints.last(where: { $0.index == chunk && $0.stage == job.options.stages.last }) { return result.text }
        return includeLive && job.options.quality == .fast && studio.activeID == id ? studio.liveChunks[chunk] ?? "" : ""
    }
    private func exportPanel(_ job: BookJob, selected: [TextChunk]) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Divider()
            HStack { Text(chapter >= 0 ? "带走这一章" : "带走这份译本").font(.system(size: 21, design: .serif)); Spacer(); Image(systemName: "square.and.arrow.up").foregroundStyle(Ink.orange) }
            Picker("导出格式", selection: $exportFormat) { Text("Markdown").tag("md"); Text("TXT").tag("txt"); Text("PDF").tag("pdf") }.pickerStyle(.segmented)
            Toggle("导出双语对照", isOn: $bilingualExport).font(.system(size: 13))
            PrimaryButton(title: "准备分享文件", icon: "square.and.arrow.up") {
                do {
                    let text = selected.map { chunk in let translated = translation(job, chunk: chunk.index, includeLive: false); return bilingualExport ? "原文\n\(chunk.text)\n\n译文\n\(translated)" : translated }.joined(separator: "\n\n")
                    let title = chapter >= 0 ? job.title + "-" + (job.chapters.first { $0.id == chapter }?.title ?? "章节") : job.title
                    exportURL = try DocumentIO.export(title: title, text: text, ext: exportFormat, preserveLayout: job.options.layout == .preserve)
                } catch { studio.message = error.localizedDescription }
            }
            if let exportURL { ShareLink(item: exportURL) { Label("分享 / 存储到文件", systemImage: "square.and.arrow.up").font(.system(size: 15, weight: .semibold)).padding(15).frame(maxWidth: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 15)) }.foregroundStyle(Ink.orange) }
        }
    }
    @ViewBuilder private func readingText(_ value: String, secondary: Bool, preserve: Bool) -> some View {
        let size = secondary ? fontSize - 2 : fontSize
        if preserve {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(readerBlocks(value)) { block in
                    switch block.kind {
                    case .heading(let level): Text(block.text).font(.system(size: size + (level == 1 ? 7 : 3), weight: .semibold, design: .serif)).padding(.top, 10)
                    case .code: ScrollView(.horizontal) { Text(block.text).font(.system(size: size - 3, design: .monospaced)).lineSpacing(4).padding(12) }.background(Ink.line.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                    case .table: ScrollView(.horizontal) { Text(block.text).font(.system(size: size - 3, design: .monospaced)).lineSpacing(5) }
                    case .prose: Text(LocalizedStringKey(block.text.isEmpty ? " " : block.text)).font(.system(size: size, design: .serif)).lineSpacing(7)
                    }
                }
            }.foregroundStyle(secondary ? Ink.muted : Ink.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        } else { Text(value).font(.system(size: size, design: .serif)).lineSpacing(9).foregroundStyle(secondary ? Ink.muted : Ink.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
    }
}

private struct ReaderBlock: Identifiable {
    enum Kind { case heading(Int), code, table, prose }
    var id: Int; var text: String; var kind: Kind
}
private func readerBlocks(_ value: String) -> [ReaderBlock] {
    var result: [ReaderBlock] = [], code: [String] = [], fence: String?
    func add(_ text: String, _ kind: ReaderBlock.Kind) { result.append(.init(id: result.count, text: text, kind: kind)) }
    for line in value.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let active = fence {
            if trimmed.hasPrefix(active) { add(code.joined(separator: "\n"), .code); code = []; fence = nil }
            else { code.append(line) }
        } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fence = String(trimmed.prefix(3)) }
        else if line.hasPrefix("# ") || line.hasPrefix("## ") || line.hasPrefix("### ") {
            add(String(line.drop { $0 == "#" || $0 == " " }), .heading(line.prefix { $0 == "#" }.count))
        } else if line.hasPrefix("|") { add(line, .table) }
        else { add(line, .prose) }
    }
    if !code.isEmpty { add(code.joined(separator: "\n"), .code) }
    return result
}
