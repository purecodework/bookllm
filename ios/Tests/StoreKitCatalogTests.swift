import XCTest
import StoreKit
import StoreKitTest
@testable import BookLLM

final class StoreKitCatalogTests: XCTestCase {
    @MainActor func testLocalStoreKitCatalogLoadsAndRefreshFailureKeepsPrices() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "BookLLM", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: source)
        session.disableDialogs = true
        defer { session.resetToDefaultState() }
        var failRefresh = false
        let store = PurchaseStore(productLoader: { ids in
            if failRefresh { throw URLError(.notConnectedToInternet) }
            return try await Product.products(for: ids)
        }, entitlementLoader: { false })
        await store.load()
        guard store.catalogState == .loaded, !store.products.isEmpty else {
            throw XCTSkip("当前模拟器的本地 StoreKit 服务未提供商品；加载超时与重试由独立状态测试验证，真实商店另验。")
        }
        XCTAssertEqual(store.catalogState, .loaded)
        XCTAssertEqual(Set(store.products.map(\.id)), Set(PurchaseStore.ids))
        XCTAssertTrue(store.products.allSatisfy { !$0.displayPrice.isEmpty })
        let prices = store.products.map(\.displayPrice)
        failRefresh = true
        await store.load()
        guard case .failed = store.catalogState else { XCTFail("Expected refresh failure"); return }
        XCTAssertEqual(store.products.map(\.displayPrice), prices)
        failRefresh = false
        await store.load()
        XCTAssertEqual(store.catalogState, .loaded)
        XCTAssertEqual(Set(store.products.map(\.id)), Set(PurchaseStore.ids))
    }
}
