import StoreKit
import Observation
import TranslationCore

@MainActor @Observable final class PurchaseStore {
    static let ids = ["app.bookllm.credits.100", "app.bookllm.credits.1000", "app.bookllm.byok.lifetime"]
    var products: [Product] = []
    var busy = false
    var message: String?
    var localOwnAPIUnlocked = false
    func load() async {
        do { products = try await Product.products(for: Self.ids).sorted { $0.price < $1.price } }
        catch { message = error.localizedDescription }
        var found = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.productID == Self.ids[2], transaction.revocationDate == nil { found = true }
        }
        localOwnAPIUnlocked = found
    }
    func buy(_ product: Product, account: CloudAccount) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let result: Product.PurchaseResult
            if let id = account.accountID { result = try await product.purchase(options: [.appAccountToken(id)]) }
            else if product.id == Self.ids[2] { result = try await product.purchase() }
            else { throw TranslationError.message("购买翻译点数前，请先登录账户。") }
            switch result {
            case .success(let verified): try await deliver(verified, account: account)
            case .pending: message = "购买等待批准，批准后会自动处理。"
            case .userCancelled: break
            @unknown default: break
            }
        } catch { message = error.localizedDescription }
    }
    func listen(account: CloudAccount) async {
        // Unfinished consumables are re-delivered after login; finish only after server crediting.
        for await result in Transaction.updates {
            do { try await deliver(result, account: account) } catch { message = error.localizedDescription }
        }
    }
    func recover(account: CloudAccount) async {
        do {
            for await result in Transaction.unfinished {
                do { try await deliver(result, account: account) } catch { message = error.localizedDescription }
            }
            if account.isLoggedIn { try await account.refresh() }
        } catch { message = error.localizedDescription }
    }
    func restore(account: CloudAccount) async {
        do { try await AppStore.sync(); await load(); await recover(account: account) }
        catch { message = error.localizedDescription }
    }
    private func deliver(_ result: VerificationResult<Transaction>, account: CloudAccount) async throws {
        guard case .verified(let transaction) = result else { throw TranslationError.message("购买验证失败。") }
        if transaction.productID == Self.ids[2] {
            localOwnAPIUnlocked = transaction.revocationDate == nil
            await transaction.finish()
        } else {
            guard account.isLoggedIn else { throw TranslationError.message("请登录后领取已购买的点数。购买会保留等待领取。") }
            try await account.redeem(jws: result.jwsRepresentation)
            await transaction.finish()
        }
    }
}
