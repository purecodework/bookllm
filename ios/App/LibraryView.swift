import SwiftUI
import UniformTypeIdentifiers
import TranslationCore

private enum LibrarySheet: Identifiable {
    case importing, paste, account, job(String), names(String), exporting(String)
    var id: String {
        switch self { case .importing: "import"; case .paste: "paste"; case .account: "account"; case .job(let id): "job-" + id; case .names(let id): "names-" + id; case .exporting(let id): "export-" + id }
    }
}
struct ReaderRoute: Hashable { let id: String; var export = false }
struct LibraryView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(ImportCoordinator.self) private var importer
    @Environment(PasteDraftCoordinator.self) private var pasteDrafts
    @Environment(CloudAccount.self) private var account
    @Environment(PurchaseStore.self) private var purchases
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var configurationID: String?
    @State private var importing = false
    @State private var chooseFile = false
    @State private var sheet: LibrarySheet?
    @State private var addedPasteID: String?
    @State private var filter = 0
    @State private var search = ""
    @State private var searching = false
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 32.0
    private var filtered: [BookJob] {
        studio.jobs.filter {
            !studio.pendingImportIDs.contains($0.id) &&
            (filter == 0 || (filter == 1 ? $0.status != .draft && $0.status != .complete : $0.status == .complete)) &&
            (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
        }
    }
    private var showsPendingPaste: Bool {
        pasteDrafts.hasDraft && filter == 0 && (search.isEmpty || pasteDrafts.draft?.title.localizedCaseInsensitiveContains(search) == true)
    }
    private var showsPendingImport: Bool {
        importer.hasPending && filter != 2 && (search.isEmpty || importer.draft?.title.localizedCaseInsensitiveContains(search) == true)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("译间").font(.subheadline)
                    Spacer()
                    PaperIconButton(symbol: "person", label: "账户与设置") { sheet = .account }
                }.padding(.bottom, 12)
                ViewThatFits(in: .horizontal) {
                    HStack { Text("书库").font(.system(size: titleSize, weight: .regular)).fixedSize(); Spacer(); libraryControls }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("书库").font(.system(size: titleSize, weight: .regular))
                        HStack { Spacer(); libraryControls }
                    }
                }.padding(.bottom, 18)
                if searching {
                    HStack {
                        TextField("搜索书名", text: $search).textInputAutocapitalization(.never).submitLabel(.search)
                        if !search.isEmpty { PaperIconButton(symbol: "xmark", label: "清除搜索") { search = "" } }
                    }.padding(.horizontal, 12).frame(minHeight: 48).background(Ink.surface, in: RoundedRectangle(cornerRadius: 7)).padding(.bottom, 12)
                }
                HStack(spacing: 28) {
                    filterButton("全部", value: 0)
                    filterButton("处理中", value: 1)
                    filterButton("已完成", value: 2)
                    Spacer(minLength: 0)
                }
                PaperRule()
                if showsPendingPaste { pendingPaste }
                if showsPendingImport { pendingImport }
                if let error = studio.libraryLoadError {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("无法读取书库").font(.title3)
                        Text(error).font(.caption).foregroundStyle(Ink.error)
                        Button("重试") { studio.reloadLibrary() }.frame(minHeight: 44)
                    }.padding(.vertical, 48)
                } else if filtered.isEmpty && !showsPendingImport && !showsPendingPaste { emptyState }
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { job in
                        bookRow(job).padding(.vertical, 22)
                        PaperRule()
                    }
                }
            }.padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 32)
                .frame(maxWidth: PaperLayout.libraryWidth).frame(maxWidth: .infinity)
        }.background { PaperBackground() }.foregroundStyle(Ink.text).toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $configurationID) { id in JobView(id: id) }
            .navigationDestination(for: ReaderRoute.self) { route in ReaderView(id: route.id, exportOnOpen: route.export) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .pdf, UTType(importedAs: "org.idpf.epub-container"), UTType(filenameExtension: "md") ?? .plainText, UTType(importedAs: "org.openxmlformats.wordprocessingml.document")]) { result in
                do { importer.start(try result.get(), studio: studio) } catch { studio.message = error.localizedDescription }
            }
            .sheet(item: $sheet, onDismiss: {
                if chooseFile { chooseFile = false; importing = true }
                if let id = addedPasteID { addedPasteID = nil; configurationID = id }
            }) { item in
                Group {
                switch item {
                case .importing: importSheet
                case .paste: PasteView { addedPasteID = $0 }
                case .account: NavigationStack { SettingsView().toolbar { PaperToolbarItem(placement: .cancellationAction) { Button("关闭") { sheet = nil } } } }
                case .names(let id): JobGlossaryView(id: id)
                case .exporting(let id): ExportView(id: id)
                case .job(let id):
                    NavigationStack {
                        JobView(id: id).toolbar { PaperToolbarItem(placement: .cancellationAction) { PaperIconButton(symbol: "xmark", label: "关闭本书详情") { sheet = nil } } }
                    }.presentationDetents([.fraction(0.88), .large]).presentationDragIndicator(.visible).presentationCornerRadius(18)
                }
                }.modifier(PaperUITestLayout())
            }
            .onChange(of: importer.presented) { _, presented in
                if !presented, let id = importer.jobID { importer.jobID = nil; if let job = studio.job(id) { openBook(job) } }
            }
            .onAppear {
                pasteDrafts.reconcile(studio: studio); importer.reconcile(studio: studio)
                if let id = importer.jobID, !importer.presented { importer.jobID = nil; if let job = studio.job(id) { openBook(job) } }
            }
    }
    private func openBook(_ job: BookJob) {
        if job.status == .draft { configurationID = job.id }
        else { sheet = .job(job.id) }
    }
    private var libraryControls: some View {
        HStack(spacing: 8) {
            PaperIconButton(symbol: "magnifyingglass", label: "搜索文稿") { searching.toggle(); if !searching { search = "" } }
            Button { sheet = .importing } label: {
                Label("导入", systemImage: "plus").font(.subheadline).frame(minHeight: 44).padding(.horizontal, 8).fixedSize(horizontal: true, vertical: false)
            }.foregroundStyle(Ink.accent).accessibilityLabel("导入文稿")
        }
    }
    private func filterButton(_ title: String, value: Int) -> some View {
        Button { filter = value } label: {
            Text(title).font(.caption).foregroundStyle(filter == value ? Ink.text : Ink.muted)
                .frame(minWidth: 44, minHeight: 44).overlay(alignment: .bottomLeading) { if filter == value { Rectangle().fill(Ink.accent).frame(height: 1.5) } }
        }.buttonStyle(.plain).accessibilityAddTraits(filter == value ? .isSelected : [])
    }
    private var pendingImport: some View {
        Button { importer.resume(studio: studio) } label: {
            HStack(spacing: 19) {
                Image(systemName: "doc.text").font(.system(size: 30, weight: .light)).frame(width: 78, height: 111).background(Ink.surface)
                VStack(alignment: .leading, spacing: 8) {
                    Text(importer.draft?.title ?? "需要恢复的导入").font(.headline)
                    if let recoveryError = importer.recoveryError {
                        Text(recoveryError).font(.caption).foregroundStyle(Ink.attention).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(importer.phase == .processing ? "设备内识别，不扣点" : "继续导入与识别").font(.caption).foregroundStyle(Ink.muted)
                        if importer.progress.total > 0 { Text("已识别 \(importer.progress.completed) / \(importer.progress.total) 页").font(.caption).foregroundStyle(Ink.muted) }
                    }
                    if let error = importer.error { Text(error).font(.caption).foregroundStyle(Ink.error) }
                }
                Spacer(minLength: 0)
            }.foregroundStyle(Ink.text)
        }.buttonStyle(.plain).padding(.vertical, 22).overlay(alignment: .bottom) { PaperRule() }
    }
    private var pendingPaste: some View {
        let title = pasteDrafts.draft?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Button { sheet = .paste } label: {
            HStack(spacing: 19) {
                Image(systemName: "doc.on.clipboard").font(.system(size: 30, weight: .light)).frame(width: 78, height: 111).background(Ink.surface)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title.isEmpty ? "尚未入库的粘贴草稿" : title).font(.system(size: 19))
                    Text("继续粘贴与编辑").font(.caption).foregroundStyle(Ink.muted)
                    if let error = pasteDrafts.loadError ?? pasteDrafts.saveError { Text(error).font(.caption).foregroundStyle(Ink.error) }
                    else { Text(pasteDrafts.isSaved ? "已保存在本机，尚未开始翻译" : "尚未入库，正在保留输入").font(.caption).foregroundStyle(Ink.muted) }
                }
                Spacer(minLength: 0)
            }.foregroundStyle(Ink.text)
        }.buttonStyle(.plain).accessibilityLabel("继续编辑粘贴草稿").padding(.vertical, 22).overlay(alignment: .bottom) { PaperRule() }
    }
    private func bookRow(_ job: BookJob) -> some View {
        HStack(alignment: .top, spacing: 19) {
            Button { openBook(job) } label: { BookCover(title: job.title, coverKey: job.coverKey) }.buttonStyle(.plain).accessibilityLabel("查看 \(job.title)")
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 0) {
                    Button { openBook(job) } label: {
                        Text(job.title).font(PaperType.reading(19)).lineLimit(2).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.buttonStyle(.plain).accessibilityLabel(job.title)
                    Menu {
                        if job.status == .draft { Button("设置翻译") { openBook(job) } }
                        else { Button("本书进度") { openBook(job) } }
                        Button("译名") { sheet = .names(job.id) }
                        if job.canExport { Button("导出") { sheet = .exporting(job.id) }.accessibilityIdentifier("book-menu-export-" + job.id) }
                    } label: { Image(systemName: "ellipsis").font(.system(size: 18, weight: .light)).frame(width: 44, height: 44) }.accessibilityLabel("\(job.title) 的菜单")
                }
                Text(job.bookMetadata).font(.caption).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
                Text(studio.activeID == job.id ? job.currentStage(events: Array(studio.processing.values)) : job.libraryState)
                    .font(.caption).foregroundStyle([.failed, .needsReview, .awaitingCredits].contains(job.status) ? Ink.attention : Ink.muted).lineLimit(2)
                if job.status != .draft && job.status != .complete {
                    GeometryReader { geometry in
                        let width = geometry.size.width.isFinite ? max(0, geometry.size.width) : 0
                        ZStack(alignment: .leading) { Rectangle().fill(Ink.track); Rectangle().fill(Ink.accent).frame(width: width * min(1, max(0, job.chapterProgress))) }
                    }.frame(height: 2).animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: job.chapterProgress).accessibilityHidden(true)
                    Text(job.chapterSummary).font(.caption).foregroundStyle(Ink.muted)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { rowActions(job) }
                    VStack(alignment: .leading, spacing: 0) { rowActions(job) }
                }.font(.caption).foregroundStyle(Ink.accent)
            }
        }
    }
    @ViewBuilder private func rowActions(_ job: BookJob) -> some View {
        if job.canRead || (job.options.quality == .fast && studio.activeID == job.id) {
            NavigationLink(value: ReaderRoute(id: job.id)) {
                HStack(spacing: 6) {
                    Text(job.readingAnchor == nil ? "开始阅读" : "继续阅读")
                    Image(systemName: "arrow.right").accessibilityHidden(true)
                }.frame(minHeight: 44)
            }.accessibilityIdentifier("library-read-" + job.id)
        }
        if job.status == .draft {
            Button("设置翻译") { openBook(job) }.frame(minHeight: 44)
        } else if job.status == .complete {
            Button("导出") { sheet = .exporting(job.id) }.frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("library-export-" + job.id)
        } else {
            if studio.activeID == job.id {
                Button(studio.pauseRequestedID == job.id ? "正在暂停…" : "暂停") { studio.pause() }.disabled(studio.pauseRequestedID == job.id).frame(minWidth: 44, minHeight: 44)
            } else {
                Button(job.status == .paused ? "继续翻译" : "查看详情") {
                    let ready = job.usesOwnAPI ? studio.canUseOwnAPI(account: account, purchases: purchases) && studio.connectionIssue == nil : account.isConfigured && account.isLoggedIn
                    if job.status == .paused && ready { studio.begin(job.id, account: account, purchases: purchases) }
                    else { openBook(job) }
                }.disabled(studio.task != nil).frame(minWidth: 44, minHeight: 44)
            }
            Button("进度") { openBook(job) }.frame(minWidth: 44, minHeight: 44)
        }
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(!search.isEmpty ? "没有找到文稿" : filter == 0 && studio.jobs.isEmpty && !importer.hasPending && !pasteDrafts.hasDraft ? "还没有文稿" : "暂无此类文稿").font(.title3)
            if studio.jobs.isEmpty && filter == 0 && search.isEmpty { PrimaryButton(title: "导入文稿", icon: "plus") { sheet = .importing } }
            else if !search.isEmpty { Button("清除搜索") { search = "" }.frame(minHeight: 44) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 64)
    }
    private var importSheet: some View {
        NavigationStack {
            ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("导入文稿").font(.system(size: 23))
                Text("EPUB、PDF、DOCX、TXT、Markdown").font(.subheadline).foregroundStyle(Ink.muted)
                PaperRule()
                Button { chooseFile = true; sheet = nil } label: {
                    HStack { Label("选择文件", systemImage: "doc"); Spacer(); Image(systemName: "chevron.right") }.frame(minHeight: 48)
                }
                PaperRule()
                Button { sheet = .paste } label: {
                    HStack { Label("粘贴文本", systemImage: "doc.on.clipboard"); Spacer(); Image(systemName: "chevron.right") }.frame(minHeight: 48)
                }
                Text("扫描或混合 PDF 在设备内识别，不扣翻译点数。识别后可以核对原页和文字，未完成的识别可以稍后继续。").font(.caption).foregroundStyle(Ink.muted).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            }.padding(24).frame(maxWidth: PaperLayout.formWidth).frame(maxWidth: .infinity)
            }.background { PaperBackground(textured: false) }
                .toolbar { PaperToolbarItem(placement: .cancellationAction) { Button("关闭") { sheet = nil } } }
        }.presentationDetents([.medium, .large]).presentationCornerRadius(18)
    }
}
struct PasteView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(PasteDraftCoordinator.self) private var drafts
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var onAdded: (String) -> Void = { _ in }
    @State private var error: String?
    @State private var discarding = false
    private enum Field: Hashable { case title, text }
    @FocusState private var focusedField: Field?
    var body: some View {
        NavigationStack {
            Group {
                if let loadError = drafts.loadError {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("无法读取粘贴草稿").font(.title3)
                            Text(loadError).font(.subheadline).foregroundStyle(Ink.error)
                            PrimaryButton(title: "重试读取", icon: "arrow.clockwise") { drafts.reload() }
                            Button("放弃无法读取的草稿", role: .destructive) { discarding = true }.frame(minHeight: 44)
                            if let error = drafts.saveError { Text(error).font(.caption).foregroundStyle(Ink.error) }
                        }.padding(24)
                    }
                } else {
                    ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("文稿名称（可选）").font(.caption).foregroundStyle(Ink.muted)
                        TextField("留空将使用“未命名”", text: Binding(get: { drafts.draft?.title ?? "" }, set: { drafts.setTitle($0) }))
                            .font(.title3).frame(minHeight: 44).focused($focusedField, equals: .title).accessibilityLabel("文稿名称，可选")
                        PaperRule()
                        Text("原文").font(.caption).foregroundStyle(Ink.muted)
                        ZStack(alignment: .topLeading) {
                            if drafts.draft?.text.isEmpty != false {
                                Text("在这里粘贴原文").font(.body).foregroundStyle(Ink.muted).padding(.horizontal, 13).padding(.vertical, 16).allowsHitTesting(false).accessibilityHidden(true)
                            }
                            TextEditor(text: Binding(get: { drafts.draft?.text ?? "" }, set: { drafts.setText($0) }))
                                .focused($focusedField, equals: .text).scrollContentBackground(.hidden).padding(8)
                                .accessibilityLabel("粘贴原文").accessibilityHint("输入将保存在本机草稿中，加入书库后进入翻译设置")
                        }.frame(minHeight: 260).background(Ink.surface, in: RoundedRectangle(cornerRadius: 7))
                        Text("\((drafts.draft?.text.count ?? 0).formatted()) / 2,000,000 字符").font(.caption).foregroundStyle(Ink.muted)
                        if dynamicTypeSize.isAccessibilitySize {
                            if let error = error ?? drafts.saveError { Text(error).font(.caption).foregroundStyle(Ink.error).fixedSize(horizontal: false, vertical: true) }
                            draftStatus
                        }
                    }.padding(24).disabled(drafts.savingToLibrary)
                    }.scrollDismissesKeyboard(.interactively)
                }
            }.frame(maxWidth: PaperLayout.formWidth).frame(maxWidth: .infinity)
                .background { PaperBackground(textured: false) }
                .safeAreaInset(edge: .bottom) {
                    if drafts.loadError == nil {
                        VStack(alignment: .leading, spacing: 10) {
                            if !dynamicTypeSize.isAccessibilitySize {
                                if let error = error ?? drafts.saveError { Text(error).font(.caption).foregroundStyle(Ink.error).fixedSize(horizontal: false, vertical: true) }
                                draftStatus
                            }
                            PrimaryButton(title: drafts.savingToLibrary ? "正在加入书库…" : "添加文稿，设置翻译", icon: "arrow.right") { add() }
                                .disabled(drafts.savingToLibrary || (drafts.draft?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false))
                        }.padding(.horizontal, 24).padding(.vertical, 12).frame(maxWidth: PaperLayout.formWidth).frame(maxWidth: .infinity).background(Ink.paper)
                    }
                }
                .navigationTitle("粘贴文本").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    PaperToolbarItem(placement: .cancellationAction) { Button("关闭") { if drafts.loadError != nil || drafts.flush() { dismiss() } }.disabled(drafts.savingToLibrary) }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { focusedField = nil } }
                }
                .confirmationDialog("放弃这份粘贴草稿？", isPresented: $discarding, titleVisibility: .visible) {
                    Button("放弃草稿", role: .destructive) { if drafts.discard() { drafts.open(); error = nil } }
                    Button("继续编辑", role: .cancel) { }
                } message: { Text("尚未加入书库的名称和原文会删除，书库中的文稿不受影响。") }
        }.interactiveDismissDisabled(drafts.savingToLibrary || drafts.saveError != nil)
            .onAppear { drafts.open() }.onDisappear { if !drafts.savingToLibrary { _ = drafts.flush() } }
    }
    private var draftStatus: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(drafts.saveError != nil ? "输入仍保留，重试保存后再关闭。" : drafts.isSaved ? "草稿已保存在本机，关闭后可继续。" : "输入会自动保存，关闭时保留草稿。")
                .font(.caption).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if drafts.saveError != nil { Button("重试保存") { _ = drafts.flush() }.font(.caption).frame(minWidth: 44, minHeight: 44) }
            Button("放弃", role: .destructive) { discarding = true }.font(.caption).frame(minWidth: 44, minHeight: 44).disabled(drafts.savingToLibrary)
        }
    }
    private func add() {
        error = nil; focusedField = nil
        Task {
            do { let id = try await drafts.addToLibrary(studio: studio); onAdded(id); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}
