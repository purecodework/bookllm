import XCTest
@testable import TranslationCore

private actor StrengthProvider: TranslationProvider {
    var requests: [TranslationRequest] = []
    var streams = 0
    func complete(_ request: TranslationRequest) async throws -> String { requests.append(request); return request.source }
    func stream(_ request: TranslationRequest, onPartial: @escaping @Sendable (String) async -> Void) async throws -> String { streams += 1; requests.append(request); await onPartial(request.source); return request.source }
    func extractTerms(source: String, target: String, requestID: String) async throws -> [Term] { [] }
}
final class StrengthTests: XCTestCase, @unchecked Sendable {
    func testFiveLevelsAddOneDistinctReviewAndKeepHistoricalWireValues() throws {
        XCTAssertEqual(Quality.allCases.map(\.title), ["速读", "精译", "深校", "精修", "定稿"])
        for (index, quality) in Quality.allCases.enumerated() {
            XCTAssertEqual(quality.stages, Array(Stage.allCases.prefix(index + 1)))
        }
        XCTAssertEqual(try JSONDecoder().decode(Quality.self, from: Data("\"publication\"".utf8)).stages.last, .editor)
        XCTAssertEqual(Quality.publication.stages.count, 4)
        XCTAssertEqual(Quality.definitive.stages.last, .verify)
    }
    func testLegacyLanguageReviewMapsToDeepWithoutChangingPaidStages() {
        var preferences = TranslationPreferences(); preferences.extraLanguageReview = true
        let old = TranslationOptions(quality: .refined, preferences: preferences)
        XCTAssertEqual(old.effectiveQuality, .deep)
        XCTAssertEqual(old.stages, Quality.deep.stages)
        XCTAssertEqual(TranslationOptions(quality: .refined).effectiveQuality, .refined)
    }
    func testAllFiveLevelsExecuteTheirRealStagesAndOnlyFastStreams() async throws {
        for quality in Quality.allCases {
            let provider = StrengthProvider()
            let options = TranslationOptions(quality: quality, documentKind: .general, sourceWasOCR: true)
            _ = try await TranslationEngine().run(jobID: "strength-\(quality.rawValue)", source: "Alice paid 42 dollars.\n\nShe kept the receipt.", options: options, provider: provider) { _ in }
            let requests = await provider.requests, streams = await provider.streams
            XCTAssertEqual(requests.map(\.stage), quality.stages)
            XCTAssertEqual(streams, quality == .fast ? 1 : 0)
            for (index, request) in requests.enumerated() {
                XCTAssertEqual(request.draft, index == 0 ? "" : requests[index - 1].source)
                XCTAssertTrue(request.prompt.contains(options.style.instruction))
                XCTAssertTrue(request.prompt.contains("OCR source"))
            }
        }
    }
    func testFictionFinishesVerificationPerChapterBeforeStartingNextChapter() async throws {
        let source = "Chapter I\n\nAlice paid 42 dollars.\n\nChapter II\n\nAlice returned with the receipt."
        let provider = StrengthProvider(), options = TranslationOptions(quality: .definitive)
        _ = try await FictionEngine().run(jobID: "final-chapters", source: source, options: options, provider: provider) { _ in }
        let requests = await provider.requests
        XCTAssertEqual(requests.map(\.stage), options.stages + options.stages)
        XCTAssertTrue(Stage.verify.instruction.contains("Correct only demonstrable problems"))
        XCTAssertTrue(Stage.verify.instruction.contains("including unchanged text"))
    }
}
