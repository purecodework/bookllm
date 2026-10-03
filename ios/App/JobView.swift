import SwiftUI
import TranslationCore

private enum JobSheet: String, Identifiable { case preferences, glossary; var id: String { rawValue } }
struct JobView: View {
    let id: String
    @Environment(StudioStore.self) private var studio
    @Environment(CloudAccount.self) private var account
    @Environment(PurchaseStore.self) private var purchases
    @State private var sheet: JobSheet?
    var body: some View {
        Group {
            if let job = studio.job(id) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 25) {
                        heading(job)
                        if job.status == .draft { configuration(job) }
                        if job.status == .reviewing { reviewCard(job) }
                        if job.status != .draft { pipeline(job) }
                        if let error = job.error { Text(error).font(.system(size: 13)).foregroundStyle(Ink.orange).padding(16).background(Ink.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 14)) }
                        if job.status == .complete || (job.options.quality == .fast && job.status != .draft && job.status != .extracting && job.status != .reviewing) || !job.readableChapters.isEmpty {
                            NavigationLink { ReaderView(id: id) } label: { HStack { Text(job.status == .complete ? "打开译本" : job.options.quality == .fast ? "边译边读" : "阅读已完成章节"); Spacer(); Image(systemName: "book") }.font(.system(size: 16, weight: .semibold)).padding(20).foregroundStyle(.white).background(Ink.text, in: RoundedRectangle(cornerRadius: 18)) }
                        }
                        if job.status != .complete { action(job) }
                        if !job.terms.isEmpty && job.status != .reviewing { Button { sheet = .glossary } label: { Label("查看本书术语 · \(job.terms.count) 个", systemImage: "text.book.closed").font(.system(size: 13)) }.padding(.top, 3) }
                        Text("译稿在本机保存。退到后台会暂停，回到前台可继续。云端已开始的段落会完成并缓存，恢复时不重复扣点。额外审校增加处理时间与 API 用量，质量提升随文本而异。").font(.system(size: 11)).foregroundStyle(Ink.muted).lineSpacing(5)
                    }.padding(24)
                }.background(Ink.paper)
            } else { ContentUnavailableView("作品不存在", systemImage: "book.closed") }
        }.navigationTitle("翻译工作台").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sheet) { destination in
            switch destination {
            case .preferences: PreferencesSheet(preferences: binding(\.options.preferences))
            case .glossary: JobGlossaryView(id: id)
            }
        }
    }
    private func binding<T>(_ path: WritableKeyPath<BookJob, T>) -> Binding<T> {
        Binding(get: { studio.job(id)![keyPath: path] }, set: { value in studio.update(id) { $0[keyPath: path] = value } })
    }
    private func heading(_ job: BookJob) -> some View {
        HStack(alignment: .center, spacing: 20) {
            BookCover(title: job.title)
            VStack(alignment: .leading, spacing: 10) { Eyebrow(text: "TRANSLATION STUDIO"); Text(job.title).font(.system(size: 25, weight: .regular, design: .serif)).lineLimit(3); Text("\(job.format) · \(job.source.count.formatted()) 字符").font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.muted) }
        }.foregroundStyle(Ink.text)
    }
    private func configuration(_ job: BookJob) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            PaperCard {
                VStack(spacing: 9) {
                    HStack {
                        if job.options.documentKind != .general { Label((job.genreWasCorrected ? "文稿类型 · " : "自动识别 · ") + job.options.documentKind.title, systemImage: "text.viewfinder").font(.system(size: 12, weight: .medium)) }
                        else { Text("文稿排版").font(.system(size: 13, weight: .medium)) }
                        Spacer()
                        Menu {
                            ForEach(DocumentKind.allCases.filter { $0 != .general }) { kind in Button(kind.title) { studio.update(id) { $0.options.documentKind = kind; $0.genreWasCorrected = true } } }
                            Button("按原文结构") { studio.update(id) { $0.options.documentKind = .general; $0.genreWasCorrected = true } }
                            Button("重新自动识别") { studio.update(id) { $0.options.documentKind = DocumentClassifier.detect(text: job.source, title: job.title, format: job.format); $0.genreWasCorrected = false } }
                        } label: { Image(systemName: "ellipsis").padding(6).foregroundStyle(Ink.muted) }.accessibilityLabel("纠正文稿类型")
                    }
                    Picker("排版", selection: binding(\.options.layout)) { ForEach(LayoutPolicy.allCases) { Text($0.title).tag($0) } }
                    Text("按文稿内容自动组织诗行、对白、引用、章节或代码。保留排版指保留内容结构；复杂 PDF 页布局近似重排。").font(.system(size: 11)).foregroundStyle(Ink.muted).lineSpacing(4)
                }
            }
            HStack { Text("翻译为").font(.system(size: 14)); Spacer(); Picker("目标语言", selection: binding(\.options.targetLanguage)) { ForEach(["简体中文", "繁體中文", "English", "日本語", "한국어", "Français", "Deutsch", "Español", "Русский"], id: \.self) { Text($0).tag($0) } }.tint(Ink.text) }
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("翻译强度").font(.system(size: 15, weight: .semibold)); Spacer(); Eyebrow(text: "EFFORT") }
                HStack(spacing: 9) {
                    ForEach(Quality.allCases) { quality in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { studio.update(id) { $0.options.quality = quality } }
                            UISelectionFeedbackGenerator().selectionChanged()
                        } label: {
                            VStack(spacing: 10) { EffortBars(quality: quality); Text(quality.title).font(.system(size: 14, weight: .medium)) }.frame(maxWidth: .infinity).padding(.vertical, 20).background(job.options.quality == quality ? Ink.orange.opacity(0.09) : .white.opacity(0.6), in: RoundedRectangle(cornerRadius: 16)).overlay { RoundedRectangle(cornerRadius: 16).stroke(job.options.quality == quality ? Ink.orange : Ink.line, lineWidth: 1) }
                        }.buttonStyle(.plain).foregroundStyle(Ink.text).accessibilityAddTraits(job.options.quality == quality ? .isSelected : [])
                    }
                }
                if job.options.documentKind == .fiction { Text("小说按章处理。精译和出版档逐轮审校，让相邻段落在人物口吻、视角与叙事节奏上保持连贯。").font(.system(size: 11)).foregroundStyle(Ink.muted).lineSpacing(4) }
                Text(job.options.quality.detail + (job.options.quality == .fast ? " · 实时流式阅读" : " · 每章审校完即可阅读")).font(.system(size: 11)).foregroundStyle(Ink.muted)
            }
            PaperCard {
                VStack(alignment: .leading, spacing: 15) {
                    Text("译文的声音").font(.system(size: 14, weight: .semibold))
                    Picker("翻译风格", selection: binding(\.options.style)) {
                        ForEach(TranslationStyle.presets + studio.customStyles) { style in Text(style.name).tag(style) }
                    }.pickerStyle(.menu).tint(Ink.text)
                    Text(job.options.style.subtitle).font(.system(size: 12)).foregroundStyle(Ink.muted)
                    Divider()
                    Button { sheet = .preferences } label: { HStack { Label("语言与注释偏好", systemImage: "slider.horizontal.3"); Spacer(); Image(systemName: "chevron.right") }.font(.system(size: 13)).foregroundStyle(Ink.text) }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("术语如何确定").font(.system(size: 15, weight: .semibold))
                Picker("术语处理", selection: binding(\.glossaryMode)) { ForEach(GlossaryMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                Text(job.glossaryMode == .review ? "先提取整份文档中的人名、地名和专业词；由你确认译名后，再开始正文。" : job.glossaryMode == .automatic ? "系统按全文提取并统一译名，应用到翻译、校对、语言审校与主编定稿。" : "使用你在「术语」页维护的词表，译名会在所有阶段保持一致。") .font(.system(size: 12)).foregroundStyle(Ink.muted).lineSpacing(4)
            }
        }.foregroundStyle(Ink.text)
    }
    private func reviewCard(_ job: BookJob) -> some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("术语已整理，等你过目", systemImage: "checklist").font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.orange)
                Text("共 \(job.terms.count) 个候选术语。可以修改译名、删除不需要的词或补充自己的译法。").font(.system(size: 13)).foregroundStyle(Ink.muted).lineSpacing(5)
                Button("校对术语表  →") { sheet = .glossary }.font(.system(size: 14, weight: .semibold))
            }
        }
    }
    private func pipeline(_ job: BookJob) -> some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 22) {
                HStack { Text(job.options.documentKind == .fiction ? "你的小说编辑部" : "你的翻译团队").font(.system(size: 15, weight: .semibold)); Spacer(); if job.status == .translating || job.status == .extracting { ThinkingDots() } }
                if job.status == .extracting { Label("术语整理 · 全文提取中", systemImage: "text.magnifyingglass").font(.system(size: 13)).foregroundStyle(Ink.orange) }
                ForEach(job.options.stages, id: \.rawValue) { stage in
                    let count = job.checkpoints.filter { $0.stage == stage }.count
                    HStack(spacing: 13) {
                        Image(systemName: count == job.chunkCount ? "checkmark.circle.fill" : "circle.dotted").font(.system(size: 20)).foregroundStyle(count == job.chunkCount ? Ink.green : Ink.orange.opacity(count > 0 ? 1 : 0.4))
                        VStack(alignment: .leading, spacing: 4) { Text(stage.title).font(.system(size: 14, weight: .medium)); Text(stageDescription(stage, kind: job.options.documentKind)).font(.system(size: 10)).foregroundStyle(Ink.muted) }
                        Spacer(); Text("\(count) / \(job.chunkCount)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Ink.muted)
                    }
                }
                ProgressView(value: job.progress).tint(Ink.orange).animation(.easeInOut(duration: 0.4), value: job.progress)
                HStack { Text(job.statusText); Spacer(); Text("\(Int(job.progress * 100))%").monospacedDigit() }.font(.system(size: 11)).foregroundStyle(Ink.muted)
            }
        }
    }
    private func action(_ job: BookJob) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if job.status == .draft { HStack { Text(studio.ownAPI ? "使用自己的 API · 由服务商计费" : "预计 \(job.estimate) 点 · 含术语与所选审校"); Spacer(); Text(studio.ownAPI ? studio.model : "DeepSeek").foregroundStyle(Ink.text).lineLimit(1) }.font(.system(size: 11)).foregroundStyle(Ink.muted) }
            if studio.activeID == id { PrimaryButton(title: "暂停，稍后继续", icon: "pause") { studio.pause() } }
            else { PrimaryButton(title: job.status == .reviewing ? "确认术语，开始翻译" : job.status == .draft ? "开始翻译" : "继续翻译", icon: "sparkle") { studio.begin(id, account: account, purchases: purchases, approved: job.status == .reviewing) }.disabled(studio.task != nil) }
        }
    }
    private func stageDescription(_ stage: Stage, kind: DocumentKind) -> String {
        if kind == .fiction {
            switch stage {
            case .translate: return "保留叙述视角、场景与人物对白"
            case .proofread: return "核对人名、别名、因果、遗漏与误译"
            case .linguist: return "审校人物口吻、指代、语气与多语对白"
            case .editor: return "参考相邻译稿，统一本章衔接与表达"
            }
        }
        switch stage {
        case .translate: return "忠实传达原作，保留段落与声音"
        case .proofread: return "核对遗漏、误译、数字与术语"
        case .linguist: return "审校外语、习语、语气与编者注"
        case .editor: return "统一风格、节奏与最终表达"
        }
    }
}
struct PreferencesSheet: View {
    @Binding var preferences: TranslationPreferences
    @Environment(\.dismiss) private var dismiss
    var body: some View { NavigationStack { PreferencesForm(preferences: $preferences).navigationTitle("语言与注释").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } } } }
}
struct PreferencesForm: View {
    @Binding var preferences: TranslationPreferences
    var body: some View {
        Form {
            Section { Picker("原文夹杂其他外语", selection: $preferences.foreignText) { ForEach(ForeignTextPolicy.allCases) { Text($0.title).tag($0) } } } header: { Text("多语言片段") } footer: { Text("例如英文小说中的法语对白。专有名词遵循术语表；代码保持原样。") }
            Section {
                Picker("编者注", selection: $preferences.annotations) { ForEach(AnnotationPolicy.allCases) { Text($0.title).tag($0) } }
                Toggle("少量注释", isOn: $preferences.sparseNotes).disabled(preferences.annotations == .none)
            } header: { Text("帮助读懂弦外之音") } footer: { Text("少量：每块最多 1 条；常规：最多 3 条。新增解释标注为「编者注」，存疑的背景不添加。模型仍可能出错，正式出版前建议人工复核。") }
            Section { Toggle("精译档加入语言专家", isOn: $preferences.extraLanguageReview) } header: { Text("审校团队") } footer: { Text("出版档始终包含语言专家与主编。此选项为精译档再增加一轮语言审校，点数和 API 用量随之增加。") }
        }.scrollContentBackground(.hidden).background(Ink.paper)
    }
}
