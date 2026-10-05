import SwiftUI
import UIKit
import TranslationCore

@MainActor struct TranslationStrengthPicker: View {
    @Binding var selection: Quality
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresented = false
    @State private var dragProgress: Double?
    private let levels = Quality.allCases
    private var index: Int { levels.firstIndex(of: selection) ?? 0 }
    private var progress: Double { dragProgress ?? Double(index) / Double(levels.count - 1) }

    var body: some View {
        HStack {
            Text("翻译强度").font(.system(size: 14))
            Spacer()
            Button { isPresented.toggle() } label: {
                HStack(spacing: 7) {
                    if index >= 2 { QualityFlame(quality: selection).frame(width: 14, height: 18) }
                    Text(selection.title).font(.system(size: 13, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Ink.muted)
                }
                .padding(.horizontal, 12).frame(height: 36)
                .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).stroke(Ink.text.opacity(0.09), lineWidth: 1) }
                .frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("翻译强度，\(selection.title)")
                .accessibilityHint("打开强度选择器")
                .popover(isPresented: $isPresented, arrowEdge: .top) {
                    optionsPanel
                        .presentationCompactAdaptation(.popover)
                        .presentationBackground(.white)
                }
        }.foregroundStyle(Ink.text)
    }

    private var optionsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("翻译强度").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(selection == .publication ? "协作" : "\(selection.stages.count) 步").font(.system(size: 11)).foregroundStyle(Ink.muted)
            }.padding(.bottom, 13)
            rail
            HStack(spacing: 0) {
                ForEach(levels) { level in
                    Button { snap(level) } label: {
                        Text(level.title).font(.system(size: 11, weight: level == selection ? .semibold : .regular))
                            .foregroundStyle(level == selection ? Ink.text : Ink.muted)
                            .frame(maxWidth: .infinity).frame(height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(level.title)，\(level.stages.count) 轮处理")
                        .accessibilityAddTraits(level == selection ? .isSelected : [])
                }
            }.padding(.horizontal, -10).padding(.top, -10)
            Divider().overlay(Ink.text.opacity(0.04)).padding(.vertical, 11)
            Text(selection.detail).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Text(selection == .publication ? "译者 → 校对＋语言专家 → 主编" : selection.stages.map(\.title).joined(separator: " · "))
                .font(.system(size: 10)).foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
        }.padding(18).frame(width: 286)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: selection)
            .onDisappear { dragProgress = nil }
    }

    private var rail: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.width - 20)
            let offset = travel * CGFloat(progress)
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.text.opacity(0.10)).frame(height: 3).padding(.horizontal, 10)
                Capsule().fill(Ink.text).frame(width: offset, height: 3).padding(.leading, 10)
                ForEach(levels.indices, id: \.self) { tick in
                    Circle().fill(tick <= index ? Ink.text : Color(red: 0.76, green: 0.76, blue: 0.75))
                        .frame(width: 5, height: 5)
                        .position(x: 10 + travel * CGFloat(tick) / CGFloat(levels.count - 1), y: 22)
                }
                Circle().fill(.white).frame(width: 16, height: 16)
                    .overlay { Circle().stroke(Ink.text, lineWidth: 2) }
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    .padding(.leading, 2 + offset)
            }.frame(height: 44).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let ratio = min(1, max(0, Double((value.location.x - 10) / travel)))
                    dragProgress = ratio
                    choose(Int((ratio * Double(levels.count - 1)).rounded()))
                }.onEnded { _ in
                    withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.86)) { dragProgress = nil }
                })
        }.frame(height: 44)
            .animation(reduceMotion || dragProgress != nil ? nil : .spring(response: 0.25, dampingFraction: 0.86), value: selection)
            .accessibilityElement(children: .ignore).accessibilityLabel("翻译强度")
            .accessibilityValue("\(selection.title)，\(selection.stages.map(\.title).joined(separator: "、"))")
            .accessibilityHint("强度越高，审校轮次、耗时与用量越多。")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: snap(levels[min(levels.count - 1, index + 1)])
                case .decrement: snap(levels[max(0, index - 1)])
                @unknown default: break
                }
            }
    }

    private func snap(_ level: Quality) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.86)) {
            dragProgress = nil; choose(levels.firstIndex(of: level) ?? 0)
        }
    }
    private func choose(_ value: Int) {
        guard levels.indices.contains(value), levels[value] != selection else { return }
        selection = levels[value]; UISelectionFeedbackGenerator().selectionChanged()
    }
}

/// Small morphing flame, not a full-screen effect. No animation while inactive or reduced motion is enabled.
struct QualityFlame: View {
    let quality: Quality
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private var blue: Bool { quality == .deep }
    private var strong: Bool { quality == .publication || quality == .definitive }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || scenePhase != .active)) { timeline in
            let time = reduceMotion || scenePhase != .active ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let outer = blue ? Color(red: 0.14, green: 0.37, blue: 0.92) : Color(red: 0.93, green: 0.28, blue: 0.12)
                let inner = blue ? Color(red: 0.36, green: 0.80, blue: 1) : Color(red: 1, green: 0.70, blue: 0.24)
                let wave = sin(time * (strong ? 5.6 : 3.2)) * (strong ? 0.065 : 0.035)
                let frame = CGRect(x: size.width * 0.12, y: size.height * 0.04, width: size.width * 0.76, height: size.height * 0.90)
                context.fill(flame(in: frame, wave: wave), with: .linearGradient(Gradient(colors: [inner, outer]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                let center = CGRect(x: size.width * 0.30, y: size.height * 0.33, width: size.width * 0.42, height: size.height * 0.60)
                context.fill(flame(in: center, wave: -wave * 0.6), with: .linearGradient(Gradient(colors: [.white.opacity(0.96), inner]), startPoint: CGPoint(x: 0, y: center.minY), endPoint: CGPoint(x: 0, y: center.maxY)))
                if strong {
                    for ember in 0..<3 {
                        let cycle = (time * 0.55 + Double(ember) / 3).truncatingRemainder(dividingBy: 1)
                        let x = size.width * (0.28 + Double(ember) * 0.2 + sin(time * 2 + Double(ember)) * 0.04)
                        let y = size.height * (0.5 - cycle * 0.46)
                        context.opacity = reduceMotion ? 0.45 : (1 - cycle) * 0.65
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.6, height: 1.6)), with: .color(inner))
                    }
                }
            }
        }.accessibilityHidden(true).allowsHitTesting(false)
    }
    private func flame(in rect: CGRect, wave: Double) -> Path {
        func point(_ x: Double, _ y: Double) -> CGPoint { .init(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y) }
        var p = Path(); p.move(to: point(0.5, 1))
        p.addCurve(to: point(0.14, 0.48), control1: point(-0.05, 0.97), control2: point(0.02, 0.68))
        p.addCurve(to: point(0.38 + wave, 0.05), control1: point(0.33, 0.34), control2: point(0.48 + wave, 0.22))
        p.addCurve(to: point(0.65, 0.48), control1: point(0.74 + wave, 0.22), control2: point(0.50, 0.40))
        p.addCurve(to: point(0.82, 0.31), control1: point(0.73, 0.46), control2: point(0.82, 0.38))
        p.addCurve(to: point(0.5, 1), control1: point(1.12, 0.72), control2: point(1.00, 0.97))
        p.closeSubpath(); return p
    }
}
#Preview { TranslationStrengthPicker(selection: .constant(.publication)).padding(28).background(Ink.paper) }
