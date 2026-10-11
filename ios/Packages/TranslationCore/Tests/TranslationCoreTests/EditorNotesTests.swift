import XCTest
@testable import TranslationCore

final class EditorNotesTests: XCTestCase {
    let note = "⟦编者注:{\"source\":\"break the ice\",\"text\":\"打破初见时的拘谨\"}⟧"
    func testWholeBookFirstOccurrenceIgnoresCompletionOrderAndCase() {
        let first = TextChunk(index: 0, text: "Break the ice.\n", context: "")
        let second = TextChunk(index: 1, text: "Then break the ice again.", context: "")
        let source = first.text + second.text
        XCTAssertEqual(EditorNotes.filter("再次破冰" + note, source: source, chunks: [first, second], index: 1), "再次破冰")
        XCTAssertEqual(EditorNotes.filter("破冰" + note + note, source: source, chunks: [first, second], index: 0), "破冰" + note)
        XCTAssertEqual(EditorNotes.display("破冰" + note), "破冰[编者注：打破初见时的拘谨]")
    }
    func testUnknownSourceKeyIsRemovedAndCodeStaysVerbatim() {
        let chunks = [TextChunk(index: 0, text: "Something else", context: "")]
        XCTAssertEqual(EditorNotes.filter(note, source: "Something else", chunks: chunks, index: 0), "")
        let code = "```text\n" + note + "\n```"
        XCTAssertEqual(EditorNotes.display(code), code)
        XCTAssertEqual(EditorNotes.display("正文⟦编者注:{\"source\":"), "正文")
        XCTAssertEqual(EditorNotes.filter(code, source: code, chunks: [.init(index: 0, text: code, context: "")], index: 0), code)
    }
    func testNotesRemainKeyedForReviewAndResume() throws {
        let source = "break the ice"
        let retained = EditorNotes.filter("破冰" + note, source: source, chunks: [.init(index: 0, text: source, context: "")], index: 0)
        let checkpoint = Checkpoint(index: 0, stage: .translate, text: retained)
        let restored = try JSONDecoder().decode(Checkpoint.self, from: JSONEncoder().encode(checkpoint))
        XCTAssertEqual(restored.text, retained)
        XCTAssertEqual(EditorNotes.filter(restored.text, source: source, chunks: [.init(index: 0, text: source, context: "")], index: 0), retained)
    }
}
