import XCTest
import StoreKit
@testable import BookLLM

private enum UXTestFailure: LocalizedError {
    case unavailable, keychain
    var errorDescription: String? {
        switch self { case .unavailable: "Test catalog unavailable"; case .keychain: "Test keychain write failed" }
    }
}

@MainActor private final class UXAsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var calls = 0
    func wait() async {
        calls += 1
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

final class PurchaseSettingsUXTests: XCTestCase {
    @MainActor func testConcurrentCatalogLoadsShareOneRequestAndEntitlementRefresh() async throws {
        let gate = UXAsyncGate()
        defer { gate.release() }
        var entitlementCalls = 0
        let store = PurchaseStore(productLoader: { ids in XCTAssertEqual(ids, PurchaseStore.ids); await gate.wait(); return [] }, entitlementLoader: {
            entitlementCalls += 1; return true
        })
        let first = Task { await store.load() }
        try await waitUntil { gate.calls == 1 }
        var secondStarted = false
        let second = Task { secondStarted = true; await store.load() }
        try await waitUntil { secondStarted }
        XCTAssertEqual(store.catalogState, .loading)
        XCTAssertEqual(gate.calls, 1)
        gate.release()
        await first.value; await second.value
        XCTAssertEqual(gate.calls, 1)
        XCTAssertEqual(entitlementCalls, 1)
        XCTAssertEqual(store.catalogState, .loaded)
        XCTAssertTrue(store.localOwnAPIUnlocked)
    }

    @MainActor func testFailedCatalogCanRetryWithoutUsingTransactionAlert() async {
        var calls = 0
        let store = PurchaseStore(productLoader: { _ in
            calls += 1
            if calls == 1 { throw UXTestFailure.unavailable }
            return []
        }, entitlementLoader: { true })
        await store.load()
        XCTAssertEqual(store.catalogState, .failed("Test catalog unavailable"))
        XCTAssertNil(store.message)
        XCTAssertTrue(store.localOwnAPIUnlocked)
        await store.load()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(store.catalogState, .loaded)
        XCTAssertTrue(store.products.isEmpty)
        XCTAssertNil(store.message)
    }

    @MainActor func testCancelledRefreshKeepsLastCatalogStateAndDoesNotShowAnError() async {
        var calls = 0
        let store = PurchaseStore(productLoader: { _ in
            calls += 1
            if calls > 1 { throw CancellationError() }
            return []
        }, entitlementLoader: { false })
        await store.load()
        XCTAssertEqual(store.catalogState, .loaded)
        await store.load()
        XCTAssertEqual(store.catalogState, .loaded)
        XCTAssertNil(store.message)
    }

    @MainActor func testCatalogTimeoutDoesNotWaitForUncooperativeProductsAndAllowsRetry() async throws {
        let gate = UXAsyncGate()
        let safetyRelease = Task { try? await Task.sleep(for: .seconds(1)); gate.release() }
        defer { safetyRelease.cancel(); gate.release() }
        var productCalls = 0, entitlementCalls = 0
        var firstReturned = false
        let store = PurchaseStore(productLoader: { _ in
            productCalls += 1
            if productCalls == 1 { await gate.wait(); firstReturned = true } // Ignores cancellation until explicitly released.
            return []
        }, entitlementLoader: { entitlementCalls += 1; return true }, catalogTimeout: .milliseconds(30))
        store.localOwnAPIUnlocked = true
        await store.load()
        XCTAssertEqual(store.catalogState, .failed("商店响应超时，请重新加载或稍后再试。"))
        XCTAssertTrue(store.localOwnAPIUnlocked)
        XCTAssertEqual(entitlementCalls, 0)
        XCTAssertNil(store.message)
        await store.load()
        XCTAssertEqual(productCalls, 2)
        XCTAssertEqual(entitlementCalls, 1)
        XCTAssertEqual(store.catalogState, .loaded)
        gate.release()
        try await waitUntil { firstReturned }
        XCTAssertEqual(entitlementCalls, 1)
        XCTAssertEqual(store.catalogState, .loaded)
    }

    @MainActor func testEntitlementTimeoutKeepsKnownPurchaseAndDoesNotBlockCatalogRetry() async throws {
        let gate = UXAsyncGate()
        let safetyRelease = Task { try? await Task.sleep(for: .seconds(1)); gate.release() }
        defer { safetyRelease.cancel(); gate.release() }
        var entitlementCalls = 0
        var firstReturned = false
        let store = PurchaseStore(productLoader: { _ in [] }, entitlementLoader: {
            entitlementCalls += 1
            if entitlementCalls == 1 { await gate.wait(); firstReturned = true; return false }
            return true
        }, catalogTimeout: .milliseconds(30))
        store.localOwnAPIUnlocked = true
        await store.load()
        XCTAssertEqual(store.catalogState, .failed("商店响应超时，请重新加载或稍后再试。"))
        XCTAssertTrue(store.localOwnAPIUnlocked)
        await store.load()
        XCTAssertEqual(entitlementCalls, 2)
        XCTAssertEqual(store.catalogState, .loaded)
        gate.release()
        try await waitUntil { firstReturned }
        XCTAssertTrue(store.localOwnAPIUnlocked)
        XCTAssertEqual(store.catalogState, .loaded)
    }

    @MainActor func testConcurrentRestoreRequestsDoNotOpenTwoStoreDialogs() async throws {
        let gate = UXAsyncGate()
        defer { gate.release() }
        let store = PurchaseStore(productLoader: { _ in XCTFail("Failed sync must not reload products"); return [] },
                                  entitlementLoader: { false }, storeSync: {
            await gate.wait(); throw UXTestFailure.unavailable
        })
        let account = CloudAccount(); account.session = ""
        let first = Task { await store.restore(account: account) }
        try await waitUntil { gate.calls == 1 }
        XCTAssertTrue(store.busy)
        XCTAssertTrue(store.isRestoring)
        await store.restore(account: account)
        XCTAssertEqual(gate.calls, 1)
        gate.release(); await first.value
        XCTAssertFalse(store.busy)
        XCTAssertFalse(store.isRestoring)
        XCTAssertEqual(store.message, "Test catalog unavailable")
    }

    @MainActor func testConnectionSaveCommitsOnlyAfterKeychainSucceeds() throws {
        var writtenKey: String?
        let (store, preferences) = try connectionStore { writtenKey = $0 }
        store.ownAPI = true
        try store.saveConnection(endpoint: " https://api.example.test/v1 ", model: " custom-model ", key: " new-secret ")
        XCTAssertEqual(writtenKey, "new-secret")
        XCTAssertEqual(store.endpoint, "https://api.example.test/v1")
        XCTAssertEqual(store.model, "custom-model")
        XCTAssertEqual(preferences.string(forKey: "endpoint"), store.endpoint)
        XCTAssertEqual(preferences.string(forKey: "model"), store.model)
        XCTAssertTrue(preferences.bool(forKey: "ownAPI"))
        XCTAssertNil(store.task)
    }

    @MainActor func testKeychainFailureKeepsSavedConnectionAndAllowsRetry() throws {
        var attempts = 0
        let (store, preferences) = try connectionStore { _ in
            attempts += 1
            if attempts == 1 { throw UXTestFailure.keychain }
        }
        XCTAssertThrowsError(try store.saveConnection(endpoint: "https://new.example.test/v1", model: "new-model", key: "new-secret"))
        XCTAssertEqual(store.endpoint, "https://old.example.test/v1")
        XCTAssertEqual(store.model, "old-model")
        XCTAssertEqual(preferences.string(forKey: "endpoint"), "https://old.example.test/v1")
        XCTAssertEqual(preferences.string(forKey: "model"), "old-model")
        try store.saveConnection(endpoint: "https://new.example.test/v1", model: "new-model", key: "new-secret")
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(store.endpoint, "https://new.example.test/v1")
        XCTAssertNil(store.task)
    }

    @MainActor func testInvalidConnectionNeverWritesKeychainOrReplacesSavedConnection() throws {
        var writes = 0
        let (store, preferences) = try connectionStore { _ in writes += 1 }
        let invalid: [(String, String, String)] = [
            ("http://api.example.test/v1", "model", "secret"),
            ("https://secret@api.example.test/v1", "model", "secret"),
            ("https://api.example.test/v1#secret", "model", "secret"),
            ("https://", "model", "secret"),
            ("https://api.example.test/v1", " \n", "secret"),
            ("https://api.example.test/v1", "model", " \n")
        ]
        for value in invalid {
            XCTAssertThrowsError(try store.saveConnection(endpoint: value.0, model: value.1, key: value.2))
        }
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(store.endpoint, "https://old.example.test/v1")
        XCTAssertEqual(store.model, "old-model")
        XCTAssertEqual(preferences.string(forKey: "endpoint"), store.endpoint)
        XCTAssertNil(store.task)
    }

    @MainActor private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw UXTestFailure.unavailable }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor private func connectionStore(keySaver: @escaping @MainActor (String) throws -> Void) throws -> (StudioStore, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "BookLLM.ConnectionUXTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.set("https://old.example.test/v1", forKey: "endpoint")
        preferences.set("old-model", forKey: "model")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let store = StudioStore(storageURL: root.appendingPathComponent("studio.json"), connectionKeySaver: keySaver, preferences: preferences)
        return (store, preferences)
    }
}
