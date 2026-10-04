import SwiftUI
import AuthenticationServices
import TranslationCore

struct SettingsView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(CloudAccount.self) private var account
    @Environment(PurchaseStore.self) private var purchases
    @State private var key = Vault.read("apiKey")
    @State private var wallet = false
    @State private var introduction = false
    @State private var saved = false
    var body: some View {
        @Bindable var studio = studio
        Form {
            Section("使用方式") {
                Picker("使用方式", selection: $studio.ownAPI) { Text("按量付费").tag(false); Text("买断自带 API").tag(true) }.pickerStyle(.segmented)
                    .onChange(of: studio.ownAPI) { _, value in UserDefaults.standard.set(value, forKey: "ownAPI") }
                if studio.ownAPI {
                    Label(purchases.localOwnAPIUnlocked || account.ownAPIUnlocked ? "已永久解锁" : "尚未解锁", systemImage: "key.horizontal")
                    if !purchases.localOwnAPIUnlocked && !account.ownAPIUnlocked { Button("买断解锁") { wallet = true } }
                } else {
                    HStack { Text("翻译点数"); Spacer(); Text(account.isLoggedIn ? "\(account.points) 点" : "登录后查看").foregroundStyle(Ink.muted) }
                    Button("购买点数") { wallet = true }
                    Text("默认 DeepSeek，按实际模型用量结算。").font(.system(size: 12)).foregroundStyle(Ink.muted)
                }
            }
            if studio.ownAPI {
                Section {
                    TextField("HTTPS Base URL", text: $studio.endpoint).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("模型名称", text: $studio.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("API Key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(saved ? "已保存 ✓" : "保存") { do { try studio.saveConnection(key: key); saved = true } catch { studio.message = error.localizedDescription } }
                } header: { Text("自己的 API") } footer: { Text("默认 DeepSeek，可用 OpenAI 兼容接口。密钥保存在本机钥匙串，用量由服务商计费。") }
            }
            Section("默认偏好") {
                NavigationLink("语言、编者注与审校") { PreferencesForm(preferences: Binding(get: { studio.defaultPreferences }, set: { studio.defaultPreferences = $0; studio.persist() })).navigationTitle("默认偏好") }
            }
            Section("账户") {
                if account.isLoggedIn {
                    Label("已通过 Apple 登录", systemImage: "checkmark.circle").foregroundStyle(Ink.green)
                    Button("刷新账户") { Task { do { try await account.refresh() } catch { studio.message = error.localizedDescription } } }
                    Button("退出登录", role: .destructive) { do { try Vault.save("", name: "session"); account.session = ""; account.accountID = nil; account.points = 0 } catch { studio.message = error.localizedDescription } }
                } else { AppleLoginView() }
                Button("恢复购买") { Task { await purchases.restore(account: account) } }
            }
            Section {
                Button("使用介绍") { introduction = true }
                Text("导入与导出：EPUB、PDF、DOCX、TXT、Markdown。保留封面和正文结构；扫描 PDF 需先 OCR，复杂页面版式可能变化。").font(.system(size: 12)).foregroundStyle(Ink.muted)
            }
        }.scrollContentBackground(.hidden).background(Ink.paper).navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $wallet) { WalletView() }.sheet(isPresented: $introduction) { OnboardingView() }
    }
}
struct AppleLoginView: View {
    @Environment(CloudAccount.self) private var account
    @Environment(StudioStore.self) private var studio
    @State private var nonce = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            if !account.isConfigured { Text("云端服务尚未配置。").font(.system(size: 12)).foregroundStyle(Ink.muted) }
        }
    }
}
struct WalletView: View {
    @Environment(StudioStore.self) private var studio
    @Environment(CloudAccount.self) private var account
    @Environment(PurchaseStore.self) private var purchases
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        @Bindable var purchases = purchases
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !studio.ownAPI {
                        PaperCard { HStack { Text("翻译点数").font(.system(size: 14)); Spacer(); Text(account.isLoggedIn ? "\(account.points.formatted())" : "登录后查看").font(.system(size: 24, design: .serif)) } }
                        if !account.isLoggedIn { AppleLoginView() }
                    }
                    ForEach(purchases.products.filter { studio.ownAPI ? $0.id == PurchaseStore.ids[2] : $0.id != PurchaseStore.ids[2] }) { product in
                        let byok = product.id == PurchaseStore.ids[2]
                        PaperCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(byok ? "自带 API · 永久解锁" : product.displayName).font(.system(size: 20, design: .serif))
                                Text(byok ? "一次购买。自己的接口、密钥和模型，所有翻译档位与导出功能可用。" : product.description).font(.system(size: 13)).foregroundStyle(Ink.muted).lineSpacing(4)
                                Button { Task { await purchases.buy(product, account: account) } } label: {
                                    HStack { Text(byok && purchases.localOwnAPIUnlocked ? "已解锁" : product.displayPrice); Spacer(); Image(systemName: "arrow.right") }.font(.system(size: 14, weight: .semibold)).padding(15).foregroundStyle(.white).background(Ink.text, in: Capsule())
                                }.disabled(purchases.busy || (byok && purchases.localOwnAPIUnlocked) || (!byok && !account.isLoggedIn))
                            }
                        }
                    }
                    if purchases.products.isEmpty { Text("商品暂不可用。").font(.system(size: 13)).foregroundStyle(Ink.muted) }
                    Text(studio.ownAPI ? "API 用量由服务商计费。" : "每 \(account.tokensPerPoint.formatted()) 个实际输入与输出 token 合计 1 点，每轮不足 1 点按 1 点计。先预留，完成后结算并退回差额。术语提取与补全按实际调用计费。").font(.system(size: 12)).foregroundStyle(Ink.muted).lineSpacing(5)
                    Button("恢复购买") { Task { await purchases.restore(account: account) } }.font(.system(size: 13)).frame(maxWidth: .infinity)
                }.padding(24)
            }.background(Ink.paper).navigationTitle(studio.ownAPI ? "买断解锁" : "购买点数").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .task { await purchases.load(); if account.isLoggedIn { try? await account.refresh() } }
                .alert("购买状态", isPresented: Binding(get: { purchases.message != nil }, set: { if !$0 { purchases.message = nil } })) { Button("知道了") { purchases.message = nil } } message: { Text(purchases.message ?? "") }
        }
    }
}
