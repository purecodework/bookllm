import XCTest
@testable import TranslationCore

private actor PaperFixture: TranslationProvider {
    var requests: [TranslationRequest] = []
    var events: [ProcessingEvent] = []
    var snapshots: [Int: [Term]] = [:]
    var overrides: [String: String] = [:]
    var failure = false
    func failCoverage() { failure = true }
    func changeName(_ value: String) { overrides["Elizabeth"] = value }
    func record(_ event: ProcessingEvent) { events.append(event) }
    func save(_ index: Int, _ terms: [Term]) { snapshots[index] = terms }
    func complete(_ request: TranslationRequest) async throws -> String {
        requests.append(request)
        if failure { return "missing structure" }
        if request.reviewMode == true { return CollaborationPrompts.json(ReviewReport(findings: [])) }
        return request.source
    }
    func extractTerms(source: String, target: String, requestID: String) async throws -> [Term] { [] }
    func resolveTerms(_ query: GlossaryQuery) async throws -> [Term] { [] }
}
final class PaperIntegrationTests: XCTestCase, @unchecked Sendable {
    func testParallelReviewEventsAreActualRequestsAndCheckpointsEndThem() async throws {
        let fixture = PaperFixture()
        _ = try await TranslationEngine().run(jobID: "roles", source: "Elizabeth waited.", options: .init(quality: .publication), provider: fixture, onEvent: { await fixture.record($0) }) { _ in }
        let events = await fixture.events
        for stage in [.translate, .proofread, .linguist, .editor] as [Stage] {
            XCTAssertTrue(events.contains { $0.stage == stage && $0.state == .started })
            XCTAssertTrue(events.contains { $0.stage == stage && $0.state == .checking })
            XCTAssertTrue(events.contains { $0.stage == stage && $0.state == .finished })
        }
        let editor = try XCTUnwrap(events.firstIndex { $0.stage == .editor && $0.state == .started })
        XCTAssertTrue(events[..<editor].contains { $0.stage == .proofread && $0.state == .finished })
        XCTAssertTrue(events[..<editor].contains { $0.stage == .linguist && $0.state == .finished })
    }
    func testCoverageFailureCannotEmitCompletedContent() async throws {
        let fixture = PaperFixture(); await fixture.failCoverage()
        do {
            _ = try await TranslationEngine().run(jobID: "coverage", source: "~~~swift\nlet value = 42\n~~~", options: .init(quality: .fast, documentKind: .technical), provider: fixture, onEvent: { await fixture.record($0) }) { _ in XCTFail("Unchecked checkpoint") }
            XCTFail("Expected failed integrity check")
        } catch is CoverageFailure { }
        let events = await fixture.events
        XCTAssertFalse(events.contains { $0.state == .finished })
    }
    func testEditedNameAppliesOnlyToNewSnapshotsAndResumeKeepsPaidPayload() async throws {
        let fixture = PaperFixture()
        let chunks = [TextChunk(index: 0, text: "Elizabeth waited.", context: ""), TextChunk(index: 1, text: "Elizabeth returned.", context: "")]
        func wrapper(_ saved: [Int: [Term]] = [:]) -> EfficientGlossaryProvider {
            .init(provider: fixture, jobID: "names", chunks: chunks, sections: [0, 1], kind: .fiction, target: "简体中文", seed: [Term(source: "Elizabeth", target: "伊丽莎白", category: .person)], snapshots: saved,
                  nameOverrides: { await fixture.overrides }, onQuery: { _, _ in }, onRejected: { _, _ in },
                  onSnapshot: { await fixture.save($0, $1) }, onDiscovery: { _, _ in })
        }
        func request(_ index: Int, _ stage: Stage = .translate) -> TranslationRequest {
            .init(requestID: "names-\(index)-\(stage.rawValue)", source: chunks[index].text, context: "", draft: "", stage: stage, options: .init(), chunkIndex: index)
        }
        let provider = wrapper()
        _ = try await provider.complete(request(0))
        await fixture.changeName("莉莎")
        _ = try await provider.complete(request(0, .proofread))
        _ = try await provider.complete(request(1))
        let saved = await fixture.snapshots
        XCTAssertEqual(saved[0]?.first?.target, "伊丽莎白")
        XCTAssertEqual(saved[1]?.first?.target, "莉莎")
        await fixture.changeName("第三种译名")
        _ = try await wrapper(saved).complete(request(0))
        let requests = await fixture.requests
        XCTAssertEqual(requests[0].options.glossary, requests[1].options.glossary)
        XCTAssertEqual(requests[0].prompt, requests[3].prompt)
        XCTAssertEqual(requests[0].requestID, requests[3].requestID)
    }
    func testOverrideRetainsNicknameAndEvidenceWithoutLinkingWording() {
        let name = Term(source: "Eleanor", target: "埃莉诺", category: .person, entityID: "person", aliases: ["Nell"], evidence: "Eleanor was called Nell.")
        let nickname = Term(source: "Nell", target: "内尔", category: .person, entityID: "person")
        let values = NameOverrides.applying([name.id: "艾琳"], to: [name, nickname])
        XCTAssertEqual(values[0].target, "艾琳")
        XCTAssertEqual(values[0].aliases, name.aliases)
        XCTAssertEqual(values[0].evidence, name.evidence)
        XCTAssertEqual(values[0].entityID, name.entityID)
        XCTAssertEqual(values[1], nickname)
    }
    func testFullySavedResumeDoesNotEmitNewProcessingOrCallProvider() async throws {
        let fixture = PaperFixture()
        let options = TranslationOptions(quality: .publication)
        let checkpoints = options.stages.map { stage in
            Checkpoint(index: 0, stage: stage, text: [.proofread, .linguist].contains(stage) ? CollaborationPrompts.json(ReviewReport(findings: [])) : "Elizabeth waited.")
        }
        _ = try await TranslationEngine().run(jobID: "saved", source: "Elizabeth waited.", options: options, provider: fixture, checkpoints: checkpoints, onEvent: { await fixture.record($0) }) { _ in XCTFail("Already completed") }
        let requests = await fixture.requests, events = await fixture.events
        XCTAssertTrue(requests.isEmpty); XCTAssertTrue(events.isEmpty)
    }
}
