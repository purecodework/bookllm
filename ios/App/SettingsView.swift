import SwiftUI
import AuthenticationServices
import TranslationCore

struct SettingsView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(CloudAccount.self) private var account
    @Environment(PurchaseStore.self) private var purchases
    @State private var key = Vault.read("apiKey")
    @State private var wallet = false
    @State private var nonce = ""
    @State private var saved = false
    var body: some View {
        @Bindable var studio = studio
        Form {
            Section {
                HStack { Image(systemName: "asterisk").font(.system(size: 30)).foregroundStyle(Ink.orange); VStack(alignment: .leading, spacing: 5) { Text("译间").font(.system(size: 25, design: .serif)); Text("把世界的文字，读成自己的语言。") .font(.system(size: 11)).foregroundStyle(Ink.muted) }.padding(.leading, 8) }.padding(.vertical, 12)
            }
            Section("翻译方式") {
                Toggle("使用自己的 API", isOn: $studio.ownAPI).onChange(of: studio.ownAPI) { _, value in UserDefaults.standard.set(value, forKey: "ownAPI") }
                if studio.ownAPI {
                    Text(purchases.localOwnAPIUnlocked || account.ownAPIUnlocked ? "自带 API 已永久解锁" : "买断后可永久使用自己的 API；用量由 API 服务商计费。") .font(.system(size: 12)).foregroundStyle(Ink.muted)
                } else { HStack { Text("翻译点数"); Spacer(); Text(account.isLoggedIn ? "\(account.points) 点" : "登录后查看").foregroundStyle(Ink.muted) } }
                Button("购买点数 / 买断解锁") { wallet = true }
            }
            Section { TextField("HTTPS Base URL", text: $studio.endpoint).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL); TextField("模型名称", text: $studio.model).textInputAutocapitalization(.never).autocorrectionDisabled(); SecureField("API Key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled(); Button(saved ? "已安全保存 ✓" : "保存 API 设置") { do { try studio.saveConnection(key: key); saved = true } catch { studio.message = error.localizedDescription } } } header: { Text("自己的 API · 默认 DeepSeek") } footer: { Text("密钥只保存在本机钥匙串，不发送到译间服务器。兼容 OpenAI 格式的 HTTPS 接口。自动分块与并发，无需手动调整。") }
            Section("默认翻译偏好") {
                NavigationLink("外语片段、编者注与语言审校") { PreferencesForm(preferences: Binding(get: { studio.defaultPreferences }, set: { studio.defaultPreferences = $0; studio.persist() })).navigationTitle("默认偏好") }
                Text("应用于新导入的作品；每份作品都能单独调整。") .font(.system(size: 11)).foregroundStyle(Ink.muted)
            }
            Section("账户") {
                if account.isLoggedIn {
                    Label("已通过 Apple 登录", systemImage: "checkmark.circle").foregroundStyle(Ink.green)
                    Button("刷新点数") { Task { do { try await account.refresh() } catch { studio.message = error.localizedDescription } } }
                    Button("退出登录", role: .destructive) { do { try Vault.save("", name: "session"); account.session = ""; account.accountID = nil; account.points = 0 } catch { studio.message = error.localizedDescription } }
                } else {
                    SignInWithAppleButton(.signIn) { request in
                        nonce = Vault.nonce(); request.nonce = Vault.hash(nonce); request.requestedScopes = []
                    } onCompletion: { result in
                        Task {
                            do {
                                let auth = try result.get()
                                guard let credential = auth.credential as? ASAuthorizationAppleIDCredential, let token = credential.identityToken, let string = String(data: token, encoding: .utf8) else { throw TranslationError.message("未取得 Apple 登录凭据。") }
                                try await account.login(identityToken: string, nonce: nonce)
                            } catch { studio.message = error.localizedDescription }
                        }
                    }.signInWithAppleButtonStyle(.black).frame(height: 44).disabled(!account.isConfigured)
                    if !account.isConfigured { Text("云端地址尚未配置，开发者需在工程中设置 CLOUD_BASE_URL。") .font(.system(size: 11)).foregroundStyle(Ink.muted) }
                }
                Button("恢复购买") { Task { await purchases.restore(account: account) } }
            }
            Section { Text("导入 EPUB、文本型 PDF、TXT、DOCX 和 Markdown；译本支持 TXT、Markdown、PDF 与双语分享。扫描 PDF 需先 OCR，原文件版式不会完整保留。") .font(.system(size: 11)).foregroundStyle(Ink.muted).lineSpacing(4) } header: { Text("文档支持") }
        }.scrollContentBackground(.hidden).background(Ink.paper).navigationTitle("我的译间").navigationBarTitleDisplayMode(.inline).sheet(isPresented: $wallet) { WalletView() }
    }
}
struct WalletView: View {
    @Environment(CloudAccount.self) private var account
    @Environment(PurchaseStore.self) private var purchases
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        @Bindable var purchases = purchases
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    Eyebrow(text: "YOUR WORDS, YOUR WAY")
                    Text("按需翻译，\n或者一次拥有。").font(.system(size: 31, design: .serif)).lineSpacing(5)
                    Text("使用点数，开箱即译。自带 API 买断后，直接使用自己的服务商账户。") .font(.system(size: 13)).foregroundStyle(Ink.muted).lineSpacing(5)
                    PaperCard { HStack { VStack(alignment: .leading, spacing: 8) { Text("翻译点数").font(.system(size: 13)).foregroundStyle(Ink.muted); Text(account.isLoggedIn ? "\(account.points.formatted())" : "登录后查看").font(.system(size: account.isLoggedIn ? 36 : 23, design: .serif)) }; Spacer(); Image(systemName: "sparkle").font(.system(size: 33)).foregroundStyle(Ink.orange) } }
                    ForEach(purchases.products) { product in
                        let byok = product.id == PurchaseStore.ids[2]
                        PaperCard {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack { Text(byok ? "自带 API · 永久解锁" : product.displayName).font(.system(size: 20, design: .serif)); Spacer(); if byok { Image(systemName: "key.horizontal").foregroundStyle(Ink.orange) } }
                                Text(byok ? "一次购买，永久使用自己的 DeepSeek 或其他兼容 API。所有风格、质量档位、术语与导出功能均可使用。" : product.description).font(.system(size: 12)).foregroundStyle(Ink.muted).lineSpacing(4)
                                Button { Task { await purchases.buy(product, account: account) } } label: { HStack { Text(byok && purchases.localOwnAPIUnlocked ? "已解锁" : product.displayPrice); Spacer(); Image(systemName: "arrow.right") }.font(.system(size: 14, weight: .semibold)).padding(15).foregroundStyle(.white).background(Ink.text, in: RoundedRectangle(cornerRadius: 13)) }.disabled(purchases.busy || (byok && purchases.localOwnAPIUnlocked) || (!byok && !account.isLoggedIn))
                            }
                        }
                    }
                    if purchases.products.isEmpty { Text("商品暂不可用。开发测试需选用 BookLLM.storekit；正式销售需在 App Store Connect 创建商品。") .font(.system(size: 12)).foregroundStyle(Ink.muted).padding(18).background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 15)) }
                    Text("点数规则：每个分块每轮处理按原文每 1000 字符 1 点，不足按 1 点计；术语提取单独计点。额外审校按实际轮数增加。自带 API 模式不扣译间点数。") .font(.system(size: 11)).foregroundStyle(Ink.muted).lineSpacing(5)
                    Button("恢复已有购买") { Task { await purchases.restore(account: account) } }.font(.system(size: 13)).frame(maxWidth: .infinity)
                }.padding(24)
            }.background(Ink.paper).navigationTitle("点数与解锁").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .task { await purchases.load() }
                .alert("购买状态", isPresented: Binding(get: { purchases.message != nil }, set: { if !$0 { purchases.message = nil } })) { Button("知道了") { purchases.message = nil } } message: { Text(purchases.message ?? "") }
        }
    }
}
