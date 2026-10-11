import SwiftUI
import UIKit
import TranslationCore

enum Ink {
    static let paper = Color(hex: 0xF6F4EE)
    static let text = Color(hex: 0x302F2C)
    static let muted = Color(hex: 0x666A60)
    static let accent = Color(hex: 0x525F50)
    static let line = Color(hex: 0xD5D4CC)
    static let track = Color(hex: 0xD7DCCF)
    static let surface = Color(hex: 0xE9EBE3)
    static let attention = Color(hex: 0x806449)
    static let error = Color(hex: 0x975044)
    static let orange = accent
    static let green = accent
}
enum PaperLayout {
    static let libraryWidth: CGFloat = 720
    static let readingWidth: CGFloat = 720
    static let formWidth: CGFloat = 560
}
private extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255) }
}
enum PaperType {
    static func reading(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        for name in ["STSongti-SC-Regular", "SongtiSC-Regular", "Songti SC", "STSong", "HiraMinProN-W3", "HiraginoMinchoProN-W3"] {
            if UIFont(name: name, size: size) != nil { return .custom(name, size: size, relativeTo: style) }
        }
        return .system(size: size, design: .serif)
    }
}
struct PaperBackground: View {
    var textured = true
    var body: some View {
        Ink.paper.overlay {
            if textured { Image("PaperTile").resizable(resizingMode: .tile).blendMode(.multiply).opacity(0.14).accessibilityHidden(true) }
        }.ignoresSafeArea().allowsHitTesting(false)
    }
}
struct PaperCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: 0.5) }
    }
}
struct Eyebrow: View {
    let text: String
    var body: some View { Text(text).font(.caption).foregroundStyle(Ink.muted) }
}
struct PaperButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.99 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
struct PrimaryButton: View {
    let title: String; var icon = "arrow.right"; var secondary = false; var action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @ScaledMetric(relativeTo: .subheadline) private var labelSize = 14.0
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { Text(title); if !icon.isEmpty { Image(systemName: icon).accessibilityHidden(true) } }
                .font(.system(size: labelSize)).frame(maxWidth: .infinity).frame(minHeight: 48)
                .padding(.horizontal, 16).padding(.vertical, 2).foregroundStyle(secondary ? Ink.accent : .white)
                .background(secondary ? Ink.paper : Ink.accent.opacity(enabled ? 1 : 0.5), in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).stroke(secondary ? Ink.line : .clear, lineWidth: 0.7) }
        }.buttonStyle(PaperButtonStyle())
    }
}
struct PaperIconButton: View {
    let symbol: String; let label: String; var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 21, weight: .light)).frame(width: 44, height: 44).contentShape(Rectangle()) }
            .buttonStyle(PaperButtonStyle()).foregroundStyle(Ink.accent).accessibilityLabel(label)
    }
}
struct PaperRule: View {
    var body: some View { Rectangle().fill(Ink.line).frame(height: 0.5).accessibilityHidden(true) }
}
@MainActor struct BookCover: View {
    let title: String
    var large = false
    var index = 0
    var coverKey: String? = nil
    var compact = false
    var body: some View {
        Group {
            if let image = CoverStorage.image(for: coverKey) { Image(uiImage: image).resizable().scaledToFit() }
            else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(PaperType.reading(large ? 20 : 13)).lineLimit(large ? 5 : 4)
                    Spacer(minLength: 0)
                    Text("译间").font(.system(size: 9)).foregroundStyle(Ink.muted)
                }.padding(large ? 16 : 10).frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(Ink.text).background(Ink.surface)
                    .overlay { Rectangle().stroke(Ink.line, lineWidth: 0.5) }
            }
        }.frame(width: large ? 126 : compact ? 60 : 78, height: large ? 179 : compact ? 85 : 111).accessibilityHidden(true)
    }
}
struct ThinkingDots: View {
    var body: some View { ProgressView().controlSize(.mini).tint(Ink.accent).accessibilityLabel("正在处理") }
}

struct PaperToolbarItem<Content: View>: ToolbarContent {
    let placement: ToolbarItemPlacement
    @ViewBuilder var content: Content
    @ToolbarContentBuilder var body: some ToolbarContent {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: placement) { content }.sharedBackgroundVisibility(.hidden)
        } else { ToolbarItem(placement: placement) { content } }
        #else
        ToolbarItem(placement: placement) { content }
        #endif
    }
}
