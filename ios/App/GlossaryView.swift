import SwiftUI
import TranslationCore

struct TermEditor: View {
    @Binding var terms: [Term]
    var editable: Bool
    @State private var source = ""
    @State private var target = ""
    @State private var search = ""
    @State private var categoryFilter = ""
    @State private var newCategory = TermCategory.name
    @State private var newAliases = ""
    var body: some View {
        List {
            Section {
                Picker("分类", selection: $categoryFilter) {
                    Text("全部").tag("")
                    ForEach(TermCategory.allCases) { Text($0.title).tag($0.rawValue) }
                    Text("未分类").tag("unclassified")
                }.pickerStyle(.menu).tint(Ink.text)
            }
            if editable {
                Section("补充一个词") {
                    TextField("原词，例如 Elizabeth", text: $source).textInputAutocapitalization(.never)
                    TextField("固定译名，例如 伊丽莎白", text: $target)
                    Picker("类型", selection: $newCategory) { ForEach(TermCategory.allCases) { Text($0.title).tag($0) } }
                    TextField("别名，用逗号分隔", text: $newAliases).textInputAutocapitalization(.never)
                    Button("添加术语", action: addTerm).disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || terms.contains { $0.source.lowercased() == source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } || source.count > 200 || target.count > 200)
                }
            }
            Section("\(terms.count) 个术语") {
                ForEach(filteredTerms) { term in
                    termRow(term)
                }
            }
        }.searchable(text: $search, prompt: "搜索原词或译名").scrollContentBackground(.hidden).background(Ink.paper)
    }
    private var filteredTerms: [Term] {
        terms.filter { term in
            let category = categoryFilter.isEmpty || term.category?.rawValue == categoryFilter || (categoryFilter == "unclassified" && term.category == nil)
            let query = search.isEmpty || term.source.localizedCaseInsensitiveContains(search) || term.target.localizedCaseInsensitiveContains(search) || (term.aliases ?? []).contains { $0.localizedCaseInsensitiveContains(search) }
            return category && query
        }
    }
    private func termRow(_ term: Term) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(term.source).font(.system(size: 13))
                    HStack(spacing: 5) {
                        if let category = term.category { Text(category.title) }
                        if term.ambiguous == true { Text("按语境") }
                    }.font(.system(size: 10)).foregroundStyle(Ink.muted)
                    if term.ambiguous == true, let evidence = term.evidence { Text(evidence).font(.system(size: 10)).foregroundStyle(Ink.muted).lineLimit(2) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Ink.muted)
                if editable {
                    TextField("译名", text: Binding(get: { terms.first { $0.id == term.id }?.target ?? "" }, set: { value in
                        if let index = terms.firstIndex(where: { $0.id == term.id }) { terms[index].target = String(value.prefix(200)) }
                    })).font(.system(size: 14)).multilineTextAlignment(.trailing)
                } else { Text(term.target).font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .trailing) }
            }
            if editable {
                TextField("别名，用逗号分隔", text: Binding(get: { (terms.first { $0.id == term.id }?.aliases ?? []).joined(separator: ", ") }, set: { value in
                    if let index = terms.firstIndex(where: { $0.id == term.id }) {
                        terms[index].aliases = Self.aliases(value)
                        linkIdentity(index)
                    }
                })).font(.system(size: 11)).foregroundStyle(Ink.muted).textInputAutocapitalization(.never)
            } else if let aliases = term.aliases, !aliases.isEmpty {
                Text(aliases.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(Ink.muted)
            }
        }.contextMenu {
            if editable {
                ForEach(TermCategory.allCases) { category in
                    Button(category.title) { if let index = terms.firstIndex(where: { $0.id == term.id }) { terms[index].category = category } }
                }
            }
        }.swipeActions { if editable { Button("删除", role: .destructive) { terms.removeAll { $0.id == term.id } } } }
    }
    private static func aliases(_ text: String) -> [String] {
        var seen = Set<String>()
        return Array(text.components(separatedBy: CharacterSet(charactersIn: ",，")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 200 && seen.insert($0.lowercased()).inserted }.prefix(8))
    }
    private func addTerm() {
        let term = Term(source: source.trimmingCharacters(in: .whitespacesAndNewlines), target: target.trimmingCharacters(in: .whitespacesAndNewlines), category: newCategory, aliases: Self.aliases(newAliases))
        terms.append(term); linkIdentity(terms.count - 1)
        source = ""; target = ""; newAliases = ""
    }
    private func linkIdentity(_ index: Int) {
        let current = terms[index]
        let related = terms.indices.filter { other in
            other != index && ((terms[other].aliases ?? []).contains { $0.caseInsensitiveCompare(current.source) == .orderedSame } ||
                (current.aliases ?? []).contains { $0.caseInsensitiveCompare(terms[other].source) == .orderedSame })
        }
        let identity = related.first.flatMap { terms[$0].entityID } ?? current.entityID ?? UUID().uuidString
        terms[index].entityID = identity
        for other in related { terms[other].entityID = identity }
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
                    Text(job.status == .reviewing ? "AI 已整理本文术语。修改、校对后确认，译者与审校共同遵守。" : "AI 为本文整理的术语，供翻译与审校共同使用。") .font(.system(size: 12)).foregroundStyle(Ink.muted).padding(20)
                    TermEditor(terms: Binding(get: { studio.job(id)?.terms ?? [] }, set: { terms in studio.update(id) { $0.terms = terms } }), editable: job.status == .reviewing)
                    if job.status == .reviewing { Text("修改会自动保存；回到工作台点击「确认术语」继续。") .font(.system(size: 11)).foregroundStyle(Ink.muted).padding(15) }
                }.background(Ink.paper).navigationTitle("本文术语").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            }
        }
    }
}
