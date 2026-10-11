import SwiftUI
import TranslationCore

extension Stage {
    var portrait: String {
        switch self { case .translate: "RoleTranslator"; case .proofread: "RoleProofreader"; case .linguist: "RoleLinguist"; case .editor, .verify: "RoleEditor" }
    }
    var responsibility: String {
        switch self {
        case .translate: "忠实传达原作，保留事实、段落与人物声音。"
        case .proofread: "逐段对照原文，检查漏译、错译、名称、数字与术语一致性。"
        case .linguist: "检查外语、习语、语域与人物口吻，核对编者注。"
        case .editor: "整合校对与语言专家意见，依据原文解决冲突，协调节奏与人物声音。"
        case .verify: "沿用旧任务的终审检查点，核对事实与完整性。"
        }
    }
}

extension Quality {
    var usageSummary: String {
        switch self {
        case .fast: "先了解内容，边译边读。完成初译后检查完整性。"
        case .refined: "适合日常阅读。初译后核对原意、遗漏与术语。"
        case .deep: "适合重视习语、外语与人物口吻的内容。增加语言专家审查。"
        case .publication: "适合希望细读的内容。校对与语言专家并行审查，再由主编整合。"
        case .definitive: "旧任务沿用原有翻译、审校与终审检查点。"
        }
    }
    var processSummary: String {
        self == .publication
            ? "初译 → 校对与语言专家并行 → 主编整合 → 完整性检查"
            : stages.map(\.title).joined(separator: " → ") + " → 完整性检查"
    }
}

@MainActor struct TranslationStrengthPicker: View {
    @Binding var selection: Quality
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("翻译质量").font(.headline.weight(.regular))
            QualityTabs(selection: $selection)
            Text(selection.usageSummary).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("quality-usage-summary")
            Text("审校阶段越多，通常模型用量也越多。实际用量受内容、术语整理和重试影响。")
                .font(.caption).foregroundStyle(Ink.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct RolePipelineView: View {
    let quality: Quality
    @State private var details = false
    @ScaledMetric(relativeTo: .caption) private var portraitHeight = 56.0
    private var stages: [Stage] { quality.stages.filter { $0 != .verify } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("参与翻译与审校的模型角色").font(.caption).foregroundStyle(Ink.muted)
            HStack(alignment: .top, spacing: 8) {
                ForEach(stages, id: \.rawValue) { stage in
                    VStack(spacing: 8) {
                        Image(stage.portrait).resizable().scaledToFit().frame(height: min(96, portraitHeight)).accessibilityHidden(true)
                        Text(stage.title).font(.caption).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity)
                }
            }
            DisclosureGroup(isExpanded: $details) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(stages, id: \.rawValue) { stage in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(stage.title).font(.subheadline)
                            Text(stage.responsibility).font(.caption).foregroundStyle(Ink.muted)
                                .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    PaperRule()
                    Text("处理顺序").font(.caption).foregroundStyle(Ink.muted)
                    Text(quality.processSummary).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 16)
            } label: {
                Text("查看角色职责与处理流程").frame(minHeight: 44, alignment: .leading)
            }.font(.subheadline).accessibilityIdentifier("role-pipeline-details")
        }
    }
}
struct QualityTabs: View {
    @Binding var selection: Quality
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var indicator
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Quality.allCases) { quality in
                let selected = selection == quality || (selection == .definitive && quality == .publication)
                Button {
                    guard selection != quality else { return }
                    withAnimation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.32)) { selection = quality }
                } label: {
                    VStack(spacing: 0) {
                        Text(quality.title).font(.subheadline).frame(maxWidth: .infinity).frame(minHeight: 44)
                        ZStack {
                            Rectangle().fill(Ink.line).frame(height: 0.5)
                            if selected {
                                Rectangle().fill(Ink.accent).frame(height: 1.5).matchedGeometryEffect(id: "quality", in: indicator)
                            }
                        }.frame(height: 2)
                    }.foregroundStyle(selected ? Ink.text : Ink.muted).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}
struct RoleEnsemble: View {
    let stages: [Stage]
    var states: [Stage: String] = [:]
    @State private var selected: Stage = .translate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var portraitHeight = 92.0
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack { Text(states.isEmpty ? "模型角色" : "模型处理状态"); Spacer(); Text("点击查看职责") }
                VStack(alignment: .leading, spacing: 6) { Text(states.isEmpty ? "模型角色" : "模型处理状态"); Text("点击查看职责") }
            }.font(.caption).foregroundStyle(Ink.muted)
            HStack(alignment: .top, spacing: 6) {
                ForEach(stages, id: \.rawValue) { stage in
                    Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { selected = stage } } label: {
                        VStack(spacing: 7) {
                            Image(stage.portrait).resizable().scaledToFit().frame(height: min(120, portraitHeight))
                                .opacity(states[stage] == "待处理" ? 0.35 : 1).accessibilityHidden(true)
                            Text(stage.title).font(.caption).foregroundStyle(Ink.text)
                                .padding(.bottom, 5).overlay(alignment: .bottom) { if selected == stage { Rectangle().fill(Ink.accent).frame(height: 1) } }
                            if let status = states[stage] { Text(status).font(.caption).foregroundStyle(Ink.muted) }
                        }.frame(maxWidth: .infinity).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityElement(children: .combine)
                        .accessibilityLabel(stage.title + (states[stage].map { "，" + $0 } ?? ""))
                        .accessibilityHint("查看职责").accessibilityAddTraits(selected == stage ? .isSelected : [])
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .modifier(active: RoleReveal(amount: 0), identity: RoleReveal(amount: 1)).animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.6)),
                            removal: .opacity.animation(.easeOut(duration: 0.18))))
                }
            }.frame(minHeight: states.isEmpty ? 113 : 134, alignment: .top)
                .animation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.52), value: stages)
            PaperRule()
            VStack(alignment: .leading, spacing: 7) {
                Text(selected.title).font(.subheadline)
                Text(selected.responsibility).font(.caption).foregroundStyle(Ink.muted).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            }.frame(minHeight: 66, alignment: .top).id(selected).transition(.opacity)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selected)
        }.onAppear {
            selected = states.isEmpty ? stages.last ?? .translate : stages.first(where: { ["处理中", "检查中", "重试中"].contains(states[$0] ?? "") }) ?? stages.first ?? .translate
        }.onChange(of: stages) { _, value in
            if states.isEmpty { selected = value.last ?? .translate }
            else if !value.contains(selected) { selected = value.first ?? .translate }
        }
    }
}

private struct RoleReveal: AnimatableModifier {
    nonisolated var amount: CGFloat
    nonisolated var animatableData: CGFloat { get { amount } set { amount = newValue } }
    func body(content: Content) -> some View {
        content.opacity(amount).offset(y: (1 - amount) * 6)
            .mask(alignment: .top) { Rectangle().scaleEffect(x: 1, y: amount, anchor: .top) }
    }
}
