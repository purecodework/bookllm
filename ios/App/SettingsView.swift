import SwiftUI
import AuthenticationServices
import StoreKit
import TranslationCore

enum SettingsSection: String { case usage, api }

private struct APIConnectionDraft: Equatable {
    var endpoint = ""
    var model = ""
    var key = ""
    var contextWindow = "32768"
    var maximumOutput = "8192"
}

struct SettingsView: View {
    var initialSection = SettingsSection.usage
    @Environment(StudioStore.self) private var studio
    @Environment(CloudAccount.self) private var account
    @Environment(PurchaseStore.self) private var purchases
    @State private var connection = APIConnectionDraft()
    @State private var connectionLoaded = false
    @State private var connectionError: String?
    @State private var wallet = false
    @State private var introduction = false
    @State private var saved = false
    @State private var work = false
    @FocusState private var editingAPI: Bool
    var body: some View {
        @Bindable var studio = studio
        ScrollViewReader { proxy in
            Form {
            Section {
                Picker("使用方式", selection: $studio.ownAPI) { Text("按量付费").tag(false); Text("买断自带 API").tag(true) }.pickerStyle(.segmented)
                    .onChange(of: studio.ownAPI) { _, value in studio.setOwnAPI(value) }
            } header: { Text("使用方式") } footer: {
                Text("此选择用于新开始的翻译。已开始的任务保留原来的使用方式。")
            }.listRowBackground(Ink.paper).id(SettingsSection.usage)
            Section {
                if studio.ownAPI {
                    Label(purchases.localOwnAPIUnlocked || account.ownAPIUnlocked ? "已永久解锁" : "尚未解锁", systemImage: "key.horizontal")
                    if !purchases.localOwnAPIUnlocked && !account.ownAPIUnlocked { Button("买断解锁") { wallet = true } }
                    Text("一次购买永久解锁自带 API，所有翻译档位与导出可用。模型用量由 API 服务商另行收费。")
                        .font(.caption).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack { Text("翻译点数"); Spacer(); Text(account.isLoggedIn ? "\(account.points) 点" : "登录后查看").foregroundStyle(Ink.muted) }
                    Button("购买点数") { wallet = true }.disabled(!account.isConfigured)
                    Text(account.isConfigured ? "默认 DeepSeek，按实际模型用量结算。" : "当前版本暂未连接点数翻译服务，暂不能购买点数或开始点数翻译。")
                        .font(.caption).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
                }
            } header: { Text("购买与余额").foregroundStyle(Ink.muted) }
                .listRowBackground(Ink.paper)
            if studio.ownAPI || initialSection == .api {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("API 服务地址").font(.caption).foregroundStyle(Ink.muted)
                        TextField("https://api.deepseek.com/v1", text: $connection.endpoint)
                            .focused($editingAPI)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .accessibilityLabel("API 服务地址").accessibilityIdentifier("api-endpoint")
                    }.padding(.vertical, 3).id(SettingsSection.api)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("模型名称").font(.caption).foregroundStyle(Ink.muted)
                        TextField("deepseek-flash", text: $connection.model)
                            .focused($editingAPI)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityLabel("模型名称").accessibilityIdentifier("api-model")
                    }.padding(.vertical, 3)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("模型上下文窗口（tokens）").font(.caption).foregroundStyle(Ink.muted)
                        TextField("32768", text: $connection.contextWindow)
                            .frame(minHeight: 44)
                            .focused($editingAPI)
                            .keyboardType(.numberPad).accessibilityLabel("模型上下文窗口，tokens")
                            .accessibilityIdentifier("api-context-window")
                    }.padding(.vertical, 3)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("模型最大输出（tokens）").font(.caption).foregroundStyle(Ink.muted)
                        TextField("8192", text: $connection.maximumOutput)
                            .frame(minHeight: 44)
                            .focused($editingAPI)
                            .keyboardType(.numberPad).accessibilityLabel("模型最大输出，tokens")
                            .accessibilityIdentifier("api-maximum-output")
                        Text("按服务商的模型说明填写。窗口包含输入与输出；背景会自动收缩，原文与译稿完整保留。默认值是预设预算，无法自动确认模型容量。")
                            .font(.caption).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 3)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("服务商密钥（API Key）").font(.caption).foregroundStyle(Ink.muted)
                        SecureField("输入服务商提供的密钥", text: $connection.key)
                            .focused($editingAPI)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityLabel("服务商密钥，API Key").accessibilityIdentifier("api-key")
                    }.padding(.vertical, 3)
                    if let connectionError {
                        Text(connectionError).font(.caption).foregroundStyle(Ink.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(saved ? "已保存 ✓" : "保存 API 设置") {
                        do {
                            guard let window = Int(connection.contextWindow), let output = Int(connection.maximumOutput) else {
                                throw TranslationError.message("请以整数填写模型窗口与最大输出 tokens。")
                            }
                            try studio.saveConnection(endpoint: connection.endpoint, model: connection.model, key: connection.key,
                                limits: .init(contextWindowTokens: window, maximumOutputTokens: output))
                            connectionError = nil; saved = true
                        } catch { connectionError = error.localizedDescription; saved = false }
                    }.accessibilityIdentifier("save-api-connection")
                } header: { Text("自己的 API").foregroundStyle(Ink.muted) } footer: {
                    Text("默认 DeepSeek，可使用 OpenAI 兼容的 HTTPS 接口。密钥保存在本机钥匙串；保存不会调用模型或产生用量。用量由服务商计费。")
                }.listRowBackground(Ink.paper)
            }
            Section {
                NavigationLink("翻译风格与自定义风格") { StylesView() }
                NavigationLink("语言与编者注") { PreferencesForm(preferences: Binding(get: { studio.defaultPreferences }, set: { studio.defaultPreferences = $0; studio.persist() })).navigationTitle("默认偏好") }
            } header: { Text("默认偏好") } footer: {
                Text("用于之后导入的文稿。已入库文稿请在本书的翻译设置中调整。")
            }.listRowBackground(Ink.paper)
            Section {
                Button("通过链接或作品编号打开译作") { work = true }
                if account.isLoggedIn {
                    Label("已通过 Apple 登录", systemImage: "checkmark.circle").foregroundStyle(Ink.green)
                    Button("刷新账户") { Task { do { try await account.refresh() } catch { studio.message = error.localizedDescription } } }
                    Button("退出登录", role: .destructive) { do { try Vault.save("", name: "session"); account.session = ""; account.accountID = nil; account.points = 0 } catch { studio.message = error.localizedDescription } }
                } else { AppleLoginView() }
                Button(purchases.isRestoring ? "正在恢复…" : "恢复购买") { Task { await purchases.restore(account: account) } }
                    .disabled(purchases.busy)
            } header: { Text("账户").foregroundStyle(Ink.muted) }
                .listRowBackground(Ink.paper)
            Section {
                Button("使用介绍") { introduction = true }
                Text("导入与导出：EPUB、PDF、DOCX、TXT、Markdown。保留封面和正文结构；扫描 PDF 在本机识别文字，可先核对原稿；复杂页面版式可能变化。").font(.caption).foregroundStyle(Ink.muted)
            }.listRowBackground(Ink.paper)
            }.scrollContentBackground(.hidden).frame(maxWidth: PaperLayout.formWidth).frame(maxWidth: .infinity)
                .background(Ink.paper).navigationTitle("账户与设置").navigationBarTitleDisplayMode(.inline)
                .task {
                    if !connectionLoaded {
                        connection = .init(endpoint: studio.endpoint, model: studio.model, key: Vault.read("apiKey"),
                            contextWindow: String(studio.apiContextWindowTokens), maximumOutput: String(studio.apiMaximumOutputTokens))
                        connectionLoaded = true
                        await Task.yield()
                        if initialSection == .api { proxy.scrollTo(SettingsSection.api, anchor: .top) }
                    }
                }
                .onChange(of: connection) { _, _ in saved = false; connectionError = nil }
        }
            .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { editingAPI = false } } }
            .sheet(isPresented: $work) { WorkLookupView() }.sheet(isPresented: $wallet) { WalletView() }.sheet(isPresented: $introduction) { OnboardingView(reviewing: true).modifier(PaperUITestLayout()) }
            .alert("购买状态", isPresented: Binding(get: { !wallet && purchases.message != nil }, set: { if !$0 { purchases.message = nil } })) {
                Button("知道了") { purchases.message = nil }
            } message: { Text(purchases.message ?? "") }
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
            if !account.isConfigured { Text("当前版本暂未连接账户与点数翻译服务。").font(.caption).foregroundStyle(Ink.muted) }
        }
    }
}
struct WalletView: View {
    var ownOverride: Bool? = nil
    @Environment(StudioStore.self) private var studio
    @Environment(CloudAccount.self) private var account
    @Environment(PurchaseStore.self) private var purchases
    @Environment(\.dismiss) private var dismiss
    private var own: Bool { ownOverride ?? studio.ownAPI }
    private var unlocked: Bool { purchases.localOwnAPIUnlocked || account.ownAPIUnlocked }
    private var availableProducts: [Product] {
        purchases.products.filter { own ? $0.id == PurchaseStore.ids[2] : $0.id != PurchaseStore.ids[2] }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if own {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("自己的 API · 永久解锁").font(PaperType.reading(22, relativeTo: .title2))
                            Text("一次购买，永久使用自己的接口、密钥和模型。所有翻译档位与导出功能可用。")
                                .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                            Text("买断费用不包含模型用量。API 用量由服务商另行收费，使用前需配置自己的 API。")
                                .font(.caption).foregroundStyle(Ink.muted).lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                            if unlocked { Label("已永久解锁", systemImage: "checkmark.circle").foregroundStyle(Ink.accent) }
                        }
                        PaperRule()
                    } else {
                        PaperCard { HStack { Text("翻译点数").font(.system(size: 14)); Spacer(); Text(account.isLoggedIn ? "\(account.points.formatted())" : "登录后查看").font(.system(size: 24, design: .serif)) } }
                        if !account.isConfigured {
                            Text("当前版本暂未连接点数翻译服务，暂不能购买点数或开始点数翻译。已完成内容仍可阅读与导出。")
                                .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        } else if !account.isLoggedIn { AppleLoginView() }
                    }
                    if (own && !unlocked) || (!own && account.isConfigured) {
                        ForEach(availableProducts) { product in
                            let byok = product.id == PurchaseStore.ids[2]
                            PaperCard {
                                VStack(alignment: .leading, spacing: 14) {
                                    Text(byok ? "买断自带 API" : product.displayName).font(PaperType.reading(20))
                                    if !byok { Text(product.description).font(.subheadline).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true) }
                                    Button { Task { await purchases.buy(product, account: account) } } label: {
                                        HStack { Text(byok ? "永久解锁 · \(product.displayPrice)" : product.displayPrice); Spacer(); Image(systemName: "arrow.right") }
                                            .font(.subheadline.weight(.semibold)).padding(15)
                                            .foregroundStyle(.white).background(Ink.accent, in: RoundedRectangle(cornerRadius: 7))
                                    }.disabled(purchases.busy || (!byok && (!account.isLoggedIn || !account.isConfigured)))
                                }
                            }
                        }
                        catalogStatus
                    }
                    if !own {
                        Text("每 \(account.tokensPerPoint.formatted()) 个实际输入与输出 token 合计 1 点，每轮不足 1 点按 1 点计。先预留，完成后结算并退回差额。术语提取与补全按实际调用计费。")
                            .font(.caption).foregroundStyle(Ink.muted).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                    }
                    Button(purchases.isRestoring ? "正在恢复…" : "恢复购买") { Task { await purchases.restore(account: account) } }
                        .font(.subheadline).frame(maxWidth: .infinity).frame(minHeight: 44).disabled(purchases.busy)
                    if own && account.isConfigured {
                        Button("改用点数翻译") {
                            studio.setOwnAPI(false); dismiss()
                        }.font(.subheadline).frame(maxWidth: .infinity).frame(minHeight: 44).disabled(purchases.busy)
                        Text("点数翻译需要 Apple 登录，按实际用量结算。切换不会更改已开始任务的方式。")
                            .font(.caption).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(24).frame(maxWidth: PaperLayout.formWidth).frame(maxWidth: .infinity)
            }.background(Ink.paper).navigationTitle(own ? "买断解锁" : "购买点数").navigationBarTitleDisplayMode(.inline)
                .toolbar { PaperToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .task { await purchases.load(); if account.isLoggedIn { try? await account.refresh() } }
                .alert("购买状态", isPresented: Binding(get: { purchases.message != nil }, set: { if !$0 { purchases.message = nil } })) { Button("知道了") { purchases.message = nil } } message: { Text(purchases.message ?? "") }
        }
    }

    @ViewBuilder private var catalogStatus: some View {
        switch purchases.catalogState {
        case .idle, .loading:
            ProgressView("正在加载商品…").font(.subheadline).frame(maxWidth: .infinity).frame(minHeight: 44)
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 12) {
                Text(availableProducts.isEmpty ? "商品加载失败" : "商品刷新失败，仍可查看上次获取的商品")
                    .font(.subheadline)
                Text(reason).font(.caption).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
                Button("重新加载商品") { Task { await purchases.load() } }.frame(minHeight: 44).disabled(purchases.busy)
            }
        case .loaded:
            if availableProducts.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(own ? "暂未获取到自带 API 解锁商品" : "暂未获取到点数商品").font(.subheadline)
                    Text("可以重新加载，或稍后再试。已有购买可通过「恢复购买」找回。")
                        .font(.caption).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
                    Button("重新加载商品") { Task { await purchases.load() } }.frame(minHeight: 44).disabled(purchases.busy)
                }
            }
        }
    }
}
