import SwiftUI
import UniformTypeIdentifiers
import TranslationCore

struct GlossaryLibraryView: View {
    @Environment(StudioStore.self) private var studio
    @State private var importing = false
    @State private var shareURL: URL?
    var body: some View {
        @Bindable var studio = studio
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) { Eyebrow(text: "WORDS THAT STAY THE SAME"); Text("一个名字，\n始终如一。").font(.system(size: 30, design: .serif)); Text("在翻译设置中选择「我的术语库」，即可将这里的词表用于全部审校阶段。") .font(.system(size: 12)).foregroundStyle(Ink.muted).lineSpacing(4) }.padding(.horizontal, 24).padding(.top, 20)
            TermEditor(terms: Binding(get: { studio.libraryTerms }, set: { studio.libraryTerms = $0; studio.persist() }), editable: true)
            HStack(spacing: 20) {
                Button { importing = true } label: { Label("导入 JSON", systemImage: "square.and.arrow.down") }
                Button {
                    do { let data = try JSONEncoder().encode(studio.libraryTerms); shareURL = try DocumentIO.export(title: "glossary", text: String(decoding: data, as: UTF8.self), ext: "json") } catch { studio.message = error.localizedDescription }
                } label: { Label("导出", systemImage: "square.and.arrow.up") }
                if let shareURL { ShareLink(item: shareURL) { Image(systemName: "arrow.up.right") } }
            }.font(.system(size: 13)).padding(24)
        }.background(Ink.paper).navigationTitle("我的术语库").navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url); guard data.count < 2_000_000 else { throw TranslationError.message("术语文件过大。") }
                let terms = try JSONDecoder().decode([Term].self, from: data)
                guard terms.count <= 10000, terms.allSatisfy({ !$0.source.isEmpty && !$0.target.isEmpty && $0.source.count < 200 && $0.target.count < 200 }) else { throw TranslationError.message("术语格式无效；每项需包含 source 和 target。") }
                var seen = Set(studio.libraryTerms.map { $0.source.lowercased() })
                for term in terms where seen.insert(term.source.lowercased()).inserted { studio.libraryTerms.append(term) }; studio.persist()
            } catch { studio.message = error.localizedDescription }
        }
    }
}
struct TermEditor: View {
    @Binding var terms: [Term]
    var editable: Bool
    @State private var source = ""
    @State private var target = ""
    @State private var search = ""
    var body: some View {
        List {
            if editable {
                Section("补充一个词") {
                    TextField("原词，例如 Elizabeth", text: $source).textInputAutocapitalization(.never)
                    TextField("固定译名，例如 伊丽莎白", text: $target)
                    Button("添加术语") { terms.append(Term(source: source.trimmingCharacters(in: .whitespacesAndNewlines), target: target.trimmingCharacters(in: .whitespacesAndNewlines))); source = ""; target = "" }.disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || terms.contains { $0.source.lowercased() == source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } || source.count > 200 || target.count > 200)
                }
            }
            Section("\(terms.count) 个术语") {
                ForEach(terms.filter { search.isEmpty || $0.source.localizedCaseInsensitiveContains(search) || $0.target.localizedCaseInsensitiveContains(search) }) { term in
                    HStack {
                        Text(term.source).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Ink.muted)
                        if editable {
                            TextField("译名", text: Binding(get: { terms.first { $0.id == term.id }?.target ?? "" }, set: { value in if let index = terms.firstIndex(where: { $0.id == term.id }) { terms[index].target = String(value.prefix(200)) } })).font(.system(size: 14)).multilineTextAlignment(.trailing)
                        } else { Text(term.target).font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .trailing) }
                    }.swipeActions { if editable { Button("删除", role: .destructive) { terms.removeAll { $0.id == term.id } } } }
                }
            }
        }.searchable(text: $search, prompt: "搜索原词或译名").scrollContentBackground(.hidden).background(Ink.paper)
    }
}
struct JobGlossaryView: View {
    let id: String
    @Environment(StudioStore.self) private var studio
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            if let job = studio.job(id) {
                VStack(spacing: 0) {
                    Text(job.status == .reviewing ? "确认后再翻译。你修改的译名会在整个流程中优先使用。" : "本书所有阶段使用同一份术语表。") .font(.system(size: 12)).foregroundStyle(Ink.muted).padding(20)
                    TermEditor(terms: Binding(get: { studio.job(id)?.terms ?? [] }, set: { terms in studio.update(id) { $0.terms = terms } }), editable: job.status == .reviewing)
                    if job.status == .reviewing { Text("修改会自动保存；回到工作台点击「确认术语」继续。") .font(.system(size: 11)).foregroundStyle(Ink.muted).padding(15) }
                }.background(Ink.paper).navigationTitle("本书术语").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            }
        }
    }
}
