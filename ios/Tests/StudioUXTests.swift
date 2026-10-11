import XCTest
import TranslationCore
@testable import BookLLM

final class StudioUXTests: XCTestCase {
    @MainActor func testRenamePersistsOnlyDraftTitleAndKeepsRequestData() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("studio.json"), store = StudioStore(storageURL: url)
        let id = try await store.addPersisted(.init(title: "original", text: "Chapter I\n\nA letter arrived.", format: "TXT"), id: UUID().uuidString)
        let previous = try XCTUnwrap(store.job(id))
        try await store.renameDraft(id, title: "  New display title  ")
        let restored = try XCTUnwrap(StudioStore(storageURL: url).job(id))
        XCTAssertEqual(restored.title, "New display title")
        XCTAssertEqual(restored.id, previous.id)
        XCTAssertEqual(restored.source, previous.source)
        XCTAssertEqual(restored.chapters.map(\.id), previous.chapters.map(\.id))
        XCTAssertEqual(restored.options, previous.options)
        XCTAssertEqual(restored.status, .draft)
        do { try await store.renameDraft(id, title: " \n "); XCTFail("Blank title accepted") } catch { }
        store.update(id) { $0.status = .paused }
        do { try await store.renameDraft(id, title: "Changed after start"); XCTFail("Running title accepted") } catch { }
        XCTAssertEqual(store.job(id)?.title, "New display title")
    }
    @MainActor func testFailedImportAndRenamePreserveAnotherBooksProgress() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("studio.json"), store = StudioStore(storageURL: url)
        var book = BookJob(title: "Keep title", source: "Original.", format: "TXT"); book.replan()
        var other = BookJob(title: "Another book", source: "Other source.", format: "TXT"); other.replan()
        store.jobs = [book, other]
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        store.update(other.id) { $0.checkpoints.append(.init(index: 0, stage: .translate, text: "Other progress")) }
        do { try await store.renameDraft(book.id, title: "Failed rename"); XCTFail("Write failure ignored") } catch { }
        XCTAssertEqual(store.job(book.id)?.title, "Keep title")
        do { _ = try await store.addPersisted(.init(title: "Failed import", text: "New input.", format: "TXT"), id: "new-import"); XCTFail("Write failure ignored") } catch { }
        XCTAssertNil(store.job("new-import"))
        XCTAssertEqual(store.job(other.id)?.checkpoints.first?.text, "Other progress")
        try FileManager.default.removeItem(at: url)
        try await store.save()
        let restored = StudioStore(storageURL: url)
        XCTAssertEqual(restored.job(book.id)?.title, "Keep title")
        XCTAssertEqual(restored.job(other.id)?.checkpoints.first?.text, "Other progress")
    }
}
