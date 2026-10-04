import SwiftUI
import TranslationCore
import UIKit

struct WorkMetadata: Decodable, Sendable {
    var id: String; var title: String; var targetLanguage: String; var styleName: String; var price: Int
    var isOwner: Bool; var purchased: Bool
}
struct WorkContent: Decodable, Sendable {
    var id: String; var title: String; var text: String; var targetLanguage: String; var coverBase64: String?
}
private struct WorkPurchase: Decodable { var work: WorkMetadata; var charged: Int }
enum WorkLink {
    static func identifier(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: text) { return id.uuidString.lowercased() }
        if let url = URL(string: text), let last = url.pathComponents.last, let id = UUID(uuidString: last),
           (url.scheme == "bookllm" && url.host == "work") || (url.scheme == "https" && url.pathComponents.contains("w")) { return id.uuidString.lowercased() }
        return nil
    }
    @MainActor static func share(_ id: String, account: CloudAccount) -> URL? {
        guard let base = account.baseURL, var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = "/w/" + id; parts.query = nil; parts.fragment = nil; return parts.url
    }
}
struct WorkLookupView: View {
    @State private var input = ""
    @State private var selected: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                TextField("粘贴译作链接或 ID", text: $input).textInputAutocapitalization(.never).autocorrectionDisabled().padding(16).background(.white, in: RoundedRectangle(cornerRadius: 14))
                PrimaryButton(title: "打开译作", icon: "book") { selected = WorkLink.identifier(input) }.disabled(WorkLink.identifier(input) == nil)
                Spacer()
            }.padding(24).background(Ink.paper).navigationTitle("打开译作").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .navigationDestination(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) { if let selected { WorkPurchaseView(workID: selected) } }
        }
    }
}
struct WorkPurchaseView: View {
    let workID: String
    @Environment(StudioStore.self) private var studio
    @Environment(CloudAccount.self) private var account
    @State private var work: WorkMetadata?
    @State private var error: String?
    @State private var busy = false
    @State private var wallet = false
    @State private var reader: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let work {
                    Text(work.title).font(.system(size: 27, weight: .medium, design: .serif))
                    Text("\(work.targetLanguage) · \(work.styleName)").font(.system(size: 13)).foregroundStyle(Ink.muted)
                    if studio.ownAPI && !work.purchased && !work.isOwner {
                        Text("译作购买使用点数账户。").font(.system(size: 13)).foregroundStyle(Ink.muted)
                        Button("切换到按量付费") { studio.ownAPI = false; UserDefaults.standard.set(false, forKey: "ownAPI") }
                    } else {
                        if !work.purchased && !work.isOwner { Text("\(work.price) 点").font(.system(size: 25, design: .serif)); Text("余额 \(account.points) 点").font(.system(size: 12)).foregroundStyle(Ink.muted) }
                        PrimaryButton(title: work.purchased || work.isOwner ? "阅读译作" : "购买并阅读", icon: "book") { Task { await buyAndRead(work) } }.disabled(busy)
                        if !work.purchased && !work.isOwner { Button("充值") { wallet = true }.font(.system(size: 13)) }
                    }
                } else if account.isLoggedIn { if error == nil { ProgressView() } else { Button("重试") { Task { await load() } } } }
                else { Text("登录后查看与购买译作。").font(.system(size: 14)); AppleLoginView() }
                if let error { Text(error).font(.system(size: 13)).foregroundStyle(Ink.orange) }
            }.padding(24)
        }.background(Ink.paper).navigationTitle("译作").navigationBarTitleDisplayMode(.inline)
            .task(id: account.session) { if account.isLoggedIn { await load() } }
            .sheet(isPresented: $wallet) { WalletView() }
            .navigationDestination(isPresented: Binding(get: { reader != nil }, set: { if !$0 { reader = nil } })) { if let reader { ReaderView(id: reader) } }
    }
    private func load() async {
        do { work = try await account.send("works/\(workID)"); try await account.refresh(); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func buyAndRead(_ value: WorkMetadata) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            if !value.purchased && !value.isOwner { let receipt: WorkPurchase = try await account.send("works/\(workID)/purchase", method: "POST"); work = receipt.work }
            let content: WorkContent = try await account.send("works/\(workID)/content")
            reader = try studio.addPurchased(content)
            try await account.refresh(); error = nil
        } catch { self.error = error.localizedDescription; try? await account.refresh() }
    }
}
struct PublishWorkView: View {
    let id: String
    @Environment(StudioStore.self) private var studio
    @Environment(CloudAccount.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var price = 10
    @State private var rights = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            if let job = studio.job(id) {
                Form {
                    Section { Text(job.title).font(.system(size: 19, design: .serif)) }
                    if let workID = job.publishedWorkID {
                        Section("分享译作") {
                            if let url = WorkLink.share(workID, account: account) { ShareLink(item: url) { Label("分享链接", systemImage: "square.and.arrow.up") } }
                            Text(workID).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            Button("复制 ID") { UIPasteboard.general.string = workID }
                        }
                    } else if account.isLoggedIn {
                        Section("点数定价") {
                            TextField("点数", value: $price, format: .number).keyboardType(.numberPad).disabled(job.publicationPrice != nil)
                            Text("购买者支付的点数记入你的账户，可用于翻译或购买译作。").font(.system(size: 12)).foregroundStyle(Ink.muted)
                        }
                        Section {
                            Toggle("我拥有翻译与分享此作品的权利", isOn: $rights)
                            Text("仅上传译本和封面。接收者可通过链接或 ID 购买、阅读和导出。").font(.system(size: 12)).foregroundStyle(Ink.muted)
                            Button(busy ? "发布中…" : "发布译作") { Task { await publish(job) } }.disabled(busy || !rights || !(1...100_000).contains(price) || job.purchasedWorkID != nil)
                        }
                    } else { Section { Text("发布需要 Apple 账户。自带 API 译作也可发布。").font(.system(size: 13)); AppleLoginView() } }
                    if let error { Section { Text(error).font(.system(size: 12)).foregroundStyle(Ink.orange) } }
                }.scrollContentBackground(.hidden).background(Ink.paper).navigationTitle("定价分享").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                    .onAppear { price = job.publicationPrice ?? 10 }
            }
        }
    }
    private func publish(_ job: BookJob) async {
        guard !busy, job.status == .complete, job.purchasedWorkID == nil else { return }; busy = true; defer { busy = false }
        do {
            let amount = job.publicationPrice ?? price
            studio.update(id) { $0.publicationPrice = amount }; try await studio.save()
            var body: [String: Any] = ["publicationID": job.id, "title": job.title, "text": EditorNotes.display(job.result), "targetLanguage": job.options.targetLanguage, "styleName": job.options.style.name, "price": amount, "rightsConfirmed": rights]
            if let cover = CoverStorage.image(for: job.coverKey) {
                let scale = min(1, 1000 / max(cover.size.width, cover.size.height))
                let resized = UIGraphicsImageRenderer(size: CGSize(width: cover.size.width * scale, height: cover.size.height * scale)).image { _ in cover.draw(in: CGRect(origin: .zero, size: CGSize(width: cover.size.width * scale, height: cover.size.height * scale))) }
                if let data = resized.jpegData(compressionQuality: 0.8), data.count <= 2_000_000 { body["coverBase64"] = data.base64EncodedString() }
            }
            let result: WorkMetadata = try await account.send("works", body: JSONSerialization.data(withJSONObject: body), method: "POST")
            studio.update(id) { $0.publishedWorkID = result.id }; try await studio.save(); error = nil
        } catch { self.error = error.localizedDescription }
    }
}
