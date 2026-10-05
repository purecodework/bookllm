import SwiftUI
import UIKit
import TranslationCore

@MainActor struct QualitySlider: View {
    @Binding var selection: Quality
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragProgress: Double?
    private let thumb: CGFloat = 42
    private let inset: CGFloat = 7
    private var levels: [Quality] { Quality.allCases }
    private var index: Int { levels.firstIndex(of: selection) ?? 0 }
    private var progress: Double { dragProgress ?? Double(index) / Double(levels.count - 1) }
    private var tint: Color { selection == .deep ? Color(red: 0.22, green: 0.47, blue: 0.89) : index >= 3 ? Ink.orange : Ink.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("翻译强度").font(.system(size: 12)).foregroundStyle(Ink.muted)
                    HStack(spacing: 8) {
                        Text(selection.title).font(.system(size: 25, weight: .medium, design: .serif))
                        if index >= 2 { QualityFlame(quality: selection).frame(width: 27, height: 32).transition(.opacity.combined(with: .scale(scale: 0.85))) }
                    }
                }
                Spacer()
                Text("\(selection.stages.count) 轮").font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.muted)
            }
            Text(selection.stages.map(\.title).joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Ink.muted).lineLimit(1).minimumScaleFactor(0.85)
            rail
            HStack(spacing: 0) {
                ForEach(levels) { level in
                    Button { snap(level) } label: {
                        Text(level.title).font(.system(size: 11, weight: level == selection ? .semibold : .regular))
                            .foregroundStyle(level == selection ? tint : Ink.muted).frame(maxWidth: .infinity).frame(height: 44)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("\(level.title)，\(level.stages.count) 轮处理").accessibilityAddTraits(level == selection ? .isSelected : [])
                }
            }.padding(.top, -8)
            HStack(spacing: 8) {
                Text(selection.detail).font(.system(size: 12)).foregroundStyle(Ink.muted)
                Spacer(minLength: 0)
                if selection != .fast { Text("逐章可读").font(.system(size: 10)).foregroundStyle(Ink.muted) }
            }
        }.animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: selection)
    }
    private var rail: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.width - thumb - inset * 2)
            let offset = travel * CGFloat(progress)
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: [Ink.text, tint.opacity(index >= 2 ? 0.8 : 1)], startPoint: .leading, endPoint: .trailing))
                Capsule().stroke(.black.opacity(0.08), lineWidth: 1)
                Capsule().fill(.white).frame(width: thumb + offset, height: thumb).padding(.leading, inset)
                ForEach(levels.indices, id: \.self) { dot in
                    Circle().fill(dot < index ? Ink.text.opacity(0.22) : .white.opacity(0.34)).frame(width: 5, height: 5)
                        .position(x: inset + thumb / 2 + travel * CGFloat(dot) / CGFloat(levels.count - 1), y: 28)
                }
                ZStack {
                    Circle().fill(Ink.text)
                    if index >= 2 { QualityFlame(quality: selection).frame(width: 23, height: 27) }
                    else { Image(systemName: selection == .fast ? "bolt.fill" : "sparkle").font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.9)) }
                }.frame(width: thumb, height: thumb).overlay { Circle().stroke(.white, lineWidth: 2.5) }
                    .shadow(color: tint.opacity(index >= 2 ? 0.22 : 0.08), radius: 7, x: 0, y: 1).padding(.leading, inset + offset)
            }.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let ratio = min(1, max(0, Double((value.location.x - inset - thumb / 2) / travel)))
                    dragProgress = ratio; choose(Int((ratio * Double(levels.count - 1)).rounded()))
                }.onEnded { _ in withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82)) { dragProgress = nil } })
        }.frame(height: 56)
            .animation(reduceMotion || dragProgress != nil ? nil : .spring(response: 0.3, dampingFraction: 0.82), value: selection)
            .accessibilityElement(children: .ignore).accessibilityLabel("翻译强度")
            .accessibilityValue("\(selection.title)，\(selection.stages.map(\.title).joined(separator: "、"))")
            .accessibilityHint("强度越高，审校轮次、耗时与用量越多。")
            .accessibilityAdjustableAction { direction in
                switch direction { case .increment: snap(levels[min(levels.count - 1, index + 1)]); case .decrement: snap(levels[max(0, index - 1)]); @unknown default: break }
            }
    }
    private func snap(_ level: Quality) { withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82)) { dragProgress = nil; choose(levels.firstIndex(of: level) ?? 0) } }
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
    private var strong: Bool { quality == .definitive }
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
#Preview { QualitySlider(selection: .constant(.definitive)).padding(28).background(Ink.paper) }
