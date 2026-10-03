import SwiftUI
import UniformTypeIdentifiers
import TranslationCore

private enum LibrarySheet: String, Identifiable { case paste, wallet; var id: String { rawValue } }
struct LibraryView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(CloudAccount.self) private var account
    @State private var importing = false
    @State private var sheet: LibrarySheet?
    @State private var path: [String] = []
    @State private var filter = 0
    private var filtered: [BookJob] { studio.jobs.filter { filter == 0 || (filter == 1 ? ["EPUB", "TXT"].contains($0.format) : ["PDF", "DOCX", "MD"].contains($0.format)) } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(text: "A ROOM FOR EVERY WORD")
                    Text("让好故事，\n不止一种语言。").font(.system(size: 33, weight: .regular, design: .serif)).tracking(-1).lineSpacing(5).foregroundStyle(Ink.text)
                    Text("从一份原文，走进另一个世界。") .font(.system(size: 13)).foregroundStyle(Ink.muted).padding(.top, 3)
                }.padding(.top, 8)
                importCard
                HStack { Text("我的书房").font(.system(size: 21, weight: .medium, design: .serif)); Spacer(); Text("\(studio.jobs.count) 份作品").font(.system(size: 12)).foregroundStyle(Ink.muted) }
                Picker("文档类型", selection: $filter) { Text("全部").tag(0); Text("小说与书籍").tag(1); Text("文档").tag(2) }.pickerStyle(.segmented)
                if filtered.isEmpty { emptyState }
                LazyVStack(spacing: 22) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, job in
                        NavigationLink(value: job.id) { bookRow(job, index: index) }.buttonStyle(.plain)
                    }
                }
                HStack(spacing: 6) { Image(systemName: "lock.shield"); Text("自己的 API 密钥仅保存在设备钥匙串中") }.font(.system(size: 10)).foregroundStyle(Ink.muted).frame(maxWidth: .infinity).padding(.bottom, 10)
            }.padding(24)
        }.background(Ink.paper).toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: String.self) { JobView(id: $0) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .pdf, UTType(filenameExtension: "epub") ?? .data, UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "docx") ?? .data]) { result in
            Task {
                do {
                    let url = try result.get()
                    let imported = try await Task.detached(priority: .userInitiated) { try DocumentIO.read(url) }.value
                    let id = studio.add(imported); path.append(id)
                } catch { studio.message = error.localizedDescription }
            }
        }
        .sheet(item: $sheet) { item in switch item { case .paste: PasteView(); case .wallet: WalletView() } }
        .navigationDestination(isPresented: Binding(get: { !path.isEmpty }, set: { if !$0 { path = [] } })) { if let id = path.last { JobView(id: id) } }
    }
    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 8) { Image(systemName: "asterisk").font(.system(size: 26, weight: .medium)).foregroundStyle(Ink.orange); Text("译间").font(.system(size: 22, weight: .semibold, design: .serif)); Text("BOOKLLM").font(.system(size: 9, design: .monospaced)).tracking(1).foregroundStyle(Ink.muted) }
            Spacer()
            Button { sheet = .wallet } label: { HStack(spacing: 5) { Image(systemName: "sparkle").foregroundStyle(Ink.orange); Text(account.isLoggedIn ? "\(account.points)" : "点数") }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 11).padding(.vertical, 8).background(.white.opacity(0.65), in: Capsule()).overlay { Capsule().stroke(Ink.line) } }.foregroundStyle(Ink.text)
        }
    }
    private var importCard: some View {
        Button { importing = true } label: {
            HStack(spacing: 18) {
                ZStack { RoundedRectangle(cornerRadius: 15).fill(Ink.orange.opacity(0.09)).frame(width: 51, height: 59); Image(systemName: "doc.badge.plus").font(.system(size: 23)).foregroundStyle(Ink.orange) }
                VStack(alignment: .leading, spacing: 7) { Text("开始一份新翻译").font(.system(size: 15, weight: .semibold)); Text("EPUB · PDF · TXT · DOCX · MD").font(.system(size: 9, design: .monospaced)).foregroundStyle(Ink.muted) }
                Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 17)).foregroundStyle(Ink.muted)
            }.padding(21).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 21)).overlay { RoundedRectangle(cornerRadius: 21).stroke(Ink.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4])) }
        }.buttonStyle(.plain).foregroundStyle(Ink.text)
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { BookCover(title: "每一页\n新的世界", large: true); Spacer(); Image(systemName: "quote.opening").font(.system(size: 44, design: .serif)).foregroundStyle(Ink.line); Spacer() }
            Text("书房还空着，故事正在等你。").font(.system(size: 17, design: .serif))
            Text("导入一本书，或粘贴一段文字。选择声音、打磨语言，把值得读的内容带在身边。").font(.system(size: 13)).lineSpacing(6).foregroundStyle(Ink.muted)
            Button("粘贴文字  →") { sheet = .paste }.font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.orange)
        }.padding(.vertical, 10)
    }
    private func bookRow(_ job: BookJob, index: Int) -> some View {
        HStack(spacing: 17) {
            BookCover(title: job.title, index: index)
            VStack(alignment: .leading, spacing: 8) {
                Text(job.title).font(.system(size: 17, weight: .medium, design: .serif)).lineLimit(2).foregroundStyle(Ink.text)
                Text("\(job.format)  ·  \(job.source.count.formatted()) 字符").font(.system(size: 10, design: .monospaced)).foregroundStyle(Ink.muted)
                HStack(spacing: 6) { Circle().fill(job.status == .complete ? Ink.green : Ink.orange).frame(width: 5); Text(job.statusText); if job.status == .translating { ThinkingDots() } }.font(.system(size: 11)).foregroundStyle(job.status == .complete ? Ink.green : Ink.muted)
                if job.status == .translating || job.status == .paused { ProgressView(value: job.progress).tint(Ink.orange).frame(maxWidth: 130) }
            }
            Spacer(minLength: 0); Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Ink.muted)
        }
    }
}
struct PasteView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(\.dismiss) private var dismiss
    @State private var title = "一份新的译稿"
    @State private var text = ""
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                TextField("作品名称", text: $title).font(.system(size: 24, design: .serif))
                TextEditor(text: $text).scrollContentBackground(.hidden).padding(12).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 16)).overlay { RoundedRectangle(cornerRadius: 16).stroke(Ink.line) }
                Text("\(text.count.formatted()) 字符").font(.caption).foregroundStyle(Ink.muted)
                PrimaryButton(title: "放入书房") { _ = studio.add(.init(title: title.isEmpty ? "未命名" : title, text: text, format: "TXT")); dismiss() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(24).background(Ink.paper).navigationTitle("粘贴原文").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }
}
