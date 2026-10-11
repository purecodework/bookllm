import Foundation

/// User-supplied limits for an OpenAI-compatible model. These are independent
/// of source chunk size; they apply to the complete messages plus the output.
public struct ModelRequestLimits: Codable, Hashable, Sendable {
    public var contextWindowTokens: Int
    public var maximumOutputTokens: Int
    public init(contextWindowTokens: Int, maximumOutputTokens: Int) {
        self.contextWindowTokens = contextWindowTokens
        self.maximumOutputTokens = maximumOutputTokens
    }
    // Conservative connection defaults, not a claim about any model's capacity.
    public static let standard = Self(contextWindowTokens: 32_768, maximumOutputTokens: 8_192)
    public func validate() throws {
        guard (1_024...10_000_000).contains(contextWindowTokens),
              (128...1_000_000).contains(maximumOutputTokens), maximumOutputTokens < contextWindowTokens else {
            throw TranslationError.message("模型上下文窗口须为 1024–10000000 tokens，最大输出须为 128–1000000 tokens 且小于上下文窗口。")
        }
    }
}

enum RequestBudget {
    struct Prepared: Sendable {
        var system: String
        var input: String
        var maxTokens: Int
        var estimatedInputTokens: Int
        var backgroundReduction: Int = 0
    }
    /// UTF-8 byte estimate rather than Unicode scalars. Without the provider's
    /// tokenizer this is an estimate; keep additional headroom and handle an
    /// explicit provider limit rejection before any accepted generation.
    static func estimatedTokens(_ text: String) -> Int { (text.utf8.count + 2) / 3 }
    static func inputTokens(system: String, input: String) -> Int {
        36 + estimatedTokens(system) + estimatedTokens(input)
    }
    static func prepare(_ original: TranslationRequest, limits: ModelRequestLimits, backgroundReduction: Int = 0) throws -> Prepared {
        try limits.validate()
        var request = original
        var appliedReduction = 0
        // A provider can reject an underestimated payload even when it appears
        // to fit. Each such rejection must actually reduce optional background.
        for _ in 0..<max(0, backgroundReduction) {
            if reduceBackground(&request) { appliedReduction += 1 }
        }
        let sourceTokens = estimatedTokens(request.source)
        // Reserve a complete translation, allowing target-language expansion,
        // or a bounded report. Never make the request fit by cutting its source,
        // draft, glossary, review diagnostics or current-chunk findings.
        let minimumOutput = request.reviewMode == true ? 128 : max(128, sourceTokens + 64)
        let desiredOutput = request.reviewMode == true ? 4_096
            : max(512, sourceTokens * 2 + 256) + (request.glossaryCapture == true ? 1_536 : 0)
        let output = min(desiredOutput, limits.maximumOutputTokens)
        guard minimumOutput <= output else {
            throw TranslationError.message("本段预计完整输出至少需要约 \(minimumOutput) tokens，超过模型最大输出 \(limits.maximumOutputTokens)。请提高模型输出上限或使用更大输出容量的模型；原文与检查点已保留。")
        }
        // A window counts both input and reserved output. Allow 10% headroom
        // (at least 256 tokens) for tokenizer differences and chat framing.
        let inputAllowance = limits.contextWindowTokens - output - max(256, limits.contextWindowTokens / 10)
        for _ in 0..<32 {
            let system = request.prompt, input = request.budgetedInput
            let count = inputTokens(system: system, input: input)
            if count <= inputAllowance { return .init(system: system, input: input, maxTokens: output, estimatedInputTokens: count, backgroundReduction: appliedReduction) }
            if reduceBackground(&request) { appliedReduction += 1 }
            else {
                throw TranslationError.message("完整请求的原文、译稿、提示词、译名与审查意见约需 \(count) 输入 tokens，另需 \(output) 输出 tokens，超过模型窗口 \(limits.contextWindowTokens)。背景已自动收缩；请使用更大窗口的模型。原文与检查点已保留。")
            }
        }
        throw TranslationError.message("无法将完整请求放入此模型窗口，请检查模型容量设置。")
    }
    private static func reduceBackground(_ request: inout TranslationRequest) -> Bool {
        if let chapter = request.chapterContext, !chapter.isEmpty { request.chapterContext = shrink(chapter); return true }
        if !request.context.isEmpty { request.context = shrink(request.context) ?? ""; return true }
        return false
    }
    static func prepare(system: String, input: String, maxTokens: Int, limits: ModelRequestLimits) throws -> Prepared {
        try limits.validate()
        let output = min(maxTokens, limits.maximumOutputTokens)
        let count = inputTokens(system: system, input: input)
        guard count + output + max(256, limits.contextWindowTokens / 10) <= limits.contextWindowTokens else {
            throw TranslationError.message("术语请求超出模型上下文窗口，请使用更大窗口的模型。原术语快照已保留。")
        }
        return .init(system: system, input: input, maxTokens: output, estimatedInputTokens: count)
    }
    private static func shrink(_ text: String) -> String? {
        let scalars = text.unicodeScalars
        guard scalars.count > 256 else { return nil }
        let size = scalars.count / 4
        return "Bounded background excerpts only; omitted passages are unavailable. Never infer gaps.\n"
            + String(String.UnicodeScalarView(scalars.prefix(size)))
            + "\n[…background omitted…]\n"
            + String(String.UnicodeScalarView(scalars.suffix(size)))
    }
}

