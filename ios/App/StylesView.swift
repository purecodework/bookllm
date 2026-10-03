import SwiftUI
import TranslationCore

struct StylesView: View {
    @Environment(StudioStore.self) private var studio
    @State private var creating = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Eyebrow(text: "FIND YOUR VOICE")
                Text("同一个故事，\n不同的回响。").font(.system(size: 32, weight: .regular, design: .serif)).lineSpacing(6)
                Text("选择翻译的气质，也可以写下你自己的标准。") .font(.system(size: 13)).foregroundStyle(Ink.muted)
                ForEach(Array((TranslationStyle.presets + studio.customStyles).enumerated()), id: \.element.id) { index, style in
                    PaperCard {
                        HStack(alignment: .top, spacing: 16) {
                            Text(String(format: "%02d", index + 1)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.orange).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 9) { Text(style.name).font(.system(size: 22, design: .serif)); Text(style.subtitle).font(.system(size: 12)).foregroundStyle(Ink.muted); Text(style.instruction).font(.system(size: 11)).lineSpacing(4).foregroundStyle(Ink.muted) }
                        }
                    }
                }
                PrimaryButton(title: "创建我的翻译风格", icon: "plus") { creating = true }
            }.padding(24)
        }.background(Ink.paper).navigationTitle("翻译风格").navigationBarTitleDisplayMode(.inline).sheet(isPresented: $creating) { CreateStyleView() }
    }
}
struct CreateStyleView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var subtitle = ""
    @State private var instruction = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("风格名称") { TextField("例如：我的科幻译法", text: $name); TextField("一句话描述", text: $subtitle) }
                Section { TextEditor(text: $instruction).frame(minHeight: 180) } header: { Text("给译者的要求") } footer: { Text("描述语气、节奏、措辞和应该保留的元素。比如：对白口语自然，叙述简洁，不添加原文没有的修饰。最多 1500 字符。") }
            }.scrollContentBackground(.hidden).background(Ink.paper).navigationTitle("自定义风格").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("保存") { studio.customStyles.append(.init(name: name, subtitle: subtitle.isEmpty ? "我的翻译标准" : subtitle, instruction: instruction)); studio.persist(); dismiss() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || instruction.isEmpty || instruction.count > 1500 || name.count > 128 || subtitle.count > 256) } }
        }
    }
}
