import Foundation
import TranslationCore

/// Derived from the existing document store; no second task state.
extension BookJob {
    var finalChunkIndices: Set<Int> {
        guard let final = options.stages.last else { return [] }
        return Set(checkpoints.filter { $0.stage == final && !EditorNotes.display($0.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.index))
    }
    var canExport: Bool { !finalChunkIndices.isEmpty }
    func chapterReadingState(_ chapter: ReadingChapter, events: [ProcessingEvent] = [], liveChunkIndices: Set<Int> = []) -> ChapterReadingState {
        let indices = Set(chapter.chunks)
        let complete = status == .complete || (!indices.isEmpty && indices.isSubset(of: finalChunkIndices))
        let available = status == .complete || options.quality == .fast || readableChapters.contains { $0.id == chapter.id }
        if complete {
            return .init(label: "已完成", detail: available ? "可阅读" : "等待前章完成后开放阅读", canRead: available)
        }
        let current = events.filter { indices.contains($0.chunkIndex) && $0.state != .finished && $0.state != .failed }
        let started = checkpoints.contains { indices.contains($0.index) } || !indices.isDisjoint(with: liveChunkIndices) || !current.isEmpty
        if !current.isEmpty {
            return .init(label: currentStage(events: current), detail: options.quality == .fast ? "初译实时更新，尚未完成检查" : "完成审校与完整性检查后可阅读", canRead: available)
        }
        let label: String
        if !started { label = "未开始" }
        else if status == .paused { label = "已暂停" }
        else if status == .awaitingCredits { label = "等待充值" }
        else if status == .needsReview { label = "需要核对" }
        else if status == .failed { label = "需要重试" }
        else { label = "处理中" }
        return .init(label: label, detail: options.quality == .fast ? "速读可先查看原文，译文完成后更新" : "完成审校与完整性检查后可阅读", canRead: available)
    }
    var canRead: Bool {
        status == .complete || !readableChapters.isEmpty ||
        (options.quality == .fast && [.translating, .paused, .failed, .awaitingCredits, .needsReview].contains(status) && !checkpoints.isEmpty)
    }
    var completedChapterCount: Int { status == .complete ? chapters.count : readableChapters.count }
    var chapterProgress: Double { chapters.isEmpty ? 0 : Double(completedChapterCount) / Double(chapters.count) }
    var chapterSummary: String { chapters.isEmpty ? "已完成 \(completedChapterCount) 章" : "已完成 \(completedChapterCount) / \(chapters.count) 章" }
    var bookMetadata: String {
        let target = TranslationLanguage.allCases.first { $0.targetName == options.targetLanguage }?.title ?? options.targetLanguage
        if purchasedWorkID != nil { return "已购译本 · " + target }
        return [options.documentKind == .general ? nil : options.documentKind.title, options.effectiveQuality.title, "\(sourceLanguage ?? "自动识别") → \(target)"].compactMap { $0 }.joined(separator: " · ")
    }
    var libraryState: String {
        if purchasedWorkID != nil { return "已购译本 · 可离线阅读" }
        switch status {
        case .draft: return "未开始翻译"
        case .paused: return pauseReason ?? "已暂停"
        case .complete: return "已完成 · \(chapters.count) 章"
        case .reviewing: return "旧任务需要继续 · 沿用已保存译名"
        case .awaitingCredits: return "余额不足 · 充值后继续"
        case .needsReview: return "完整性检查需要核对"
        case .failed: return error ?? "处理失败，请重试"
        default: return statusText
        }
    }
    func roleStates(events: [ProcessingEvent]) -> [Stage: String] {
        let active = events.filter { $0.chunkIndex >= 0 }
        let chapter = chapters.first { chapter in active.contains { chapter.chunks.contains($0.chunkIndex) } } ?? chapters.first { chapter in !readableChapters.contains { $0.id == chapter.id } }
        let scope = Set(chapter?.chunks ?? Array(0..<chunkCount))
        return Dictionary(uniqueKeysWithValues: options.stages.filter { $0 != .verify }.map { stage in
            let events = active.filter { $0.stage == stage && scope.contains($0.chunkIndex) }
            let count = checkpoints.filter { $0.stage == stage && scope.contains($0.index) }.count
            let label: String
            if !scope.isEmpty && count == scope.count { label = "已完成" }
            else if status == .paused { label = "已暂停" }
            else if status == .failed || status == .needsReview { label = events.isEmpty ? "待处理" : "需要处理" }
            else if events.contains(where: { $0.state == .retrying }) { label = "重试中" }
            else if events.contains(where: { $0.state == .checking }) { label = "检查中" }
            else if events.contains(where: { $0.state == .started }) { label = "处理中" }
            else { label = count > 0 ? "部分完成" : "待处理" }
            return (stage, label)
        })
    }
    func currentStage(events: [ProcessingEvent]) -> String {
        let stages = Set(events.filter { $0.state != .finished && $0.state != .failed }.map(\.stage))
        if options.usesCollaborativeEditing && stages.contains(.proofread) && stages.contains(.linguist) { return "校对与语言专家并行审校" }
        if stages.count > 1 { return options.stages.filter { stages.contains($0) }.map(\.title).joined(separator: "、") + "处理中" }
        if events.contains(where: { $0.state == .checking }) { return "完整性检查" }
        if let stage = options.stages.first(where: { stages.contains($0) }) { return stage.title + "处理中" }
        return libraryState
    }
}

struct ChapterReadingState: Equatable {
    var label: String
    var detail: String
    var canRead: Bool
}
