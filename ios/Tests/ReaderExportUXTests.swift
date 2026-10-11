import XCTest
import TranslationCore
@testable import BookLLM

final class ReaderExportUXTests: XCTestCase {
    private func fixture() -> (BookJob, [TextChunk]) {
        let source = "Chapter I\n\nA short beginning.\n\nChapter II\n\n" + Array(repeating: String(repeating: "The letter waited on the table. ", count: 35), count: 8).joined(separator: "\n\n")
        var job = BookJob(title: "范围测试", source: source, format: "TXT")
        job.options.quality = .publication
        job.replan(); job.status = .translating
        return (job, Chunker.plan(text: source, kind: job.options.documentKind).chunks)
    }
    private func finish(_ job: inout BookJob, indices: [Int]) {
        for index in indices { job.checkpoints.append(.init(index: index, stage: job.options.stages.last!, text: "已完成译文\(index)")) }
    }
    func testDirectoryKeepsKnownChaptersAndExistingCompletionBoundary() throws {
        var (job, _) = fixture()
        XCTAssertEqual(job.chapters.count, 2)
        let first = try XCTUnwrap(job.chapters.first), second = try XCTUnwrap(job.chapters.last)
        XCTAssertEqual(job.chapterReadingState(second).label, "未开始")
        XCTAssertFalse(job.chapterReadingState(second).canRead)
        finish(&job, indices: second.chunks)
        XCTAssertEqual(job.chapterReadingState(second).label, "已完成")
        XCTAssertFalse(job.chapterReadingState(second).canRead, "A later final chapter must not widen the existing completed prefix.")
        XCTAssertEqual(job.completedChapterCount, 0)
        finish(&job, indices: first.chunks)
        XCTAssertTrue(job.chapterReadingState(second).canRead)
        XCTAssertEqual(job.completedChapterCount, 2)
    }
    func testFastDirectoryPreservesEarlyReadingWithoutPretendingCompletion() throws {
        var (job, _) = fixture()
        job.options.quality = .fast
        let chapter = try XCTUnwrap(job.chapters.last)
        let unopened = job.chapterReadingState(chapter)
        XCTAssertTrue(unopened.canRead)
        XCTAssertEqual(unopened.label, "未开始")
        let index = try XCTUnwrap(chapter.chunks.first)
        let event = ProcessingEvent(requestID: "existing-id", chunkIndex: index, stage: .translate, state: .started)
        let active = job.chapterReadingState(chapter, events: [event], liveChunkIndices: [index])
        XCTAssertTrue(active.canRead)
        XCTAssertEqual(active.label, "译者处理中")
        XCTAssertEqual(job.completedChapterCount, 0)
    }
    func testExportScopesUseExplicitChaptersRatherThanReadingPosition() throws {
        var (job, chunks) = fixture()
        finish(&job, indices: chunks.map(\.index))
        let first = try XCTUnwrap(job.chapters.first), second = try XCTUnwrap(job.chapters.last)
        job.readingChapter = first.id; job.readingAnchor = "\(first.chunks[0])-2"
        let all = BookExportSelection(job: job, chunks: chunks, scope: .all, currentChapterID: first.id, selectedChapterIDs: [])
        XCTAssertEqual(all.chapters.map(\.id), [first.id, second.id])
        XCTAssertEqual(all.completeChapterCount, 2)
        let current = BookExportSelection(job: job, chunks: chunks, scope: .current, currentChapterID: first.id, selectedChapterIDs: [])
        XCTAssertEqual(current.chunks.map(\.index), first.chunks)
        let selected = BookExportSelection(job: job, chunks: chunks, scope: .selected, currentChapterID: first.id, selectedChapterIDs: [second.id])
        XCTAssertEqual(selected.chunks.map(\.index), second.chunks)
        XCTAssertFalse(selected.snapshot(job: job, bilingual: false).text.contains("已完成译文\(first.chunks[0])"))
        XCTAssertEqual(job.readingChapter, first.id)
        XCTAssertEqual(job.readingAnchor, "\(first.chunks[0])-2")
    }
    func testExportIncludesPartialFinalChapterButExcludesUnfinishedPasses() throws {
        var (job, chunks) = fixture()
        let first = try XCTUnwrap(job.chapters.first), second = try XCTUnwrap(job.chapters.last)
        XCTAssertGreaterThan(second.chunks.count, 1)
        finish(&job, indices: first.chunks + [second.chunks[0]])
        job.checkpoints.append(.init(index: second.chunks[1], stage: .translate, text: "未经审校的草稿"))
        let selection = BookExportSelection(job: job, chunks: chunks, scope: .all, currentChapterID: nil, selectedChapterIDs: [])
        XCTAssertTrue(selection.canGenerate)
        XCTAssertEqual(selection.completeChapterCount, 1)
        XCTAssertEqual(selection.partialChapterCount, 1)
        let snapshot = selection.snapshot(job: job, bilingual: true)
        XCTAssertTrue(snapshot.text.contains("已完成译文\(second.chunks[0])"))
        XCTAssertFalse(snapshot.text.contains("未经审校的草稿"))
        XCTAssertTrue(snapshot.text.contains("原文\n"))
        XCTAssertTrue(snapshot.summary.contains("另有 1 章"))
    }
    func testPurchasedExportNeverIncludesOriginalEvenIfRequested() {
        var (job, chunks) = fixture()
        job.purchasedWorkID = "purchased-existing"; job.options.quality = .fast; job.status = .complete
        finish(&job, indices: chunks.map(\.index))
        let snapshot = BookExportSelection(job: job, chunks: chunks, scope: .all, currentChapterID: nil, selectedChapterIDs: []).snapshot(job: job, bilingual: true)
        XCTAssertFalse(snapshot.text.contains("原文\n"))
        XCTAssertFalse(snapshot.text.contains("A short beginning."))
        XCTAssertTrue(snapshot.text.contains("已完成译文0"))
    }
    func testGeneratedSnapshotStaysFixedWhenMoreContentCompletes() throws {
        var (job, chunks) = fixture()
        let first = try XCTUnwrap(job.chapters.first), second = try XCTUnwrap(job.chapters.last)
        finish(&job, indices: first.chunks)
        let snapshot = BookExportSelection(job: job, chunks: chunks, scope: .all, currentChapterID: nil, selectedChapterIDs: []).snapshot(job: job, bilingual: false)
        let originalText = snapshot.text
        finish(&job, indices: second.chunks)
        let fresh = BookExportSelection(job: job, chunks: chunks, scope: .all, currentChapterID: nil, selectedChapterIDs: []).snapshot(job: job, bilingual: false)
        XCTAssertEqual(snapshot.text, originalText)
        XCTAssertNotEqual(snapshot.text, fresh.text)
        XCTAssertFalse(snapshot.text.contains("已完成译文\(second.chunks[0])"))
    }
    func testNoFinalContentCannotBeExported() {
        var (job, chunks) = fixture()
        job.checkpoints = [.init(index: 0, stage: .translate, text: "只有初译")]
        XCTAssertFalse(job.canExport)
        XCTAssertFalse(BookExportSelection(job: job, chunks: chunks, scope: .all, currentChapterID: nil, selectedChapterIDs: []).canGenerate)
    }
    func testExistingAnchorsAndSavedChapterRestoreWithoutResettingToStart() throws {
        var (job, _) = fixture()
        finish(&job, indices: job.chapters.flatMap(\.chunks))
        let second = try XCTUnwrap(job.chapters.last)
        job.readingChapter = second.id
        XCTAssertEqual(BookReadingAnchor.initialChapterID(job), second.id)
        job.readingChapter = 400
        XCTAssertEqual(BookReadingAnchor.initialChapterID(job), job.chapters.first?.id)
        let ids = ["5-source-0", "5-source-1", "5-1", "6-0"]
        XCTAssertEqual(BookReadingAnchor.resolve("5-source-1", availableIDs: ids), "5-source-1")
        XCTAssertEqual(BookReadingAnchor.resolve("5-8", availableIDs: ids), "5-source-0")
        XCTAssertEqual(BookReadingAnchor.resolve("5-1", availableIDs: ids + ["6-1"]), "5-1")
        XCTAssertNil(BookReadingAnchor.resolve("5-1", availableIDs: []))
    }
    func testModeChangeKeepsLookbackChunkRatherThanOldTranslationPosition() {
        XCTAssertEqual(BookReadingAnchor.modeAnchor("6-source-1", rememberedTranslation: "5-2", destinationMode: 0, availableIDs: ["5-2", "6-0", "6-1"]), "6-0")
        XCTAssertEqual(BookReadingAnchor.modeAnchor("6-source-1", rememberedTranslation: "6-2", destinationMode: 0, availableIDs: ["5-2", "6-0", "6-2"]), "6-2")
        XCTAssertEqual(BookReadingAnchor.modeAnchor("6-source-1", rememberedTranslation: nil, destinationMode: 2, availableIDs: ["6-source-0", "6-source-1"]), "6-source-1")
        XCTAssertEqual(BookReadingAnchor.modeAnchor("6-2", rememberedTranslation: "6-2", destinationMode: 1, availableIDs: ["6-source-0", "6-1", "6-2"]), "6-2")
    }
    func testLeavingComparisonPreservesCurrentTranslationParagraphWithinSameChunk() {
        XCTAssertEqual(BookReadingAnchor.modeAnchor("5-8", rememberedTranslation: "5-2", destinationMode: 0, availableIDs: ["5-2", "5-8", "6-0"]), "5-8")
    }
}
