import SwiftUI
import TranslationCore

private enum JobSheet: String, Identifiable { case preferences, glossary, wallet, repair, unlock, ocr; var id: String { rawValue } }
struct JobView: View {
    let id: String
    @Environment(StudioStore.self) private var studio
    @Environment(CloudAccount.self) private var account
    @Environment(PurchaseStore.self) private var purchases
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sheet: JobSheet?
    @State private var partialChoice = false
    var body: some View {
        Group {
            if let job = studio.job(id) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 25) {
                        heading(job)
                        if job.ocrPages != nil { Button("查看识别原稿") { sheet = .ocr }.font(.system(size: 13)) }
                        if job.status == .draft { configuration(job) }
                        if job.status == .reviewing { reviewCard(job) }
                        if job.status != .draft { pipeline(job) }
                        if let error = job.error { Text(error).font(.system(size: 13)).foregroundStyle(Ink.orange).padding(16).background(Ink.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 14)) }
                        if job.status == .complete || (job.options.quality == .fast && job.status != .draft && job.status != .extracting && job.status != .reviewing) || !job.readableChapters.isEmpty {
                            NavigationLink { ReaderView(id: id) } label: { HStack { Text(job.status == .complete ? "打开译本" : job.options.quality == .fast ? "边译边读" : "阅读已完成章节"); Spacer(); Image(systemName: "book") }.font(.system(size: 16, weight: .semibold)).padding(20).foregroundStyle(.white).background(Ink.text, in: RoundedRectangle(cornerRadius: 18)) }
                        }
                        if job.status != .complete { action(job) }
                        if !job.terms.isEmpty && job.status != .reviewing { Button { sheet = .glossary } label: { Label("查看本书术语 · \(job.terms.count) 个", systemImage: "text.book.closed").font(.system(size: 13)) }.padding(.top, 3) }
                    }.padding(24)
                }.background(Ink.paper)
            } else { ContentUnavailableView("作品不存在", systemImage: "book.closed") }
        }.navigationTitle("翻译").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sheet) { destination in
            switch destination {
            case .preferences: PreferencesSheet(preferences: binding(\.options.preferences))
            case .glossary: JobGlossaryView(id: id)
            case .wallet: WalletView(ownOverride: false)
            case .unlock: WalletView(ownOverride: true)
            case .repair: RepairDraftView(id: id)
            case .ocr:
                if let job = studio.job(id) {
                    NavigationStack {
                        OCRReviewView(imported: .init(title: job.title, text: job.source, format: job.format, ocrPages: job.ocrPages, sourceDocumentID: job.sourceDocumentID), readOnly: job.status != .draft, saveTitle: "保存原稿") { reviewed in
                            studio.update(id) {
                                $0.source = reviewed.text; $0.ocrPages = reviewed.ocrPages
                                $0.options.sourceWasOCR = reviewed.ocrPages?.contains(where: { $0.usedOCR }) == true ? true : nil
                                $0.options.sourceLanguage = SourceLanguageDetection.code(for: reviewed.text)
                                if !$0.genreWasCorrected { $0.options.documentKind = DocumentClassifier.detect(text: reviewed.text, title: $0.title, format: $0.format) }
                                $0.replan()
                            }
                            sheet = nil
                        }.navigationTitle("识别原稿").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sheet = nil } } }
                    }
                }
            }
        }
        .alert("点数可能不足", isPresented: $partialChoice) {
            Button("用现有术语，先翻译部分") { studio.begin(id, account: account, purchases: purchases, partial: true) }
            Button("充值") { sheet = .wallet }
            Button("取消", role: .cancel) { }
        } message: { Text("可先翻译到剩余点数不足以完成下一段时暂停，再充值续译。为保留正文用量，先使用现有术语库；选择「我先校对」仍会等你确认术语。实际点数按模型用量结算。") }
    }
    private func binding<T>(_ path: WritableKeyPath<BookJob, T>) -> Binding<T> {
        Binding(get: { studio.job(id)![keyPath: path] }, set: { value in studio.update(id) { $0[keyPath: path] = value } })
    }
    private func heading(_ job: BookJob) -> some View {
        HStack(alignment: .center, spacing: 20) {
            BookCover(title: job.title, coverKey: job.coverKey)
            VStack(alignment: .leading, spacing: 8) { Text(job.title).font(.system(size: 22, weight: .medium, design: .serif)).lineLimit(3); Text(metadata(job)).font(.system(size: 12)).foregroundStyle(Ink.muted) }
        }.foregroundStyle(Ink.text)
    }
    private func configuration(_ job: BookJob) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            PaperCard {
                VStack(spacing: 9) {
                    HStack {
                        Text(job.options.documentKind.title).font(.system(size: 13, weight: .medium))
                        if !job.genreWasCorrected { Text("自动").font(.system(size: 11)).foregroundStyle(Ink.muted) }
                        Spacer()
                        Menu {
                            ForEach(DocumentKind.allCases.filter { $0 != .general }) { kind in Button(kind.title) { studio.update(id) { $0.options.documentKind = kind; $0.genreWasCorrected = true } } }
                            Button("按原文结构") { studio.update(id) { $0.options.documentKind = .general; $0.genreWasCorrected = true } }
                            Button("重新自动识别") { studio.update(id) { $0.options.documentKind = DocumentClassifier.detect(text: job.source, title: job.title, format: job.format); $0.genreWasCorrected = false } }
                        } label: { Image(systemName: "ellipsis").padding(6).foregroundStyle(Ink.muted) }.accessibilityLabel("纠正文稿类型")
                    }
                    Picker("排版", selection: binding(\.options.layout)) { ForEach(LayoutPolicy.allCases) { Text($0.title).tag($0) } }.tint(Ink.text)
                }
            }
            HStack { Text("翻译为").font(.system(size: 14)); Spacer(); Picker("目标语言", selection: binding(\.options.targetLanguage)) { ForEach(TranslationLanguage.allCases) { language in Text(language.title).tag(language.targetName) }; if !TranslationLanguage.allCases.contains(where: { $0.targetName == job.options.targetLanguage }) { Text(job.options.targetLanguage).tag(job.options.targetLanguage) } }.tint(Ink.text) }
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("翻译强度").font(.system(size: 15, weight: .semibold)); Spacer(); Text(job.options.quality.title).font(.system(size: 13, weight: .medium)) }
                Text(job.options.stages.map(\.title).joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(Ink.muted)
                QualitySlider(selection: binding(\.options.quality))
            }
            PaperCard {
                VStack(alignment: .leading, spacing: 15) {
                    HStack { Text("风格").font(.system(size: 14)); Spacer(); Picker("翻译风格", selection: binding(\.options.style)) {
                        ForEach(TranslationStyle.presets + studio.customStyles) { style in Text(style.name).tag(style) }
                    }.pickerStyle(.menu).tint(Ink.text) }
                    Divider()
                    Button { sheet = .preferences } label: { HStack { Text("语言与注释"); Spacer(); Image(systemName: "chevron.right") }.font(.system(size: 14)).foregroundStyle(Ink.text) }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("术语库").font(.system(size: 15, weight: .semibold))
                Picker("术语处理", selection: binding(\.glossaryMode)) { ForEach(GlossaryMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                if job.glossaryMode == .review { Text("确认术语后开始翻译。").font(.system(size: 12)).foregroundStyle(Ink.muted) }
                if job.glossaryMode == .custom && studio.libraryTerms.isEmpty { Text("请先在术语页添加词表。").font(.system(size: 12)).foregroundStyle(Ink.muted) }
            }
        }.foregroundStyle(Ink.text)
    }
    private func reviewCard(_ job: BookJob) -> some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("确认术语").font(.system(size: 15, weight: .semibold)); Spacer(); Text("\(job.terms.count) 个").font(.system(size: 12)).foregroundStyle(Ink.muted) }
                Button("查看与修改") { sheet = .glossary }.font(.system(size: 14, weight: .medium))
            }
        }
    }
    private func pipeline(_ job: BookJob) -> some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 22) {
                HStack { Text("翻译进度").font(.system(size: 15, weight: .semibold)); Spacer(); if job.status == .translating || job.status == .extracting { ThinkingDots() } }
                if job.status == .extracting { Label("整理术语", systemImage: "text.magnifyingglass").font(.system(size: 13)).foregroundStyle(Ink.orange) }
                ForEach(job.options.stages, id: \.rawValue) { stage in
                    let count = job.checkpoints.filter { $0.stage == stage }.count
                    HStack(spacing: 13) {
                        Image(systemName: count == job.chunkCount ? "checkmark.circle.fill" : "circle.dotted").font(.system(size: 20)).foregroundStyle(count == job.chunkCount ? Ink.green : Ink.orange.opacity(count > 0 ? 1 : 0.4))
                        Text(stage.title).font(.system(size: 14, weight: .medium))
                        Spacer(); Text("\(count) / \(job.chunkCount)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Ink.muted)
                    }.accessibilityElement(children: .combine).accessibilityHint(stageDescription(stage, kind: job.options.documentKind))
                }
                ProgressView(value: job.progress).tint(Ink.orange).animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: job.progress)
                HStack { Text(job.statusText); Spacer(); Text("\(Int(job.progress * 100))%").monospacedDigit() }.font(.system(size: 11)).foregroundStyle(Ink.muted)
            }
        }
    }
    private func action(_ job: BookJob) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if job.status == .draft { HStack { Text(studio.ownAPI ? "自带 API · 服务商计费" : "约 \(job.estimatedPoints(tokensPerPoint: account.tokensPerPoint)) 点"); Spacer(); Text(studio.ownAPI ? studio.model : "DeepSeek").foregroundStyle(Ink.text).lineLimit(1) }.font(.system(size: 12)).foregroundStyle(Ink.muted) }
            if job.status == .awaitingCredits { Button("充值") { sheet = .wallet }.font(.system(size: 14)) }
            if job.status == .draft && studio.ownAPI && !studio.canUseOwnAPI(account: account, purchases: purchases) {
                PrimaryButton(title: "买断解锁", icon: "key.horizontal") { sheet = .unlock }
            } else if job.reviewDraft != nil && studio.activeID != id {
                PrimaryButton(title: "核对待校稿", icon: "text.magnifyingglass") { sheet = .repair }
            } else if studio.activeID == id { PrimaryButton(title: "暂停翻译", icon: "pause") { studio.pause() } }
            else { PrimaryButton(title: job.status == .reviewing ? "确认术语，开始翻译" : job.status == .draft ? "开始翻译" : "继续翻译", icon: "sparkle") {
                if !studio.ownAPI && job.status == .draft && account.isLoggedIn && job.estimatedPoints(tokensPerPoint: account.tokensPerPoint) > account.points && job.partialApproved != true { partialChoice = true }
                else { studio.begin(id, account: account, purchases: purchases, approved: job.status == .reviewing) }
            }.disabled(studio.task != nil) }
        }
    }
    private func metadata(_ job: BookJob) -> String {
        let target = TranslationLanguage.allCases.first { $0.targetName == job.options.targetLanguage }?.title ?? job.options.targetLanguage
        guard let source = job.sourceLanguage else { return "\(job.format) · \(job.source.count.formatted()) 字符" }
        return "\(source) → \(target)"
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
            Section { Picker("其他外语", selection: $preferences.foreignText) { ForEach(ForeignTextPolicy.allCases) { Text($0.title).tag($0) } } } header: { Text("混合语言") }
            Section {
                Picker("编者注", selection: $preferences.annotations) { ForEach(AnnotationPolicy.allCases) { Text($0.title).tag($0) } }
                Toggle("少量注释", isOn: $preferences.sparseNotes).disabled(preferences.annotations == .none)
            } header: { Text("解释与注释") } footer: { Text("俚语、双关与文化背景仅在全书首次出现时解释，新增内容标为「编者注」。") }
            Section { Toggle("精译加入语言专家", isOn: $preferences.extraLanguageReview) } header: { Text("语言审校") } footer: { Text("出版档已包含。开启会增加精译档用量。") }
        }.scrollContentBackground(.hidden).background(Ink.paper)
    }
}