/// Only explicit window/output rejections may adapt a self-hosted request.
/// Authorization, validation, transport and billing errors keep their behavior.
struct ModelLimitRejection: Error, Sendable {
    var contextWindow: Int?
    var maximumOutput: Int?
    var contextExceeded: Bool
    var outputExceeded: Bool
    static func decode(_ data: Data) -> Self? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return nil }
        let message = (error["message"] as? String ?? "").lowercased()
        let code = (error["code"] as? String ?? "").lowercased()
        let contextExceeded = code == "context_length_exceeded" || code == "context_window_exceeded"
            || message.contains("maximum context length") || message.contains("context window exceeded")
        let outputExceeded = (message.contains("max_tokens") || message.contains("max_completion_tokens") || message.contains("maximum output"))
            && (message.contains("at most") || message.contains("less than") || message.contains("<") || message.contains("too large") || message.contains("maximum") || message.contains("exceed"))
        guard contextExceeded || outputExceeded else { return nil }
        let context = number(in: message, patterns: [#"maximum context length(?: is| of|:)\s*([0-9,]+)"#, #"context window(?: is| of|:)\s*([0-9,]+)"#])
            ?? (error["context_window"] as? Int)
        let inclusiveOutput = number(in: message, patterns: [#"(?:max_tokens|max_completion_tokens)\s*(?:must be|is|:)\s*(?:less than or equal to|<=|at most)\s*([0-9,]+)"#, #"at most\s*([0-9,]+)\s*(?:completion|output) tokens"#, #"maximum output(?: tokens)?(?: is| of|:)\s*([0-9,]+)"#])
        let strictOutput = number(in: message, patterns: [#"(?:max_tokens|max_completion_tokens)\s*(?:must be|is|:)\s*(?:less than|<)\s*([0-9,]+)"#]).map { $0 - 1 }
        let output = inclusiveOutput ?? strictOutput ?? (error["max_output_tokens"] as? Int)
        return .init(contextWindow: context, maximumOutput: output, contextExceeded: contextExceeded, outputExceeded: outputExceeded)
    }
    func reduced(_ current: ModelRequestLimits) throws -> ModelRequestLimits {
        var next = current
        if contextExceeded {
            let observed = contextWindow ?? current.contextWindowTokens / 2
            next.contextWindowTokens = observed < current.contextWindowTokens ? observed : current.contextWindowTokens * 3 / 4
            next.maximumOutputTokens = min(next.maximumOutputTokens, next.contextWindowTokens - 256)
        }
        if outputExceeded { next.maximumOutputTokens = min(next.maximumOutputTokens, current.maximumOutputTokens - 1, maximumOutput ?? current.maximumOutputTokens / 2) }
        do { try next.validate() } catch { throw TranslationError.message("服务商返回的模型窗口或输出上限过小，请核对 API 模型容量设置。") }
        return next
    }
    private static func number(in text: String, patterns: [String]) -> Int? {
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text),
                  let value = Int(text[range].replacingOccurrences(of: ",", with: "")), value > 0 else { continue }
            return value
        }
        return nil
    }
}
