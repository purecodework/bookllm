import SwiftUI
import TranslationCore

private struct ReadingUnit: Identifiable {
    var id: String
    var chunk: Int
    var original: String?
    var translated: String?
    var kind: ReaderBlock.Kind
    var sectionLabel: String? = nil
}
struct ReaderView: View {
    let id: String
    var exportOnOpen = false
    var onClose: (() -> Void)? = nil
    var closeLabel = "返回本书进度"
    @Environment(StudioStore.self) private var studio
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mode = 0
    @State private var fontSize = 20.0
    @State private var chapter = -1
    @State private var chunks: [TextChunk] = []
    @State private var visibleAnchor: String?
    @State private var translatedAnchor: String?
    @State private var ready = false
    @State private var publish = false
    @State private var exporting = false
    @State private var directory = false
    @State private var notes: String?
    var body: some View {
        if let job = studio.job(id) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    chapterHeader(job).padding(.bottom, 32).id("heading")
                    ForEach(readingUnits(job)) { unit in
                        passage(unit, job: job).padding(.bottom, 27).id(unit.id)
                    }
                    if readingUnits(job).isEmpty {
                        Text("章节审校完成后即可阅读。").font(.subheadline).foregroundStyle(Ink.muted).padding(.vertical, 32)
                    }
                }.scrollTargetLayout().padding(.horizontal, 26).padding(.top, 28).padding(.bottom, 40)
                    .frame(maxWidth: PaperLayout.readingWidth, alignment: .leading).frame(maxWidth: .infinity)
            }.scrollPosition(id: $visibleAnchor, anchor: .top)
                .background { PaperBackground() }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if job.purchasedWorkID == nil {
                        HStack(spacing: 0) {
                            modeButton("译文", value: 0); modeButton("原文", value: 2); modeButton("对照", value: 1)
                        }.padding(.horizontal, 24).frame(maxWidth: PaperLayout.readingWidth).frame(maxWidth: .infinity).background(Ink.paper)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { readerTools(job).background(Ink.paper) }
                .navigationTitle(job.title).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
                .toolbar {
                    if let onClose {
                        PaperToolbarItem(placement: .cancellationAction) {
                            Button(action: onClose) { Label(closeLabel, systemImage: "chevron.left").labelStyle(.iconOnly).frame(width: 44, height: 44) }
                                .accessibilityLabel(closeLabel)
                        }
                    }
                    PaperToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("导出与分享") { exporting = true }
                            if job.status == .complete && job.purchasedWorkID == nil { Button("定价分享译作") { publish = true } }
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("阅读菜单")
                    }
                }
                .task(id: job.options.documentKind) {
                    chunks = Chunker.plan(text: job.source, kind: job.options.documentKind).chunks
                    if !ready {
                        mode = job.purchasedWorkID == nil ? (job.readingMode ?? 0) : 0
                        fontSize = job.readingFontSize ?? 20
                        chapter = BookReadingAnchor.initialChapterID(job)
                        visibleAnchor = resolve(job.readingAnchor, job: job)
                        ready = true
                        if exportOnOpen { exporting = true }
                    }
                }
                .onChange(of: visibleAnchor) { _, anchor in
                    if ready, let anchor { studio.update(id) { $0.readingAnchor = anchor } }
                }
                .onChange(of: job.readableChapters.count) { _, _ in
                    if chapter == -2, let first = job.readableChapters.first { selectChapter(first.id, job: job) }
                }
                .sheet(isPresented: $publish) { PublishWorkView(id: id) }
                .sheet(isPresented: $exporting) {
                    ExportView(id: id, currentChapterID: chapter >= 0 ? chapter : nil, initialScope: chapter >= 0 ? .current : .all).modifier(PaperUITestLayout())
                }
                .sheet(isPresented: $directory) {
                    directoryPanel(job).modifier(PaperUITestLayout())
                }
                .sheet(isPresented: Binding(get: { notes != nil }, set: { if !$0 { notes = nil } })) {
                    NavigationStack {
                        ScrollView { Text(notes ?? "").font(PaperType.reading(fontSize)).lineSpacing(8).padding(24) }.background(Ink.paper)
                            .navigationTitle("编者注").navigationBarTitleDisplayMode(.inline)
                            .toolbar { PaperToolbarItem(placement: .cancellationAction) { Button("关闭") { notes = nil } } }
                    }.presentationDetents([.medium, .large])
                }
        }
    }
    private func modeButton(_ title: String, value: Int) -> some View {
        Button {
            let saved = visibleAnchor
            if mode == 0 { translatedAnchor = saved }
            mode = value
            studio.update(id) { $0.readingMode = value }
            if let job = studio.job(id) {
                let units = readingUnits(job)
                let next = BookReadingAnchor.modeAnchor(saved, rememberedTranslation: translatedAnchor, destinationMode: value, availableIDs: units.map(\.id))
                Task { await Task.yield(); visibleAnchor = next }
            }
        } label: {
            Text(title).font(.subheadline).foregroundStyle(mode == value ? Ink.text : Ink.muted)
                .frame(maxWidth: .infinity).frame(minHeight: 48)
                .overlay(alignment: .bottom) { Rectangle().fill(mode == value ? Ink.accent : Ink.line).frame(height: mode == value ? 1.5 : 0.5) }
        }.buttonStyle(.plain).accessibilityAddTraits(mode == value ? .isSelected : [])
    }
    private func chapterHeader(_ job: BookJob) -> some View {
        let selected = job.chapters.first { $0.id == chapter }
        let chapterName = translatedChapterTitle(job) ?? selected?.title ?? job.title
        return VStack(alignment: .leading, spacing: 18) {
            Text(chapter >= 0 ? "第 \(chapter + 1) 章" : "译本").font(.subheadline).foregroundStyle(Ink.muted)
            Text(chapterName).font(PaperType.reading(32, relativeTo: .title)).fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(Ink.line).frame(width: 36, height: 1)
            if job.status != .complete {
                Text(job.options.quality == .fast ? "初译实时更新，尚未完成检查" : job.chapterSummary).font(.caption).foregroundStyle(Ink.muted)
            }
        }
    }
    private func readerTools(_ job: BookJob) -> some View {
        VStack(spacing: 0) {
            PaperRule()
            HStack {
                Button { directory = true } label: { Label("目录", systemImage: "list.bullet").font(.caption).frame(minHeight: 48) }
                Spacer()
                Text(chapter >= 0 ? "第 \(chapter + 1) / \(job.chapters.count) 章" : job.status == .complete ? "\(job.chapters.count) 章" : job.chapterSummary).font(.caption).foregroundStyle(Ink.muted)
                Spacer()
                Menu {
                    Button("更大字号") { resize(min(32, fontSize + 2)) }
                    Button("更小字号") { resize(max(14, fontSize - 2)) }
                } label: { Image(systemName: "textformat.size").frame(width: 44, height: 48) }.accessibilityLabel("阅读字号")
            }.padding(.horizontal, 24).frame(maxWidth: PaperLayout.readingWidth).frame(maxWidth: .infinity)
        }
    }
    private func resize(_ size: Double) {
        let anchor = visibleAnchor
        fontSize = size
        studio.update(id) { $0.readingFontSize = size }
        Task { await Task.yield(); visibleAnchor = anchor }
    }
    private func resolve(_ anchor: String?, job: BookJob) -> String? {
        BookReadingAnchor.resolve(anchor, availableIDs: readingUnits(job).map(\.id))
    }
    private func selectChapter(_ value: Int, job: BookJob) {
        chapter = value
        studio.update(id) { $0.readingChapter = value }
        translatedAnchor = nil
        visibleAnchor = readingUnits(job).first?.id
        directory = false
    }
    private func readableChunks(_ job: BookJob) -> [TextChunk] {
        if chapter >= 0 {
            let indices = Set(job.chapters.first { $0.id == chapter }?.chunks ?? [])
            return chunks.filter { indices.contains($0.index) }
        }
        if job.options.quality == .fast || job.status == .complete { return chunks }
        let indices = Set(job.readableChapters.flatMap(\.chunks))
        return chunks.filter { indices.contains($0.index) }
    }
    private func readingUnits(_ job: BookJob) -> [ReadingUnit] {
        readableChunks(job).flatMap { chunk -> [ReadingUnit] in
            let translated = translation(job, chunk: chunk.index, includeLive: true)
            if mode == 1 {
                // Group by the stored chunk; never invent source/translation paragraph pairs.
                let original = readerBlocks(chunk.text).enumerated().map { offset, block in
                    ReadingUnit(id: "\(chunk.index)-source-\(block.id)", chunk: chunk.index, original: block.text, translated: nil, kind: block.kind, sectionLabel: offset == 0 ? "原文" : nil)
                }
                let targetBlocks = readerBlocks(translated).filter { !$0.text.isEmpty }
                let target = targetBlocks.filter { block in
                    !(chunk.index == readableChunks(job).first?.index && block.id == targetBlocks.first?.id && translatedChapterTitle(job) == block.text)
                }.enumerated().map { offset, block in
                    ReadingUnit(id: "\(chunk.index)-\(block.id)", chunk: chunk.index, original: nil, translated: block.text, kind: block.kind, sectionLabel: offset == 0 ? "译文" : nil)
                }
                return original + (target.isEmpty ? [.init(id: "\(chunk.index)-0", chunk: chunk.index, original: nil, translated: "", kind: .prose, sectionLabel: "译文")] : target)
            }
            let text = mode == 2 ? chunk.text : translated
            if text.isEmpty { return [.init(id: "\(chunk.index)-0", chunk: chunk.index, original: nil, translated: "", kind: .prose)] }
            let blocks = readerBlocks(text).filter { !$0.text.isEmpty }
            return blocks.filter { block in
                !(mode == 0 && chunk.index == readableChunks(job).first?.index && block.id == blocks.first?.id && translatedChapterTitle(job) == block.text)
            }.map {
                .init(id: mode == 2 ? "\(chunk.index)-source-\($0.id)" : "\(chunk.index)-\($0.id)", chunk: chunk.index, original: mode == 2 ? $0.text : nil, translated: mode == 2 ? nil : $0.text, kind: $0.kind)
            }
        }
    }
    @ViewBuilder private func passage(_ unit: ReadingUnit, job: BookJob) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if mode == 1, let label = unit.sectionLabel {
                HStack(spacing: 10) {
                    Text(label).font(.caption).foregroundStyle(Ink.muted)
                    Rectangle().fill(Ink.line).frame(height: 0.5)
                }.accessibilityAddTraits(.isHeader)
            }
            if let original = unit.original {
                if mode == 1 {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(readerBlocks(original)) { block in render(block.text, kind: block.kind, size: fontSize * 0.85, secondary: true, fiction: false) }
                    }.padding(.leading, 14).overlay(alignment: .leading) { Rectangle().fill(Ink.line).frame(width: 1) }
                } else { render(original, kind: unit.kind, size: fontSize, secondary: false, fiction: job.options.documentKind == .fiction) }
            }
            if let translated = unit.translated {
                if translated.isEmpty {
                    Text(job.status == .translating ? "这一段还在翻译中…" : "这一段尚未翻译完成").font(.caption).foregroundStyle(Ink.muted)
                } else if mode == 1 {
                    ForEach(readerBlocks(translated)) { block in render(block.text, kind: block.kind, size: fontSize, secondary: false, fiction: job.options.documentKind == .fiction) }
                } else { render(translated, kind: unit.kind, size: fontSize, secondary: false, fiction: job.options.documentKind == .fiction) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func render(_ text: String, kind: ReaderBlock.Kind, size: Double, secondary: Bool, fiction: Bool) -> some View {
        switch kind {
        case .heading(let level):
            Text(text).font(PaperType.reading(size + (level == 1 ? 7 : 3), relativeTo: .title3)).foregroundStyle(Ink.text).padding(.top, 12)
        case .code, .table:
            ScrollView(.horizontal) { Text(text).font(.system(size: size * 0.85, design: .monospaced)).lineSpacing(5).padding(12).textSelection(.enabled) }
                .background(Ink.surface, in: RoundedRectangle(cornerRadius: 4))
        case .prose:
            Text(LocalizedStringKey((fiction && text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) ? "　　" : "") + text))
                .font(PaperType.reading(size)).lineSpacing(size * 0.8).foregroundStyle(secondary ? Ink.muted : Ink.text)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func translatedChapterTitle(_ job: BookJob) -> String? {
        guard mode != 2, let first = readableChunks(job).first,
              let block = readerBlocks(translation(job, chunk: first.index, includeLive: true)).first,
              case .heading = block.kind else { return nil }
        return block.text
    }
    private func translation(_ job: BookJob, chunk: Int, includeLive: Bool) -> String {
        if let result = job.checkpoints.last(where: { $0.index == chunk && $0.stage == job.options.stages.last }) { return EditorNotes.display(result.text) }
        return includeLive && job.options.quality == .fast && studio.activeID == id ? EditorNotes.display(studio.liveChunks[chunk] ?? "") : ""
    }
    private func directoryPanel(_ job: BookJob) -> some View {
        let events = studio.activeID == id ? Array(studio.processing.values) : []
        let live = studio.activeID == id ? Set(studio.liveChunks.keys) : []
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if job.options.quality == .fast || job.status == .complete {
                        Button { selectChapter(-1, job: job) } label: {
                            HStack { Text("全部章节"); Spacer(); if chapter == -1 { Image(systemName: "checkmark").foregroundStyle(Ink.accent) } }.frame(minHeight: 48)
                        }.accessibilityAddTraits(chapter == -1 ? .isSelected : [])
                        PaperRule()
                    }
                    ForEach(job.chapters) { item in
                        let state = job.chapterReadingState(item, events: events, liveChunkIndices: live)
                        Button { selectChapter(item.id, job: job) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(alignment: .top) {
                                    Text("第 \(item.id + 1) 章 · " + item.title).fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 8)
                                    if chapter == item.id { Image(systemName: "checkmark").foregroundStyle(Ink.accent) }
                                }
                                Text(state.label).font(.caption).foregroundStyle(state.canRead ? Ink.accent : Ink.muted)
                                if !state.canRead || job.options.quality == .fast && state.label != "已完成" {
                                    Text(state.detail).font(.caption).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
                                }
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.vertical, 14).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!state.canRead)
                            .accessibilityIdentifier("toc-chapter-\(item.id)")
                            .accessibilityLabel("第 \(item.id + 1) 章，\(item.title)，\(state.label)，\(state.detail)")
                            .accessibilityAddTraits(chapter == item.id ? .isSelected : [])
                        PaperRule()
                    }
                }.font(.subheadline).foregroundStyle(Ink.text).padding(24).frame(maxWidth: PaperLayout.formWidth, alignment: .leading).frame(maxWidth: .infinity)
            }.background { PaperBackground(textured: false) }.navigationTitle("目录").navigationBarTitleDisplayMode(.inline)
                .toolbar { PaperToolbarItem(placement: .cancellationAction) { Button("关闭") { directory = false } } }
        }
    }
}

