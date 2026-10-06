import SwiftUI
import TranslationCore

struct StylesView: View {
    @Environment(StudioStore.self) private var studio
    @State private var creating = false
    private var styles: [TranslationStyle] { TranslationStyle.presets + studio.customStyles }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PaperCard {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(styles) { style in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(style.name).font(.system(size: 17, weight: .medium))
                                Text(style.subtitle).font(.system(size: 12)).foregroundStyle(Ink.muted)
                                if studio.customStyles.contains(where: { $0.id == style.id }) {
                                    DisclosureGroup("风格要求") {
                                        Text(style.instruction).font(.system(size: 13)).lineSpacing(4).foregroundStyle(Ink.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                                    }.font(.system(size: 13)).tint(Ink.muted)
                                }
                            }.padding(.vertical, 13)
                            if style.id != styles.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                PrimaryButton(title: "自定义风格", icon: "plus") { creating = true }
            }.padding(20)
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
                Section("风格名称") { TextField("例如：科幻译法", text: $name); TextField("简短描述", text: $subtitle) }
                Section { TextEditor(text: $instruction).frame(minHeight: 180) } header: { Text("风格要求") } footer: { Text("描述语气、措辞和保留的元素。\(instruction.count) / 1500 字符。") }
            }.scrollContentBackground(.hidden).background(Ink.paper).navigationTitle("自定义风格").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("保存") { studio.customStyles.append(.init(name: name, subtitle: subtitle.isEmpty ? "我的翻译标准" : subtitle, instruction: instruction)); studio.persist(); dismiss() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || instruction.isEmpty || instruction.count > 1500 || name.count > 128 || subtitle.count > 256) } }
        }
    }
}
