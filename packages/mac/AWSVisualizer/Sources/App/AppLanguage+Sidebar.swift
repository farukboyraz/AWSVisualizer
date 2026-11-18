import Foundation

/// Text of the sidebar's service right-click menu and its confirmations.
extension AppLanguage {
    var sidebarOpen: String { self == .tr ? "Aç" : "Open" }
    var sidebarOpenNewTab: String { self == .tr ? "Yeni sekmede aç" : "Open in New Tab" }
    var sidebarAddFavorite: String { self == .tr ? "Favorilere ekle" : "Add to Favorites" }
    var sidebarRemoveFavorite: String { self == .tr ? "Favorilerden çıkar" : "Remove from Favorites" }
    var sidebarAddCard: String { self == .tr ? "Dashboard'a kart ekle…" : "Add to Dashboard Cards…" }
    var sidebarCopyName: String { self == .tr ? "Servis adını kopyala" : "Copy Service Name" }
    var sidebarHide: String { self == .tr ? "Kenar çubuğundan kaldır" : "Remove from Sidebar" }
    var sidebarServiceSettings: String { self == .tr ? "Servis seçimi…" : "Service Selection…" }

    var confirmTitle: String { self == .tr ? "Emin misiniz?" : "Are you sure?" }
    var confirmYes: String { self == .tr ? "Evet" : "Yes" }
    var confirmNo: String { self == .tr ? "Hayır" : "No" }

    func sidebarRemoveFavoriteMessage(_ name: String) -> String {
        self == .tr ? "\"\(name)\" favorilerden çıkarılacak." : "\"\(name)\" will be removed from your favorites."
    }

    func sidebarHideMessage(_ name: String) -> String {
        self == .tr
            ? "\"\(name)\" kenar çubuğundan kaldırılacak ve açık sekmeleri kapanacak. Settings › Services'ten tekrar ekleyebilirsiniz."
            : "\"\(name)\" will be removed from the sidebar and its open tabs closed. You can add it back in Settings › Services."
    }

    var sidebarCardLimit: String { self == .tr ? "Kart sınırına ulaşıldı" : "Card limit reached" }
    var sidebarLastService: String { self == .tr ? "Son servis kaldırılamaz" : "The last service can't be removed" }

    /// Service lists: shown while nothing is selected.
    var serviceSelectionEmpty: String {
        self == .tr ? "Kaydetmek için en az bir servis seçin." : "Select at least one service to save."
    }
}