enum BookReadingAnchor {
    static func initialChapterID(_ job: BookJob) -> Int {
        let allAvailable = job.options.quality == .fast || job.status == .complete
        let available = allAvailable ? job.chapters : job.readableChapters
        if let saved = job.readingChapter, saved == -1 && !available.isEmpty || available.contains(where: { $0.id == saved }) { return saved }
        return available.first?.id ?? (allAvailable ? -1 : -2)
    }
    static func resolve(_ anchor: String?, availableIDs: [String]) -> String? {
        guard let anchor else { return availableIDs.first }
        if availableIDs.contains(anchor) { return anchor }
        let chunk = anchor.split(separator: "-").first
        return availableIDs.first { $0.split(separator: "-").first == chunk } ?? availableIDs.first
    }
    static func modeAnchor(_ saved: String?, rememberedTranslation: String?, destinationMode: Int, availableIDs: [String]) -> String? {
        if let saved, availableIDs.contains(saved) { return saved }
        let chunk = saved?.split(separator: "-").first
        if destinationMode == 0 {
            let rememberedChunk = rememberedTranslation?.split(separator: "-").first
            return resolve(rememberedChunk == chunk ? rememberedTranslation ?? saved : saved, availableIDs: availableIDs)
        }
        if destinationMode == 2, let saved, !availableIDs.contains(saved) {
            return availableIDs.first { $0.contains("-source-") && $0.split(separator: "-").first == chunk } ?? resolve(saved, availableIDs: availableIDs)
        }
        return resolve(saved, availableIDs: availableIDs)
    }
}

