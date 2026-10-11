import XCTest
import SwiftUI
import PDFKit
import ZIPFoundation
import TranslationCore
@testable import BookLLM

final class PaperStoreTests: XCTestCase {
    private func location() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("studio.json")
    }
    @MainActor func testNameSaveSurvivesRestartAndDoesNotChangeContentOrOtherBook() async throws {
        let url = try location(), store = StudioStore(storageURL: url)
        var first = BookJob(title: "第一本", source: "Elizabeth waited.", format: "TXT")
        first.terms = [Term(source: "Elizabeth", target: "伊丽莎白", category: .person)]
        first.replan(); first.status = .complete
        first.checkpoints = [.init(index: 0, stage: .proofread, text: "她等待着。")]
        first.result = "她等待着。"
        var second = first; second.id = "second"; second.title = "第二本"
        store.jobs = [first, second]
        try await store.saveNameOverride(bookID: first.id, termID: "Elizabeth", target: "莉莎")
        XCTAssertNil(store.task)
        XCTAssertEqual(store.job(first.id)?.displayTerms.first?.target, "莉莎")
        XCTAssertEqual(store.job(second.id)?.displayTerms.first?.target, "伊丽莎白")
        XCTAssertEqual(store.job(first.id)?.result, first.result)
        XCTAssertEqual(store.job(first.id)?.checkpoints.map(\.text), first.checkpoints.map(\.text))
        let restored = StudioStore(storageURL: url)
        XCTAssertEqual(restored.job(first.id)?.displayTerms.first?.target, "莉莎")
        XCTAssertEqual(restored.job(first.id)?.status, .complete)
    }
    @MainActor func testBlankNameAndDiskFailureKeepOriginalPreference() async throws {
        let url = try location(), store = StudioStore(storageURL: url)
        var job = BookJob(title: "保存失败", source: "Mary waited.", format: "TXT")
        job.terms = [.init(source: "Mary", target: "玛丽")]
        store.jobs = [job]
        do { try await store.saveNameOverride(bookID: job.id, termID: "Mary", target: " \n "); XCTFail("Blank accepted") } catch { }
        // A directory at the save path forces an atomic write failure.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        do { try await store.saveNameOverride(bookID: job.id, termID: "Mary", target: "梅"); XCTFail("Disk failure ignored") } catch { }
        XCTAssertNil(store.job(job.id)?.nameOverrides?["Mary"])
        XCTAssertEqual(store.job(job.id)?.displayTerms.first?.target, "玛丽")
    }
    @MainActor func testOldManualTaskLoadsWithoutStartingOrLosingNames() async throws {
        let url = try location()
        var job = BookJob(title: "旧记录", source: "Mary waited.", format: "TXT")
        job.status = .reviewing; job.glossaryMode = .review
        job.terms = [.init(source: "Mary", target: "用户已编辑")]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        for key in ["nameOverrides", "readingAnchor", "readingFontSize", "readingMode", "readingChapter", "pauseReason"] { object.removeValue(forKey: key) }
        let old: [String: Any] = ["jobs": [object], "styles": [], "preferences": try JSONSerialization.jsonObject(with: JSONEncoder().encode(TranslationPreferences()))]
        try JSONSerialization.data(withJSONObject: old).write(to: url)
        let store = StudioStore(storageURL: url)
        XCTAssertEqual(store.jobs.count, 1)
        XCTAssertEqual(store.jobs[0].status, .reviewing)
        XCTAssertEqual(store.jobs[0].terms[0].target, "用户已编辑")
        XCTAssertNil(store.task); XCTAssertNil(store.activeID); XCTAssertNil(store.jobs[0].nameOverrides)
    }
    @MainActor func testIncompleteFinalChapterCannotBecomeReadable() {
        var job = BookJob(title: "完整性", source: "Chapter I\n\nHello.", format: "TXT")
        job.replan()
        job.checkpoints = [.init(index: 0, stage: .translate, text: "你好。")]
        job.status = .needsReview
        XCTAssertEqual(job.completedChapterCount, 0)
        XCTAssertTrue(job.readableChapters.isEmpty)
        XCTAssertFalse(job.canRead)
    }
    @MainActor func testParallelRolesUseActualEventsAndChapterScope() {
        var job = BookJob(title: "并行", source: "Chapter I\n\nHello.", format: "TXT")
        job.options.quality = .publication; job.replan(); job.status = .translating
        job.checkpoints = [.init(index: 0, stage: .translate, text: "你好。")]
        let events = [.proofread, .linguist].map { ProcessingEvent(requestID: $0.rawValue, chunkIndex: 0, stage: $0, state: .started) }
        let roles = job.roleStates(events: events)
        XCTAssertEqual(roles[.translate], "已完成")
        XCTAssertEqual(roles[.proofread], "处理中")
        XCTAssertEqual(roles[.linguist], "处理中")
        XCTAssertEqual(roles[.editor], "待处理")
        XCTAssertEqual(job.currentStage(events: events), "校对与语言专家并行审校")
    }
    @MainActor func testAllExportsContainRealContentAndCanBeReadBack() async throws {
        let root = try location().deletingLastPathComponent()
        let text = "# 风起时\n\n午后的光越过窗沿。\n\n她收到一封信。"
        for ext in ["txt", "md", "pdf", "epub", "docx"] {
            let url = try DocumentIO.export(title: "导出测试-" + UUID().uuidString, text: text, ext: ext, preserveLayout: true, coverData: nil)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            XCTAssertGreaterThan(try Data(contentsOf: url).count, 0)
            let copy = root.appendingPathComponent("readback." + ext)
            try FileManager.default.copyItem(at: url, to: copy)
            let imported = try await DocumentIO.read(copy)
            XCTAssertTrue(imported.text.contains("午后的光越过窗沿"), ext)
            XCTAssertTrue(imported.text.contains("她收到一封信"), ext)
        }
    }
}

