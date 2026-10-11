import XCTest
import TranslationCore
@testable import BookLLM

private enum ConnectionLimitTestError: Error { case keychain }

final class ModelConnectionLimitsTests: XCTestCase {
    @MainActor func testFreshConnectionUsesFlashAndSavedModelIsPreserved() throws {
        let suite = "BookLLM.ModelDefaults." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        XCTAssertEqual(StudioStore(storageURL: url, preferences: preferences).model, "deepseek-flash")
        preferences.set("deepseek-chat", forKey: "model")
        XCTAssertEqual(StudioStore(storageURL: url, preferences: preferences).model, "deepseek-chat")
    }
    @MainActor private func store(keySaver: @escaping @MainActor (String) throws -> Void = { _ in }) throws -> (StudioStore, UserDefaults, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "BookLLM.ModelConnectionLimitsTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.set("https://old.example.test/v1", forKey: "endpoint")
        preferences.set("old-model", forKey: "model")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: folder)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let url = folder.appendingPathComponent("studio.json")
        return (StudioStore(storageURL: url, connectionKeySaver: keySaver, preferences: preferences), preferences, url)
    }

    @MainActor func testMissingLimitsUseDefaultsAndNewLimitsSurviveRestart() throws {
        let (value, preferences, url) = try store()
        XCTAssertEqual(value.apiContextWindowTokens, ModelRequestLimits.standard.contextWindowTokens)
        XCTAssertEqual(value.apiMaximumOutputTokens, ModelRequestLimits.standard.maximumOutputTokens)
        try value.saveConnection(endpoint: "https://new.example.test/v1", model: "small-model", key: "key", limits: .init(contextWindowTokens: 8192, maximumOutputTokens: 2048))
        let restored = StudioStore(storageURL: url, connectionKeySaver: { _ in }, preferences: preferences)
        XCTAssertEqual(restored.apiContextWindowTokens, 8192)
        XCTAssertEqual(restored.apiMaximumOutputTokens, 2048)
        XCTAssertEqual(restored.model, "small-model")
        XCTAssertNil(restored.task)
    }

    @MainActor func testKeychainFailureLeavesSavedLimitsUnchangedAndAllowsRetry() throws {
        var writes = 0
        let (value, preferences, _) = try store { _ in
            writes += 1
            if writes == 1 { throw ConnectionLimitTestError.keychain }
        }
        preferences.set(16384, forKey: "apiContextWindowTokens")
        preferences.set(4096, forKey: "apiMaximumOutputTokens")
        value.apiContextWindowTokens = 16384; value.apiMaximumOutputTokens = 4096
        let replacement = ModelRequestLimits(contextWindowTokens: 8192, maximumOutputTokens: 2048)
        XCTAssertThrowsError(try value.saveConnection(endpoint: "https://new.example.test/v1", model: "new-model", key: "key", limits: replacement))
        XCTAssertEqual(value.endpoint, "https://old.example.test/v1")
        XCTAssertEqual(value.model, "old-model")
        XCTAssertEqual(value.apiContextWindowTokens, 16384)
        XCTAssertEqual(value.apiMaximumOutputTokens, 4096)
        XCTAssertEqual(preferences.integer(forKey: "apiContextWindowTokens"), 16384)
        XCTAssertEqual(preferences.integer(forKey: "apiMaximumOutputTokens"), 4096)
        try value.saveConnection(endpoint: "https://new.example.test/v1", model: "new-model", key: "key", limits: replacement)
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(value.apiContextWindowTokens, 8192)
        XCTAssertEqual(value.apiMaximumOutputTokens, 2048)
        XCTAssertEqual(preferences.integer(forKey: "apiContextWindowTokens"), 8192)
        XCTAssertEqual(preferences.integer(forKey: "apiMaximumOutputTokens"), 2048)
    }

    @MainActor func testInvalidLimitsFailBeforeKeychainOrPreferenceMutation() throws {
        var writes = 0
        let (value, preferences, _) = try store { _ in writes += 1 }
        for limits in [
            ModelRequestLimits(contextWindowTokens: 1023, maximumOutputTokens: 128),
            .init(contextWindowTokens: 8192, maximumOutputTokens: 127),
            .init(contextWindowTokens: 8192, maximumOutputTokens: 8192),
            .init(contextWindowTokens: 8192, maximumOutputTokens: 9000),
            .init(contextWindowTokens: 10_000_001, maximumOutputTokens: 128),
            .init(contextWindowTokens: 10_000_000, maximumOutputTokens: 1_000_001)
        ] {
            XCTAssertThrowsError(try value.saveConnection(endpoint: "https://new.example.test/v1", model: "new-model", key: "key", limits: limits))
        }
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(value.apiContextWindowTokens, ModelRequestLimits.standard.contextWindowTokens)
        XCTAssertEqual(value.apiMaximumOutputTokens, ModelRequestLimits.standard.maximumOutputTokens)
        XCTAssertEqual(value.endpoint, "https://old.example.test/v1")
        XCTAssertEqual(value.model, "old-model")
        XCTAssertNil(preferences.object(forKey: "apiContextWindowTokens"))
        XCTAssertNil(preferences.object(forKey: "apiMaximumOutputTokens"))
    }

    @MainActor func testExistingSaveCallPreservesConfiguredLimits() throws {
        let (value, preferences, _) = try store()
        try value.saveConnection(endpoint: value.endpoint, model: value.model, key: "first-key", limits: .init(contextWindowTokens: 4096, maximumOutputTokens: 512))
        try value.saveConnection(key: "new-key")
        XCTAssertEqual(value.apiContextWindowTokens, 4096)
        XCTAssertEqual(value.apiMaximumOutputTokens, 512)
        XCTAssertEqual(preferences.integer(forKey: "apiContextWindowTokens"), 4096)
        XCTAssertEqual(preferences.integer(forKey: "apiMaximumOutputTokens"), 512)
    }
}
