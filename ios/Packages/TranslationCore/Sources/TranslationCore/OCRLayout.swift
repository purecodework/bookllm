import Foundation

public struct OCRLine: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var text: String
    public var confidence: Double
    /// Normalized coordinates with top-left origin, after image orientation.
    public var x: Double; public var y: Double; public var width: Double; public var height: Double
    public init(id: Int, text: String, confidence: Double, x: Double, y: Double, width: Double, height: Double) {
        self.id = id; self.text = text; self.confidence = confidence
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}
public struct OCRPage: Codable, Sendable, Equatable, Identifiable {
    public var number: Int
    public var text: String
    public var usedOCR: Bool
    public var lines: [OCRLine]
    public var warnings: [String]
    public var confirmedEmpty: Bool?
    public var id: Int { number }
    public var uncertainLines: [OCRLine] { lines.filter { $0.confidence < 0.8 } }
    public init(number: Int, text: String, usedOCR: Bool, lines: [OCRLine] = [], warnings: [String] = [], confirmedEmpty: Bool? = nil) {
        self.number = number; self.text = text; self.usedOCR = usedOCR; self.lines = lines; self.warnings = warnings
        self.confirmedEmpty = confirmedEmpty
    }
}
public struct OCRProgress: Sendable {
    public var completed: Int; public var total: Int; public var recognized: Int
    public init(completed: Int, total: Int, recognized: Int) { self.completed = completed; self.total = total; self.recognized = recognized }
}
public enum OCRLayout {
    public struct Result: Sendable { public var text: String; public var complex: Bool }
    public static func assemble(_ observations: [OCRLine]) -> Result {
        let lines = observations.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            $0.x.isFinite && $0.y.isFinite && $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0
        }
        guard !lines.isEmpty else { return .init(text: "", complex: false) }
        let typical = lines.map(\.height).sorted()[lines.count / 2]
        var gutter: Double?
        var best = 0.0
        for candidate in stride(from: 0.30, through: 0.70, by: 0.025) {
            let body = lines.filter { $0.width < 0.72 }
            let left = body.filter { $0.x + $0.width < candidate - 0.015 }
            let right = body.filter { $0.x > candidate + 0.015 }
            let crossing = body.count - left.count - right.count
            guard left.count >= 3, right.count >= 3, crossing <= max(1, body.count / 10) else { continue }
            let upper = max(left.map(\.y).min() ?? 1, right.map(\.y).min() ?? 1)
            let lower = min(left.map { $0.y + $0.height }.max() ?? 0, right.map { $0.y + $0.height }.max() ?? 0)
            let overlap = lower - upper
            let gap = (right.map(\.x).min() ?? 0) - (left.map { $0.x + $0.width }.max() ?? 1)
            if overlap >= 0.15 && gap >= 0.04 && overlap + gap > best { best = overlap + gap; gutter = candidate }
        }
        func rows(_ values: [OCRLine]) -> [[OCRLine]] {
            let sorted = values.sorted { if $0.y != $1.y { return $0.y < $1.y }; return $0.x < $1.x }
            var result: [[OCRLine]] = []
            for line in sorted {
                if let last = result.last, let anchor = last.first, abs(line.y - anchor.y) <= typical * 0.45 {
                    result[result.count - 1].append(line)
                } else { result.append([line]) }
            }
            return result.map { $0.sorted { $0.x < $1.x } }
        }
        func render(_ values: [OCRLine]) -> String {
            var previousBottom: Double?, output = ""
            for row in rows(values) {
                let top = row.map(\.y).min() ?? 0
                if !output.isEmpty { output += previousBottom.map { top - $0 > typical * 0.85 ? "\n\n" : "\n" } ?? "\n" }
                output += row.map(\.text).joined(separator: "\t")
                previousBottom = row.map { $0.y + $0.height }.max()
            }
            return output
        }
        guard let gutter else { return .init(text: render(lines), complex: rows(lines).filter { $0.count >= 3 }.count >= 3) }
        let alignedRows = rows(lines.filter { $0.width < 0.72 })
        let pairs = alignedRows.filter { row in row.contains { $0.x + $0.width < gutter } && row.contains { $0.x > gutter } }.count
        // A table-like grid keeps cells on the same row. Flag it instead of inventing table semantics.
        let smallCells = lines.filter { $0.width < 0.24 }.count >= lines.count / 2
        if smallCells && pairs >= 3 && Double(pairs) / Double(max(1, alignedRows.count)) >= 0.7 {
            return .init(text: render(lines), complex: true)
        }
        let bridges = lines.filter { $0.x < gutter && $0.x + $0.width >= gutter }.sorted { $0.y < $1.y }
        var remaining = lines.filter { !bridges.map(\.id).contains($0.id) }, parts: [String] = []
        func band(_ values: [OCRLine]) -> String {
            [render(values.filter { $0.x < gutter }), render(values.filter { $0.x >= gutter })].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        for bridge in bridges {
            let before = remaining.filter { $0.y < bridge.y }
            let body = band(before); if !body.isEmpty { parts.append(body) }
            parts.append(bridge.text); remaining.removeAll { $0.y < bridge.y }
        }
        let final = band(remaining); if !final.isEmpty { parts.append(final) }
        return .init(text: parts.joined(separator: "\n\n"), complex: true)
    }
    /// Keep uncertain glyphs as seen. A model must never silently invent OCR repairs.
    public static func usableTextLayer(_ text: String) -> Bool {
        let content = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard content.count >= 80 else { return false }
        let broken = content.filter { $0.value == 0xfffd || (0xe000...0xf8ff).contains($0.value) }.count
        return Double(broken) / Double(content.count) < 0.02 && content.filter { CharacterSet.alphanumerics.contains($0) }.count >= 40
    }
    public static func joined(_ pages: [OCRPage]) -> String {
        pages.sorted { $0.number < $1.number }.map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
    }
}
