import StoreKit
import Observation
import TranslationCore

private struct StoreKitTimeout: LocalizedError {
    var errorDescription: String? { "商店响应超时，请重新加载或稍后再试。" }
}

@MainActor private final class StoreKitRace<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, any Error>?
    var request: Task<Void, Never>?
    var timer: Task<Void, Never>?
    private var onFinish: (() -> Void)?
    init(continuation: CheckedContinuation<Value, any Error>, onFinish: @escaping () -> Void) {
        self.continuation = continuation; self.onFinish = onFinish
    }
    func finish(_ result: Result<Value, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        let request = request, timer = timer, onFinish = onFinish
        self.request = nil; self.timer = nil; self.onFinish = nil
        request?.cancel(); timer?.cancel()
        onFinish?()
        continuation.resume(with: result)
    }
}

@MainActor @Observable final class PurchaseStore {
    enum CatalogState: Equatable { case idle, loading, loaded, failed(String) }
    private enum TransactionActivity { case purchasing, restoring }
    static let ids = ["app.bookllm.credits.100", "app.bookllm.credits.1000", "app.bookllm.byok.lifetime"]
    var products: [Product] = []
    private(set) var catalogState = CatalogState.idle
    private var transactionActivity: TransactionActivity?
    var busy: Bool { transactionActivity != nil }
    var isRestoring: Bool { transactionActivity == .restoring }
    var message: String?
    var localOwnAPIUnlocked = false
    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    @ObservationIgnored private let productLoader: @MainActor ([String]) async throws -> [Product]
    @ObservationIgnored private let entitlementLoader: @MainActor () async -> Bool
    @ObservationIgnored private let storeSync: @MainActor () async throws -> Void
    @ObservationIgnored private let catalogTimeout: Duration
    @ObservationIgnored private var storeKitRaces: [UUID: AnyObject] = [:]
    private struct CatalogSnapshot: Sendable {
        let products: Result<[Product], any Error>
        let unlocked: Bool
    }

    init(
        productLoader: @escaping @MainActor ([String]) async throws -> [Product] = { try await Product.products(for: $0) },
        entitlementLoader: @escaping @MainActor () async -> Bool = {
            for await result in Transaction.currentEntitlements {
                if case .verified(let transaction) = result,
                   transaction.productID == PurchaseStore.ids[2], transaction.revocationDate == nil { return true }
            }
            return false
        },
        storeSync: @escaping @MainActor () async throws -> Void = { try await AppStore.sync() },
        catalogTimeout: Duration = .seconds(20)
    ) {
        self.productLoader = productLoader; self.entitlementLoader = entitlementLoader; self.storeSync = storeSync
        self.catalogTimeout = catalogTimeout
    }

    func load() async {
        if let catalogTask { await catalogTask.value; return }
        let previousState = catalogState
        catalogState = .loading
        let task = Task { @MainActor in
            do {
                let snapshot = try await loadCatalogSnapshot()
                localOwnAPIUnlocked = snapshot.unlocked
                let loaded = try snapshot.products.get()
                products = loaded.sorted { $0.price < $1.price }
                catalogState = .loaded
            } catch is CancellationError {
                catalogState = previousState
            } catch {
                // A failed refresh must not discard a catalog already shown to the user.
                catalogState = .failed(error.localizedDescription)
            }
        }
        catalogTask = task
        await task.value
        catalogTask = nil
    }
    private func loadCatalogSnapshot() async throws -> CatalogSnapshot {
        let loadProducts = productLoader, loadEntitlement = entitlementLoader
        return try await withStoreKitTimeout {
            let products: Result<[Product], any Error>
            do { products = .success(try await loadProducts(Self.ids)) }
            catch { products = .failure(error) }
            try Task.checkCancellation()
            let unlocked = await loadEntitlement()
            try Task.checkCancellation()
            return CatalogSnapshot(products: products, unlocked: unlocked)
        }
    }
    private func withStoreKitTimeout<Value: Sendable>(_ operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let id = UUID(), timeout = catalogTimeout
        return try await withCheckedThrowingContinuation { continuation in
            let race = StoreKitRace(continuation: continuation) { [weak self] in self?.storeKitRaces[id] = nil }
            storeKitRaces[id] = race
            race.request = Task { @MainActor [weak race] in
                do {
                    let value = try await operation()
                    guard !Task.isCancelled else { return }
                    race?.finish(.success(value))
                } catch {
                    guard !Task.isCancelled else { return }
                    race?.finish(.failure(error))
                }
            }
            race.timer = Task { @MainActor [weak race] in
                do { try await Task.sleep(for: timeout) } catch { return }
                race?.finish(.failure(StoreKitTimeout()))
            }
        }
    }
    func buy(_ product: Product, account: CloudAccount) async {
        guard !busy else { return }
        let byok = product.id == Self.ids[2]
        guard byok || account.isConfigured else { message = "当前版本暂未连接点数翻译服务，暂不能购买点数。"; return }
        guard !byok || (!localOwnAPIUnlocked && !account.ownAPIUnlocked) else { message = "自带 API 已永久解锁。"; return }
        transactionActivity = .purchasing; message = nil
        defer { transactionActivity = nil }
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
            if account.isLoggedIn && account.isConfigured { try await account.refresh() }
        } catch { message = error.localizedDescription }
    }
    func restore(account: CloudAccount) async {
        guard !busy else { return }
        transactionActivity = .restoring; message = nil
        defer { transactionActivity = nil }
        do {
            try await storeSync(); await load()
            // Restore must re-read entitlements after sync, even if its catalog load
            // joined a refresh that started before the sync completed.
            let loadEntitlement = entitlementLoader
            localOwnAPIUnlocked = try await withStoreKitTimeout { await loadEntitlement() }
            await recover(account: account)
            if message == nil {
                message = localOwnAPIUnlocked || account.ownAPIUnlocked
                    ? "自带 API 已永久解锁。已购买的点数会在登录并确认到账后更新余额。"
                    : "恢复检查完成，未找到可恢复的自带 API 购买。已购买的点数会在登录并确认到账后更新余额。"
            }
        }
        catch { message = error.localizedDescription }
    }
    private func deliver(_ result: VerificationResult<Transaction>, account: CloudAccount) async throws {
        guard case .verified(let transaction) = result else { throw TranslationError.message("购买验证失败。") }
        if transaction.productID == Self.ids[2] {
            localOwnAPIUnlocked = transaction.revocationDate == nil
            await transaction.finish()
        } else {
            guard account.isLoggedIn else { throw TranslationError.message("请登录后领取已购买的点数。购买会保留等待领取。") }
            guard account.isConfigured else { throw TranslationError.message("点数翻译服务暂不可用，购买会保留等待确认到账。") }
            try await account.redeem(jws: result.jwsRepresentation)
            await transaction.finish()
        }
    }
}
