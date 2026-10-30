import Foundation

/// Stable identifiers for translation settings, borrowing the original language palette's labels.
/// A language selects a direction and text-segmentation locale; it does not promise model support.
public nonisolated enum LearningLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case english = "en", spanish = "es", french = "fr", german = "de", italian = "it"
    case portuguese = "pt", dutch = "nl", russian = "ru", chinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja", korean = "ko", hindi = "hi", arabic = "ar"

    public var id: String { rawValue }
}