final class PaperTypographyTests: XCTestCase {
    @MainActor func testNativeViewportSnapshots() async throws {
        let names = UIFont.familyNames.filter { $0.localizedCaseInsensitiveContains("song") || $0.localizedCaseInsensitiveContains("ming") || $0.localizedCaseInsensitiveContains("mincho") }.flatMap { UIFont.fontNames(forFamilyName: $0) }
        print("PAPER_READING_FONTS: \(names)")
        for width in [320, 375, 390, 430, 768] {
            let studio = StudioStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
            var job = BookJob(title: "长书名排版检查——一部需要完整显示的小说", source: "The text.", format: "TXT")
            job.options.quality = .publication; job.replan(); studio.jobs = [job]
            let root = NavigationStack { JobView(id: job.id) }.environment(studio).environment(CloudAccount()).environment(PurchaseStore()).tint(Ink.accent).preferredColorScheme(.light)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let previous = scene.windows.first { $0.isKeyWindow }
            let window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: root)
            window.rootViewController = host
            window.frame = CGRect(x: 0, y: 0, width: width, height: 844)
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let image = UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in
                XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "viewport-\(width)"; attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
            previous?.makeKeyAndVisible()
        }
    }
}

private actor StoreRecordingProvider: TranslationProvider {
    var requests: [TranslationRequest] = []
    var waiting: CheckedContinuation<Void, Never>?
    var released = false
    func release() { released = true; waiting?.resume(); waiting = nil }
    func complete(_ request: TranslationRequest) async throws -> String {
        requests.append(request)
        if requests.count == 1 && !released { await withCheckedContinuation { waiting = $0 } }
        return request.source
    }
    func extractTerms(source: String, target: String, requestID: String) async throws -> [Term] { [] }
    func resolveTerms(_ query: GlossaryQuery) async throws -> [Term] { [] }
}
final class PaperLiveStoreTests: XCTestCase {
    @MainActor func testLiveStoreUpdatesOnlyLaterUnfrozenChapterAndUsesAutomaticMode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = StudioStore(storageURL: root.appendingPathComponent("studio.json"))
        defer { try? FileManager.default.removeItem(at: root) }
        var job = BookJob(title: "运行中编辑", source: "Chapter I\n\nElizabeth arrived.\n\nChapter II\n\nElizabeth left.", format: "TXT")
        job.terms = [.init(source: "Elizabeth", target: "伊丽莎白", category: .person)]
        job.glossaryMode = .review; job.replan()
        store.jobs = [job]
        let provider = StoreRecordingProvider()
        store.testingProvider = provider
        store.begin(job.id, account: CloudAccount(), purchases: PurchaseStore())
        let deadline = ContinuousClock.now + .seconds(10)
        while await provider.requests.isEmpty {
            if ContinuousClock.now > deadline { XCTFail("First request not dispatched"); await provider.release(); store.pause(); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await store.saveNameOverride(bookID: job.id, termID: "Elizabeth", target: "莉莎")
        await provider.release()
        while store.task != nil {
            if ContinuousClock.now > deadline { XCTFail("Task did not finish"); store.pause(); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let requests = await provider.requests
        let initial = requests.filter { $0.stage == .translate }
        XCTAssertEqual(initial.count, 2)
        XCTAssertEqual(initial[0].options.glossary.first(where: { $0.source == "Elizabeth" })?.target, "伊丽莎白")
        XCTAssertEqual(initial[1].options.glossary.first(where: { $0.source == "Elizabeth" })?.target, "莉莎")
        XCTAssertEqual(store.job(job.id)?.glossaryMode, .accumulated)
        XCTAssertEqual(store.job(job.id)?.status, .complete)
        XCTAssertEqual(store.job(job.id)?.completedChapterCount, 2)
    }
}

final class PaperCompatibilityTests: XCTestCase {
    @MainActor func testPurchasedMetadataDoesNotInventSourceOrTranslationQuality() {
        var job = BookJob(title: "已购译本", source: "只有译文。", format: "MD")
        job.purchasedWorkID = UUID().uuidString; job.status = .complete; job.replan()
        XCTAssertFalse(job.bookMetadata.contains("自动识别"))
        XCTAssertFalse(job.bookMetadata.contains("速读"))
        XCTAssertFalse(job.bookMetadata.contains("→"))
        XCTAssertTrue(job.bookMetadata.contains("已购译本"))
        XCTAssertTrue(job.canRead)
    }
    @MainActor func testUnreadableLibraryCannotBeOverwrittenByImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("studio.json"), original = Data("retained invalid record".utf8)
        try original.write(to: url)
        let store = StudioStore(storageURL: url)
        XCTAssertNotNil(store.libraryLoadError)
        XCTAssertThrowsError(try store.add(.init(title: "新文稿", text: "Hello.", format: "TXT")))
        do { try await store.save(); XCTFail("Unreadable records overwritten") } catch { }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    @MainActor func testManualRepairPauseClearsPendingUIAndPreservesRequestOnResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = StudioStore(storageURL: root.appendingPathComponent("studio.json"))
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "~~~swift\nlet value = 42\n~~~"
        var job = BookJob(title: "补全恢复", source: source, format: "MD")
        job.options = .init(quality: .fast, documentKind: .technical)
        job.replan(); job.status = .needsReview
        let original = TranslationRequest(requestID: job.id + "-0-translate", source: source, context: "", draft: "", stage: .translate, options: job.options)
        job.reviewDraft = .init(original: original, output: "missing", issues: ["missing code"], index: 0)
        store.jobs = [job]
        let provider = StoreRecordingProvider(); store.testingProvider = provider
        let account = CloudAccount(), purchases = PurchaseStore()
        store.repair(job.id, account: account, purchases: purchases)
        let deadline = ContinuousClock.now + .seconds(10)
        while await provider.requests.isEmpty {
            if ContinuousClock.now > deadline { XCTFail("Repair never dispatched"); await provider.release(); store.pause(); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        store.pause(); await provider.release()
        while store.task != nil {
            if ContinuousClock.now > deadline { XCTFail("Repair pause never completed"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(store.pauseRequestedID); XCTAssertTrue(store.processing.isEmpty)
        XCTAssertEqual(store.job(job.id)?.completedChapterCount, 0)
        store.repair(job.id, account: account, purchases: purchases)
        while store.task != nil {
            if ContinuousClock.now > deadline { XCTFail("Repair resume never finished"); store.pause(); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].requestID, requests[1].requestID)
        XCTAssertEqual(requests[0].prompt, requests[1].prompt)
        XCTAssertEqual(store.job(job.id)?.status, .complete)
    }
}

final class PaperReaderStructureTests: XCTestCase {
    @MainActor func testParagraphsDoNotInheritChapterHeadingTypography() {
        let blocks = readerBlocks("# 风起时\n\n午后的光越过窗沿。\n\n她打开了信。")
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks.first?.text, "风起时")
        guard case .heading(1) = blocks[0].kind else { return XCTFail("Missing chapter heading") }
        guard case .prose = blocks[1].kind else { return XCTFail("Prose rendered as a heading") }
        XCTAssertEqual(blocks[1].text, "午后的光越过窗沿。")
    }
    @MainActor func testPoemLineBreaksTablesAndLongCodeFencesRemainIntact() {
        let text = "诗的第一行\n诗的第二行\n\n| 名称 | 数字 |\n| --- | --- |\n| 甲 | 42 |\n\n~~~~swift\n# inside code\n~~~\nlet value = 42\n~~~~"
        let blocks = readerBlocks(text)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].text, "诗的第一行\n诗的第二行")
        guard case .table = blocks[1].kind else { return XCTFail("Table rows lost") }
        XCTAssertEqual(blocks[1].text.components(separatedBy: "\n").count, 3)
        guard case .code = blocks[2].kind else { return XCTFail("Code is prose") }
        XCTAssertEqual(blocks[2].text, "# inside code\n~~~\nlet value = 42")
    }
}
