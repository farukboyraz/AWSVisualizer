import Foundation

/// Text of the tag forms (shared `ResourceTagsEditor`, Lambda, CodeCommit).
extension AppLanguage {
    var tagsTitle: String { self == .tr ? "Etiketler" : "Tags" }
    var tagKeyPlaceholder: String { self == .tr ? "Anahtar" : "Key" }
    var tagValuePlaceholder: String { self == .tr ? "Değer" : "Value" }
    var addTagButton: String { self == .tr ? "Etiket Ekle" : "Add Tag" }
    var removeTagHelp: String { self == .tr ? "Etiketi Kaldır" : "Remove Tag" }

    /// `noun` is the English resource name ("function", "table"); Turkish
    /// uses a neutral sentence instead of mixing languages.
    func noTagsMessage(noun: String) -> String {
        self == .tr ? "Bu kaynakta henüz etiket yok." : "No tags on this \(noun)."
    }
}
