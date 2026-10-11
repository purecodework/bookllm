import XCTest
import TranslationCore
@testable import BookLLM

final class PreparationCompatibilityTests: XCTestCase {
    private let academicSource = "Introduction\n\nAn experiment is described below.\n\n1. Install the package.\n\n2. Run the experiment.\n\nResults\n\nThe observed result was stable."
    private let fictionSource = "Chapter I\n\nMary waited by the window.\n\n| Name | Age |\n| --- | --- |\n| Mary | 21 |\n\nChapter II\n\nShe opened the letter."

    private func location() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("studio.json")
    }

    private func saveOldSnapshot(_ jobs: [BookJob], to url: URL) throws {
        let records = try jobs.map { job -> [String: Any] in
            var record = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
            var options = try XCTUnwrap(record["options"] as? [String: Any])
            options.removeValue(forKey: "preparationVersion")
            record["options"] = options
            return record
        }
        let snapshot: [String: Any] = ["jobs": records, "styles": [], "preferences": try JSONSerialization.jsonObject(with: JSONEncoder().encode(TranslationPreferences()))]
        try JSONSerialization.data(withJSONObject: snapshot).write(to: url)
    }

    @MainActor func testOldCompletedBookReplansWithTheOriginalChunkAndChapterMapping() throws {
        let url = try location()
        var book = BookJob(title: "Completed paper", source: academicSource, format: "TXT")
        book.options.documentKind = .academic; book.options.quality = .fast
        book.options.preparationVersion = nil; book.options.pipelineVersion = nil
        book.replan(); book.status = .complete
        book.checkpoints = (0..<book.chunkCount).map { .init(index: $0, stage: .translate, text: "saved translation \($0)") }
        book.result = book.checkpoints.map(\.text).joined(separator: "\n\n")
        book.readingAnchor = "chunk-2"; book.readingChapter = 1
        try saveOldSnapshot([book], to: url)

        let store = StudioStore(storageURL: url)
        var restored = try XCTUnwrap(store.job(book.id))
        XCTAssertNil(restored.options.preparationVersion)
        XCTAssertNil(restored.options.pipelineVersion)
        XCTAssertEqual(restored.status, .complete)
        restored.replan()
        XCTAssertEqual(restored.chunkCount, book.chunkCount)
        XCTAssertEqual(restored.chapters.map(\.title), book.chapters.map(\.title))
        XCTAssertEqual(restored.chapters.map(\.chunks), book.chapters.map(\.chunks))
        XCTAssertEqual(restored.readableChapters.map(\.chunks), book.readableChapters.map(\.chunks))
        XCTAssertEqual(restored.checkpoints.map(\.index), book.checkpoints.map(\.index))
        XCTAssertEqual(restored.result, book.result)
        XCTAssertEqual(restored.readingAnchor, "chunk-2")
        XCTAssertEqual(restored.readingChapter, 1)
        XCTAssertGreaterThan(book.chapters.count, Chunker.plan(text: academicSource, kind: .academic, preparationVersion: 2).sections.count)
        XCTAssertNil(store.task)
    }

    @MainActor func testUnstartedDraftUpgradesPreparationAndAutomaticClassification() throws {
        let url = try location()
        var book = BookJob(title: "A novel", source: fictionSource, format: "TXT")
        book.options.documentKind = .technical; book.options.pipelineVersion = nil
        book.options.preparationVersion = nil; book.replan()
        try saveOldSnapshot([book], to: url)

        let store = StudioStore(storageURL: url)
        let restored = try XCTUnwrap(store.job(book.id))
        XCTAssertEqual(restored.options.preparationVersion, 2)
        XCTAssertEqual(restored.options.pipelineVersion, 2)
        XCTAssertEqual(restored.options.documentKind, .fiction)
        XCTAssertEqual(restored.chapters.map(\.title), ["Chapter I", "Chapter II"])
        XCTAssertEqual(restored.status, .draft)
        XCTAssertNil(store.task); XCTAssertNil(store.activeID)
        store.reloadLibrary()
        XCTAssertEqual(store.job(book.id)?.options.preparationVersion, 2)
        XCTAssertNil(store.task)
    }

    @MainActor func testDraftUpgradePreservesTheUserSelectedKindAndTerms() throws {
        let url = try location()
        var book = BookJob(title: "User selected", source: fictionSource, format: "TXT")
        book.options.documentKind = .general; book.options.preparationVersion = nil
        book.genreWasCorrected = true; book.glossaryMode = .custom
        book.terms = [.init(source: "Mary", target: "用户译名")]
        book.nameOverrides = ["Mary": "用户覆盖"]
        book.replan()
        try saveOldSnapshot([book], to: url)

        let store = StudioStore(storageURL: url)
        let restored = try XCTUnwrap(store.job(book.id))
        XCTAssertEqual(restored.options.preparationVersion, 2)
        XCTAssertEqual(restored.options.documentKind, .general)
        XCTAssertEqual(restored.displayTerms.first?.target, "用户覆盖")
        XCTAssertEqual(restored.glossaryMode, .custom)
        XCTAssertNil(store.task)
    }

    @MainActor func testStartedAndFrozenDraftsNeverUpgradePreparation() throws {
        let url = try location()
        var base = BookJob(title: "Legacy", source: academicSource, format: "TXT")
        base.options.documentKind = .academic; base.options.preparationVersion = nil
        base.replan()
        let term = Term(source: "package", target: "软件包")
        var books: [BookJob] = []
        for status in [JobStatus.translating, .extracting, .paused, .complete, .reviewing] {
            var book = base; book.id = status.rawValue; book.status = status; books.append(book)
        }
        var frozenQuery = base; frozenQuery.id = "query"
        frozenQuery.glossaryQueries = [0: .init(requestID: "query-g0", source: academicSource, target: "简体中文")]
        books.append(frozenQuery)
        var frozenSeed = base; frozenSeed.id = "seed"; frozenSeed.glossarySeed = [term]; books.append(frozenSeed)
        var completedTerms = base; completedTerms.id = "terms"; completedTerms.termBatches = [0: [term]]; books.append(completedTerms)
        var ready = base; ready.id = "ready"; ready.glossaryReady = true; books.append(ready)
        var translated = base; translated.id = "checkpoint"; translated.checkpoints = [.init(index: 0, stage: .translate, text: "已保存")]; books.append(translated)
        try saveOldSnapshot(books, to: url)

        let store = StudioStore(storageURL: url)
        for original in books {
            let restored = try XCTUnwrap(store.job(original.id))
            XCTAssertNil(restored.options.preparationVersion, original.id)
            XCTAssertEqual(restored.chunkCount, original.chunkCount, original.id)
            XCTAssertEqual(restored.chapters.map(\.chunks), original.chapters.map(\.chunks), original.id)
        }
        XCTAssertEqual(store.job("translating")?.status, .paused)
        XCTAssertEqual(store.job("extracting")?.status, .paused)
        XCTAssertEqual(store.job("query")?.glossaryQueries?[0]?.requestID, "query-g0")
        XCTAssertEqual(store.job("terms")?.termBatches[0]?.first?.target, "软件包")
        XCTAssertNil(store.task); XCTAssertNil(store.activeID)
    }

    @MainActor func testNewImportPersistsImprovedPreparationAndDistinctNovelChapters() async throws {
        let url = try location(), store = StudioStore(storageURL: url)
        let id = try await store.addPersisted(.init(title: "A novel", text: fictionSource, format: "TXT"), id: "new-novel")
        let imported = try XCTUnwrap(store.job(id))
        XCTAssertEqual(imported.options.preparationVersion, 2)
        XCTAssertEqual(imported.options.documentKind, .fiction)
        XCTAssertEqual(imported.chapters.map(\.title), ["Chapter I", "Chapter II"])
        let restored = StudioStore(storageURL: url)
        XCTAssertEqual(restored.job(id)?.options.preparationVersion, 2)
        XCTAssertEqual(restored.job(id)?.chapters.map(\.chunks), imported.chapters.map(\.chunks))
        XCTAssertNil(restored.task)
    }
}
