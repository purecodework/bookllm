import SwiftUI
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
struct BookCover: View {
    let title: String; var large = false; var index = 0
    private var shade: Color { [Color(red: 0.27, green: 0.39, blue: 0.33), Color(red: 0.71, green: 0.40, blue: 0.30), Color(red: 0.30, green: 0.37, blue: 0.44)][abs(index) % 3] }
    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [shade, shade.opacity(0.84)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(.black.opacity(0.12)).frame(width: 6).frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                Text("译 间 藏 书").font(.system(size: large ? 8 : 5, weight: .medium)).tracking(large ? 3 : 1)
                Spacer()
                Text(title).font(.system(size: large ? 24 : 12, weight: .medium, design: .serif)).lineLimit(large ? 4 : 3)
                Rectangle().fill(.white.opacity(0.55)).frame(width: large ? 26 : 16, height: 1)
                Text("BOOKLLM").font(.system(size: large ? 7 : 4, design: .monospaced)).tracking(1)
            }.padding(large ? 18 : 10).foregroundStyle(.white.opacity(0.9))
        }.frame(width: large ? 126 : 65, height: large ? 172 : 90).clipShape(RoundedRectangle(cornerRadius: 5)).shadow(color: .black.opacity(0.12), radius: 10, x: 3, y: 6).accessibilityHidden(true)
    }
}
struct EffortBars: View {
    let quality: Quality
    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<4) { i in RoundedRectangle(cornerRadius: 2).fill(i < (quality == .fast ? 1 : quality == .refined ? 2 : 4) ? Ink.orange : Ink.line).frame(width: 4, height: CGFloat(6 + i * 4)) }
        }.accessibilityLabel(quality.title)
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
