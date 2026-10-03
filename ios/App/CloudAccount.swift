import Foundation
import Observation
import TranslationCore

@MainActor @Observable final class CloudAccount {
    var points = 0
    var ownAPIUnlocked = false
    var accountID: UUID?
    var session = Vault.read("session")
    var isLoggedIn: Bool { !session.isEmpty }
    var isConfigured: Bool { baseURL != nil }
    var baseURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CloudBaseURL") as? String, let url = URL(string: raw), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
    struct AccountResponse: Decodable { let accountID: UUID; let points: Int; let ownAPIUnlocked: Bool; let token: String? }
    func login(identityToken: String, nonce: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["identityToken": identityToken, "nonce": nonce])
        try apply(try await request("session", body: body, method: "POST"))
    }
    func refresh() async throws { try apply(try await request("account", body: nil, method: "GET")) }
    func redeem(jws: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["signedTransaction": jws])
        try apply(try await request("purchases", body: body, method: "POST"))
    }
    private func apply(_ value: AccountResponse) throws {
        points = value.points; ownAPIUnlocked = value.ownAPIUnlocked; accountID = value.accountID
        if let token = value.token { try Vault.save(token, name: "session"); session = token }
    }
    private func request(_ path: String, body: Data?, method: String) async throws -> AccountResponse {
        guard let baseURL else { throw TranslationError.message("云端服务尚未配置。可在 Xcode 中配置 CloudBaseURL 后使用点数翻译。") }
        var request = URLRequest(url: baseURL.appendingPathComponent(path)); request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw TranslationError.message("账户请求失败。请检查网络或重新登录。") }
        return try JSONDecoder().decode(AccountResponse.self, from: data)
    }
}
