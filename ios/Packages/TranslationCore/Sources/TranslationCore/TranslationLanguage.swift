import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

public enum TranslationLanguage: String, CaseIterable, Identifiable, Sendable {
    case chinese = "zh", english = "en", japanese = "ja", korean = "ko"
    case french = "fr", german = "de", spanish = "es", russian = "ru"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .chinese: return "中文"
        case .english: return "英语"
        case .japanese: return "日语"
        case .korean: return "韩语"
        case .french: return "法语"
        case .german: return "德语"
        case .spanish: return "西班牙语"
        case .russian: return "俄语"
        }
    }
    public var targetName: String {
        switch self {
        case .chinese: return "简体中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .spanish: return "Español"
        case .russian: return "Русский"
        }
    }
    public static func sourceTitle(_ code: String?) -> String? {
        guard let base = code?.lowercased().split(separator: "-").first else { return nil }
        return Self(rawValue: String(base))?.title
    }
}

public enum SourceLanguageDetection {
    public static func code(for text: String) -> String? {
        #if canImport(NaturalLanguage)
        let sample: String
        if text.count <= 12000 { sample = text }
        else {
            let midpoint = text.index(text.startIndex, offsetBy: text.count / 2)
            let middle = text.index(midpoint, offsetBy: -2000)
            sample = String(text.prefix(4000)) + "\n" + String(text[middle...].prefix(4000)) + "\n" + String(text.suffix(4000))
        }
        guard sample.lazy.filter({ $0.isLetter }).prefix(24).count >= 24 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let language = recognizer.dominantLanguage,
              (recognizer.languageHypotheses(withMaximum: 3)[language] ?? 0) >= 0.5 else { return nil }
        return language.rawValue
        #else
        return nil
        #endif
    }
}
