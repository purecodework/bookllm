import SwiftUI

struct OnboardingView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(\.dismiss) private var dismiss
    @AppStorage("onboardingCompleted") private var completed = false
    @State private var page = 0
    @State private var own = false
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack { Text("译间").font(.system(size: 20, weight: .medium, design: .serif)); Spacer(); Text("\(page + 1) / 3").font(.caption).foregroundStyle(Ink.muted) }
            Spacer()
            Image(systemName: page == 0 ? "book.closed" : page == 1 ? "slider.horizontal.3" : "key.horizontal").font(.system(size: 44, weight: .light)).foregroundStyle(Ink.orange)
            Text(page == 0 ? "导入，开始读。" : page == 1 ? "选一种翻译强度。" : "选一种使用方式。").font(.system(size: 30, weight: .medium, design: .serif))
            if page == 0 {
                Text("EPUB、PDF、DOCX、TXT、Markdown。\n自动识别语言与文稿类型，保留已有封面。").font(.system(size: 15)).foregroundStyle(Ink.muted).lineSpacing(7)
            } else if page == 1 {
                VStack(alignment: .leading, spacing: 16) {
                    intro("快速", "一边翻译，一边阅读")
                    intro("精译", "译者与校对，逐章阅读")
                    intro("出版", "加入语言专家与主编，逐章定稿")
                }
                Text("文风、术语和首次编者注都可以调整。").font(.system(size: 13)).foregroundStyle(Ink.muted)
            } else {
                mode(false, title: "按量付费", detail: "购买点数，默认 DeepSeek；按实际用量结算。")
                mode(true, title: "买断自带 API", detail: "一次解锁，用自己的接口与密钥；由服务商计费。")
            }
            Spacer()
            PrimaryButton(title: page == 2 ? "进入书架" : "继续", icon: "arrow.right") {
                if page == 2 { studio.ownAPI = own; UserDefaults.standard.set(own, forKey: "ownAPI"); completed = true; dismiss() }
                else { withAnimation(.easeInOut(duration: 0.2)) { page += 1 } }
            }
            if page > 0 { Button("上一步") { page -= 1 }.font(.system(size: 13)).frame(maxWidth: .infinity) }
        }.padding(28).background(Ink.paper).interactiveDismissDisabled().onAppear { own = studio.ownAPI }
    }
    private func intro(_ title: String, _ detail: String) -> some View {
        HStack { Text(title).font(.system(size: 15, weight: .medium)).frame(width: 42, alignment: .leading); Text(detail).font(.system(size: 14)).foregroundStyle(Ink.muted) }
    }
    private func mode(_ value: Bool, title: String, detail: String) -> some View {
        Button { own = value } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: own == value ? "checkmark.circle.fill" : "circle").foregroundStyle(own == value ? Ink.orange : Ink.muted)
                VStack(alignment: .leading, spacing: 8) { Text(title).font(.system(size: 16, weight: .medium)).foregroundStyle(Ink.text); Text(detail).font(.system(size: 13)).foregroundStyle(Ink.muted).multilineTextAlignment(.leading) }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 18)).overlay { RoundedRectangle(cornerRadius: 18).stroke(own == value ? Ink.orange : Ink.line) }
        }.buttonStyle(.plain)
    }
}