struct ReaderBlock: Identifiable {
    enum Kind { case heading(Int), code, table, prose }
    var id: Int; var text: String; var kind: Kind
}
func readerBlocks(_ value: String) -> [ReaderBlock] {
    var result: [ReaderBlock] = [], prose: [String] = [], code: [String] = [], tables: [String] = []
    var fence: (Character, Int)?
    func add(_ text: String, _ kind: ReaderBlock.Kind) { result.append(.init(id: result.count, text: text, kind: kind)) }
    func flush() {
        if !prose.isEmpty { add(prose.joined(separator: "\n"), .prose); prose = [] }
        if !tables.isEmpty { add(tables.joined(separator: "\n"), .table); tables = [] }
    }
    for line in value.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let active = fence {
            if trimmed.first == active.0 && trimmed.prefix(while: { $0 == active.0 }).count >= active.1 && trimmed.drop(while: { $0 == active.0 }).trimmingCharacters(in: .whitespaces).isEmpty {
                add(code.joined(separator: "\n"), .code); code = []; fence = nil
            } else { code.append(line) }
        } else if let marker = trimmed.first, (marker.asciiValue == 96 || marker == "~"), trimmed.prefix(while: { $0 == marker }).count >= 3 {
            flush(); fence = (marker, trimmed.prefix(while: { $0 == marker }).count)
        } else if trimmed.isEmpty { flush() }
        else if trimmed.hasPrefix("# ") || trimmed.hasPrefix("## ") || trimmed.hasPrefix("### ") {
            flush(); add(String(trimmed.drop(while: { $0 == "#" || $0 == " " })), .heading(trimmed.prefix(while: { $0 == "#" }).count))
        } else if trimmed.hasPrefix("|") { if !prose.isEmpty { flush() }; tables.append(line) }
        else { if !tables.isEmpty { flush() }; prose.append(line) }
    }
    if fence != nil { add(code.joined(separator: "\n"), .code) }
    flush()
    return result
}
