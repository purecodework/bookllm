import Foundation

/// Shared semantic chapter markers for classification and source sectioning.
/// Markdown title extraction and code-block handling stay with each caller.
enum FictionChapterHeading {
    static func matches(_ text: String) -> Bool {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.contains(where: { $0.isNewline }) else { return false }
        let chineseNumber = "[零〇一二三四五六七八九十百千万两壹贰叁肆伍陆柒捌玖拾佰仟0-9０-９]+"
        if match(title, "^第" + chineseNumber + "[章卷回].*$") { return true }
        // Keep the existing Arabic/Roman title separators, including a dash.
        if match(title, #"^Chapter[ \t]+(?:[0-9]+|[IVXLCDM]+)(?:[ \t]+.*|[.:：—–-].*)?$"#) { return true }

        let units = "(?:one|two|three|four|five|six|seven|eight|nine)"
        let teens = "(?:ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen)"
        let tens = "(?:twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)"
        let words = "(?:" + tens + "(?:(?:[ \\t]+|[-‐‑])" + units + ")?|" + teens + "|" + units + ")"
        // An attached ASCII hyphen belongs to a word-number compound. Requiring
        // that compound to finish avoids interpreting "twenty-one-year-old" as
        // a chapter marker. A spaced title or colon/dash separator still works.
        return match(title, "^Chapter[ \\t]+" + words + #"(?:[ \t]+.*|[.:：—–].*)?$"#)
    }

    private static func match(_ title: String, _ pattern: String) -> Bool {
        title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
