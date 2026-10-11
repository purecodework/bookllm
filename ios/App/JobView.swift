import SwiftUI
import TranslationCore

private enum JobSheet: String, Identifiable { case glossary, wallet, repair, unlock, ocr, styles, settings, api, rename, export; var id: String { rawValue } }
struct JobView: View {
    let id: String
    @Environment(StudioStore.self) private var studio
    @Environment(CloudAccount.self) private var account
    @Environment(PurchaseStore.self) private var purchases
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sheet: JobSheet?
    @State private var partialChoice = false
    @State private var more = false
    @State private var reading = false
    @State private var editedTitle = ""
    @State private var titleError: String?
    @State private var savingTitle = false
    @ScaledMetric(relativeTo: .subheadline) private var actionLabelSize = 14.0
    private var events: [ProcessingEvent] { studio.activeID == id ? Array(studio.processing.values) : [] }
    var body: some View {
        Group {
            if let job = studio.job(id) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if job.status == .draft { heading(job); PaperRule() }
                        else { Text(job.bookMetadata).font(.caption).foregroundStyle(Ink.muted) }
                        if job.status == .draft { configuration(job) }
                        else if job.purchasedWorkID != nil { Text("已购译本 · 可离线阅读与导出").font(.subheadline).foregroundStyle(Ink.muted) }
                        else { pipeline(job) }
                        if job.status == .reviewing {
                            Text("这是旧版待确认任务。继续时沿用已保存译名，不会在打开页面时自动启动。")
                                .font(.caption).foregroundStyle(Ink.muted).lineSpacing(5)
                        }
                        if let error = job.error {
                            Text(error).font(.subheadline).foregroundStyle(Ink.error).fixedSize(horizontal: false, vertical: true)
                        }
                        if job.ocrPages != nil {
                            Button("查看识别原稿") { sheet = .ocr }.font(.subheadline).frame(minHeight: 44)
                        }
                        if job.status == .complete && job.canRead {
                            Button { reading = true } label: {
                                HStack { Text(job.status == .complete ? "继续阅读" : "阅读已完成章节"); Spacer(); Image(systemName: "arrow.right") }.frame(minHeight: 48)
                            }.font(.subheadline)
                        }
                    }.frame(maxWidth: PaperLayout.formWidth, alignment: .leading).padding(24).frame(maxWidth: .infinity)
                }.background { PaperBackground(textured: job.status == .draft) }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if job.status != .complete {
                            action(job).frame(maxWidth: PaperLayout.formWidth, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 12).frame(maxWidth: .infinity).background(Ink.paper)
                        }
                    }
            } else { ContentUnavailableView("文稿不存在", systemImage: "book.closed") }
        }.foregroundStyle(Ink.text)
            .navigationTitle(studio.job(id)?.status == .draft ? "翻译设置" : studio.job(id)?.title ?? "本书进度").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar {
                PaperToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("译名") { sheet = .glossary }
                        if studio.job(id)?.canExport == true { Button("导出与分享") { sheet = .export } }
                        if let job = studio.job(id), job.status == .draft {
                            Button("修改文稿名称") { editedTitle = job.title; titleError = nil; sheet = .rename }
                            Menu("文稿类型") {
                                ForEach(DocumentKind.allCases) { kind in
                                    Button(kind.title) { studio.update(id) { $0.options.documentKind = kind; $0.genreWasCorrected = true } }
                                }
                                Button("重新自动识别") { studio.update(id) { $0.options.documentKind = DocumentClassifier.detect(text: $0.source, title: $0.title, format: $0.format); $0.genreWasCorrected = false } }
                            }
                        }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("本书菜单")
                }
            }
            .sheet(item: $sheet) { destination in
                Group {
                switch destination {
                case .glossary: JobGlossaryView(id: id)
                case .wallet: WalletView(ownOverride: false)
                case .unlock: WalletView(ownOverride: true)
                case .repair: RepairDraftView(id: id)
                case .styles: NavigationStack { StylesView().toolbar { PaperToolbarItem(placement: .cancellationAction) { Button("关闭") { sheet = nil } } } }
                case .settings, .api:
                    NavigationStack {
                        SettingsView(initialSection: destination == .api ? .api : .usage)
                            .toolbar { PaperToolbarItem(placement: .cancellationAction) { Button("关闭") { sheet = nil } } }
                    }
                case .export: ExportView(id: id)
                case .rename: renameSheet
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
                            }.navigationTitle("识别原稿").navigationBarTitleDisplayMode(.inline).toolbar { PaperToolbarItem(placement: .confirmationAction) { Button("完成") { sheet = nil } } }
                        }
                    }
                }
                }.modifier(PaperUITestLayout())
            }
            .fullScreenCover(isPresented: $reading) {
                NavigationStack { ReaderView(id: id, onClose: { reading = false }) }.modifier(PaperUITestLayout())
            }
            .alert("点数可能不足", isPresented: $partialChoice) {
                Button("先处理部分") { studio.begin(id, account: account, purchases: purchases, partial: true) }
                Button("充值") { sheet = .wallet }
                Button("取消", role: .cancel) { }
            } message: { Text("按实际用量结算。点数不足以完成下一段时暂停，充值后可继续，已完成内容保留。") }
    }
    private func binding<T>(_ path: WritableKeyPath<BookJob, T>) -> Binding<T> {
        Binding(get: { studio.job(id)![keyPath: path] }, set: { value in studio.update(id) { $0[keyPath: path] = value } })
    }
    private func heading(_ job: BookJob) -> some View {
        HStack(alignment: .center, spacing: 19) {
            BookCover(title: job.title, coverKey: job.coverKey, compact: job.status == .draft)
            VStack(alignment: .leading, spacing: 8) {
                Text(job.title).font(PaperType.reading(23, relativeTo: .title2)).fixedSize(horizontal: false, vertical: true)
                Text(job.status == .draft ? "\(job.format) · \(job.options.documentKind.title)" : job.bookMetadata).font(.caption).foregroundStyle(Ink.muted)
                if job.coverKey != nil { Text("保留已提取的原始封面").font(.caption).foregroundStyle(Ink.muted) }
                Button("修改名称") { editedTitle = job.title; titleError = nil; sheet = .rename }.font(.caption).frame(minHeight: 44)
            }
            Spacer(minLength: 0)
        }
    }
    private func configuration(_ job: BookJob) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("原文语言 · 自动识别").font(.caption).foregroundStyle(Ink.muted)
                    Text(job.sourceLanguage ?? "自动").font(PaperType.reading(20)).frame(minHeight: 44, alignment: .leading)
                }
                Spacer(); Image(systemName: "arrow.right").font(.caption).foregroundStyle(Ink.muted).padding(.top, 40).accessibilityHidden(true); Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    Text("翻译为").font(.caption).foregroundStyle(Ink.muted)
                    Picker("目标语言", selection: binding(\.options.targetLanguage)) {
                        ForEach(TranslationLanguage.allCases) { language in Text(language.title).tag(language.targetName) }
                        if !TranslationLanguage.allCases.contains(where: { $0.targetName == job.options.targetLanguage }) { Text(job.options.targetLanguage).tag(job.options.targetLanguage) }
                    }.labelsHidden().font(PaperType.reading(20)).frame(minHeight: 44)
                }
            }
            PaperRule()
            TranslationStrengthPicker(selection: Binding(get: { studio.job(id)?.options.effectiveQuality ?? .refined }, set: { value in
                studio.update(id) { $0.options.quality = value; $0.options.pipelineVersion = 2; $0.options.preferences.extraLanguageReview = false }
            }))
            PaperRule()
            HStack {
                Text("翻译风格").font(.subheadline); Spacer()
                Picker("翻译风格", selection: binding(\.options.style)) {
                    ForEach(TranslationStyle.presets + studio.customStyles) { style in Text(style.name).tag(style) }
                }.labelsHidden().frame(minHeight: 44)
            }
            Button("编辑自定义风格") { sheet = .styles }.font(.caption).frame(minHeight: 44)
            Text("译名自动保持一致，需要时可在本书菜单中修改。").font(.caption).foregroundStyle(Ink.muted).lineSpacing(5)
            Text("这里的设置仅用于这本文稿；账户中的默认偏好用于之后导入的文稿。").font(.caption).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
            RolePipelineView(quality: job.options.effectiveQuality)
            PaperRule()
            DisclosureGroup("更多设置", isExpanded: $more) {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("混合外语", selection: binding(\.options.preferences.foreignText)) { ForEach(ForeignTextPolicy.allCases) { Text($0.title).tag($0) } }
                    Picker("编者注", selection: binding(\.options.preferences.annotations)) { ForEach(AnnotationPolicy.allCases) { Text($0.title).tag($0) } }
                    Toggle("少量注释", isOn: binding(\.options.preferences.sparseNotes)).disabled(job.options.preferences.annotations == .none)
                    Picker("排版", selection: binding(\.options.layout)) { ForEach(LayoutPolicy.allCases) { Text($0.title).tag($0) } }
                }.font(.subheadline).padding(.top, 16)
            }.font(.subheadline)
            PaperRule()
            usageSummary(job)
        }
    }
    private func pipeline(_ job: BookJob) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("本书翻译进度").font(.caption).foregroundStyle(Ink.muted)
                ProgressView(value: job.chapterProgress).tint(Ink.accent).animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: job.chapterProgress).accessibilityLabel(job.chapterSummary)
                Text(job.chapterSummary).font(.caption).foregroundStyle(Ink.muted)
                Text("关闭面板仍会在前台继续翻译；进入后台会暂停，回来后请点“继续翻译”。")
                    .font(.caption).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(studio.pauseRequestedID == id ? "正在暂停…" : job.currentStage(events: events)).font(.title3)
                if let index = events.map(\.chunkIndex).min(), let chapter = job.chapters.first(where: { $0.chunks.contains(index) }) {
                    Text("正在处理 · " + chapter.title).font(.caption).foregroundStyle(Ink.muted)
                }
            }
            RoleEnsemble(stages: job.options.stages.filter { $0 != .verify }, states: job.roleStates(events: events))
            PaperRule()
            HStack {
                Text("完整性检查")
                Spacer()
                Text(job.status == .complete ? "已通过" : job.status == .needsReview ? "需要核对" : events.contains(where: { $0.state == .checking }) ? "检查中" : "每轮结果返回后检查")
            }.font(.caption).foregroundStyle(Ink.muted)
            if job.options.stages.contains(.verify) { Text("旧任务沿用原有终审检查点。").font(.caption).foregroundStyle(Ink.muted) }
            Text("完成审校与完整性检查的章节才计入完成。速读可提前查看初译，仍需检查。").font(.caption).foregroundStyle(Ink.muted).lineSpacing(5)
        }
    }
    private func action(_ job: BookJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if job.status == .draft {
                Text(studio.ownAPI ? "自带 API · 服务商另计费" : account.isConfigured ? "翻译点数 · 预估约 \(job.estimatedPoints(tokensPerPoint: account.tokensPerPoint)) 点" : "点数服务暂不可用")
                    .font(.caption).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
                Button("使用方式与费用") { sheet = .settings }.font(.caption).frame(minHeight: 44)
                    .accessibilityLabel("更改使用方式与 API 设置")
            }
            if job.status == .awaitingCredits {
                Button("充值") { sheet = .wallet }.frame(minWidth: 44, minHeight: 44).disabled(!account.isConfigured)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { command(job); readingAction(job) }
                VStack(spacing: 12) { command(job); readingAction(job) }
            }
        }
    }
    @ViewBuilder private func readingAction(_ job: BookJob) -> some View {
        if job.status != .draft && (job.canRead || (job.options.quality == .fast && studio.activeID == id)) {
            PrimaryButton(title: job.options.quality == .fast ? "阅读当前内容" : "阅读已完成章节", icon: "") { reading = true }
        }
    }
    private func usageSummary(_ job: BookJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(studio.ownAPI ? "使用方式 · 买断自带 API" : "使用方式 · 翻译点数").font(.caption)
            Text(studio.ownAPI ? "一次购买永久解锁自带 API，支持所有翻译档位与导出。模型用量由服务商另外计费。" : account.isConfigured ? "预估约 \(job.estimatedPoints(tokensPerPoint: account.tokensPerPoint)) 点，按实际模型用量结算。" : "当前版本暂未连接点数翻译服务。").font(.caption).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
    @ViewBuilder private func command(_ job: BookJob) -> some View {
            if studio.activeID != id && (job.status == .draft ? studio.ownAPI : job.usesOwnAPI) && !studio.canUseOwnAPI(account: account, purchases: purchases) {
                PrimaryButton(title: "买断解锁", icon: "key.horizontal") { sheet = .unlock }
            } else if job.reviewDraft != nil && studio.activeID != id {
                PrimaryButton(title: "核对待校稿", icon: "text.magnifyingglass") { sheet = .repair }
            } else if studio.activeID == id {
                PrimaryButton(title: studio.pauseRequestedID == id ? "正在暂停…" : "暂停翻译", icon: "pause", secondary: job.canRead) { studio.pause() }.disabled(studio.pauseRequestedID == id)
            } else if (job.status == .draft ? studio.ownAPI : job.usesOwnAPI) && studio.connectionIssue != nil {
                PrimaryButton(title: "配置 API", icon: "key.horizontal") { sheet = .api }
            } else if !(job.status == .draft ? studio.ownAPI : job.usesOwnAPI) && !account.isConfigured {
                PrimaryButton(title: "点数服务暂不可用", icon: "", secondary: true) { }.disabled(true)
            } else if !(job.status == .draft ? studio.ownAPI : job.usesOwnAPI) && !account.isLoggedIn {
                PrimaryButton(title: "登录后开始", icon: "person") { sheet = .settings }
            } else {
                PrimaryButton(title: job.status == .reviewing ? "沿用已保存译名并继续" : job.status == .draft ? "开始翻译" : "继续翻译", secondary: job.status != .draft && job.canRead) {
                    if !studio.ownAPI && job.status == .draft && account.isLoggedIn && job.estimatedPoints(tokensPerPoint: account.tokensPerPoint) > account.points && job.partialApproved != true { partialChoice = true }
                    else { studio.begin(id, account: account, purchases: purchases, approved: job.status == .reviewing) }
                }.disabled(studio.task != nil)
            }
    }
    private var renameSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("文稿名称").font(.subheadline)
                TextField("请输入文稿名称", text: $editedTitle).textInputAutocapitalization(.never).frame(minHeight: 48).accessibilityLabel("文稿名称")
                if let titleError { Text(titleError).font(.caption).foregroundStyle(Ink.error) }
                PrimaryButton(title: savingTitle ? "正在保存…" : "保存", icon: "") {
                    savingTitle = true
                    Task {
                        do { try await studio.renameDraft(id, title: editedTitle); savingTitle = false; sheet = nil }
                        catch { titleError = error.localizedDescription; savingTitle = false }
                    }
                }.disabled(savingTitle)
                Spacer(minLength: 0)
            }.frame(maxWidth: PaperLayout.formWidth).padding(24).frame(maxWidth: .infinity).background(Ink.paper)
                .navigationTitle("修改名称").navigationBarTitleDisplayMode(.inline)
                .toolbar { PaperToolbarItem(placement: .cancellationAction) { Button("取消") { sheet = nil }.disabled(savingTitle) } }
        }.presentationDetents([.medium, .large]).interactiveDismissDisabled(savingTitle)
    }
}
struct PreferencesSheet: View {
    @Binding var preferences: TranslationPreferences
    @Environment(\.dismiss) private var dismiss
    var body: some View { NavigationStack { PreferencesForm(preferences: $preferences).navigationTitle("语言与注释").navigationBarTitleDisplayMode(.inline).toolbar { PaperToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } } } }
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
