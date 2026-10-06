import SwiftUI
import UniformTypeIdentifiers
import TranslationCore
import VisionKit

private enum LibrarySheet: String, Identifiable { case paste, wallet, work; var id: String { rawValue } }
struct LibraryView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(ImportCoordinator.self) private var importer
    @Environment(CloudAccount.self) private var account
    @State private var importing = false
    @State private var scanning = false
    @State private var scannedURL: URL?
    @State private var sheet: LibrarySheet?
    @State private var path: [String] = []
    @State private var filter = 0
    private var filtered: [BookJob] { studio.jobs.filter { filter == 0 || (filter == 1 ? ["EPUB", "TXT"].contains($0.format) : !["EPUB", "TXT"].contains($0.format)) } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                importCard
                if importer.hasPending {
                    Button { importer.resume(studio: studio) } label: { HStack { Label("继续导入与识别", systemImage: "doc.text.viewfinder"); Spacer(); Image(systemName: "chevron.right") }.font(.system(size: 13)).padding(16).foregroundStyle(Ink.text).background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 14)) }
                }
                if !studio.jobs.isEmpty {
                    Picker("文档类型", selection: $filter) { Text("全部").tag(0); Text("书籍").tag(1); Text("文档").tag(2) }.pickerStyle(.segmented)
                }
                if filtered.isEmpty { emptyState }
                LazyVStack(spacing: 20) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, job in
                        VStack(alignment: .leading, spacing: 10) {
                            NavigationLink {
                                if job.status == .complete { ReaderView(id: job.id) }
                                else { JobView(id: job.id) }
                            } label: { bookRow(job, index: index) }.buttonStyle(.plain)
                            if job.status != .complete && canRead(job) {
                                NavigationLink { ReaderView(id: job.id) } label: { Label("继续阅读", systemImage: "book").font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.text) }.padding(.leading, 81)
                            }
                        }
                    }
                }
            }.padding(24)
        }.background(Ink.paper).toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: String.self) { JobView(id: $0) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .pdf, .image, UTType(filenameExtension: "epub") ?? .data, UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "docx") ?? .data]) { result in
            do { importer.start(try result.get(), studio: studio) } catch { studio.message = error.localizedDescription }
        }
        .sheet(isPresented: $scanning, onDismiss: {
            if let scannedURL { importer.start(scannedURL, studio: studio); self.scannedURL = nil }
        }) {
            DocumentScanner(cancelled: { scanning = false }) { result in
                switch result { case .success(let url): scannedURL = url; case .failure(let error): studio.message = error.localizedDescription }
                scanning = false
            }.ignoresSafeArea()
        }
        .onChange(of: importer.jobID) { _, value in if let value { path = [value]; importer.jobID = nil } }
        .sheet(item: $sheet) { item in switch item { case .paste: PasteView(); case .wallet: WalletView(); case .work: WorkLookupView() } }
        .navigationDestination(isPresented: Binding(get: { !path.isEmpty }, set: { if !$0 { path = [] } })) { if let id = path.last { JobView(id: id) } }
    }
    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 9) { Text("书架").font(.system(size: 22, weight: .semibold)); if !studio.jobs.isEmpty { Text("\(studio.jobs.count)").font(.system(size: 13)).foregroundStyle(Ink.muted) } }
            Spacer()
            if VNDocumentCameraViewController.isSupported { Button { scanning = true } label: { Image(systemName: "doc.viewfinder").font(.system(size: 18)).padding(8) }.accessibilityLabel("扫描纸张") }
            Button { sheet = .work } label: { Image(systemName: "link").font(.system(size: 16)).padding(8) }.accessibilityLabel("通过链接或 ID 打开译作")
            if !studio.ownAPI { Button { sheet = .wallet } label: { HStack(spacing: 5) { Image(systemName: "sparkle").foregroundStyle(Ink.orange); Text(account.isLoggedIn ? "\(account.points)" : "点数") }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 11).padding(.vertical, 8).background(.white.opacity(0.65), in: Capsule()).overlay { Capsule().stroke(Ink.line) } }.foregroundStyle(Ink.text) }
        }
    }
    private var importCard: some View {
        HStack(spacing: 10) {
            Button { importing = true } label: {
                Label("导入文件", systemImage: "plus").font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 14).foregroundStyle(.white).background(Ink.text, in: Capsule())
            }.buttonStyle(.plain)
            Button { sheet = .paste } label: {
                Label("粘贴文本", systemImage: "doc.on.clipboard").font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 14).foregroundStyle(Ink.text).background(.white.opacity(0.6), in: Capsule()).overlay { Capsule().stroke(Ink.line) }
            }.buttonStyle(.plain)
        }
    }
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical").font(.system(size: 28, weight: .light))
            Text(studio.jobs.isEmpty ? "暂无作品" : "暂无此类作品").font(.system(size: 14))
        }.foregroundStyle(Ink.muted).frame(maxWidth: .infinity).padding(.vertical, 65)
    }
    private func bookRow(_ job: BookJob, index: Int) -> some View {
        HStack(spacing: 17) {
            BookCover(title: job.title, index: index, coverKey: job.coverKey)
            VStack(alignment: .leading, spacing: 8) {
                Text(job.title).font(.system(size: 17, weight: .medium, design: .serif)).lineLimit(2).foregroundStyle(Ink.text)
                Text(metadata(job)).font(.system(size: 11)).foregroundStyle(Ink.muted)
                HStack(spacing: 6) { Text(job.status == .complete ? "继续阅读" : job.statusText); if job.status == .translating { ThinkingDots() } }.font(.system(size: 12)).foregroundStyle(job.status == .complete ? Ink.text : Ink.muted)
                if job.status == .translating || job.status == .paused { ProgressView(value: job.progress).tint(Ink.orange).frame(maxWidth: 130) }
            }
            Spacer(minLength: 0); Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Ink.muted)
        }
    }
    private func canRead(_ job: BookJob) -> Bool {
        job.status == .complete || !job.readableChapters.isEmpty || (job.options.quality == .fast && [.translating, .paused, .failed, .awaitingCredits, .needsReview].contains(job.status) && (!job.checkpoints.isEmpty || studio.activeID == job.id))
    }
    private func metadata(_ job: BookJob) -> String {
        let target = TranslationLanguage.allCases.first { $0.targetName == job.options.targetLanguage }?.title ?? job.options.targetLanguage
        guard let source = job.sourceLanguage else { return "\(job.format) · \(job.source.count.formatted()) 字符" }
        return "\(source) → \(target)"
    }
}
struct PasteView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                TextField("作品名称", text: $title).font(.system(size: 18, weight: .medium))
                TextEditor(text: $text).scrollContentBackground(.hidden).padding(12).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 16)).overlay { RoundedRectangle(cornerRadius: 16).stroke(Ink.line) }
                Text("\(text.count.formatted()) 字符").font(.caption).foregroundStyle(Ink.muted)
                PrimaryButton(title: "添加作品") {
                    do { _ = try studio.add(.init(title: title.isEmpty ? "未命名" : title, text: text, format: "TXT")); dismiss() }
                    catch { studio.message = error.localizedDescription }
                }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(24).background(Ink.paper).navigationTitle("粘贴原文").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }
}
