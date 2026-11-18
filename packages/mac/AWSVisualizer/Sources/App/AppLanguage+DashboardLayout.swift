import Foundation

/// Text of the dashboard's layout editor (drag sections into rows).
extension AppLanguage {
    var dashArrange: String { self == .tr ? "Düzeni düzenle" : "Arrange layout" }
    var dashArrangeTitle: String { self == .tr ? "Dashboard düzeni" : "Dashboard layout" }
    var dashArrangeHint: String {
        self == .tr
            ? "Bölümleri sürükleyip bırakın: bir bölümün yanına bırakınca aynı satıra girer (sığdığı kadar), üst ya da alt kenarına bırakınca kendi satırına geçer. S / M / L ile boyutunu (¼, ½ ya da tam satır), göz simgesiyle görünürlüğünü değiştirin. Kutular bölümlerin gerçek oranlarıyla çizilir; her değişiklik hemen kaydedilir."
            : "Drag and drop sections: drop one beside another to share its row (as far as they fit), or on its top or bottom edge to give it a row of its own. S / M / L sets its size (¼, ½ or a full row), the eye shows or hides it. Tiles are drawn in the sections' real proportions; every change is saved right away."
    }
    var dashArrangeDone: String { self == .tr ? "Bitti" : "Done" }
    var dashArrangeReset: String { self == .tr ? "Varsayılan düzen" : "Default layout" }
    var dashArrangeDropHere: String { self == .tr ? "Buraya bırak" : "Drop here" }
    var dashArrangeOff: String { self == .tr ? "kapalı" : "off" }
}
