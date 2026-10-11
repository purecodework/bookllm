import SwiftUI

struct OnboardingView: View {
    var reviewing = false
    @Environment(StudioStore.self) private var studio
    @Environment(CloudAccount.self) private var account
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("onboardingCompleted") private var completed = false
    @State private var page = 0
    @State private var own = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("译间").font(PaperType.reading(20, relativeTo: .title3))
                Spacer()
                Text("\(page + 1) / 3").font(.caption).foregroundStyle(Ink.muted)
                    .accessibilityLabel("使用介绍，第 \(page + 1) 步，共 3 步")
                if reviewing { PaperIconButton(symbol: "xmark", label: "关闭使用介绍") { dismiss() } }
            }.padding(.horizontal, 24).padding(.vertical, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: page == 0 ? "book.closed" : page == 1 ? "slider.horizontal.3" : "key.horizontal")
                        .font(.system(size: 40, weight: .light)).foregroundStyle(Ink.accent).accessibilityHidden(true)
                    Text(page == 0 ? "先导入，再翻译。" : page == 1 ? "选择翻译质量" : reviewing ? "两种使用方式" : "选择使用方式")
                        .font(PaperType.reading(30, relativeTo: .largeTitle)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if page == 0 {
                        Text("从文件导入，或粘贴原文。导入后选择目标语言、质量和风格，再开始翻译。")
                            .font(.body).lineSpacing(5)
                        Text("支持 EPUB、PDF、DOCX、TXT 和 Markdown。扫描 PDF 在设备内识别，可先核对文字，不扣翻译点数。")
                            .font(.subheadline).foregroundStyle(Ink.muted).lineSpacing(5)
                    } else if page == 1 {
                        VStack(alignment: .leading, spacing: 0) {
                            intro("速读", "先了解内容，边译边读")
                            intro("精译", "初译后校对，适合日常阅读")
                            intro("深校", "增加语言专家，关注习语和口吻")
                            intro("精修", "并行审查，再由主编整合")
                        }
                        Text("这些角色由模型承担。审校越多，通常用量也越多；译名自动整理，需要时可在本书菜单中修改。")
                            .font(.subheadline).foregroundStyle(Ink.muted).lineSpacing(5)
                    } else {
                        mode(false, title: "按量付费", detail: account.isConfigured ? "购买翻译点数，按实际模型用量结算。" : "当前版本点数服务暂不可用，可先导入和整理文稿。")
                        mode(true, title: "买断自带 API", detail: "一次购买解锁，使用自己的模型服务地址与密钥。模型用量由服务商另行收费。")
                        Text(reviewing ? "这里仅介绍使用方式。需要切换时，请返回账户与设置。" : "选择不会立即购买或扣点，之后可在账户与设置中更改。")
                            .font(.caption).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: PaperLayout.formWidth, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 32).frame(maxWidth: .infinity)
            }.id(page)
            VStack(spacing: 8) {
                PrimaryButton(title: page == 2 ? reviewing ? "完成介绍" : "进入书库" : "继续") {
                    if page == 2 {
                        if !reviewing { studio.setOwnAPI(own); completed = true }
                        dismiss()
                    } else { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { page += 1 } }
                }
                if page > 0 { Button("上一步") { page -= 1 }.font(.subheadline).frame(maxWidth: .infinity, minHeight: 44) }
            }.frame(maxWidth: PaperLayout.formWidth).padding(.horizontal, 24).padding(.vertical, 12).frame(maxWidth: .infinity)
        }.background { PaperBackground(textured: false) }.foregroundStyle(Ink.text)
            .interactiveDismissDisabled(!reviewing).onAppear { own = studio.ownAPI }
    }
    private func intro(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline.weight(.regular))
            Text(detail).font(.subheadline).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
            PaperRule().padding(.top, 8)
        }.padding(.vertical, 12)
    }
    @ViewBuilder private func mode(_ value: Bool, title: String, detail: String) -> some View {
        if reviewing { modeLabel(value, title: title, detail: detail) }
        else {
            Button { own = value } label: { modeLabel(value, title: title, detail: detail) }
                .buttonStyle(PaperButtonStyle()).accessibilityAddTraits(own == value ? .isSelected : [])
        }
    }
    private func modeLabel(_ value: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: reviewing ? value ? "key.horizontal" : "circle.grid.2x2" : own == value ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(Ink.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline.weight(.regular))
                Text(detail).font(.subheadline).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.multilineTextAlignment(.leading).padding(.vertical, 18).padding(.horizontal, 16)
            .background(!reviewing && own == value ? Ink.surface : Ink.paper, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).stroke(!reviewing && own == value ? Ink.accent : Ink.line, lineWidth: 0.7) }
    }
}
