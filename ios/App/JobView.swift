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
                        if !job.terms.isEmpty && job.status != .reviewing { Button { sheet = .glossary } label: { Label("查看本文术语 · \(job.terms.count) 个", systemImage: "text.book.closed").font(.system(size: 13)) }.padding(.top, 3) }
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
            Button("先处理部分") { studio.begin(id, account: account, purchases: purchases, partial: true) }
            Button("充值") { sheet = .wallet }
            Button("取消", role: .cancel) { }
        } message: { Text("按所选术语模式处理，点数不足以完成下一段时暂停，充值后继续。全文术语整理也消耗点数，可先改选「自动保持一致」。") }
    }
    private func binding<T>(_ path: WritableKeyPath<BookJob, T>) -> Binding<T> {
        Binding(get: { studio.job(id)![keyPath: path] }, set: { value in studio.update(id) { $0[keyPath: path] = value } })
    }
    private func heading(_ job: BookJob) -> some View {
        HStack(alignment: .center, spacing: 20) {
            BookCover(title: job.title, coverKey: job.coverKey)
            VStack(alignment: .leading, spacing: 8) { Text(job.title).font(.system(size: 22, weight: .medium, design: .serif)).lineLimit(3); Text(metadata(job)).font(.system(size: 12)).foregroundStyle(Ink.muted)
                if job.status != .draft { HStack(spacing: 5) { Text(job.options.effectiveQuality.title).font(.system(size: 11)).foregroundStyle(Ink.muted); if [.deep, .publication, .definitive].contains(job.options.effectiveQuality) { QualityFlame(quality: job.options.effectiveQuality).frame(width: 15, height: 18) } } }
            }
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
            TranslationStrengthPicker(selection: Binding(get: { job.options.effectiveQuality }, set: { value in
                studio.update(id) { $0.options.quality = value; $0.options.pipelineVersion = 2; $0.options.preferences.extraLanguageReview = false }
            }))
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
                HStack {
                    Text("术语处理").font(.system(size: 14))
                    Spacer()
                    Picker("术语处理", selection: Binding(get: { job.glossaryMode == .custom ? .accumulated : job.glossaryMode }, set: { value in studio.update(id) { $0.glossaryMode = value } })) {
                        ForEach(GlossaryMode.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.menu).tint(Ink.text)
                }
                Text(job.glossaryMode.detail).font(.system(size: 12)).foregroundStyle(Ink.muted)
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
                if job.options.usesCollaborativeEditing { Text("校对与语言专家并行审查，主编集中整合").font(.system(size: 11)).foregroundStyle(Ink.muted) }
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
            if job.status == .draft && job.options.pipelineVersion == 2 { Text("必要时定向补全，按实际用量结算").font(.system(size: 11)).foregroundStyle(Ink.muted) }
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
            case .editor: return "整合审查意见，统筹本章文风与衔接"
            case .verify: return "对照原稿，终审本章事实、术语与完整性"
            }
        }
        switch stage {
        case .translate: return "忠实传达原作，保留段落与声音"
        case .proofread: return "核对遗漏、误译、数字与术语"
        case .linguist: return "审校外语、习语、语气与编者注"
        case .editor: return "整合审查意见，协调文风与表达"
        case .verify: return "对照原稿，终审事实、术语与完整性"
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
        }.scrollContentBackground(.hidden).background(Ink.paper)
    }
}
