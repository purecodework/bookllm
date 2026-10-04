import SwiftUI
import TranslationCore

struct RepairDraftView: View {
    let id: String
    @Environment(StudioStore.self) private var studio
    @Environment(CloudAccount.self) private var account
    @Environment(PurchaseStore.self) private var purchases
    @Environment(\.dismiss) private var dismiss
    @State private var source = false
    var body: some View {
        NavigationStack {
            if let job = studio.job(id), let draft = job.reviewDraft {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(draft.issues.joined(separator: "\n")).font(.system(size: 13)).foregroundStyle(Ink.orange)
                        Picker("待校内容", selection: $source) { Text("待校译文").tag(false); Text("原文").tag(true) }.pickerStyle(.segmented)
                        Text(source ? draft.original.source : EditorNotes.display(draft.output)).font(.system(size: 17, design: .serif)).lineSpacing(7).textSelection(.enabled)
                        Divider()
                        Text(job.usesOwnAPI ? "补全会调用你的 API，由服务商计费。" : "补全会发起一轮处理，按实际用量扣点。暂停后可继续，同一轮不会重复扣点。").font(.system(size: 12)).foregroundStyle(Ink.muted)
                        PrimaryButton(title: draft.prepared == nil ? "补全并继续" : "继续这一轮补全", icon: "checkmark") { studio.repair(id, account: account, purchases: purchases); dismiss() }.disabled(studio.task != nil)
                    }.padding(24)
                }.background(Ink.paper).navigationTitle("完整性核对").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            }
        }
    }
}
