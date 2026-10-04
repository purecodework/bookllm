import SwiftUI
import UIKit
import TranslationCore

enum Ink {
    static let paper = Color(red: 0.973, green: 0.965, blue: 0.945)
    static let text = Color(red: 0.16, green: 0.17, blue: 0.16)
    static let muted = Color(red: 0.49, green: 0.49, blue: 0.46)
    static let orange = Color(red: 0.87, green: 0.38, blue: 0.24)
    static let line = Color(red: 0.88, green: 0.87, blue: 0.84)
    static let green = Color(red: 0.28, green: 0.44, blue: 0.38)
}
struct PaperCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 22)).overlay { RoundedRectangle(cornerRadius: 22).stroke(Ink.line.opacity(0.65), lineWidth: 1) } }
}
struct Eyebrow: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(Ink.muted) }
}
struct PrimaryButton: View {
    let title: String; var icon = "arrow.right"; var action: () -> Void
    var body: some View {
        Button(action: action) { HStack { Text(title); Spacer(); Image(systemName: icon) }.font(.system(size: 16, weight: .semibold)).padding(19).foregroundStyle(.white).background(Ink.text, in: RoundedRectangle(cornerRadius: 18)) }
        .buttonStyle(.plain)
    }
}
@MainActor struct BookCover: View {
    let title: String
    var large = false
    var index = 0
    var coverKey: String? = nil
    private var shade: Color { [Color(red: 0.27, green: 0.39, blue: 0.33), Color(red: 0.71, green: 0.40, blue: 0.30), Color(red: 0.30, green: 0.37, blue: 0.44)][abs(index) % 3] }
    var body: some View {
        Group {
            if let image = CoverStorage.image(for: coverKey) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ZStack(alignment: .leading) {
                    LinearGradient(colors: [shade, shade.opacity(0.84)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Rectangle().fill(.black.opacity(0.12)).frame(width: 5)
                    VStack(alignment: .leading, spacing: 10) {
                        Spacer()
                        Text(title).font(.system(size: large ? 23 : 12, weight: .medium, design: .serif)).lineLimit(large ? 4 : 3)
                        Rectangle().fill(.white.opacity(0.5)).frame(width: large ? 26 : 16, height: 1)
                    }.padding(large ? 18 : 10).foregroundStyle(.white.opacity(0.9))
                }
            }
        }.frame(width: large ? 126 : 65, height: large ? 172 : 90).background(Ink.paper).clipShape(RoundedRectangle(cornerRadius: 4)).shadow(color: .black.opacity(0.09), radius: 5, x: 1, y: 3).accessibilityHidden(true)
    }
}

@MainActor struct QualitySlider: View {
    @Binding var selection: Quality
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragProgress: Double?
    private let thumbSize: CGFloat = 36
    private let inset: CGFloat = 6
    private var qualities: [Quality] { Quality.allCases }
    private var selectedIndex: Int { qualities.firstIndex(of: selection) ?? 0 }
    private var progress: Double { dragProgress ?? Double(selectedIndex) / Double(max(1, qualities.count - 1)) }

    var body: some View {
        VStack(spacing: 9) {
            GeometryReader { geometry in
                let travel = max(1, geometry.size.width - thumbSize - inset * 2)
                let offset = travel * CGFloat(progress)
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.text)
                    Capsule().fill(.white).frame(width: thumbSize + offset, height: thumbSize).padding(.leading, inset)
                    ForEach(qualities.indices, id: \.self) { index in
                        Circle().fill(index < selectedIndex ? Ink.text.opacity(0.55) : .white.opacity(0.5))
                            .frame(width: 4, height: 4)
                            .position(x: inset + thumbSize / 2 + travel * CGFloat(index) / CGFloat(max(1, qualities.count - 1)), y: 24)
                    }
                    Circle().fill(Ink.text).overlay { Circle().stroke(.white, lineWidth: 2.5) }
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 1)
                        .padding(.leading, inset + offset)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let value = min(1, max(0, Double((value.location.x - inset - thumbSize / 2) / travel)))
                        dragProgress = value
                        choose(Int((value * Double(qualities.count - 1)).rounded()))
                    }
                    .onEnded { value in
                        let position = min(1, max(0, Double((value.location.x - inset - thumbSize / 2) / travel)))
                        choose(Int((position * Double(qualities.count - 1)).rounded()))
                        withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.85)) { dragProgress = nil }
                    })
            }.frame(height: 48)
            HStack {
                Text(qualities[0].title)
                Spacer()
                Text(qualities[1].title)
                Spacer()
                Text(qualities[2].title)
            }.font(.system(size: 12)).foregroundStyle(Ink.muted).padding(.horizontal, 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("翻译强度")
        .accessibilityValue(selection.title)
        .accessibilityAdjustableAction { direction in
            let next: Int
            switch direction {
            case .increment: next = min(qualities.count - 1, selectedIndex + 1)
            case .decrement: next = max(0, selectedIndex - 1)
            @unknown default: return
            }
            withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.85)) { choose(next) }
        }
    }

    private func choose(_ index: Int) {
        guard qualities.indices.contains(index), qualities[index] != selection else { return }
        selection = qualities[index]
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
struct ThinkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.4, paused: reduceMotion)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) { ForEach(0..<3) { i in Circle().fill(Ink.orange).frame(width: 4, height: 4).opacity(reduceMotion ? 0.7 : 0.3 + 0.7 * (sin(phase * 3 - Double(i)) + 1) / 2) } }
        }.accessibilityLabel("正在处理")
    }
}
