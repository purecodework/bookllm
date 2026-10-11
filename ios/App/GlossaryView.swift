import SwiftUI
import UIKit
import TranslationCore

struct JobGlossaryView: View {
    let id: String
    @Environment(StudioStore.self) private var studio
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Term?
    @State private var search = ""
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 32.0
    var body: some View {
        NavigationStack {
            ScrollView {
                if let job = studio.job(id) {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(job.title).font(.caption).foregroundStyle(Ink.muted)
                        Text("译名").font(.system(size: titleSize))
                        Text("自动保持一致，需要时再修改。").font(.caption).foregroundStyle(Ink.muted)
                        if job.displayTerms.count > 20 {
                            TextField("搜索原词或译名", text: $search).padding(12).background(Ink.surface, in: RoundedRectangle(cornerRadius: 7)).accessibilityLabel("搜索译名")
                        }
                        PaperRule()
                        if job.displayTerms.isEmpty {
                            Text(job.purchasedWorkID == nil ? "译名会随翻译积累。不用提前整理，可以直接开始翻译。" : "此译本没有可修改的译名记录。").font(.subheadline).foregroundStyle(Ink.muted).lineSpacing(6).padding(.vertical, 24)
                        }
                        LazyVStack(spacing: 0) {
                            ForEach(job.displayTerms.filter { search.isEmpty || $0.source.localizedCaseInsensitiveContains(search) || $0.target.localizedCaseInsensitiveContains(search) }) { term in
                                HStack(alignment: .center, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(term.source).font(.subheadline).foregroundStyle(Ink.muted)
                                        Text(term.target).font(PaperType.reading(19)).foregroundStyle(Ink.text)
                                        if job.nameOverrides?[term.id] != nil { Text("已修改").font(.caption).foregroundStyle(Ink.accent) }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Button("修改") { editing = term }.font(.caption).frame(minWidth: 44, minHeight: 44).accessibilityLabel("修改 \(term.source) 的译名")
                                }.padding(.vertical, 22)
                                PaperRule()
                            }
                        }
                        Text("修改只用于之后新准备的处理。已启动调用与已完成内容保留原译名，不会自动重译或扣点。").font(.caption).foregroundStyle(Ink.muted).lineSpacing(5)
                    }.frame(maxWidth: PaperLayout.formWidth, alignment: .leading).padding(24).frame(maxWidth: .infinity)
                } else { ContentUnavailableView("文稿不存在", systemImage: "book.closed") }
            }.background { PaperBackground() }.navigationBarTitleDisplayMode(.inline)
                .toolbar { PaperToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .sheet(item: $editing) { term in NameEditSheet(bookID: id, term: term).modifier(PaperUITestLayout()) }
        }
    }
}
struct NameEditSheet: View {
    let bookID: String
    let term: Term
    @Environment(StudioStore.self) private var studio
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var target = ""
    @State private var saving = false
    @State private var error: String?
    @State private var context = false
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(studio.job(bookID)?.title ?? "").font(.caption).foregroundStyle(Ink.muted)
                    Text("原词").font(.caption).foregroundStyle(Ink.muted)
                    Text(term.source).font(.subheadline).textSelection(.enabled)
                    Text("译名").font(.caption).foregroundStyle(Ink.muted)
                    TextField("请输入译名", text: $target).font(.subheadline).focused($focused)
                        .padding(12).frame(minHeight: 48).background(Ink.paper)
                        .overlay { RoundedRectangle(cornerRadius: 4).stroke(Ink.line, lineWidth: 1) }
                        .submitLabel(.done).onSubmit { save() }.accessibilityLabel("译名").id("name-input")
                    if let error { Text(error).font(.caption).foregroundStyle(Ink.error) }
                    if dynamicTypeSize.isAccessibilitySize { effectNote }
                    DisclosureGroup("查看原文语境", isExpanded: $context) {
                        Text(term.evidence ?? sourceContext).font(.subheadline).foregroundStyle(Ink.muted).lineSpacing(5).textSelection(.enabled).padding(.top, 10)
                    }.font(.caption)
                }.frame(maxWidth: PaperLayout.formWidth, alignment: .leading).padding(24).frame(maxWidth: .infinity)
            }.background { PaperBackground(textured: false) }
                .safeAreaInset(edge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        if !dynamicTypeSize.isAccessibilitySize { effectNote }
                        HStack(spacing: 12) {
                            Button("取消") { dismiss() }.frame(minWidth: 64, minHeight: 48).disabled(saving)
                            PrimaryButton(title: saving ? "正在保存…" : "保存", icon: "") { save() }.disabled(saving)
                        }
                    }.frame(maxWidth: PaperLayout.formWidth, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 12).frame(maxWidth: .infinity).background(Ink.paper)
                }
                .navigationTitle("修改译名").navigationBarTitleDisplayMode(.inline)
                .toolbar { PaperToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(saving) } }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                    if focused { proxy.scrollTo("name-input", anchor: .center) }
                }
            }
        }.presentationDetents([.large]).presentationDragIndicator(.visible).presentationCornerRadius(18)
            .interactiveDismissDisabled(saving).onAppear { target = term.target }
    }
    private var effectNote: some View {
        Text(effectExplanation).font(.caption).foregroundStyle(Ink.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("name-effect-explanation")
    }
    private var effectExplanation: String {
        guard let job = studio.job(bookID) else { return "保存不会重新翻译，也不扣点。" }
        if job.glossaryMode != .accumulated {
            return "这本书沿用已保存的固定译名。修改不会改变已准备好、正在翻译和已完成的内容，也不会重新翻译或扣点。后续处理仍受原任务规则限制。"
        }
        if job.status == .complete {
            return "当前译文不会改变。保存仅用于之后新准备的翻译内容，不会重新翻译，也不扣点。"
        }
        return "用于之后新准备的翻译内容。已经准备好、正在翻译和已完成的内容仍用原译名。保存不会重新翻译，也不扣点。"
    }
    private var sourceContext: String {
        guard let source = studio.job(bookID)?.source, let range = source.range(of: term.source, options: .caseInsensitive) else { return "暂无可用的原文语境。" }
        let start = source.index(range.lowerBound, offsetBy: -80, limitedBy: source.startIndex) ?? source.startIndex
        let end = source.index(range.upperBound, offsetBy: 120, limitedBy: source.endIndex) ?? source.endIndex
        return String(source[start..<end])
    }
    private func save() {
        guard !saving else { return }
        guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "请输入译名。"; focused = true; return }
        saving = true; error = nil
        Task {
            do { try await studio.saveNameOverride(bookID: bookID, termID: term.id, target: target); saving = false; dismiss() }
            catch { self.error = error.localizedDescription; saving = false }
        }
    }
}
